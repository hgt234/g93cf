# Proxmox GPU AVD Hybrid deployment runbook

This runbook adds a Proxmox-hosted Windows 11 Enterprise GPU desktop to the existing Azure Virtual Desktop POC. It does not provision, start, stop, or delete the Proxmox VM. The guest uses outbound HTTPS for Azure Arc, Entra ID, Intune, Microsoft Defender for Endpoint, Windows Update, and AVD. No inbound internet rule, public IP, VPN Gateway, NAT Gateway, or Bastion resource is created for the hybrid desktop.

## 1. Register providers and deploy the isolated Azure foundation

Run `scripts/Register-AvdResourceProviders.ps1` with the target subscription. It now includes `Microsoft.HybridCompute` and does not unregister anything.

Update `infra/parameters/hybrid-poc.bicepparam` with the existing AVD workspace resource group/name. Create a pipeline from `pipelines/azure-pipelines-hybrid-platform.yml`, then run it with the privileged platform service connection. The what-if gate rejects `Delete` and `Recreate`; deployment uses incremental mode.

Expected Azure resources:

- resource group `rg-avd-hybrid-poc01` with `ManagedBy=AzureVirtualDesktopPoc`, `PocId=POC01`, and `HostingPlatform=Proxmox`;
- personal/direct host pool `vdpool-avd-hybrid-poc01` with a system-assigned identity;
- desktop application group `vdag-avd-hybrid-poc01` added to the existing workspace;
- Reader for the host-pool identity at the dedicated hybrid resource group.

The Azure-hosted host pool is unchanged.

## 2. Bootstrap no-delete workload identities

Use workload identity federation for three Azure DevOps service connections. Run `pipelines/azure-pipelines-hybrid-access.yml` once with a privileged, approval-protected bootstrap connection and the three service-principal object IDs.

- deployment identity: Arc machine/extension read-write plus AVD host-pool registration-token operations;
- readiness identity: Arc machine, extension, and fixed Run Command read-write plus AVD read;
- assignment identity: exact resource role-assignment write plus AVD personal-host assignment write.

The custom roles contain no delete actions. The readiness service principal also needs tenant-level application permissions and admin consent for Microsoft Graph `Device.Read.All` and `DeviceManagementManagedDevices.Read.All`, and Defender for Endpoint `Machine.Read.All`. The readiness and assignment identities each need `User.Read.All` because preflight and final assignment resolve the requested Entra user. Keep these permissions off the ServiceNow integration account.

## 3. Build the persistent Proxmox VM manually

Create a persistent Windows 11 Enterprise 24H2 or later, single-session VM with the already-tested Intel mediated-GPU configuration. Before Arc onboarding:

1. Derive the exact hostname from the RITM: `RITM1234` becomes `AVD1234`. Preserve leading zeros.
2. Configure vTPM, Secure Boot where supported, the QEMU guest agent, current Intel GPU driver, and a vaulted local break-glass administrator.
3. Confirm the display adapter has Device Manager error code 0 and `dxdiag` reports the Intel GPU.
4. Apply the RDP policies `bEnumerateHWBeforeSW=1` and `AVCHardwareEncodePreferred=1` under `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`, preferably through Intune after enrollment.
5. Confirm outbound DNS, NTP, and HTTPS to the documented Azure Arc, AVD, Entra, Intune, MDE, Windows Update, and application endpoints.
6. Confirm there is no inbound internet exposure and no public IP associated with the guest.

Do not clone an already enrolled or Arc-connected guest. The VM name must be set before enrollment.

## 4. Connect the guest to Azure Arc

Create a temporary service principal scoped only to `rg-avd-hybrid-poc01` with the built-in **Azure Connected Machine Onboarding** role. Use a short credential lifetime and do not put it in the VM template.

On the VM, install the current Azure Connected Machine agent and run the portal-generated onboarding command with:

- the target tenant and subscription;
- `rg-avd-hybrid-poc01` and the configured Azure region;
- the exact `AVD<digits>` resource name;
- the temporary onboarding service principal.

Verify the Arc machine shows `Connected`, then remove the temporary credential/service principal according to the POC credential procedure. The onboarding pipeline starts only after this point.

## 5. Create and secure the Entra/Intune provisioning package

Use Windows Configuration Designer to create a provisioning package for Entra bulk join and Intune enrollment. Bulk tokens expire after 180 days, so record both creation and expiration UTC values.

1. Store the `.ppkg` in a private Azure Storage container outside any image or repository.
2. Disable anonymous blob access and restrict who can read the container.
3. Record the package SHA-256 hash in the `avd-poc-hybrid` variable group.
4. Before a run, issue a short-lived, read-only HTTPS SAS and save it as the secret `AVD_HYBRID_PPKG_SAS_URI`.
5. Record `AVD_HYBRID_PPKG_CREATED_UTC` and `AVD_HYBRID_PPKG_EXPIRES_UTC`.

