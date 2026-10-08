# EUC Early Adopter Pilot Program

Users join or leave the pilot by installing or uninstalling the Join app in
Company Portal. The sync script updates an Entra device group using the app's
Intune installation status. Devices must be Intune-managed and Entra-joined.

## How it works

```
Company Portal: install or uninstall the Join app
    -> Intune app installation status
    -> Sync-EucPilotGroup.ps1 (Local or Azure Automation)
    -> Entra pilot device group and optional comms group
    -> Pilot updates and apps
```

Each run adds devices reporting `installed` and removes devices reporting
`notInstalled`, `notApplicable`, or no longer present in the report or Intune.
Pending, failed, uninstall-failed, and unknown states leave membership as it is.
Users install the app on each device they want to include.

The optional comms group contains the Intune primary users of pilot devices.
Use a dedicated group: other user members are removed, except group owners.

The sync script stops on Graph errors or incomplete reports, retries HTTP
429/503/504 responses, and checks `MaxRemovals` before making changes. An empty
report stops the run when the pilot group contains devices. Devices already
in the requested membership state are left alone.

## Files

| File | Purpose |
|---|---|
| `Sync-EucPilotGroup.ps1` | Sync script for pilot and comms group membership |
| `Install-EucPilotJoin.ps1` | Win32 wrapper installer (writes the opt-in marker) |
| `Uninstall-EucPilotJoin.ps1` | Win32 wrapper uninstaller (removes the marker) |
| `Detect-EucPilotJoin.ps1` | Win32 custom detection script |
| `Build-IntuneWin.ps1` | Packages the .intunewin with IntuneWinAppUtil |
| `Test-EucPilotProgram.ps1` | Offline parser, analyzer, and Join-app contract checks |
| `PSScriptAnalyzerSettings.psd1` | Windows PowerShell 5.1 compatibility rules |

## Authentication

| Mode | Sign-in | Dependency |
|---|---|---|
| Local | `Connect-MgGraph` with MFA/Conditional Access | `Microsoft.Graph.Authentication` |
| Azure Automation | System-assigned managed identity | None |

The script uses managed identity when `IDENTITY_ENDPOINT` and `IDENTITY_HEADER`
are present; otherwise it prompts for sign-in.

### Required permissions

Local runs use these delegated permissions:

- `DeviceManagementApps.Read.All` (install status report)
- `DeviceManagementManagedDevices.Read.All` (managed device -> Entra device ID)
- `Device.Read.All` (Entra device objects and group device members)
- `User.Read.All` (comms group user lookup)
- `GroupMember.ReadWrite.All` (group membership writes)

Azure Automation uses the same five application permissions, granted to its
managed identity by an administrator. Delegated membership writes also require
the signed-in user's group-management rights, such as ownership or an active
Intune Administrator role for security groups.

`GroupMember.ReadWrite.All` as an application role can change the membership
of any non-role-assignable group in the tenant. Restrict who can edit or run
the Automation account accordingly.

### Read-only demo export

Export installed devices for manual group import:

```powershell
.\Sync-EucPilotGroup.ps1 -JoinAppId <app-guid> -ReadOnly -ExportDirectory C:\Temp\EucPilot
```

This mode requests only `DeviceManagementApps.Read.All`,
`DeviceManagementManagedDevices.Read.All`, and `Device.Read.All`. Consent and
user access are still required. It exports data without group operations or
Teams notifications; `PilotGroupId` is optional.

Two timestamped UTF-8 CSVs are saved to `ExportDirectory` (the current directory
by default):

- **`EucPilotCandidates-<timestamp>.csv`**: `DeviceName`, `EntraObjectId`,
  `EntraDeviceId`, `IntuneManagedDeviceId`, `AssignedUserPrincipalName`,
  `InstallState`, and `FirstInstalled` (ISO 8601).
- **`EntraGroupImport-<timestamp>.csv`**: device object IDs in Entra's
  group-member import format.

The export includes each resolved installed device once, sorted by first
installation time and machine name. Missing records are logged and skipped.
The assigned-user UPN is the Intune primary user; it and the installation time
can be blank. `MemberCap` does not limit the export. Empty results produce
header-only CSVs; adding `-WhatIf` suppresses file creation.

To load the pilot device group, open **Entra ID > Groups > All groups >
your group > Members > Bulk operations > Import members**. Review the
`EntraGroupImport` CSV and compare its header with the portal template before
uploading. The import adds devices; existing members may be reported as already
present. For individual additions, use `EntraObjectId`. Import requires your
own group-management rights, such as active Intune Administrator PIM.

