# Azure Virtual Desktop POC end-to-end solution guide

This guide explains the implemented Azure-hosted personal desktop path, its supporting image factory, ServiceNow integration, operational controls, and teardown. The repository also contains an isolated Proxmox GPU AVD Hybrid path; it is summarized where it affects shared operations and is documented in detail in the [hybrid runbook](../HYBRID-DEPLOYMENT-RUNBOOK.md).

> **Current state when this guide was authored:** Operational verification outside the checked-in validation chronology confirmed that Azure DevOps decommission run `240` removed the rebuilt Azure POC resources while preserving directory records. Before that teardown, the validated deployment built custom Compute Gallery image version `1.0.0`, deployed the validated VM from that custom version, and completed all final-acceptance gates. Run numbers in the [validation record](TEARDOWN-REBUILD-VALIDATION.md) are historical evidence, not proof for a future commit, rebuild, or current Azure state.

> **Boundary:** Conditional Access is not managed by this repository. Do not create, query, change, disable, or delete Conditional Access policies as part of deployment, validation, or teardown.

## 1. Executive overview

The solution automates one private, personal Windows 11 Azure Virtual Desktop (AVD) for a ServiceNow requested-for user:

1. ServiceNow derives an immutable `AVD<digits>` hostname from `RITM<digits>` and queues Azure DevOps with request identity only.
2. Azure DevOps validates the request independently and obtains environment settings from protected variable groups.
3. Additive Bicep deploys a private Trusted Launch VM from a custom Azure Compute Gallery image.
4. VM extensions perform Entra join, initiate Intune MDM enrollment, and register the VM with AVD.
5. Readiness checks Azure, Entra, required applications, Microsoft Defender for Endpoint (MDE), AVD, and optionally Intune inventory/compliance.
6. Only a ready host receives user login rights, desktop rights, and the personal host assignment.
7. The pipeline writes `Ready` or `Failed` to ServiceNow. Failures preserve the VM for diagnosis and request drain mode.

This is a controlled POC, not a multi-host production landing zone. Its important design choices are:

- **Private session hosts:** no VM public IP or inbound management path; outbound traffic uses a shared NAT Gateway.
- **Separation of duties:** deployment, readiness, assignment, and destructive work are designed for distinct service connections, principals, and roles. Azure DevOps administrators must configure and verify that separation; the YAML cannot prove that differently named connections do not use the same principal.
- **Additive ordinary operation:** what-if rejects `Delete` and `Recreate`; normal roles omit delete actions.
- **Evidence before handoff:** assignment follows readiness rather than merely successful ARM deployment.
- **Fixed destructive scope:** teardown is plan-bound, tag-guarded, and specific to POC01. The YAML references a protected environment, but an Azure DevOps administrator must configure and verify its approval checks.

Start with the [deployment runbook](../DEPLOYMENT-RUNBOOK.md) for the exact acceptance sequence and use this guide to understand and evolve the design.

## 2. Architecture and lifecycle

### 2.1 Logical architecture

```mermaid
sequenceDiagram
    actor User as Requester
    participant SN as ServiceNow RITM
    participant ADO as Azure DevOps session-host pipeline
    participant ARM as Azure Resource Manager
    participant AIB as Azure Image Builder
    participant SIG as Azure Compute Gallery
    participant VM as Private Windows 11 VM
    participant ID as Entra ID and Intune
    participant MDE as Defender for Endpoint
    participant AVD as AVD control plane

    Note over AIB,SIG: Prerequisite image pipeline
    AIB->>AIB: Start from Marketplace Windows 11 Enterprise 24H2
    AIB->>AIB: Customize, restart, update, optimize, generalize
    AIB->>SIG: Publish custom image version

    User->>SN: Submit desktop request
    SN->>ADO: Queue RITM, sys_id, derived hostname, requested-for UPN
    ADO->>ADO: Validate exact RITM-to-hostname contract
    ADO->>SN: Set In Progress
    ADO->>SIG: Resolve pinned or latest usable custom version
    ADO->>AVD: Reuse or refresh registration token
    ADO->>ARM: What-if, then incremental session-host deployment
    ARM->>VM: Create private NIC, Trusted Launch VM, Standard SSD
    VM->>ID: AADLoginForWindows Entra join and MDM enrollment
    VM->>AVD: DSC extension registers host
    ID-->>VM: Intune policy, applications, and MDE onboarding
    ADO->>VM: Run Command checks installed applications
    ADO->>ID: Check Entra and optional Intune compliance
    ADO->>MDE: Check Onboarded and Active
    ADO->>AVD: Check host is Available
    ADO->>ARM: Grant VM User Login and Desktop Virtualization User
    ADO->>AVD: Directly assign user; allow new sessions
    ADO->>SN: Set Ready

    Note over ADO,ARM: Approved teardown is separate
    ADO->>ARM: Inventory, drain, verify sessions, delete fixed POC groups
    ADO-->>SN: Preserve ServiceNow and Azure DevOps records
```

### 2.2 Control and data movement

| Flow | Data | Trust decision |
|---|---|---|
| ServiceNow to Azure DevOps | RITM number, 32-character sys_id, derived hostname, requested-for UPN | ServiceNow cannot choose subscription, image, VM size, network, or service connection. Azure DevOps revalidates the request. |
| Azure DevOps to Azure | Bicep parameters and short-lived AVD registration token | Workload identity federation and scoped custom roles; no normal delete permission. |
| Session host outbound | Entra, Intune, MDE, AVD, Windows Update, application endpoints | Private NIC uses subnet NAT. No public IP is attached to the VM. |
| Readiness to guest | Azure VM Run Command | Readiness role can run the required-app inventory only at POC resource-group scope. |
| Azure DevOps to ServiceNow | Status, hostname, and work note | Restricted OAuth client is preferred; Basic authentication is a POC bootstrap fallback. |
| Teardown | Current-run plan plus live Azure/optional Graph inventory | Fixed names, IDs, tags, fingerprints, session checks, exact confirmation, and approvals. |

### 2.3 End-to-end lifecycle

