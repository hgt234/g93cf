# EUC Early Adopter Pilot Program

Users join or leave the pilot by installing or uninstalling the Join app in
Company Portal. A sync runbook updates an Entra device group, and an optional
comms user group, from the app's Intune installation status. Devices must be
Intune-managed and Entra-joined.

The 10/30/60 phased rollout export is a separate, unrelated tool; see
[`../PhasedRollout`](../PhasedRollout/README.md).

## How it works

```
Company Portal: install or uninstall the Join app
    -> JoinApp writes/removes the HKLM opt-in marker; detection reports installed
    -> Intune app installation status
    -> GroupSync/Sync-EucPilotGroup.ps1 (local or Azure Automation)
    -> Entra pilot device group and optional comms group
    -> Pilot updates and apps
```

Each run:

- **Adds** devices reporting `installed` that checked in to Intune within
  `ActiveWithinDays` (30 by default), first come first served up to
  `MemberCap`.
- **Removes** devices reporting `notInstalled` or `notApplicable`, devices no
  longer in the report or in Intune, and **inactive** devices (no Intune
  check-in within `ActiveWithinDays`), so a shelved or reimaged device cannot
  hold a pilot slot. An inactive device that checks in again rejoins through
  the normal first-come-first-served queue.
- **Holds** active devices in pending, failed, uninstall-failed, or unknown
  states where they are.

Users install the app on each device they want to include. The comms group
contains the Intune primary users of the planned pilot devices, taken
directly from each device's `userId`. Use a dedicated group: other user
members are removed, except group owners.

## Layout

| Path | Purpose |
|---|---|
| `JoinApp/Package/Install-EucPilotJoin.ps1` | Win32 installer: writes the opt-in marker |
| `JoinApp/Package/Uninstall-EucPilotJoin.ps1` | Win32 uninstaller: removes the marker |
| `JoinApp/Detect-EucPilotJoin.ps1` | Win32 custom detection script (uploaded separately) |
| `JoinApp/Build-IntuneWin.ps1` | Packages only `JoinApp/Package` into the .intunewin |
| `GroupSync/Sync-EucPilotGroup.ps1` | Runbook: reconciles the pilot and comms groups |
| `tests/Sync-EucPilotGroup.Tests.ps1` | Offline Pester tests for the runbook |
| `Test-EucPilotProgram.ps1` | Validation gate: parse, analyzer, Join app contract, Pester |
| `PSScriptAnalyzerSettings.psd1` | Windows PowerShell 5.1 compatibility rules |

## Safety

The runbook stops before any write when:

- any Graph call fails (errors are never treated as an empty state);
- the install report has no valid `TotalRowCount`, the total changes between
  pages, a row repeats (unstable paging), or fewer rows arrive than the total;
- the report is empty while the pilot group has members;
- planned removals for either group exceed `MaxRemovals`.

Report pages use a stable sort and advance by the rows actually returned.
Graph calls retry HTTP 429/502/503/504/509, honor `Retry-After` (seconds or
HTTP date), and refresh the managed identity token once on HTTP 401. Batch
responses with unexpected, duplicate, or missing ids stop the run.

Every membership change goes through `ShouldProcess` with
`ConfirmImpact = 'High'`. Interactive runs prompt for each change unless you
pass `-Force` (or `-Confirm:$false`); `-WhatIf` reads everything, prints the
plan, and changes nothing.

## Authentication

| Mode | Sign-in | Dependency |
|---|---|---|
| Local | `Connect-MgGraph` with MFA/Conditional Access | `Microsoft.Graph.Authentication` |
| Azure Automation | System-assigned managed identity | None |

The runbook uses managed identity when `IDENTITY_ENDPOINT` and
`IDENTITY_HEADER` are present; otherwise it prompts for sign-in. Managed
identity runs must pass `-Force` or `-WhatIf`, because the Automation host
cannot answer confirmation prompts; without either, the run stops before
reading any group.

### Required permissions

Local runs use these delegated permissions:

- `DeviceManagementApps.Read.All` (install status report)
- `DeviceManagementManagedDevices.Read.All` (managed device, primary user, last check-in)
- `Device.Read.All` (Entra device objects and group device members)
- `User.Read.All` (user properties in comms group listings; without a user
  read permission Graph returns only `id` for user members)
- `GroupMember.ReadWrite.All` (group membership reads and writes)

Azure Automation uses the same five application permissions, granted to its
managed identity by an administrator. Delegated membership writes also require
the signed-in user's group-management rights, such as ownership or an active
Intune Administrator role for security groups.

`GroupMember.ReadWrite.All` as an application role can change the membership
of any non-role-assignable group in the tenant. Restrict who can edit or run
the Automation account accordingly.

## Read-only demo export

Export the devices that would qualify, for manual group import:

```powershell
.\GroupSync\Sync-EucPilotGroup.ps1 -JoinAppId <app-guid> -ReadOnly -ExportDirectory C:\Temp\EucPilot
```

This mode requests only the first three (read) scopes, makes no group calls,
and sends no Teams notification; `PilotGroupId` is optional. It writes two
timestamped UTF-8 CSVs (confirm the export prompt, or add `-Force`):

- **`EucPilotCandidates-<timestamp>.csv`**: `DeviceName`, `EntraObjectId`,
  `EntraDeviceId`, `IntuneManagedDeviceId`, `AssignedUserPrincipalName`,
  `InstallState`, `FirstInstalled`, and `LastCheckIn` (ISO 8601 UTC).
- **`EntraGroupImport-<timestamp>.csv`**: device object IDs in Entra's
  group-member import format.