See [Microsoft's bulk group-member import instructions](https://learn.microsoft.com/en-us/entra/identity/users/groups-bulk-import-members).

## Local testing

1. Copy the Join app's **Object ID** from Intune. For a demo, you can use an
   app already installed on your test device.
2. Create `SEC-EUC-Pilot-Devices-POC` in Entra as an **assigned security
   group** (not dynamic or synced) and copy its **Object ID**.
3. Install a working authentication module:

   ```powershell
   Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser -Force
   ```

   Versions **2.41.0 and 2.41.1** have a `System.Text.Json` sign-in issue and
   are skipped. If either was already loaded, open a new PowerShell session.
4. Preview changes:
   `.\Sync-EucPilotGroup.ps1 -JoinAppId <id> -PilotGroupId <gid> -WhatIf`
   Sign in and review the plan. Add `-UseDeviceCode` if browser sign-in hangs.
5. Remove `-WhatIf` to apply changes. Run again to confirm there are no further
   changes. Remove a device manually and rerun to check that it is added back.
6. To test the empty-report guard, use an app with no report rows while the
   pilot group contains a device. The run should stop before changes.

If the tenant restricts user consent, an admin grants tenant-wide consent to
the **Microsoft Graph PowerShell** application for the five scopes above.

For report errors HTTP 400/404, try
`-InstallReportAction getDeviceInstallStatusReport`.

## Azure Automation

1. Import `Sync-EucPilotGroup.ps1` as a runbook. No Graph modules needed.
2. Enable the system-assigned managed identity.
3. Admin-consent the five application roles to that identity.
4. For Teams notifications, create a **Workflows** webhook and store its URL
   in an **encrypted** Automation variable, such as `EucPilotTeamsWebhook`.
   Pass its name through `TeamsWebhookVariable`. Avoid passing the URL as a
   runbook parameter, since parameters are recorded in job history.
5. Set runbook parameters:

   | Parameter | Default | Purpose |
   |---|---|---|
   | `JoinAppId` | required | Intune Join app object ID |
   | `PilotGroupId` | required | Assigned security group for pilot devices |
   | `ReadOnly` | false | Export installed devices without group operations; makes `PilotGroupId` optional |
   | `ExportDirectory` | current directory | Local directory for detail and device bulk-import CSVs with `ReadOnly` |
   | `CommsGroupId` | none | Optional dedicated user group for pilot comms |
   | `MemberCap` | 50 | Max pilot devices; extra installs are deferred first-come-first-served. 0 = no cap |
   | `MaxRemovals` | 10 | Abort the run if more removals are planned for either group |
   | `TeamsWebhookVariable` | none | Name of the encrypted variable from step 4 |
   | `TeamsWebhookUri` | none | Direct webhook URL for local runs |
   | `InstallReportAction` | `retrieveDeviceAppInstallationStatusReport` | Report action fallback switch |

6. Schedule hourly; Intune installation status can take time to update.
7. Assign pilot updates and apps to the group. **Exclude it from production
   update rings** to avoid overlapping assignments.

## Intune app packaging

1. Obtain Microsoft's IntuneWinAppUtil, then build the package:

   ```powershell
   .\Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe
   ```

   Output is saved to `EucPilotProgramOutput` beside this folder.

2. Create a Windows app (Win32) in Intune with these values:
   - Install behavior: **System**
   - Device restart behavior: **No specific action**
   - 64-bit client: **Yes**
3. Install command:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-EucPilotJoin.ps1
   ```

4. Uninstall command:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-EucPilotJoin.ps1
   ```

5. Detection rule: **Use a custom detection script**, upload
   `Detect-EucPilotJoin.ps1`. Leave the "run as 64-bit" toggle at its default;
   enable signature checking only if the scripts are signed.
6. Assignment: **Available for enrolled devices** so users install it from
   Company Portal and can uninstall it to leave the pilot.

The app writes a `Joined` marker under `HKLM:\SOFTWARE\EucPilotProgram`.
Detection checks `WOW6432Node` first, then the native path; uninstall removes
both. The marker is for app detection, while the Entra group controls pilot
assignments. Installation requires a working Intune Management Extension.

## Validation

Run `.\Test-EucPilotProgram.ps1` before committing script changes. It checks
parsing, Windows PowerShell 5.1 compatibility, and the Join app registry
contract offline. Use `-WhatIf` on the sync script to preview live changes.

## Troubleshooting

| Case | Behavior |
|---|---|
| Shared device | Device-wide signal; every user of the device gets pilot payloads |
| Stale report entry (managed device deleted) | Skipped and logged; does not halt the run |
| Intune device with no Entra object | Skipped before the cap, never consumes a slot |
| Member cap reached | Removals free slots first; remaining adds are deferred oldest-install-first |
| Teams webhook fails | Logged as a warning; membership changes stand |

The sync script uses Graph v1.0, except for the Intune installation report,
which uses `/beta/deviceManagement/reports`.
