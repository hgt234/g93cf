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
  1. GET app deviceStatuses          -> desired state
  2. GET pilot group members         -> current state
  3. diff -> add/remove devices in the Entra pilot group
  4. cap check, comms-group sync, audit summary
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
- **Error is never empty.** Any Graph failure halts the run. A missing app or
  a failed query can never wipe the group.
- **Idempotent.** HTTP 400 (already member) and 404 (not a member) are
  absorbed as success, so re-runs are always safe.

## Files

| File | Purpose |
|---|---|
| `Sync-EucPilotGroup.ps1` | Reconciler: app status -> pilot group membership |
| `Install-EucPilotJoin.ps1` | Win32 wrapper installer (writes the opt-in marker) |
| `Uninstall-EucPilotJoin.ps1` | Win32 wrapper uninstaller (removes the marker) |
| `Detect-EucPilotJoin.ps1` | Win32 custom detection script |
| `Test-EucPilotProgram.ps1` | Offline parser, analyzer, and logic validation |
| `PSScriptAnalyzerSettings.psd1` | Windows PowerShell 5.1 compatibility rules |

## Authentication

| Mode | When | Mechanism | Dependencies |
|---|---|---|---|
| Interactive (POC) | Run as a signed-in user | `Connect-MgGraph` prompt with MFA/Conditional Access | `Microsoft.Graph.Authentication` module |
| Managed identity (PROD) | Azure Automation runbook | IMDS token via `IDENTITY_ENDPOINT` | None (raw `Invoke-RestMethod`) |

The script auto-detects the branch: `IDENTITY_ENDPOINT` present means managed
identity; otherwise the interactive prompt opens.

### Required permissions

Interactive (delegated, consented at the prompt):

- `DeviceManagementApps.Read.All`
- `DeviceManagementManagedDevices.Read.All`
- `Directory.Read.All`
- `GroupMember.ReadWrite.All`

Production (application roles on the managed identity, admin-consented once):

- Same four roles, granted to the Automation account's system-assigned
  identity.

## POC run steps

1. Pick or create the Join app in Intune and copy its **Object ID**
   (`GET /deviceAppManagement/mobileApps?$filter=displayName eq '...'`).
   For a quick POC, any app already installed on your test device works.
2. Create `SEC-EUC-Pilot-Devices-POC` in Entra and copy its **Object ID**.
3. Install the SDK once:
   `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`.
4. Dry run:
   `.\Sync-EucPilotGroup.ps1 -JoinAppId <id> -PilotGroupId <gid> -WhatIf`
   Sign in at the interactive prompt (MFA applies), review the planned diff.
5. Real run: drop `-WhatIf`. Verify the device appears in the group.
6. Run again: expect zero adds and zero removes (idempotency).
7. Delete the device from the group in the portal, re-run, confirm re-add.
8. Failure guard: run with a bogus `-JoinAppId`; the script must terminate
   on the 404 rather than treating it as an empty app.

If the tenant restricts user consent, an admin grants tenant-wide consent to
the **Microsoft Graph PowerShell** application for the four scopes above.

## Moving to production (Azure Automation)

1. Import `Sync-EucPilotGroup.ps1` as a runbook. No Graph modules needed.
2. Enable the system-assigned managed identity.
3. Admin-consent the four application roles to that identity.
4. Add parameters (`JoinAppId`, `PilotGroupId`, optionally `CommsGroupId`,
   `MemberCap`, `TeamsWebhookUri`) as runbook defaults.
5. Schedule every 10 minutes.
6. Assign pilot payloads to the group and **exclude the group from all
   production update rings** (overlapping Windows Update rings apply no
   policy).

## Intune app packaging

1. Package the wrapper with Microsoft's IntuneWinAppUtil:
   `IntuneWinAppUtil.exe -c . -s Install-EucPilotJoin.ps1 -o . -q`
2. Install command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-EucPilotJoin.ps1`
3. Uninstall command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-EucPilotJoin.ps1`
4. Detection: use `Detect-EucPilotJoin.ps1` as a custom detection script.
5. Assignment: **Available for enrolled devices** so users install it from
   the Company Portal. Available apps are user-uninstallable and Intune does
   not automatically reinstall an uninstalled available app, which makes
   uninstall a sticky opt-out.

## Validation

Run `.\Test-EucPilotProgram.ps1` before every commit. It parses all scripts,
applies the project PSScriptAnalyzer settings (Windows PowerShell 5.1
compatibility), and exercises pagination, idempotency absorption, the
error-guard, and cap arithmetic against mocked Graph responses. No network
access or sign-in is required.

## Edge cases

| Case | Behavior |
|---|---|
| Multi-device user | Installs on each device they want piloted |
| Shared device | Device-wide signal; every user of the device gets pilot payloads |
| Device unenrolled | Status disappears; reconciler removes it on the next run |
| Stale Intune device with no Entra object | Skipped and logged, never orphaned in the group |
| Leave then rejoin | Reinstall; the next cycle re-adds |
| App deleted or query fails | Run halts; group is never modified on error |
| Member cap reached | Adds are deferred; the run logs the cap |

## Notes

- The registry marker is only the wrapper app's detection state. The Entra
  group is the single source of truth for all pilot assignments.
- Win32 install/uninstall requires a healthy Intune Management Extension on
  the device; it is installed automatically on managed Windows devices.
- The reconciler uses only Graph v1.0 endpoints.