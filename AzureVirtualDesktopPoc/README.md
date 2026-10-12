# Automated Azure Virtual Desktop POC

This repository automates personal Windows 11 desktops requested through ServiceNow. It has two isolated paths:

- Azure-hosted session hosts in `rg-avd-poc01`;
- manually built Proxmox GPU hosts connected through Azure Arc and AVD Hybrid in `rg-avd-hybrid-poc01`.

Both paths validate the request, wait for management and security readiness, directly assign the user, and update the RITM. Azure-hosted VMs have no inbound public IP.

Start with [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md). For reset testing, use [docs/TEARDOWN-REBUILD-VALIDATION.md](docs/TEARDOWN-REBUILD-VALIDATION.md). For Proxmox, also use [HYBRID-DEPLOYMENT-RUNBOOK.md](HYBRID-DEPLOYMENT-RUNBOOK.md).

## Request contract

ServiceNow sends exactly four immutable pipeline parameters:

```json
{
  "templateParameters": {
    "ritmNumber": "RITM0000001",
    "ritmSysId": "0123456789abcdef0123456789abcdef",
    "requestedHostName": "AVD0000001",
    "requestedForUpn": "user@contoso.com"
  }
}
```

The hostname is always `AVD` plus the RITM digits, including leading zeros. Azure DevOps recomputes it and rejects a mismatch. Valid lifecycle values are `Queued`, `In Progress`, `Ready`, `Failed`, and `Timed Out`.

## End-to-end flow

1. ServiceNow derives the hostname and queues `pipelines/azure-pipelines-session-host.yml`.
2. Azure DevOps validates all four request fields and marks the RITM `In Progress`.
3. Provisioning resolves the Entra user and latest usable gallery image, then reuses an AVD registration token only when at least 30 minutes remain; otherwise it creates a 24-hour token.
4. Bicep creates a private `Standard_E4bs_v5` VM with Trusted Launch, Standard SSD, Entra login/MDM extension, and the AVD DSC extension.
5. Readiness checks Azure, Entra, optional Intune enrollment/compliance, exact installed-app display names, MDE, and AVD `Available` state.
6. Assignment grants Azure VM login and AVD application-group access, then directly assigns the personal host.
7. ServiceNow becomes `Ready`. Failure preserves the VM, requests drain mode, and writes `Failed`.

The DSC extension can finish before the guest reboot and AVD agent registration are visible. Readiness polling—not extension completion—is the handoff boundary.

## Repository map

The repository may be checked out as a child folder named `AzureVirtualDesktopPoc`; pipeline paths intentionally include that prefix.

```text
AzureVirtualDesktopPoc/
├── config/       Azure DevOps variable-group examples
├── docs/         change history, reset/rebuild validation, and cost notes
├── image/        generalized image customizer
├── infra/        six deployable Bicep entry points, parameters, and modules
├── pipelines/    Azure-hosted and hybrid Azure DevOps pipelines
├── scripts/      deployment, readiness, assignment, and teardown operations
├── servicenow/   Flow Designer queue scripts and concise integration contract
└── tests/        static safety and request-contract tests
```

### Six Bicep entry points

- `infra/main.bicep`: Azure-hosted platform and network.
- `infra/access.bicep`: Azure-hosted no-delete workload roles.
- `infra/image-main.bicep`: image identity, gallery, definition, and template.
- `infra/session-host.bicep`: one private Azure-hosted session host.
- `infra/hybrid-main.bicep`: isolated AVD Hybrid control plane.
- `infra/hybrid-access.bicep`: hybrid no-delete workload roles.

### Main guides

- [DEPLOYMENT-RUNBOOK.md](DEPLOYMENT-RUNBOOK.md): Azure-hosted deployment and acceptance.
- [HYBRID-DEPLOYMENT-RUNBOOK.md](HYBRID-DEPLOYMENT-RUNBOOK.md): Proxmox/Arc/AVD Hybrid onboarding.
- [ServiceNowconfig.md](ServiceNowconfig.md): canonical detailed ServiceNow configuration.
- [servicenow/README.md](servicenow/README.md): request and callback quick reference.
- [docs/IMPLEMENTATION-CHANGELOG.md](docs/IMPLEMENTATION-CHANGELOG.md): implementation corrections and validated runs.
- [docs/TEARDOWN-REBUILD-VALIDATION.md](docs/TEARDOWN-REBUILD-VALIDATION.md): exact POC01 reset and rebuild procedure.
- [docs/Hybrid-Cost-Model.md](docs/Hybrid-Cost-Model.md): 30-day Azure versus hybrid cost model.

## Required capacity and permissions

Confirm both regional quota families:

- **Standard EBDSv5 Family vCPUs** for `Standard_E4bs_v5` session hosts;
- **Standard Dsv6 Family vCPUs** for the temporary `Standard_D4s_v6` Image Builder VM.

Use workload identity federation and separate service connections:

- deployment: POC-scoped VM/network deployment, Graph `User.Read.All`, and host-pool registration-token operations;
- readiness: POC Azure reads/Run Command, Graph `Device.Read.All` and `DeviceManagementManagedDevices.Read.All`, and WindowsDefenderATP `Machine.Read.All`;
- assignment: Graph `User.Read.All`, role-assignment read/write, and personal-host assignment;
- decommission: disabled or unprivileged except during an approved reset, then granted temporary POC-only delete and optional directory-record permissions.

Ordinary identities and custom roles contain no delete actions. Do not grant service connections to all pipelines.

## Operational boundaries

- Routine runs use `AVD_REQUIRE_INTUNE_COMPLIANT=false`; final acceptance is a separate run with it set to `true`. MDE remains required.
- Required applications use exact, case-insensitive installed `DisplayName` matching. Configure full names, not substrings.
- The local administrator password is generated per deployment, passed as a secure Bicep parameter, removed with the temporary parameter file, and not retained by the pipeline.
- The image customization script is external immutable content. A POC-owned storage account/container inside the deleted resource group is deleted during reset and must be recreated and repopulated before image rebuild.
- MDE inventory is not deleted by teardown; it ages out according to Defender retention.
- BitLocker is not an acceptance requirement for this POC.
- **Conditional Access is out of scope; do not touch it.**

## Validation

Run the static test suite and compile all six entry points:

```powershell
pwsh ./AzureVirtualDesktopPoc/tests/Test-AvdPoc.ps1
pwsh ./AzureVirtualDesktopPoc/scripts/Test-AvdPocPrerequisites.ps1 `
  -SubscriptionId <subscription-id> `
  -TenantId <tenant-id> `
  -Location centralus `
  -VmSize Standard_E4bs_v5
```

Known-good successful Azure DevOps runs are **167** and **194**. Treat them as historical evidence, not a substitute for validating the current commit and tenant.
