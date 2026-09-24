# Clear Microsoft Teams Cache

| Field | Value |
|-------|-------|
| **Product** | Microsoft Teams (New Teams) |
| **Category** | Client Performance / Sign-In |
| **Severity** | Medium |
| **Audience** | T0 Service Desk, End-User Self-Service |
| **Estimated Time** | 5 minutes |
| **Requires Admin** | No |
| **Requires Reboot** | No |
| **Last Updated** | 2026-06-16 |

---

## Symptoms

The user reports one or more of the following:

- Teams fails to sign in, hangs on the loading screen, or displays a blank white window
- Messages are not sending or are stuck in "sending" state
- Channels, chats, or calendar are not loading or appear out of date
- Teams is slow to launch, unresponsive, or crashes on startup
- Profile picture, status, or presence indicator is incorrect or not updating
- Meeting join button is missing or meetings fail to connect

> **Triage note:** If the issue is limited to a single chat/channel and other users in the same tenant are unaffected, try cache clearing first. If the issue is tenant-wide, escalate to the M365 team.

---

## Root Cause

New Teams is a packaged WebView2 application that stores local cache data under its package directory. Over time this data can become corrupted due to:

- Incomplete updates or version mismatches after a Teams client upgrade
- Abrupt shutdowns (power loss, force-quit) while Teams is writing to cache
- Disk space exhaustion or filesystem errors
- Profile or tenant migration leaving stale cached tokens

Clearing the cache forces Teams to rebuild these stores from the server on next launch, resolving most client-side issues without data loss — chat history and files are cloud-backed.

---

## Prerequisites

- The user must know their Teams credentials (email + password / MFA method) — they will need to sign in again
- The user must have permission to delete files from their own `$env:LOCALAPPDATA` directory (standard for non-kiosk users)
- Close all Office applications if possible — Teams shares components with Outlook/Word/Excel

---

## Resolution

### Step 1: Fully Exit Teams

Teams must be completely closed — not just minimized to the taskbar.

```powershell
Get-Process -Name "ms-teams" -ErrorAction SilentlyContinue | Stop-Process -Force
```

> If the user prefers GUI: right-click the **Teams icon** in the system tray (near the clock) and select **Quit**.

**Verification:**

```powershell
Get-Process -Name "ms-teams" -ErrorAction SilentlyContinue
```

This should return nothing. If a process is still listed, wait 10 seconds and run the stop command again.

---

### Step 2: Delete the Teams Cache

New Teams stores all cache under its package directory. Run the following in **PowerShell**:

```powershell
$teamsCache = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"

if (Test-Path $teamsCache) {
    Get-ChildItem -Path $teamsCache -Directory | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed: $($_.Name)"
    }
    Write-Host "Teams cache cleared successfully."
} else {
    Write-Host "Teams cache path not found — Teams may not be installed for this user."
}
```

**One-liner (copy-paste entire block):**

```powershell
$c = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"; if (Test-Path $c) { Get-ChildItem $c -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "Cache cleared." } else { Write-Host "Cache path not found." }
```

> **Expected output:** A list of removed directories (e.g. `Cache`, `GPUCache`, `Code Cache`, `blob_storage`). Some may not exist on every install — `Remove-Item` with `-ErrorAction SilentlyContinue` handles this gracefully.

---

### Step 3: Restart Teams

1. Launch Teams from the **Start Menu** or desktop shortcut
2. Sign in with the user's work or school account
3. Complete any MFA prompt

**Verification:**
- Teams launches to the main chat/teams view (not a blank screen)
- The user's chats, channels, and calendar load within 30–60 seconds
- Send a test message to confirm messaging works

---

## Verification Checklist

After completing the steps, confirm all of the following with the user:

- [ ] Teams launches without errors or hangs
- [ ] Chat messages send and receive successfully
- [ ] Channels and teams list loads completely
- [ ] Calendar tab displays upcoming meetings
- [ ] Profile picture and presence status are correct
- [ ] User can join a test meeting (if applicable)

---

## If the Issue Persists

Run these additional steps before escalating:

### 1. Clear Teams Credentials from Windows Credential Manager

```powershell
cmdkey /list | Select-String "Teams" | ForEach-Object {
    $target = ($_ -replace '.*Target:\s*(.*?)\s*Type:.*', '$1').Trim()
    cmdkey /delete:$target
    Write-Host "Removed credential: $target"
}
```

> This removes all stored Teams credentials. The user will be prompted to sign in again.

### 2. Reset the Teams App Package

If cache clearing and credential removal don't resolve the issue, reset the entire Teams app package:

```powershell
Get-AppxPackage -Name "MSTeams" | ForEach-Object {
    Write-Host "Resetting: $($_.PackageFamilyName)"
    Add-AppxPackage -Register -DisableDevelopmentMode "$($_.InstallLocation)\AppxManifest.xml"
}
```

> This re-registers the Teams app without removing user data. A reboot is not required but may help if the issue persists after this step.

### 3. Run the Teams Network Assessment Tool

If the issue appears network-related (messages not sending, calls dropping):

1. Press `Ctrl+Alt+Shift+T` while Teams is in focus
2. Review the network statistics shown in the overlay
3. Packet loss > 5% or latency > 200ms indicates a network issue — escalate to network team

---

## Escalation Criteria

Escalate to **Tier 2 / Desktop Engineering** if:

- Cache clearing, credential reset, and app re-registration do not resolve the issue
- The issue affects multiple users on the same machine (indicates machine-level corruption)
- Teams fails to install or update (error codes present during launch)
- The issue reproduces on a different machine with the same user account (indicates tenant-side issue — escalate to M365 team)

**Information to include in the ticket escalation:**

- Teams version (from Settings → About)
- Windows version (`winver`)
- Exact error message or behavior observed
- Steps already attempted (cache clear, credential reset, app re-registration)
- Whether the issue occurs on another machine with the same account
- Whether other users on the same machine experience the same issue

---

## Related Articles

- [Reset Microsoft Teams (Microsoft Learn)](https://learn.microsoft.com/en-us/microsoftteams/troubleshoot/teams-administration/reset-teams)
- [Teams sign-in troubleshooting](https://learn.microsoft.com/en-us/microsoftteams/troubleshoot/teams-sign-in/sign-in-issues)
- [Clear Office credential cache](https://learn.microsoft.com/en-us/office/troubleshoot/administration/clear-cached-credentials)

---

*Template version 1.0 — Use this structure for all T0 troubleshooting articles.*
