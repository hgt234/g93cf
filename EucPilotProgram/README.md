# EUC Early Adopter Pilot Program

Self-service opt-in/opt-out for an Intune-managed, Entra-joined Windows pilot
ring. The user's action in the Company Portal is the signal; a reconciler
keeps an Entra device group in sync with that signal. No Forms, no Flow, no
premium licensing, no secrets.

## How it works

```
JOIN:   Company Portal -> Install "EUC Early Adopter - Join"
LEAVE:  Company Portal -> Uninstall the app
          |
          v
Intune app install status per device ("installed")
          |
          v
Sync-EucPilotGroup.ps1 (POC: interactive | PROD: Azure Automation managed identity)
  1. POST Intune install status report -> desired state
  2. GET pilot group members           -> current state
  3. guards -> remove opted-out devices -> add new devices within the cap
  4. comms-group sync, audit summary
          |
          v
Pilot rings / feature updates / app pilots
(production rings must exclude the pilot group)
```

- **State-based, not event-based.** Like a Configuration Manager collection
  query, every run converges to "installed = in group." Missed runs, drift,
  and resubmissions self-heal.
- **The device is the context.** Installing the app on a device opts that
  device in. Multi-device users install on each device they want piloted.
- **Only explicit opt-out removes.** `installed` adds; `notInstalled`,
  `notApplicable`, or a device gone from the report/Intune removes.
  Transient states (`pendingInstall`, `failed`, `uninstallFailed`,
  `unknown`) hold the device where it is.
- **Error is never empty.** Any Graph failure halts the run. A report with
  zero rows, a partial report, or more than `-MaxRemovals` planned removals
  aborts before any write.
- **Idempotent.** "Already a member" (HTTP 400 with that specific error) and
  "not a member" (HTTP 404) are absorbed, so re-runs are always safe. Any
  other 400 halts the run.
- **Throttle-aware.** HTTP 429/503/504 are retried, honoring `Retry-After`.

## Files

| File | Purpose |
|---|---|
| `Sync-EucPilotGroup.ps1` | Reconciler: app status -> pilot group membership |
| `Install-EucPilotJoin.ps1` | Win32 wrapper installer (writes the opt-in marker) |
| `Uninstall-EucPilotJoin.ps1` | Win32 wrapper uninstaller (removes the marker) |
| `Detect-EucPilotJoin.ps1` | Win32 custom detection script |
| `Build-IntuneWin.ps1` | Packages the .intunewin with IntuneWinAppUtil |
| `Test-EucPilotProgram.ps1` | Offline parser, analyzer, and Join-app contract checks |
| `PSScriptAnalyzerSettings.psd1` | Windows PowerShell 5.1 compatibility rules |

## Authentication

| Mode | When | Mechanism | Dependencies |
|---|---|---|---|
| Interactive (POC) | Run as a signed-in user | `Connect-MgGraph` prompt with MFA/Conditional Access | `Microsoft.Graph.Authentication` module |
| Managed identity (PROD) | Azure Automation runbook | Automation identity endpoint (`IDENTITY_ENDPOINT` + `IDENTITY_HEADER`) | None (raw REST) |

The script auto-detects the branch: `IDENTITY_ENDPOINT` and `IDENTITY_HEADER`
present means managed identity; otherwise the interactive prompt opens.

### Required permissions

Interactive (delegated, consented at the prompt):

- `DeviceManagementApps.Read.All` (install status report)
- `DeviceManagementManagedDevices.Read.All` (managed device -> Entra device ID)
- `Device.Read.All` (Entra device objects and group device members)
- `User.Read.All` (comms group user lookup)
- `GroupMember.ReadWrite.All` (group membership writes)

Production (application roles on the managed identity, admin-consented once):

- Same five roles, granted to the Automation account's system-assigned
  identity.

`GroupMember.ReadWrite.All` as an application role can change the membership
of any non-role-assignable group in the tenant. Restrict who can edit or run
the Automation account accordingly.

## POC run steps

1. Pick or create the Join app in Intune and copy its **Object ID**
   (`GET /deviceAppManagement/mobileApps?$filter=displayName eq '...'`).
   For a quick POC, any app already installed on your test device works.
2. Create `SEC-EUC-Pilot-Devices-POC` in Entra as an **assigned security
   group** (not dynamic, not synced) and copy its **Object ID**. The script
   refuses to run against any other group type.
3. Install the SDK once:
   `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`.
4. Dry run:
   `.\Sync-EucPilotGroup.ps1 -JoinAppId <id> -PilotGroupId <gid> -WhatIf`
   Sign in at the interactive prompt (MFA applies), review the planned diff.
5. Real run: drop `-WhatIf`. Verify the device appears in the group.
6. Run again: expect zero adds and zero removes (idempotency).
7. Delete the device from the group in the portal, re-run, confirm re-add.
8. Failure guard: with at least one device in the group, run with a bogus
   `-JoinAppId`. The report returns no rows and the script must abort
   without removing anything.

If the tenant restricts user consent, an admin grants tenant-wide consent to
the **Microsoft Graph PowerShell** application for the five scopes above.