Only active installed devices are exported (inactive ones are logged), sorted
by first installation time and name. `MemberCap` does not limit the export.
`FirstInstalled` is the earliest install-report status change, not a
guaranteed installation date. `-WhatIf` suppresses file creation.

To load a group manually, open **Entra ID > Groups > All groups > your group >
Members > Bulk operations > Import members** and upload the `EntraGroupImport`
CSV after comparing its header with the portal template. See
[Microsoft's bulk group-member import instructions](https://learn.microsoft.com/en-us/entra/identity/users/groups-bulk-import-members).

## Local testing

1. Copy the Join app's **Object ID** from Intune.
2. Create `SEC-EUC-Pilot-Devices-POC` in Entra as an **assigned security
   group** (not dynamic or synced) and copy its **Object ID**.
3. Install a working authentication module:

   ```powershell
   Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser -Force
   ```

   Versions **2.41.0 and 2.41.1** have a `System.Text.Json` sign-in issue and
   are skipped. If either was already loaded, open a new PowerShell session.
4. Preview changes:
   `.\GroupSync\Sync-EucPilotGroup.ps1 -JoinAppId <id> -PilotGroupId <gid> -WhatIf`
   Sign in and review the plan. Add `-UseDeviceCode` if browser sign-in hangs.
5. Run without `-WhatIf` and confirm each change (or add `-Force`). Run again
   to confirm there are no further changes. Remove a device manually and rerun
   to check that it is added back.
6. To test the empty-report guard, use an app with no report rows while the
   pilot group contains a device. The run should stop before changes.

If the tenant restricts user consent, an admin grants tenant-wide consent to
the **Microsoft Graph PowerShell** application for the five scopes above.

For report errors HTTP 400/404, try
`-InstallReportAction getDeviceInstallStatusReport`.

## Azure Automation

1. Import `GroupSync/Sync-EucPilotGroup.ps1` as a PowerShell runbook. It is a
   single self-contained file; no Graph modules are needed.
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
   | `Force` | false | **Set to true on schedules**; unattended runs cannot answer prompts |
   | `CommsGroupId` | none | Optional dedicated user group for pilot comms |
   | `MemberCap` | 50 | Max pilot devices; extra installs are deferred first-come-first-served. 0 = no cap |
   | `MaxRemovals` | 10 | Abort the run if more removals are planned for either group |
   | `ActiveWithinDays` | 30 | Devices without an Intune check-in in this many days are removed/not added. 0 = off |
   | `DeviceLookup` | Auto | `Batch` per device, `Bulk` lists all devices once; Auto = Bulk above 1,000 |
   | `TeamsWebhookVariable` | none | Name of the encrypted variable from step 4 |
   | `TeamsWebhookUri` | none | Direct webhook URL for local runs only |
   | `InstallReportAction` | `retrieveDeviceAppInstallationStatusReport` | Report action fallback switch |
   | `ReadOnly` / `ExportDirectory` | false / current directory | Demo export instead of group changes |

6. Schedule hourly; Intune installation status can take time to update.
7. Assign pilot updates and apps to the group. **Exclude it from production
   update rings** to avoid overlapping assignments.

When upgrading an existing schedule, add `Force = true` and run once with
`WhatIf = true` first: the new inactivity rule can plan removals for devices
that have not checked in for 30 days, and `MaxRemovals` stops the run if
there are more than expected.

## Intune app packaging

1. Obtain Microsoft's IntuneWinAppUtil, then build the package:

   ```powershell
   .\JoinApp\Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe
   ```

   Only `JoinApp/Package` is packaged. Output is saved to
   `EucPilotProgramOutput` at the repository root.

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
   `JoinApp/Detect-EucPilotJoin.ps1`. Leave the "run as 64-bit" toggle at its
   default; enable signature checking only if the scripts are signed.
6. Assignment: **Available for enrolled devices** so users install it from
   Company Portal and can uninstall it to leave the pilot.

The app writes a `Joined` marker under `HKLM:\SOFTWARE\EucPilotProgram`.
Detection checks `WOW6432Node` first, then the native path, and writes a line
to STDOUT on success (Intune requires exit 0 plus STDOUT); uninstall removes
both. The marker is for app detection, while the Entra group controls pilot
assignments. Installation requires a working Intune Management Extension.

## Validation

Run `.\Test-EucPilotProgram.ps1` before committing. It parses every script,
runs PSScriptAnalyzer (Windows PowerShell 5.1 compatibility), checks the Join
app registry and package contract, and runs the Pester tests. Everything is
offline: the runbook runs end to end against an in-memory fake tenant with
only sign-in and HTTP replaced. Requires PSScriptAnalyzer and Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -SkipPublisherCheck
```

## Troubleshooting

| Case | Behavior |
|---|---|
| Shared device | Device-wide signal; every user of the device gets pilot payloads |
| Stale report entry (managed device deleted) | Skipped and logged; does not halt the run |
| Intune device with no Entra object | Skipped before the cap, never consumes a slot |
| Device inactive for `ActiveWithinDays` | Logged as `INACTIVE`, removed if a member, not added |
| Member cap reached | Removals free slots first; remaining adds are deferred oldest-install-first |
| Primary user deleted | Comms add logged as `notFound`; the run continues |
| Managed identity run prompts or stops with "must pass -Force" | Set `Force = true` on the schedule |
| Teams webhook fails | Logged as a warning; membership changes stand |

The runbook uses Graph v1.0, except for the Intune installation report, which
uses `/beta/deviceManagement/reports`. Group member reads use `$select` and
`$top=999` without OData type casts, because casts require
`ConsistencyLevel: eventual`, whose index can lag recent membership changes.
