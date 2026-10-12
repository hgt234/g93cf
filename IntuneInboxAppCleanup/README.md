# Intune Inbox App Cleanup

This Intune Remediations package removes these inbox Appx packages:

| Display name | Appx package name | Package family name (PFN) |
|---|---|---|
| Get Help | `Microsoft.GetHelp` | `Microsoft.GetHelp_8wekyb3d8bbwe` |
| Mixed Reality Portal | `Microsoft.MixedReality.Portal` | `Microsoft.MixedReality.Portal_8wekyb3d8bbwe` |
| Maps | `Microsoft.WindowsMaps` | `Microsoft.WindowsMaps_8wekyb3d8bbwe` |

The remediation removes both package states that matter:

- registrations for existing user profiles, using `Remove-AppxPackage -AllUsers`;
- provisioning for future user profiles, using `Remove-AppxProvisionedPackage -Online`.

It then inventories the device again and exits with failure if Windows left any target in
place. This prevents a protected or busy package from being reported as successfully removed.

## Recommended deployment

Keep the Windows policy as the authoritative reinstallation block. On supported Windows 11
Enterprise or Education devices, create a device-targeted Settings Catalog policy under:

```text
Administrative Templates > Windows Components > App Package Deployment
```

Enable **Remove Microsoft Store apps with dynamic list** and enter these PFNs, one per line:

```text
Microsoft.GetHelp_8wekyb3d8bbwe
Microsoft.MixedReality.Portal_8wekyb3d8bbwe
Microsoft.WindowsMaps_8wekyb3d8bbwe
```

The policy-based removal feature requires Windows 11 24H2 or later and Enterprise or
Education edition. It runs at provisioning or user sign-in, not immediately in an existing
session. Use the remediation below to clean up packages that are already registered.

Create an Intune Remediations script package with:

- Detection script: `Detect-InboxAppCleanup.ps1`
- Remediation script: `Remediate-InboxAppCleanup.ps1`
- Run this script using the logged-on credentials: **No**
- Enforce script signature check: according to the organization's signing policy
- Run script in 64-bit PowerShell: **Yes**
- Assignment: a pilot device group first, then the required device groups
- Schedule: daily during rollout; reduce the frequency after compliance stabilizes

Removing Get Help can affect links that use the `ms-contact-support` protocol. Confirm that
the service desk does not rely on it before broad deployment. Removing Maps deletes local app
data, including app-managed offline map data.

## Add or remove targets

Edit `$targetPackageNames` in both the detection and remediation scripts. Use the package
`Name`, not its versioned `PackageFullName` or PFN. Discover names and PFNs on a representative
device with elevated 64-bit Windows PowerShell:

```powershell
Get-AppxPackage -AllUsers -PackageTypeFilter Bundle,Main |
    Sort-Object Name |
    Select-Object Name, PackageFamilyName, IsPartOfSystem

Get-AppxProvisionedPackage -Online |
    Sort-Object DisplayName |
    Select-Object DisplayName, PackageName
```

Run `Test-InboxAppCleanup.ps1` after editing. It checks PowerShell syntax and verifies that
both scripts contain the same target list.

## Troubleshooting

If remediation remains noncompliant, inspect:

```powershell
Get-AppxPackage -AllUsers -PackageTypeFilter Bundle,Main |
    Where-Object Name -in @(
        'Microsoft.GetHelp',
        'Microsoft.MixedReality.Portal',
        'Microsoft.WindowsMaps'
    ) |
    Select-Object Name, PackageFullName, PackageFamilyName, IsPartOfSystem,
        NonRemovable, PackageUserInformation

Get-AppxProvisionedPackage -Online |
    Where-Object DisplayName -in @(
        'Microsoft.GetHelp',
        'Microsoft.MixedReality.Portal',
        'Microsoft.WindowsMaps'
    ) |
    Select-Object DisplayName, PackageName
```

Also review **Applications and Services Logs > Microsoft > Windows > AppxDeployment-Server >
Operational**. With policy-based removal, event 614 indicates removal failure, event 873
identifies a system component that Windows refused to remove, and event 875 indicates a
malformed PFN.

### Protected system components

`IsPartOfSystem` and `NonRemovable` mean different things. A package can be part of Windows
and still support removal. If `NonRemovable` is `True`, Windows doesn't provide a supported
Appx uninstall path; the remediation reports that state instead of trying to delete protected
files or Appx registration keys.

For Mixed Reality Portal on Windows versions that still include Windows Mixed Reality, remove
the related Windows capability first from elevated 64-bit Windows PowerShell:

```powershell
$capabilities = Get-WindowsCapability -Online |
    Where-Object {
        $_.Name -like 'Analog.Holographic.Desktop*' -and
        $_.State -eq 'Installed'
    }

$capabilities | Remove-WindowsCapability -Online
```

Restart the device, then rerun the Appx remediation. Don't hard-code a capability version;
discover its complete identity on the target device as shown above.

For any package that remains `NonRemovable=True`, leave the component serviced by Windows and
control exposure instead: remove its Start pin and use an AppLocker packaged-app rule or App
Control for Business policy when execution must be blocked. Taking ownership of
`C:\Program Files\WindowsApps`, deleting package folders, or editing the Appx repository is not
a supported removal method and can break cumulative updates, feature updates, Sysprep, and
component repair.
