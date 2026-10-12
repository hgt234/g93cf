# Intune configuration inventory report

`Export-IntuneConfigurationReport.ps1` creates a read-only inventory for Intune policy
consolidation. It covers:

- Settings Catalog and modern endpoint-security profiles
- Legacy Windows device-configuration profiles
- Legacy Administrative Templates (ADMX)
- Included and excluded groups
- All Users and All Devices assignments
- Intune assignment filters and filter rules
- Duplicate setting IDs across policies, as consolidation candidates

## Prerequisites

- PowerShell 7 or later
- An Intune-licensed tenant
- An account that can read Intune configuration and Entra groups
- The Microsoft Graph authentication module

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

The interactive sign-in requests these delegated scopes:

- `DeviceManagementConfiguration.Read.All`
- `Group.Read.All`

An administrator might need to grant consent in your tenant. The script only sends GET
requests and does not change Intune.

## Run

```powershell
Set-Location D:\Git\CPF\g93cf
./Export-IntuneConfigurationReport.ps1 -OutputPath C:\Reports\IntuneBaseline
```

Or select a tenant explicitly:

```powershell
./Export-IntuneConfigurationReport.ps1 `
    -TenantId contoso.onmicrosoft.com `
    -OutputPath C:\Reports\IntuneBaseline
```

The default report is Windows-focused. Use `-IncludeNonWindows` for every platform. Use
`-SkipLegacyAdministrativeTemplates` if your tenant no longer has the older ADMX profile
type.

## Output

| File | Purpose |
|---|---|
| `IntuneConfigurationReport.html` | Self-contained searchable report |
| `IntunePolicySettings.csv` | One row per configured setting, with assignment summary |
| `IntunePolicyAssignments.csv` | One row per include/exclude assignment and filter |
| `IntuneSettingOverlap.csv` | Setting IDs appearing in more than one policy |

The overlap file is a shortlist, not an automatic merge plan. The same setting can be
intentional when policies target mutually exclusive groups or assignment filters. Compare
scope, value, platform, and technology before removing or combining a policy.

Likely passwords, secrets, certificate payloads, and unusually long values are redacted by
default. `-ShowSensitiveValues` disables that guard; protect the output appropriately.

## Notes

Modern Intune configuration resources are currently exposed through Microsoft Graph beta.
Microsoft recommends v1.0 when an API is available there; beta APIs can change. If a legacy
resource family is unavailable in a tenant, the script warns and continues with the other
policy families.