1. **Prerequisites:** register providers, compile Bicep, verify Marketplace image and VM SKU availability, quota, licensing, non-overlapping network ranges, Intune policy, MDE integration, and API permissions.
2. **Platform:** [main.bicep](../infra/main.bicep) creates `rg-avd-poc01`; [platform.bicep](../infra/modules/platform.bicep) creates networking, NAT, personal/direct host pool, desktop application group, and workspace.
3. **Access:** [access.bicep](../infra/access.bicep) creates no-delete workload roles and a persistent subscription read-only planning role.
4. **Image:** the image pipeline downloads and hashes a customization script, deploys the Image Builder template, runs it, and records the published gallery version ID.
5. **Request:** the ServiceNow Business Rule or Flow queues [azure-pipelines-session-host.yml](../pipelines/azure-pipelines-session-host.yml). `Test-AvdRequest.ps1` preserves leading zeros and rejects mismatched hostnames.
6. **Provision:** `New-AvdSessionHost.ps1` resolves the Entra user and image version, checks existing VM ownership tags, obtains an AVD token, performs what-if, and deploys incrementally.
7. **Join and management:** `AADLoginForWindows` enables Entra join with the Intune MDM application ID. Intune enrollment and assigned policy are asynchronous and tenant-controlled.
8. **AVD registration:** the Microsoft PowerShell DSC extension uses the protected registration token to add the host to the personal pool.
9. **Readiness:** `Wait-AvdReadiness.ps1` waits for a running VM, enabled Entra device, exact installed app display names, optional compliant Intune record, active/onboarded MDE record, and AVD `Available` status.
10. **Assignment:** `Set-AvdPersonalDesktopAssignment.ps1` grants built-in `Virtual Machine User Login` at the VM and `Desktop Virtualization User` at the app group, then directly assigns the requested user.
11. **Status:** the RITM moves through `Queued`, `In Progress`, and `Ready`; a failed pipeline attempts `Failed`, preserves evidence, and drains a registered host. Azure DevOps is authoritative if callback delivery fails.
12. **Decommission:** a fresh plan inventories the fixed POC01 scope. Approved execution drains, refuses active or unplanned sessions, removes reviewed Azure resources, optionally removes exact correlated Intune then Entra records, and removes four workload custom roles.

## 3. Marketplace input versus custom session-host image

These are different resources at different lifecycle points.

| Image | Current implementation | Consumer |
|---|---|---|
| Microsoft Marketplace platform image | `MicrosoftWindowsDesktop:windows-11:win11-24h2-ent:latest` in the `source` block of [image-builder.bicep](../infra/modules/image-builder.bicep) | Azure Image Builder uses it as raw input. |
| Azure Compute Gallery custom image version | A generalized, customized version under gallery definition `win11-avd-personal` | Session hosts normally use this exact version resource ID. |

The word `latest` in the Marketplace source means Image Builder can pick the current Microsoft-published 24H2 base when a new image build runs. It does **not** mean each session host boots directly from Marketplace.

The normal path is:

```text
Marketplace 24H2 platform image
  -> Azure Image Builder customizations and Windows Update
  -> Azure Compute Gallery definition
  -> version such as the historically validated 1.0.0
  -> session-host VM
```

The optional `Marketplace` branch in [session-host.bicep](../infra/session-host.bicep) is a fallback for initial testing before a corporate gallery image exists. It bypasses the corporate baseline and therefore is not the normal production path. Keep `AVD_IMAGE_SOURCE_TYPE=Gallery` for validated deployments.

## 4. Resource inventory and security boundaries

### 4.1 Azure-hosted resources

| Scope | Implemented resources and behavior |
|---|---|
| `rg-avd-poc01` | VNet, three subnets, empty-rule NSG, NAT Gateway and Standard static public IP, personal/direct host pool, desktop app group, workspace, gallery, gallery definition/versions, Image Builder template and managed identity, session-host VM/NIC/disk/extensions. Explicitly tagged resources carry POC lifecycle tags; generated child resources such as the managed OS disk must not be assumed to inherit those tags. |
| `rg-avd-poc01-aib-stage` | Transient Image Builder worker resources. Image pipeline applies required safety tags while the run is active. The group can be absent outside a build. |
| Subscription scope | Four POC workload custom roles plus `AVD POC Planning Inventory POC01`. The planning role and its readiness-principal assignment intentionally survive teardown. |
| `rg-avd-hybrid-poc01` | Separate optional Hybrid host pool, app group, Arc machine resources, and Hybrid roles. It is not deleted by Azure-hosted POC teardown. |

The three subnets are:

- `snet-sessionhosts`: private session-host NICs;
- `snet-imagebuilder`: Image Builder worker VM;
- `snet-imagebuilder-aci`: delegated to Azure Container Instances for the Image Builder control container.

All set `defaultOutboundAccess: false` and use the shared NAT Gateway. The NAT public IP is egress infrastructure; it is not attached to a VM and creates no inbound session-host path. AVD uses reverse-connect outbound connectivity.

### 4.2 Identity and authorization boundary

Use workload identity federation for Azure Resource Manager service connections. WIF authentication and approval checks are Azure DevOps configuration outside this repository and must be verified in the project:

| Identity/service connection | Current role |
|---|---|
| Bootstrap | Deploy platform/access/image foundation. Protect by approval and remove broad privilege after bootstrap. |
| `sc-avd-poc-deploy` | POC-scoped VM/NIC/disk/extension writes and AVD registration-token operations; Graph `User.Read.All`; no delete action. |
| `sc-avd-poc-readiness` | POC VM/AVD reads and VM Run Command; Graph device and Intune reads; MDE machine read. It also has persistent subscription `*/read` inventory only. |
| `sc-avd-poc-assignment` | POC role-assignment write and session-host assignment write; Graph `User.Read.All`; no delete action. |
| `sc-avd-poc-decommission` | Separate destructive identity, fixed in teardown YAML. Keep disabled/unprivileged except for an approved teardown window. |
| Image Builder managed identity | POC-scoped gallery version write and subnet join through the no-delete image role. It is deleted with the platform group and recreated on rebuild. |

Use service-principal **object IDs**, not application/client IDs, when running the access pipeline. Before bootstrap, prove that the deployment, readiness, and assignment object IDs are distinct and that their three named service connections resolve to those distinct principals; neither the access template nor the session-host YAML rejects duplicate identities. Tenant API permissions require admin consent and are separate from Azure RBAC.

### 4.3 Configuration, approval, and destructive isolation

- `avd-poc-platform` contains operator-controlled Azure IDs, VM settings, image selectors, readiness policy, and ordinary service-connection names.
- `avd-poc-servicenow` contains the instance URL, field names, and one callback authentication pair. Mark password/client secret as secrets.
- `avd-poc-hybrid` is used only by the optional Hybrid path; its provisioning-package SAS URI is secret.
- Platform, access bootstrap, ServiceNow configuration, and decommission YAML jobs reference Azure DevOps environments. Those environments enforce approvals only after administrators configure checks in Azure DevOps; verify the checks rather than treating an environment reference as proof of approval.
- Ordinary pipelines reject destructive what-if changes and use no-delete roles. Pipeline checks are defense in depth; RBAC is the security boundary.
- The decommission pipeline hardcodes planning and execution service connections and exposes only directory cleanup, execute, and confirmation controls.