The pipeline refuses onboarding with fewer than 30 days remaining, passes the SAS only as a protected Arc Run Command parameter, verifies SHA-256 inside the guest, removes the local package, and never publishes the package as an artifact.

## 6. Configure Intune and Defender policy

Target the hybrid device population with device-based assignments for:

- Windows security baseline and compliance;
- Microsoft Defender for Endpoint onboarding;
- required corporate applications;
- Windows Update rings;
- RDP hardware graphics adapter and H.264/AVC hardware encoding policies.

Do not put tenant identity, MDE onboarding state, or Intune enrollment into the Proxmox source VM. The readiness job waits for the enrolled device, required compliance, active MDE state, installed applications, and graphics settings.

## 7. Configure Azure DevOps

Create the `avd-poc-hybrid` variable group from `config/avd-poc-hybrid.variables.example.yml`; mark the SAS URI secret. Create the onboarding pipeline from `pipelines/azure-pipelines-hybrid-onboard.yml` and allow only the controlled hybrid service connections.

The pipeline accepts only:

```text
ritmNumber
ritmSysId
requestedHostName
requestedForUpn
```

It validates the request, validates the connected Arc machine, enrolls the guest, installs `AADLoginForWindows` and `Microsoft.AzureVirtualDesktop.CloudDeviceExtension`, waits for every readiness gate, grants `Virtual Machine User Login` and `Desktop Virtualization User`, directly assigns the user to the personal host, and updates ServiceNow.

The hosted Azure DevOps agent never needs a route to the Proxmox network; guest checks run through Arc Run Command. A failure requests AVD drain mode, records the failed stage and run URL, and preserves the VM.

## 8. Configure the ServiceNow catalog item

Create a separate catalog item named **Hybrid GPU Desktop**. Do not expose Azure identifiers, host-pool names, service connections, package locations, or hashes as requester variables.

Create a REST Message named `Azure DevOps AVD Hybrid` targeting the Runs API for `azure-pipelines-hybrid-onboard.yml`. Use `servicenow/Queue-AvdHybridPipeline.js` in a Flow Designer custom Action. Map these `sc_req_item` fields:

- `u_avd_build_status`;
- `u_avd_hostname`;
- `u_avd_platform`, set to `Hybrid GPU`;
- optional ADO run ID and URL fields.

Use a short-lived Azure DevOps PAT with only **Build: Read & execute** for the developer instance, then move to an Entra-backed integration identity. Give the callback account access only to the mapped RITM fields and work notes.

## 9. Test and hand off

Run these tests before declaring the POC successful:

- reject `RITM1234` paired with `AVD9999`;
- reject an absent/disconnected Arc machine and a PPKG with fewer than 30 days remaining;
- prove Arc reconnects after the enrollment reboot;
- prove Entra join, enabled device, Intune compliance, active MDE, required apps, healthy Intel GPU, DirectX detection, and both RDP graphics policies;
- connect with Windows App and verify the requested user receives the directly assigned personal desktop;
- exercise the graphics workload and verify Intel rendering/hardware encoding;
- reboot the Proxmox VM and repeat readiness;
- verify no public IP or inbound firewall rule was introduced;
- rerun the same RITM and confirm no duplicate Arc, Entra, Intune, or AVD object is created;
- force an extension failure and confirm drain mode, ServiceNow `Failed`, and VM preservation.

The readiness JSON pipeline artifact captures the GPU driver version and all gate evidence, but never contains the PPKG or SAS URI.

## 10. Decommission safely

Create a pipeline from `pipelines/azure-pipelines-hybrid-decommission.yml` and protect environment `avd-poc-hybrid-decommission` with an approval. First run with `execute: false` and inspect the exact inventory artifact.

Execution requires all of the following:

- matching `ManagedBy`, `PocId`, and `HostingPlatform=Proxmox` tags;
- exact RITM-to-hostname match;
- `execute: true`;
- exact confirmation `DELETE HYBRID POC01` (substitute the real POC ID);
- environment approval.

The script drains and unregisters the exact session host, removes its exact login assignments, disconnects the Arc agent when reachable, removes the dedicated hybrid Azure resource group and exact hybrid custom roles, and leaves the Proxmox VM intact. No hybrid deletion exists in Bicep or the onboarding pipeline.

## Product boundaries

AVD Hybrid supplies the AVD control-plane connection for Arc-enabled session hosts. Proxmox remains responsible for VM creation, GPU configuration, power state, recovery, and deletion. Autoscale and Start VM on Connect are disabled for the hybrid host pool. Obtain the tenant-specific AVD Hybrid per-user service quote from the Microsoft account team before production use.

Microsoft references:

- [Azure Virtual Desktop Hybrid overview](https://learn.microsoft.com/azure/virtual-desktop/hybrid-overview)
- [Deploy Azure Virtual Desktop Hybrid](https://learn.microsoft.com/azure/virtual-desktop/deploy-azure-virtual-desktop-hybrid)
- [Azure Virtual Desktop pricing](https://azure.microsoft.com/pricing/details/virtual-desktop/)
