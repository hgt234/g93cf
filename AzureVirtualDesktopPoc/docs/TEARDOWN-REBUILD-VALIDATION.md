# POC01 teardown, rebuild, and validation

Use this runbook to reset only the Azure-hosted POC and prove a clean rebuild. Run plan and execute as separate Azure DevOps runs.

> **Prohibited:** Conditional Access is out of scope; do not touch, create, edit, disable, or delete any Conditional Access policy.

## Scope and preservation boundaries

Delete only these exactly tagged resource groups:

```text
rg-avd-poc01
rg-avd-poc01-aib-stage
```

Required tags:

```text
ManagedBy=AzureVirtualDesktopPoc
PocId=POC01
```

POC01 resource names used during validation:

| Resource | Name or ID suffix |
|---|---|
| Resource group | `rg-avd-poc01` |
| AIB staging group | `rg-avd-poc01-aib-stage` |
| Host pool | `vdpool-avd-poc01` |
| Desktop application group | `vdag-avd-poc01` |
| Workspace | `vdws-avd-poc01` |
| VNet | `vnet-avd-poc01` |
| Session-host subnet | `.../virtualNetworks/vnet-avd-poc01/subnets/snet-sessionhosts` |
| Image Builder subnet | `.../virtualNetworks/vnet-avd-poc01/subnets/snet-imagebuilder` |
| ACI subnet | `.../virtualNetworks/vnet-avd-poc01/subnets/snet-imagebuilder-aci` |
| NAT Gateway | `nat-avd-poc01` |
| NAT public IP | `pip-nat-avd-poc01` |
| Gallery | `acgavdpoc01` |
| Image definition | `win11-avd-personal` |
| Image template | `aib-win11-avd-poc01` |
| Image identity | `id-aib-avd-poc01` |
| Test request/host | `RITM0000001` / `AVD0000001` |

Full IDs begin with:

```text
/subscriptions/<subscription-id>/resourceGroups/rg-avd-poc01/providers/...
```

Preserve:

- Azure DevOps project, pipelines, variable groups, environments, run artifacts, and service connections;
- ServiceNow catalog configuration and `RITM0000001` record;
- source repository and external secret stores;
- MDE device history, which ages out under Defender retention;
- `rg-avd-hybrid-poc01` and the Proxmox VM unless running the separate hybrid teardown;
- tenant-wide Intune and security policies.

Optional exact Entra and Intune records for `AVD0000001` may be removed only with `removeDirectoryRecords=true`. The plan reports object IDs before execution. MDE records are never deleted by this workflow.

## 1. Pre-reset evidence

Capture:

- current commit and Azure DevOps run URL;
- `RITM0000001` status, `sys_id`, hostname, run ID, and run URL;
- VM, NIC, disk, host-pool/session-host, assignment, Entra, Intune, and MDE object IDs;
- image definition/version IDs;
- resource-group tags and full inventory;
- active AVD sessions and `allowNewSession` state;
- current variable-group values with secrets redacted;
- location and quota evidence for EBDSv5 and Dsv6 families.

Stop if an active AVD user session exists. The execution script drains first and refuses deletion while an active session remains.

## 2. Prepare temporary decommission access

Keep `sc-avd-poc-decommission` disabled or unprivileged during normal operation. For the reset window only:

1. Grant delete authority scoped to the two POC resource groups and the four deterministic POC custom roles.
2. If directory cleanup is approved, grant only the Graph device permissions required to enumerate/delete the exact Entra and Intune records.
3. Confirm environment `avd-poc-decommission` requires approval.
4. Do not grant this identity to ordinary deployment pipelines.

## 3. Dry-run

Queue `pipelines/azure-pipelines-decommission.yml`:

```text
azureServiceConnection=sc-avd-poc-decommission
subscriptionId=<subscription-id>
tenantId=<tenant-id>
pocId=POC01
resourceGroupNames=[rg-avd-poc01, rg-avd-poc01-aib-stage]
hostPoolResourceGroupName=rg-avd-poc01
hostPoolName=vdpool-avd-poc01
removeDirectoryRecords=true
execute=false
confirmationText=PLAN-ONLY
```

Review `avd-poc-decommission-plan/plan.json`. Require:

- only the two explicit groups; no wildcard;
- exact safety tags;
- exact VM and session-host match;
- drain intent and zero active sessions;
- exact case-sensitive Entra/Intune names and object IDs when cleanup is enabled;
- only the four POC custom roles, with assignable scopes inside validated groups;
- no Conditional Access resource or action.

The exact staging group may already be absent. No other required group may be absent.

## 4. Execute

After plan approval, queue a new run with the same values except:

```text
execute=true
confirmationText=DELETE POC01
```

Approve `avd-poc-decommission`. Execution order is:

1. set matched session hosts to drain mode;
2. refuse execution if active sessions remain;
3. deallocate matched VMs;
4. remove matched session-host records;
5. optionally remove exact Entra and Intune records;
6. remove only in-scope locks;
7. delete the two validated groups and wait for completion;
8. delete the four validated POC custom roles.

Download `avd-poc-decommission-execution/execution.json`. Then revoke the temporary Azure and Graph permissions and disable the decommission connection.

## 5. Confirm preservation and deletion

Evidence checklist:

- [ ] Both POC resource groups are absent.
- [ ] NAT Gateway, public IP, VM, disk, gallery, and image versions are absent.
- [ ] The four POC custom roles are absent.
- [ ] Optional Entra/Intune records are absent only if requested.
- [ ] MDE historical record remains subject to Defender retention.
- [ ] `RITM0000001`, Azure DevOps run history, ServiceNow configuration, and hybrid resources remain.
- [ ] No Conditional Access policy changed.

The POC-owned custom-script storage account/container, if it was inside `rg-avd-poc01`, is also deleted. Its contents and URI must be recreated before image build.

## 6. Rebuild in exact order

1. Run provider registration and prerequisite validation.
2. Confirm `Standard_E4bs_v5` availability and EBDSv5 quota.
3. Confirm `Standard_D4s_v6` availability and Dsv6 quota.
4. Run the platform pipeline; approve only a no-delete/no-recreate what-if.
5. Run the access pipeline with deployment, readiness, and assignment service-principal **object IDs**.
6. Recreate private custom-script storage if it was deleted; upload the exact script and generate a fresh short-lived read-only URI.
7. Run the image pipeline and capture the new gallery image-version ID.
8. Refresh `AVD_GALLERY_IMAGE_DEFINITION_ID`; leave `AVD_GALLERY_IMAGE_VERSION_ID` empty or pin the new version.
9. Confirm the AVD DSC URI is current and the registration-token identity has required actions.
10. Run the session-host pipeline with the reused request contract below.

```text
ritmNumber=RITM0000001
ritmSysId=<existing RITM0000001 sys_id>
requestedHostName=AVD0000001
requestedForUpn=<licensed test user UPN>
```

Reuse of `RITM0000001` is intentional after the prior VM and optional exact directory records are removed. Do not create a requester-selected hostname.

## 7. Routine validation

Set:

```text
AVD_REQUIRE_INTUNE_COMPLIANT=false
AVD_REQUIRE_MDE=true
```

Require:

- private NIC and NAT egress;
- `Standard_E4bs_v5`, Trusted Launch, and Standard SSD;
- Entra device enabled;
- exact required-app `DisplayName` matches;
- MDE `Onboarded` and `Active`;
- AVD host `Available` and directly assigned;
- ServiceNow `Ready` with run correlation.

DSC extension completion may precede its reboot and AVD registration. Allow readiness polling to reach the configured timeout; do not redeploy because of the normal transient gap.

## 8. Separate final acceptance

After routine success, run a separate acceptance with:

```text
AVD_REQUIRE_INTUNE_COMPLIANT=true
AVD_REQUIRE_MDE=true
```

Final evidence:

- [ ] Intune managed-device record exists and is compliant.
- [ ] Required apps match exactly.
- [ ] MDE is active.
- [ ] AVD is available and assigned.
- [ ] User launches the desktop.
- [ ] RITM reaches `Ready`.
- [ ] No public IP exists.
- [ ] BitLocker was not treated as a requirement.
- [ ] No Conditional Access change occurred.

Known-good historical successful runs are **167** and **194**. Preserve the new run IDs and artifacts as the current validation record.