### 4.4 Teardown preservation boundary

Azure-hosted teardown deletes the fixed, correctly tagged `rg-avd-poc01` and `rg-avd-poc01-aib-stage`, including VM/disks, NAT/public IP, gallery versions, image template, and POC-owned Image Builder identity. It also removes the four workload custom roles.

It preserves:

- Azure DevOps pipelines, environments, service connections, variable groups, history, and artifacts;
- ServiceNow configuration and RITM history;
- workload/service-connection identities and the persistent planning-inventory role;
- tenant policies, Intune policies, the test user, hybrid resources, and MDE history;
- all Conditional Access configuration, which is out of scope.

Directory deletion is optional and defaults to disabled. It was disabled for operational run `240`, so directory records were preserved. When explicitly enabled in a future approved run, it deletes only exact correlated Intune records first and then the exact Entra device. The decommission identity first requires admin-consented Graph application permissions `Device.ReadWrite.All` and `DeviceManagementManagedDevices.ReadWrite.All`. Validate those permissions before enabling cleanup: Azure resource-group deletion completes before Graph deletion, so a later Graph authorization failure leaves an intentionally recoverable but partially completed teardown. Reusing a hostname while old directory records remain can cause ambiguity; clean them through an approved process before rebuilding that same name.

## 5. Prerequisites and deployment order

### 5.1 Prerequisite checklist

- [ ] PowerShell 7.2+, Azure CLI with Bicep, and an authenticated subscription/tenant context.
- [ ] Required providers from [Register-AvdResourceProviders.ps1](../scripts/Register-AvdResourceProviders.ps1), including Compute, Network, DesktopVirtualization, ContainerInstance, ManagedIdentity, VirtualMachineImages, and HybridCompute.
- [ ] Windows 11 Enterprise 24H2 Marketplace availability and quota for `Standard_E4bs_v5` plus temporary `Standard_D4s_v6` Image Builder capacity.
- [ ] AVD, Windows, Intune, and MDE licensing for the test user.
- [ ] Intune automatic enrollment, compliance/configuration/app assignments, Intune-MDE connector, and device-targeted MDE onboarding policy.
- [ ] Three non-overlapping subnet CIDRs and outbound access to Microsoft/application endpoints.
- [ ] WIF service connections, environment approvals, Graph/MDE application permissions, and admin consent.
- [ ] HTTPS-accessible immutable customization script artifact.
- [ ] ServiceNow fields, restricted integration identity, outbound Azure DevOps credential, and request pipeline ID.

Do not bake Intune enrollment, tenant identity, MDE onboarding blobs, user data, or secrets into a generalized image.

### 5.2 Rebuild procedure

Run from the repository parent, matching the paths used in pipeline YAML.