If the install report call fails with HTTP 400/404, switch the report action
with `-InstallReportAction getDeviceInstallStatusReport`. Both are Intune
beta report actions; the replacement for the retired `deviceStatuses` API.

## Moving to production (Azure Automation)

1. Import `Sync-EucPilotGroup.ps1` as a runbook. No Graph modules needed.
2. Enable the system-assigned managed identity.
3. Admin-consent the five application roles to that identity.
4. Optional Teams notification: create a Teams **Workflows** webhook ("Post
   to a channel when a webhook request is received") and store its URL in an
   **encrypted** Automation variable, e.g. `EucPilotTeamsWebhook`. Never pass
   the URL as a parameter; job parameters are visible in job history.
5. Set runbook parameters:

   | Parameter | Default | Purpose |
   |---|---|---|
   | `JoinAppId` | required | Intune Join app object ID |
   | `PilotGroupId` | required | Assigned security group for pilot devices |
   | `CommsGroupId` | none | Optional dedicated user group for pilot comms |
   | `MemberCap` | 50 | Max pilot devices; extra installs are deferred first-come-first-served. 0 = no cap |
   | `MaxRemovals` | 10 | Abort the run if more removals are planned for either group |
   | `TeamsWebhookVariable` | none | Name of the encrypted variable from step 4 |
   | `InstallReportAction` | `retrieveDeviceAppInstallationStatusReport` | Report action fallback switch |

6. Schedule hourly (the minimum Azure Automation schedule recurrence).
   Intune install status itself can lag, so faster runs add little.
7. Assign pilot payloads to the group and **exclude the group from all
   production update rings** (overlapping Windows Update rings apply no
   policy).

The comms group should be dedicated to this program: any user member who is
not the primary user of a pilot device is removed, except group owners.

## Intune app packaging

1. Obtain Microsoft's IntuneWinAppUtil, then build the package:

   ```powershell
   .\Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe
   ```

   The `.intunewin` is written to the `EucPilotProgramOutput` folder beside
   this one. Run `.\Test-EucPilotProgram.ps1` separately if you want the
   offline validation checks.

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
   `Detect-EucPilotJoin.ps1`. It reads both the redirected and native marker
   keys, so the "run as 64-bit" toggle can be left at its default. Do not
   enforce signature checking unless the scripts are signed.
6. Assignment: **Available for enrolled devices** so users install it from
   the Company Portal. Available apps are user-uninstallable and Intune does
   not automatically reinstall an uninstalled available app, which makes
   uninstall a sticky opt-out.

**Why detection reads WOW6432Node:** writing to the root of HKLM is not
permitted in this environment, so the marker lives under `HKLM\SOFTWARE`.
The Intune Management Extension runs the install from a 32-bit process, and
WOW64 redirects `HKLM\SOFTWARE` writes to `HKLM\SOFTWARE\WOW6432Node`, so
the marker physically lands at
`HKLM\SOFTWARE\WOW6432Node\EucPilotProgram`. The detection script reads that
redirected node, and falls back to the native `SOFTWARE` key so it works
whether Intune runs detection as a 32-bit or 64-bit process. Uninstall
removes both physical copies. All scripts use plain PowerShell registry
cmdlets - no Sysnative, .cmd, .vbs, or .NET code.

## Validation

Run `.\Test-EucPilotProgram.ps1` before every commit. It parses all scripts,
applies the project PSScriptAnalyzer settings (Windows PowerShell 5.1
compatibility), and checks the Join app registry contract. No network access
or sign-in is required. Use `-WhatIf` on the reconciler to review a plan
against the live tenant without writing.

## Edge cases

| Case | Behavior |
|---|---|
| Multi-device user | Installs on each device they want piloted |
| Shared device | Device-wide signal; every user of the device gets pilot payloads |
| Device unenrolled | Status disappears; reconciler removes it on the next run |
| Stale report entry (managed device deleted) | Skipped and logged; does not halt the run |
| Intune device with no Entra object | Skipped before the cap, never consumes a slot |
| Install pending, failed, or detection hiccup | Held: kept if a member, not added if not |
| Leave then rejoin | Reinstall; the next cycle re-adds |
| App deleted, unassigned, or wrong app ID | Report has zero rows; run aborts without removals |
| Partial report page | Row count mismatch with `TotalRowCount`; run aborts |
| Mass removal (> `MaxRemovals`) | Run aborts before any write |
| Member cap reached | Removals free slots first; remaining adds are deferred oldest-install-first |
| Graph throttling | Retried with `Retry-After`; persistent throttling halts the run |
| Teams webhook fails | Logged as a warning; membership changes stand |

## Notes

- The registry marker is only the wrapper app's detection state. The Entra
  group is the single source of truth for all pilot assignments.
- Win32 install/uninstall requires a healthy Intune Management Extension on
  the device; it is installed automatically on managed Windows devices.
- The reconciler uses Graph v1.0 for everything except the Intune install
  status report, which only exists in beta (`/beta/deviceManagement/reports`).