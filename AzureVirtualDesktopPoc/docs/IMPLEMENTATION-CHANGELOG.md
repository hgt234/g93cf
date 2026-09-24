# Implementation changelog

This ledger records the corrections made after the initial implementation, from `6ade591` through `547f30a`. The current checkout contains the resulting implementation but not the source branch's intervening Git objects; the entries therefore identify the available boundary commits and enumerate every implemented correction by root cause, fix, and validation outcome without inventing unavailable hashes.

## Validation baseline

- Known-good successful Azure DevOps runs: **167** and **194**.
- Static validation: `tests/Test-AvdPoc.ps1`.
- Live validation still depends on tenant IDs, permissions, policies, quotas, and external artifact availability.

## `6ade591` — initial post-baseline implementation

| Area | Root cause | Fix | Validation |
|---|---|---|---|
| Request identity | Requesters could supply names unrelated to the RITM. | Defined `ritmNumber`, `ritmSysId`, `requestedHostName`, and `requestedForUpn`; both ServiceNow and Azure DevOps enforce `RITM<digits> -> AVD<digits>`. | Leading-zero and mismatch tests in `Test-AvdPoc.ps1`. |
| Isolation | Session hosts risked inbound exposure or implicit outbound access. | Private NIC only, `defaultOutboundAccess=false`, shared NAT Gateway, empty NSG rules. | Static no-public-IP test and live NIC/subnet checks. |
| Lifecycle safety | Normal deployments could remove existing resources. | Incremental deployment, what-if gates for `Delete`/`Recreate`, and no-delete custom roles. | Static destructive-command checks and published what-if artifacts. |
| Readiness | Provisioning success did not prove a usable desktop. | Added Azure, Entra, Intune, app, MDE, and AVD polling before assignment. | Readiness JSON artifact and successful end-to-end run. |
| Failure handling | Automatic cleanup destroyed diagnostic evidence. | Preserve failed VM, request drain mode, and write ServiceNow `Failed`. | Forced missing-app/extension failure. |

## Post-initial corrections through `547f30a`

| Area | Root cause | Fix | Validation |
|---|---|---|---|
| Repository paths | Azure DevOps checks out the project with `AzureVirtualDesktopPoc` as a child folder. | Pipeline and command examples use the child-folder prefix consistently. | Hosted-agent file resolution in known-good runs. |
| Quota | Checking only Dsv6 missed the session-host family. | Require EBDSv5 quota for `Standard_E4bs_v5` and Dsv6 quota for Image Builder `Standard_D4s_v6`. | Prerequisite report plus portal/CLI quota evidence. |
| Bicep coverage | Validation described four entry points while six are deployed. | Compile `main`, `access`, `image-main`, `session-host`, `hybrid-main`, and `hybrid-access`. | `Test-AvdPocPrerequisites.ps1` compiles all six. |
| API permissions | Azure RBAC was conflated with Graph and MDE authorization. | Added Graph `User.Read.All`, `Device.Read.All`, `DeviceManagementManagedDevices.Read.All`, and WindowsDefenderATP `Machine.Read.All` to the appropriate separate identities. | User/device/managed-device/MDE queries succeed under least privilege. |
| Application gate | Substring matching could accept the wrong product or edition. | Azure-hosted readiness uses exact case-insensitive uninstall-registry `DisplayName` matching across 64/32-bit paths. | Missing exact name fails; configured full display name passes. |
| Token lifecycle | Long polls and stale AVD tokens caused intermittent failures. | Reuse AVD registration tokens only with 30+ minutes remaining; otherwise issue a 24-hour token. Refresh Graph/MDE tokens on 40-minute intervals and keep audiences separate. | Registration and long readiness polling complete without expired-token retry. |
| DSC timing | Extension success was mistaken for immediate AVD availability. | Treat DSC reboot/agent registration as asynchronous and let readiness polling determine availability. | Session host becomes `Available` after the expected transient gap. |
| Windows CLI | Windows command resolution and split `@file` arguments caused CLI parsing failures. | Support explicit `az.cmd`; pass each `@file` value as one argument. | What-if, deployment, and Run Command succeed on `windows-latest`. |
| Graph cleanup | `az rest` selected the wrong audience for Microsoft Graph. | Acquire an `ms-graph` token and use direct `Invoke-RestMethod`; keep ARM REST for AVD. | Plan enumerates exact IDs and optional execution deletes only those IDs. |
| SKU accuracy | Generic family labels obscured deployed sizes. | Documented `Standard_E4bs_v5` for session hosts and `Standard_D4s_v6` for Image Builder. | Live resource inventory matches templates. |
| Intune timing | Mandatory compliance on every run made routine rebuilds nondeterministic. | Routine gate uses `AVD_REQUIRE_INTUNE_COMPLIANT=false`; final acceptance is a separate `true` run. | Routine provisioning and later compliance acceptance are recorded separately. |
| Image script storage | Teardown removed POC-owned blob storage, leaving a stale customizer URI. | Recreate storage/container, republish exact content, and issue a new read-only URI before image rebuild. | Image pipeline downloads, hashes, and builds from the new URI. |
| Local administrator | A persistent documented password created secret-retention risk. | Generate a cryptographically random password per deployment, pass it as a secure parameter, and delete the temporary parameter file. | No password appears in repository or artifacts. |
| Least privilege | Bootstrap/decommission authority could remain active after use. | Separate WIF connections; ordinary roles omit deletes; decommission permissions are temporary and POC-scoped. | Role definitions and pipeline authorizations reviewed before/after reset. |
| Teardown targeting | Broad cleanup could affect shared or similarly named objects. | Require exact group names/tags, deterministic role IDs, exact case-sensitive directory matches, drain mode, and active-session refusal. | Plan artifact proves scope before approved execution. |
| Preservation | Cleanup expectations for external systems were unclear. | Preserve Azure DevOps, ServiceNow, hybrid resources, and MDE history; make Entra/Intune deletion optional. | Post-teardown evidence checklist. |
| Security scope | Conditional Access advice risked tenant-wide change. | Declared Conditional Access out of scope and prohibited all changes. | Static teardown test rejects Conditional Access references. |
| Acceptance | BitLocker was treated as an implied gate without implementation support. | Explicitly removed BitLocker from POC acceptance criteria. | Acceptance checks only implemented readiness signals. |
| ServiceNow | Legacy names/statuses diverged from the pipeline contract. | Canonicalized four camelCase parameters and statuses `Queued`, `In Progress`, `Ready`, `Failed`, `Timed Out`; documented implemented `SN_*` variables. | Queue script and callback pipeline use the documented names. |
| ServiceNow auth | Basic-only guidance did not describe the implemented OAuth path. | Made OAuth client credentials plus restricted Table API auth scope canonical; retained Basic as bootstrap fallback. | Token request and RITM PATCH succeed without logging secrets. |

## `547f30a` — validated correction baseline

The range closes with the implementation and documentation aligned around:

- deterministic POC01 teardown and rebuild;
- safe reuse of `RITM0000001` as `AVD0000001` after cleanup;
- separate routine and final Intune validation;
- no BitLocker requirement;
- no Conditional Access changes;
- least-privilege ordinary operation and temporary decommission authority.

Runs **167** and **194** are the known-good successful references for this correction series. Future changes must record a new run ID and retain the associated what-if, readiness, and ServiceNow evidence.