1. **Register and test prerequisites.**

   ```powershell
   pwsh ./AzureVirtualDesktopPoc/scripts/Register-AvdResourceProviders.ps1 `
     -SubscriptionId <subscription-id>

   pwsh ./AzureVirtualDesktopPoc/scripts/Test-AvdPocPrerequisites.ps1 `
     -SubscriptionId <subscription-id> `
     -TenantId <tenant-id> `
     -Location centralus `
     -VmSize Standard_E4bs_v5
   ```

2. **Set platform parameters.** Review [poc.bicepparam](../infra/parameters/poc.bicepparam): POC ID, region, dedicated resource-group name, VNet/subnet ranges, owner, and cost center.
3. **Deploy platform.** Queue [azure-pipelines-platform.yml](../pipelines/azure-pipelines-platform.yml) with bootstrap service connection, subscription, region, and parameter file. Review `avd-poc-what-if`, then approve `avd-poc-platform`.
4. **Bootstrap access.** Queue [azure-pipelines-access.yml](../pipelines/azure-pipelines-access.yml) with the three workload service-principal object IDs. Approve `avd-poc-access-bootstrap`.
5. **Configure Intune/MDE.** Assign device-targeted baseline, applications, compliance, updates, and MDE onboarding before deploying a host. This repo does not deploy those tenant policies.
6. **Publish the customization artifact.** The checked-in [Install-CorporateBaseline.ps1](../image/Install-CorporateBaseline.ps1) is the current source example, but the image pipeline does not upload it. Publish reviewed bytes to an immutable HTTPS URI.
7. **Build an image.** Queue [azure-pipelines-image.yml](../pipelines/azure-pipelines-image.yml) with the image service connection, subscription, two Image Builder subnet IDs, artifact URI, and staging group. Retain both image artifacts.
8. **Create variable groups.** Copy names from the examples in [config](../config/), replace placeholders, mark secrets, and restrict pipeline authorization.
9. **Configure ServiceNow.** Follow [ServiceNowconfig.md](../ServiceNowconfig.md). The protected configure pipeline is tenant-specific bootstrap automation for the validated developer instance, not a portable catalog installer. Its script creates or reactivates the exact `Order AVD Build` item, adds a mandatory `Requested for` `sys_user` reference variable, contains fixed test-record and Azure DevOps identifiers, modifies the fixed test RITM, and does not create the timeout timer described in the manual guide.
10. **Test manually.** Queue the session-host pipeline with one real RITM/sys_id/user before using the catalog trigger.
11. **Test end to end.** Submit the catalog item and verify request correlation, all readiness evidence, assignment, user launch, no public VM IP, and ServiceNow `Ready`.
12. **Run final acceptance.** In a controlled run set `AVD_REQUIRE_INTUNE_COMPLIANT=true`; routine builds currently use `false`. Keep `AVD_REQUIRE_MDE=true`.

Use [TEARDOWN-REBUILD-VALIDATION.md](TEARDOWN-REBUILD-VALIDATION.md) for the fixed POC01 teardown and historical acceptance evidence.

## 6. Image lifecycle in detail

### 6.1 Template and source

[image-main.bicep](../infra/image-main.bicep) creates the no-delete Image Builder custom role and calls [image-builder.bicep](../infra/modules/image-builder.bicep). The module creates:

- user-assigned identity `id-aib-avd-poc01`;
- Azure Compute Gallery `acgavdpoc01`;
- generalized, Generation 2, x64 definition `win11-avd-personal` with Trusted Launch support;
- Image Builder template `aib-win11-avd-poc01`.

The template uses Marketplace `MicrosoftWindowsDesktop/windows-11/win11-24h2-ent/latest`, worker size `Standard_D4s_v6`, 128 GB worker OS disk, private worker/ACI subnets, and a 180-minute template timeout.

Its ordered build steps are:

1. Run the supplied PowerShell customization URI as elevated SYSTEM and require its SHA-256 checksum.
2. Restart Windows and require `C:\ProgramData\AvdImage\baseline.complete` to exist.
3. Install up to 60 non-preview Windows updates.
4. Enable VM boot optimization.
5. Distribute a non-excluded shared image to the local gallery/region with source metadata tags.

Image Builder performs generalization as part of producing the gallery artifact; customization must leave the machine safe for that process.

### 6.2 URI and integrity wiring

The image pipeline accepts `customizationScriptUri`, downloads those exact bytes with `Invoke-WebRequest`, calculates lowercase SHA-256 with `Get-FileHash`, and passes both values to Bicep. Image Builder downloads the URI again and validates `sha256Checksum`. A mutable URI that changes between those downloads causes the build to fail rather than silently execute different bytes.

Use a commit-pinned raw URL or immutable object/version URL. A short-lived read-only SAS can work for private storage, but it must remain valid for template deployment and the delayed Image Builder download. Never print a SAS or store it in a public artifact.

### 6.3 Version publication and selection

Bicep outputs the gallery and image-definition identities, not a fixed image version. After Image Builder reports `Succeeded`, the pipeline lists definition versions by `publishingProfile.publishedDate`, records the newest ID in `image-build.json`, and emits `galleryImageVersionId` as a task output. The historically validated build published `1.0.0`; the template itself does not hardcode that version string.

The current lookup does not correlate the selected version to the specific AIB run, compare the version list before and after the build, or filter this pipeline lookup by successful/non-excluded state. Prevent concurrent publishers for this image definition and independently inspect the reported version before promotion. Production hardening should obtain the version from the run output or otherwise prove run-to-version correlation.

For each session-host request, [New-AvdSessionHost.ps1](../scripts/New-AvdSessionHost.ps1) behaves as follows:

- If `AVD_GALLERY_IMAGE_VERSION_ID` is populated, pass that pinned version directly.
- If it is blank and source type is `Gallery`, query versions under `AVD_GALLERY_IMAGE_DEFINITION_ID`, retain only `provisioningState=Succeeded` and `excludeFromLatest!=true`, sort by publication date descending, and select the newest.
- If source type is `Marketplace`, skip gallery resolution.

[session-host.bicep](../infra/session-host.bicep) uses an image reference containing `id: galleryImageVersionId` for `Gallery`; only the fallback branch uses the Marketplace object. Thus the image **definition ID** is a collection used for discovery, while the **version ID** is the immutable artifact actually supplied to VM creation.

## 7. Add applications or configuration to the custom image

### 7.1 Safe change procedure

1. **Edit and review the source.** The current repository candidate is [image/Install-CorporateBaseline.ps1](../image/Install-CorporateBaseline.ps1), which installs 64-bit Microsoft 365 Apps on Monthly Enterprise and writes the completion marker. Image Builder executes content supplied by URI; it does not automatically execute the repository copy.
2. **Make customization machine-wide and idempotent.** Detect the desired state before changing it, use noninteractive installers, accept only documented success/reboot exit codes, and make reruns converge.
3. **Fail closed.** Use strict mode and `$ErrorActionPreference='Stop'`; validate process exit codes and throw on failure. Write the completion marker only after every required step succeeds.
4. **Log locally.** Write useful diagnostics under `C:\ProgramData\AvdImage`. Do not log credentials, tokens, SAS query strings, or tenant secrets. AIB build logs and the staging resources are the primary failure evidence.
5. **Protect package integrity.** Prefer vendor HTTPS repositories plus a pinned version/hash, or immutable private storage. Hash downloaded packages before execution. Do not trust only a mutable filename such as `setup.exe`.
6. **Handle reboot semantics.** Exit code `3010` may mean success with reboot required. Let the template's explicit `WindowsRestart` step own the reboot; do not start an uncontrolled reboot in the customization script. If an installer requires multiple reboots, redesign/test the template sequence.
7. **Remain generalizable.** Do not join Entra, enroll Intune, onboard MDE, create user profiles, retain machine certificates/identities, or run Sysprep manually. Avoid software that binds its identity or license to the temporary build VM.
8. **Keep secrets out.** Do not embed tenant secrets, PATs, passwords, MDE packages, provisioning packages, or long-lived SAS values in script, image, logs, or markers.
9. **Publish immutable bytes.** Upload the reviewed script to a new versioned URI. Queue the image pipeline with that URI; it computes the checksum automatically.
10. **Update readiness expectations.** If the app must gate handoff, add its exact machine uninstall-registry `DisplayName` to `AVD_REQUIRED_APP_NAMES_JSON` in the protected `avd-poc-platform` variable group and update [the example](../config/avd-poc-platform.variables.example.yml) in the same implementation change.
11. **Build and inspect.** Review `avd-image-template/image-what-if.json`, AIB status, and `avd-image-build/image-build.json`. Confirm the new gallery version is successful and not excluded.
12. **Validate a canary.** Pin `AVD_GALLERY_IMAGE_VERSION_ID` to the new version and deploy a disposable test RITM. Check `readiness.json`, launch the desktop, test the app, reboot, and rerun readiness.
13. **Promote or roll back.** Leave the tested version pinned for controlled rollout, or clear the version variable to select latest. Roll back by pinning the previous successful version; this affects new deployments and does not mutate an existing VM's OS disk.

### 7.2 Illustrative example only

The following is an **example pattern**, not the current repository implementation and not a complete installer. Replace the URI, hash, detection, and exit-code contract with vendor-verified values.

```powershell
# Example only: machine-wide, idempotent package installation.
$installer = 'C:\ProgramData\AvdImage\ExampleApp.msi'
$expectedHash = '<reviewed-sha256>'
$installed = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' `
  -ErrorAction SilentlyContinue | Where-Object DisplayName -eq 'Example App'

if (-not $installed) {
    Invoke-WebRequest 'https://immutable.example/app/1.2.3/app.msi' -OutFile $installer
    if ((Get-FileHash $installer -Algorithm SHA256).Hash -ine $expectedHash) {
        throw 'Example App package checksum mismatch.'
    }
    $process = Start-Process msiexec.exe -ArgumentList '/i', $installer, '/qn', '/norestart' -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "Installer failed: $($process.ExitCode)" }
}
```

## 8. Monthly image automation

### 8.1 Current behavior and operational gap

[azure-pipelines-image.yml](../pipelines/azure-pipelines-image.yml) defines:

```yaml
schedules:
  - cron: '0 6 1 * *'
    branches:
      include:
        - main
    always: true
