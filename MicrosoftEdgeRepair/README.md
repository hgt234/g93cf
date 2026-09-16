# Microsoft Edge Post-Autopilot Repair

This package detects an incomplete machine-wide Microsoft Edge Stable installation and silently
runs Microsoft's installer to repair it. It is intended to run as `SYSTEM` after Autopilot.

Detection requires all of the following:

- a machine-wide `msedge.exe` with a valid Microsoft Authenticode signature;
- matching Microsoft Edge Updater registration for the Stable channel;
- a version folder matching the executable version;
- non-empty `msedge.dll`, `resources.pak`, and `icudtl.dat` files in that version folder;
- an `msedge.dll` version matching `msedge.exe` and at least one non-empty locale `.pak` file.

This catches the partial `Microsoft\Edge\Application` directory condition without launching Edge
or changing user profiles. The repair does not delete browser data and does not forcibly close
Edge. If files are locked by an active Edge process, Intune can retry the repair later.

## Recommended: Intune Remediations

Create a device remediation under **Devices > Scripts and remediations > Remediations**:

| Setting | Value |
|---|---|
| Detection script | `Detect-MicrosoftEdgeHealth.ps1` |
| Remediation script | `Repair-MicrosoftEdge.ps1` |
| Run this script using the logged-on credentials | **No** |
| Enforce script signature check | **No**, unless you sign both supplied scripts |
| Run script in 64-bit PowerShell | **Yes** |

Assign it to an Autopilot device group. Run it hourly during the initial rollout, then reduce the
schedule after the issue is stable. Exit code `1` from detection triggers repair; exit code `0`
means Edge passed validation.

When no installer is packaged beside the repair script, it downloads the current Edge Stable
bootstrapper from Microsoft's official redirect:

```text
https://go.microsoft.com/fwlink/?linkid=2108834&Channel=Stable&language=en&brand=M100
```

The downloaded file must have a valid Microsoft Authenticode signature before it can run. The
download has a five-minute timeout and occurs as `SYSTEM`, so use the Win32 option below if the
device's system-context proxy or Autopilot network cannot reach `go.microsoft.com` and Microsoft's
download CDN.

Microsoft documents reinstalling or using **Installed apps > Microsoft Edge > Modify > Repair**
for broken installations, but it does not publish a guarantee that the web bootstrapper forces a
same-version file repair. This script verifies the result instead of trusting setup's exit code;
if the payload remains incomplete, it exits `1` so Intune reports the failure and can retry.

## Win32 App Option

Place a current `MicrosoftEdgeSetup.exe` in this folder if you want a fully packaged source:

```text
MicrosoftEdgeRepair\
  Detect-MicrosoftEdgeHealth.ps1
  MicrosoftEdgeSetup.exe
  Repair-MicrosoftEdge.ps1
```

Package the folder with the Microsoft Win32 Content Prep Tool:

```powershell
IntuneWinAppUtil.exe -c .\MicrosoftEdgeRepair -s Repair-MicrosoftEdge.ps1 -o .\Output -q
```

Use these Win32 app settings:

| Setting | Value |
|---|---|
| Install behavior | System |
| Device restart behavior | No specific action |
| Install command | `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-MicrosoftEdge.ps1` |
| Uninstall command | `cmd.exe /c exit /b 0` |
| Detection rule | Use a custom detection script: `Detect-MicrosoftEdgeHealth.ps1` |
| 64-bit script host for detection | Yes |

Packaging the EXE is optional. If it is absent, the Win32 app also downloads the current signed
bootstrapper at runtime. This is a repair-only package: do not make an uninstall assignment or
offer an uninstall from Company Portal; its required Intune uninstall command intentionally does
nothing and does not remove the Windows browser.

## Manual Test

Run from elevated 64-bit Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Detect-MicrosoftEdgeHealth.ps1
$LASTEXITCODE

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-MicrosoftEdge.ps1
$LASTEXITCODE
```

Review `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\MicrosoftEdgeRepair.log` for the
download source, setup exit code, post-install validation result, and any failure detail.