```

Azure DevOps YAML cron is UTC, so this requests a run at **06:00 UTC on day 1 of every month**, from `main`. `always: true` means it runs even when source has not changed since the previous scheduled run.

Every image run requires these runtime parameters:

| Parameter | Default? | Purpose |
|---|---:|---|
| `imageBuilderServiceConnection` | No | Azure identity used by template deployment and AIB run. |
| `subscriptionId` | No | Target subscription. |
| `location` | `centralus` | Deployment/build region. |
| `pocId` | `POC01` | Naming and safety tags. |
| `resourceGroupName` | `rg-avd-poc01` | Existing platform/gallery group. |
| `imageBuilderSubnetId` | No | Private worker subnet. |
| `imageBuilderAciSubnetId` | No | Delegated ACI subnet. |
| `customizationScriptUri` | No | Immutable customization content URI. |
| `stagingResourceGroupName` | `rg-avd-poc01-aib-stage` | AIB staging group. |

**Gap:** The current parameterized YAML is not sufficient for unattended scheduled execution. Azure DevOps schedules do not provide queue-time values, and the subscription, both subnet IDs, service connection, and script URI have no defaults. A manually queued run can provide them; the schedule cannot reliably do so.

Minimal remediation options:

1. Add reviewed nonsecret defaults for every required parameter and use an immutable, non-expiring artifact URL; or
2. Move schedule-controlled values into a protected image variable group and use fixed pipeline configuration, retaining runtime parameters only for an explicitly manual template; or
3. Disable/pause the schedule until a dedicated scheduled wrapper/template supplies all values.

Do not place a secret SAS in a runtime parameter as a long-term fix: runtime parameters are not secret variables, and a short-lived SAS will expire before later monthly runs.

### 8.2 Post-build operation

**Implemented now:** AIB status polling, staging-group tagging, latest gallery-version lookup, and JSON artifact publication. There is no automatic canary deployment, promotion label, version pruning, rollback, alerting, or notification stage.

**Recommended operating procedure:**

1. Confirm template and build stages succeeded; inspect both image JSON artifacts and AIB logs.
2. Confirm the reported gallery version ID is new, `Succeeded`, and not excluded.
3. Pin that ID in a canary variable group or temporarily in `AVD_GALLERY_IMAGE_VERSION_ID`.
4. Deploy a canary, pass readiness with Intune compliance enabled, launch it, test core apps, and reboot it.
5. Promote by retaining the pin for controlled rollout or clearing it so latest resolution selects the version.
6. Roll back new builds by pinning the last known-good version. Replace/redeploy affected hosts; changing the variable does not reimage existing VMs.
7. Retain at least the active version and one or more tested rollback versions. Prune only through a separately approved destructive process after proving no VM references them.
8. Add Azure DevOps/Azure Monitor notifications for pipeline failure, AIB timeout/failure, gallery publication failure, and canary failure.

## 9. Pipeline reference

All repository pipelines have `trigger: none` and `pr: none`; the image pipeline additionally has the monthly schedule.

| Pipeline | Purpose, inputs, and flow | Outputs and safety/dependencies |
|---|---|---|
| [azure-pipelines-platform.yml](../pipelines/azure-pipelines-platform.yml) | Parameters: service connection, subscription, location, parameter file. `Validate` compiles and runs subscription what-if; `Deploy` creates the platform and initializes a 24-hour registration-token window. | `avd-poc-what-if`; blocks Delete/Recreate; incremental deployment; protected `avd-poc-platform`; prerequisite for access/image/hosts. |
| [azure-pipelines-access.yml](../pipelines/azure-pipelines-access.yml) | Privileged bootstrap connection plus subscription, POC/group, and three principal object IDs. One protected deployment performs access what-if then deployment. | `avd-poc-access-what-if`; blocks Delete/Recreate; creates ordinary roles and persistent planning role; run after platform. |
| [azure-pipelines-image.yml](../pipelines/azure-pipelines-image.yml) | Service connection, subscription/location/POC/group, two subnet IDs, script URI, staging group. `ValidateAndDeployTemplate` hashes content and deploys template; `BuildImage` invokes AIB and waits up to four hours. | `avd-image-template` and `avd-image-build`; blocks Delete/Recreate; tags staging group; publishes selected version ID. Schedule gap documented above. |
| [azure-pipelines-session-host.yml](../pipelines/azure-pipelines-session-host.yml) | Four request parameters; `avd-poc-platform` and `avd-poc-servicenow` groups. Stages: validate/callback, provision, readiness, assign, ready callback; failure stage drains/notifies. | Per-host provision what-if and readiness JSON artifacts. Separate deploy/readiness/assignment connections; failed VM is preserved. Requires platform, access, image, tenant policy, and ServiceNow configuration. |
| [azure-pipelines-decommission.yml](../pipelines/azure-pipelines-decommission.yml) | Only `removeDirectoryRecords`, `execute`, and confirmation. `Plan` uses fixed readiness connection; `Decommission` uses fixed destructive connection and current-run plan. | `avd-poc-decommission-plan` and attempt-specific execution report; defaults plan-only; requires `DELETE POC01`, service-connection check, protected environment, exact tags/scope. |
| [azure-pipelines-servicenow-configure.yml](../pipelines/azure-pipelines-servicenow-configure.yml) | Uses ServiceNow variable group and protected `avd-poc-servicenow-config`; runs tenant-specific integration bootstrap with OAuth credentials and a queue PAT. The script creates or reactivates `Order AVD Build` and has fixed test RITM, organization/project, and pipeline identifiers. | `servicenow-avd-configuration` with nonsecret IDs. One-shot admin operation; remove the temporary Azure DevOps variable after configuration and revoke the PAT after the catalog request is queued. The ServiceNow timeout timer remains a manual configuration step. |
| [azure-pipelines-servicenow-admin-test.yml](../pipelines/azure-pipelines-servicenow-admin-test.yml) | Uses ServiceNow OAuth to test read-only API access and inventory selected REST, catalog, rule, field, user, and RITM records. | `servicenow-avd-inventory`; contains tenant-specific lookup constants and is an administrative diagnostic, not generic deployment. |
| [azure-pipelines-servicenow-trigger-test.yml](../pipelines/azure-pipelines-servicenow-trigger-test.yml) | Protected one-shot trigger for the fixed test RITM through ServiceNow OAuth. | `servicenow-avd-trigger`; intentionally writes/queues work and depends on configured ServiceNow integration. |
| [azure-pipelines-hybrid-platform.yml](../pipelines/azure-pipelines-hybrid-platform.yml) | Validates/deploys the separate Hybrid foundation, then adds its app group to the existing workspace. | `avd-hybrid-platform-what-if`; protected environment; no Azure network resources; blocks Delete/Recreate. |
| [azure-pipelines-hybrid-access.yml](../pipelines/azure-pipelines-hybrid-access.yml) | Bootstraps three no-delete Hybrid roles from service-principal object IDs. | `avd-hybrid-access-what-if`; protected environment; blocks Delete/Recreate. |
| [azure-pipelines-hybrid-onboard.yml](../pipelines/azure-pipelines-hybrid-onboard.yml) | Four request inputs plus Hybrid/ServiceNow groups. Validates Arc VM/package lifetime, applies protected enrollment package, installs Arc extensions, checks management/security/GPU/AVD, assigns, and notifies. | Preflight/readiness artifacts; preserves Proxmox VM on failure. Requires a manually built and Arc-connected VM. |
| [azure-pipelines-hybrid-decommission.yml](../pipelines/azure-pipelines-hybrid-decommission.yml) | Parameterized Hybrid inventory then approved Azure teardown with `DELETE HYBRID <pocId>`. | Plan/execution artifacts; preserves the Proxmox VM. Unlike Azure-hosted teardown, service connection and scope are queue parameters, so approvals and careful review are essential. |

## 10. Template, module, and script reference

### 10.1 Bicep

| Path | Responsibility |
|---|---|
| [infra/main.bicep](../infra/main.bicep) | Subscription entry point; creates tagged dedicated group and invokes the platform module. |
| [infra/modules/platform.bicep](../infra/modules/platform.bicep) | NAT/public IP, VNet/subnets/NSG, personal host pool, desktop app group, workspace. |
| [infra/image-main.bicep](../infra/image-main.bicep) | Existing group scope, no-delete Image Builder role, image module, image-definition outputs. |
| [infra/modules/image-builder.bicep](../infra/modules/image-builder.bicep) | AIB identity/template, Marketplace source, customizers, gallery/definition, distribution. |
| [infra/session-host.bicep](../infra/session-host.bicep) | Private NIC, Trusted Launch VM, selected image reference, Entra/Intune extension, AVD DSC registration. |
| [infra/access.bicep](../infra/access.bicep) | Deployment/readiness/assignment roles and persistent planning-inventory role. |
| [infra/modules/access-assignments.bicep](../infra/modules/access-assignments.bicep) | Assigns ordinary roles to separate workload principals at POC group scope. |
| [infra/hybrid-main.bicep](../infra/hybrid-main.bicep), [hybrid-platform.bicep](../infra/modules/hybrid-platform.bicep) | Separate Hybrid group, personal host pool identity, Reader assignment, and app group. |
| [infra/hybrid-access.bicep](../infra/hybrid-access.bicep), [hybrid-access-assignments.bicep](../infra/modules/hybrid-access-assignments.bicep) | Hybrid no-delete roles and assignments. |

### 10.2 Core PowerShell orchestration

| Path | Responsibility |
|---|---|
| [Register-AvdResourceProviders.ps1](../scripts/Register-AvdResourceProviders.ps1) | Additively registers required Azure providers. |
| [Test-AvdPocPrerequisites.ps1](../scripts/Test-AvdPocPrerequisites.ps1) | Checks account context, providers, VM SKU, Marketplace source, and Bicep compilation; writes JSON. |
| [Test-AvdRequest.ps1](../scripts/Test-AvdRequest.ps1) | Validates RITM/sys_id/UPN and exact case-sensitive derived hostname. |
| [New-AvdSessionHost.ps1](../scripts/New-AvdSessionHost.ps1) | Validates user/ownership, resolves gallery version, refreshes AVD token, generates ephemeral local password, performs what-if and incremental deployment. |
| [Wait-AvdReadiness.ps1](../scripts/Wait-AvdReadiness.ps1) | Polls Azure, Entra, optional Intune compliance, guest app inventory, optional MDE, and AVD; continuously writes readiness JSON. |
| [Set-AvdPersonalDesktopAssignment.ps1](../scripts/Set-AvdPersonalDesktopAssignment.ps1) | Idempotently grants two built-in roles and directly assigns an Available host. |
| [Set-AvdDrainMode.ps1](../scripts/Set-AvdDrainMode.ps1) | Prevents new sessions on a registered host after failure. |
| [Update-ServiceNowRitm.ps1](../scripts/Update-ServiceNowRitm.ps1) | Patches status/hostname/platform/work notes by OAuth or Basic auth. |
| [Set-ServiceNowAvdCatalogIntegration.ps1](../scripts/Set-ServiceNowAvdCatalogIntegration.ps1) | Idempotently creates validated developer-instance fields, REST configuration, test identity, catalog integration, and guarded rules. |
| [Invoke-ServiceNowAvdTestRequest.ps1](../scripts/Invoke-ServiceNowAvdTestRequest.ps1) | Triggers the fixed validation RITM and records correlation. |
| [Remove-AvdPoc.ps1](../scripts/Remove-AvdPoc.ps1) | Fixed POC01 plan-bound teardown, partial-attempt recovery, optional exact directory cleanup, and JSON evidence. |
| [Wait-AvdHybridReadiness.ps1](../scripts/Wait-AvdHybridReadiness.ps1) and related `*Hybrid*.ps1` | Arc preflight/enrollment/extensions, GPU/management readiness, assignment, and separate Hybrid teardown. |
| [tests/Test-AvdPoc.ps1](../tests/Test-AvdPoc.ps1) | Parses scripts and checks naming, private VM, no-delete paths, Hybrid boundaries, teardown invariants, and documentation constants. |

## 11. Variable-group configuration reference

### 11.1 `avd-poc-platform`

Create it from [avd-poc-platform.variables.example.yml](../config/avd-poc-platform.variables.example.yml).

| Group | Variables |
|---|---|
| Identity/location | `AVD_POC_ID`, subscription ID, tenant ID, location, session-host/platform groups. |
| AVD/network | Host pool, desktop app group, full session-host subnet resource ID. |
| Compute | VM size and OS disk SKU. |
| Image | Source type, gallery image **definition ID**, optional gallery image **version ID**. |
| Guest/readiness | Explicit AVD DSC package URI, exact required app JSON, Intune/MDE switches, timeout. |
| Connections | Deployment, readiness, and assignment service-connection names. |

Definition versus version is operationally significant:

```text
.../galleries/acgavdpoc01/images/win11-avd-personal
                                                    ^ definition ID

.../galleries/acgavdpoc01/images/win11-avd-personal/versions/1.0.0
                                                                   ^ version ID
```

- Blank version: resolve newest successful, non-excluded version for every request. This enables automatic roll-forward but can make two requests use different images.
- Pinned version: deterministic new-host builds and safer staged rollout. It must be a full version resource ID, not `1.0.0` alone.
- Marketplace source: gallery values are not used, and the corporate baseline is bypassed.

### 11.2 ServiceNow and Hybrid groups

- [avd-poc-servicenow.variables.example.yml](../config/avd-poc-servicenow.variables.example.yml): URL, OAuth or Basic callback pair, and field mappings. Populate one auth pair only and mark secrets.
- [avd-poc-hybrid.variables.example.yml](../config/avd-poc-hybrid.variables.example.yml): Hybrid Azure/AVD IDs, GPU/app gates, package lifetime/hash/secret SAS, and three Hybrid connections.

Azure DevOps variable groups are definitions/configuration, not proof that resources currently exist. Revalidate every ID after teardown/rebuild.

## 12. Day-2 operating procedures

### Monthly refresh

1. Resolve the scheduling gap in section 8 or queue manually.
2. Publish immutable customization bytes and run the image pipeline.
3. Inspect artifacts/AIB logs; pin the new version for a canary.
4. Run final readiness and user-launch testing.
5. Promote, retain rollback versions, and record commit/run/version evidence.

### Application or image configuration change

Follow section 7. Update script, package integrity metadata, exact readiness display names, tests, config example, and operator documentation together. Never retrofit a generalized image by modifying a gallery version; create a new version.

### Deploy another desktop

1. Confirm a unique RITM maps to a unique `AVD<digits>` name of at most 15 characters.
2. Confirm requested user licensing and enabled Entra account.
3. Choose a tested image pin or approved latest behavior.
4. Submit through ServiceNow or queue the four request parameters manually.
5. Retain provision/readiness artifacts and verify direct assignment and launch.

The fixed POC01 teardown currently expects exactly one VM/host named `AVD0000001`. Deploying additional hosts is compatible with ordinary provisioning but deliberately makes that fixed teardown plan fail. Extend and retest destructive scope before using it for a multi-host environment.

### Troubleshoot a failed image build

1. Inspect `avd-image-template/image-what-if.json` and the template deployment task.
2. Inspect AIB `lastRunStatus.message` and staging resource logs while the staging group exists.
3. Verify script URI lifetime/reachability, checksum stability, worker/ACI subnet routing, quota, package endpoints, installer exit code, marker creation, restart, and Windows Update duration.
4. Correct the source and publish a new immutable artifact; do not overwrite evidence.

### Troubleshoot or validate a session host

1. Inspect `avd-session-host-provision-<host>/session-host-what-if.json`.
2. Inspect `avd-session-host-readiness-<host>/readiness.json`; `checks`, `details`, and `errors` identify the pending gate.
3. Confirm VM/extensions, Entra exact name, Intune last sync/compliance, Run Command output, MDE device-ID correlation, AVD status, and registration-token timing.
4. Keep the failed VM drained. Repair policy/connectivity/permissions, then rerun the same request; ownership tags make same-request convergence idempotent.
5. Do not delete evidence automatically and do not mark ServiceNow `Ready` manually without passing gates.

### Rollback

1. Set `AVD_GALLERY_IMAGE_VERSION_ID` to the previous tested full ID.
2. Deploy a canary and verify readiness.
3. Replace failed/new hosts through an approved lifecycle; an image pin does not alter existing disks.
4. Exclude/quarantine the bad version through an approved image-management process and retain its build evidence.

### Teardown and rebuild

1. Pause image/request pipelines and establish an exclusive maintenance window.
2. Queue a preliminary decommission run with `execute=false`; inspect `plan.json` and confirm zero active sessions.
3. Queue a new run with `execute=true` and exact `DELETE POC01`. That run creates its own fresh plan; review that plan before approving its Decommission stage. Runtime parameters cannot be changed on the preliminary run. Directory cleanup remains optional and should be enabled only after reviewing the exact directory records and validating the required Graph permissions.
4. Verify both groups are absent and shared records listed in section 4 remain.
5. Rebuild in order: platform, access, image, session host. Recreate any customization storage that was inside the deleted POC group.

## 13. Modification map

| Change | Primary location | Coupled updates/checks |
|---|---|---|
| Session-host VM size | `AVD_VM_SIZE`, [session-host.bicep](../infra/session-host.bicep) default | Prerequisite SKU/quota check, accelerated networking support, runbook/validation expectations. |
| OS disk SKU | `AVD_OS_DISK_SKU`, `osDiskSku` in session-host Bicep | Allowed values, cost model, config example, acceptance. |
| Gallery source/version | Platform variable group and `New-AvdSessionHost.ps1` | Definition versus version semantics, canary/rollback process, tests/docs. |
| Marketplace base OS SKU | `source` in [image-builder.bicep](../infra/modules/image-builder.bicep) | Gallery definition identifier, prerequisite image URN, baseline marker metadata, tests/runbooks, Trusted Launch compatibility. |
| Required apps | Customization artifact plus `AVD_REQUIRED_APP_NAMES_JSON` | Exact uninstall display names, Intune assignments if policy-delivered, config example, readiness tests. |
| Intune compliance gate | `AVD_REQUIRE_INTUNE_COMPLIANT` | Routine/final acceptance policy and Graph permissions. |
| MDE gate | `AVD_REQUIRE_MDE` | MDE connector/onboarding policy, `Machine.Read.All`, acceptance. Keep enabled for the validated posture. |
| Image cadence | `schedules` in image pipeline | Resolve scheduled parameters, retention, canary, notifications, operator calendar. |
| Network ranges | [poc.bicepparam](../infra/parameters/poc.bicepparam), main/platform Bicep | Overlap review, subnet sizing, IDs in variable group, what-if. Existing range changes can be destructive and will be blocked. |
| Naming | Variables in platform/image modules and RITM regex scripts | ServiceNow rules, 15-character limit, access/decommission deterministic IDs, tests, config, runbooks. |
| Role permissions | [access.bicep](../infra/access.bicep) or Hybrid access Bicep | Least-privilege review, Graph/MDE consent, teardown role expectations, static tests. Never add delete to ordinary roles. |
| AVD DSC URI/version | `AVD_DSC_CONFIGURATION_URI` | Microsoft release validation, registration test, config example. |
| Readiness timeout | `AVD_READINESS_TIMEOUT_MINUTES` | Session-host job timeout remains larger; ServiceNow timer must leave callback margin. |

Compile every Bicep entry point and run [Test-AvdPoc.ps1](../tests/Test-AvdPoc.ps1) after coupled changes. Update examples and runbooks in the same change when implementation contracts move.

## 14. Troubleshooting reference

| Symptom | Evidence | Likely implementation-grounded checks |
|---|---|---|
| Platform/access blocked | What-if artifact | A change reports Delete/Recreate; use a new additive design rather than bypassing the gate. Confirm bootstrap scope. |
| Image template fails early | `image-what-if.json`, deployment logs | Invalid subnet IDs, missing ACI delegation, role propagation, inaccessible/expired script URI, checksum length/content. |
| AIB times out/fails | AIB `lastRunStatus`, staging logs | `Standard_D4s_v6` quota, NAT/DNS, installer hangs/exit code, no marker, restart timeout, Windows Update over 180 minutes. |
| Wrong/no gallery version | `image-build.json`, gallery version properties | Definition ID is mistaken for version ID, version excluded, provisioning not `Succeeded`, stale pin, no versions after teardown. |
| Request rejected | ValidateRequest log | RITM/hostname mismatch, lost leading zero, invalid sys_id, malformed UPN. |
| Provision fails | Session-host what-if and ARM deployment operations | Existing VM belongs to another RITM/user, wrong subscription/tenant, Graph user permission, registration-token permission, NIC/subnet join, SKU quota, unsupported image/VM combination. |
| Entra/Intune pending | `readiness.json` details/errors | AAD extension failure, automatic MDM scope/licensing, duplicate old device name, policy targeting, Graph permissions, delayed sync/compliance. |
| Required app pending | Run Command task and readiness `missing` list | Exact registry `DisplayName` mismatch, 32/64-bit uninstall path, image install failure, Intune install still pending. |
| MDE pending | Readiness MDE details/errors | Connector/onboarding policy, `Machine.Read.All`, token audience, Entra `deviceId` correlation, onboarding or health not `Active`. |
| AVD unavailable | VM DSC extension, host pool session-host list | Expired token, blocked endpoints, DSC URI/version, host agent state, name/resource mapping. |
| Assignment fails | Assign stage | Host not `Available`, conflicting assigned user, missing role-assignment write or Graph user read. |
| ServiceNow status stale | Callback task, RITM work notes, ADO run URL | OAuth/Basic pair, ACL/field mapping, sys_id, callback outage. Azure DevOps remains authoritative. |
| Teardown plan refuses | `plan.json` or Plan log | Active session, extra VM/host, absent required platform group, tag mismatch, inventory visibility, unexpected roles/locks. Do not weaken checks. |

Artifacts are intentionally nonsecret evidence, but review them before external sharing because they contain resource IDs, user identifiers, device IDs, and topology.

## 15. Cost and lifecycle

- **Image Builder:** worker VM, disk, networking, and ACI resources are transient in the staging group during a build. Failed/stalled builds can leave billable staging resources until cleanup.
- **Gallery:** every retained image version consumes storage and may replicate by region. This implementation uses one region and does not prune versions automatically.
- **Session host:** VM compute bills while allocated; OS disk persists and bills when deallocated. Boot diagnostics may add managed storage cost.
- **Network:** NAT Gateway and its Standard public IP continue billing even when VMs are stopped. NAT cannot be paused.
- **Control plane:** AVD control-plane pricing/licensing and user licenses are separate from infrastructure; Hybrid has separate commercial considerations.
- **Teardown:** deleting the two fixed POC groups is the spend-stop mechanism because it removes VM/disks, NAT/public IP, gallery/image resources, and AIB resources. Shared control-plane records are preserved because they are operational evidence or reusable identity/configuration, not POC compute resources.

## 16. Current implementation versus recommended production hardening

| Area | Current implementation | Recommended production hardening |
|---|---|---|
| Scope | Fixed single-host POC and fixed teardown target | Parameterized environment factories with policy-approved, inventory-safe multi-host lifecycle. |
| Image promotion | Successful build is available; hosts use a pin or latest. The pipeline's newest-version lookup is not correlated to its specific AIB run. | Separate build/canary/promote rings, explicit run-to-version correlation, serialized publication, signed artifacts, vulnerability scanning, release metadata, automatic rollback criteria. |
| Schedule | Monthly cron exists but required runtime values are unresolved | Dedicated scheduled configuration with protected values, durable artifact URI, alerts, and canary gate. |
| Retention | No automatic image deletion | Approved retention policy preserving active and rollback versions, with reference checks. |
| ServiceNow auth | Short-lived PAT for developer POC; OAuth/Basic callbacks | Entra-backed Azure DevOps integration and restricted OAuth-only callback; managed credential rotation. |
| Agents | Microsoft-hosted `windows-latest` | Governed Managed DevOps Pool/self-hosted agents as required, with pinned tool versions and egress policy. |
| Networking | Empty-rule NSG plus NAT and Microsoft service connectivity | Validated egress allowlisting/firewall/private endpoints where supported, DNS/monitoring design, production address plan. |
| Secrets | Azure DevOps secret variables/ServiceNow credentials | Enterprise vault integration, automated rotation, secret scanning, no secret runtime parameters. |
| Monitoring | Pipeline logs and JSON artifacts | Central Log Analytics/Azure Monitor, AVD Insights, MDE/Intune operational alerts, ServiceNow incident integration, SLOs. |
| Availability | One personal host, one region | Tested backup/profile/data strategy, capacity reservations or quotas, regional DR, update rings, replacement automation. |
| Governance | Custom no-delete roles and approval environments | Periodic access reviews, PIM/JIT destructive privilege, policy-as-code, signed commits/artifacts, formal change control. |
| Compliance | MDE required; Intune compliance optional for routine and required for final acceptance | Enforce compliance according to production policy and prove it continuously. Conditional Access remains owned outside this repo. |

Recommendations in this table are not claims about the current implementation.

## 17. Glossary

| Term | Meaning here |
|---|---|
| AIB | Azure VM Image Builder, which creates a generalized custom image from the Marketplace source. |
| AVD | Azure Virtual Desktop control plane and reverse-connect desktop service. |
| Compute Gallery | Versioned store for the custom session-host image. Formerly Shared Image Gallery. |
| Definition ID | Parent gallery image identity used to enumerate versions; not deployable as the selected immutable version in this workflow. |
| Version ID | Full immutable gallery image version resource ID passed to VM deployment. |
| Entra join | Device registration/join to Microsoft Entra ID through `AADLoginForWindows`. |
| Intune enrollment | MDM registration initiated for each deployed VM; not baked into the image. |
| MDE | Microsoft Defender for Endpoint; readiness requires `Onboarded` and `Active` when enabled. |
| Personal/direct | One AVD session host is explicitly assigned to one requested user. |
| RITM | ServiceNow requested item; its digits deterministically form the hostname. |
| WIF | Workload identity federation used by Azure DevOps service connections instead of stored Azure client secrets. |
| Drain mode | `allowNewSession=false`; prevents new AVD sessions while preserving a failed host or preparing teardown. |
| Planning-inventory role | Persistent subscription `*/read` role used to prove fixed teardown inventory; it has no write, delete, action, or data-plane permission. |
