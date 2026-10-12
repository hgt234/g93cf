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

## URL Association Diagnostics

The original detection validates Edge's installation but does not currently validate Windows URL
protocol registration. If **Run > `https://example.com`** reports that no app is available, run
`Get-EdgeUrlAssociationDiagnostics.ps1` while signed in as the affected user:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Get-EdgeUrlAssociationDiagnostics.ps1 `
    -OutputPath "$env:USERPROFILE\Desktop\EdgeUrlAssociations.json"
```

Do not run the first capture as `SYSTEM` or another administrator. The effective `http` and
`https` selections are stored in the affected user's registry hive. If possible, collect a second
report from a working device for comparison. Use `-IncludeOtherUsers` only when an elevated or
`SYSTEM` capture needs loaded-user association data; it adds user SIDs and profile paths.

The script does not modify registry or association state and does not attempt to open a URL. It
only creates the requested JSON report. The report includes the computer name, current user name
and SID, and active user name. It records:

- the Windows association API result for `http` and `https`;
- current-user `UserChoice` ProgIDs and hashes, plus loaded users when explicitly requested;
- current-user, merged, and machine protocol classes and their open commands;
- `MSEdgeHTM` and any selected ProgID commands, including whether their executables exist;
- Edge registered-application capabilities, App Paths, updater registration, and policies;
- available Edge executable paths, versions, and signature status.

Provide the resulting `EdgeUrlAssociations.json` from both the broken and working device before
changing detection or attempting to write `UserChoice`. Windows protects `UserChoice` with a hash;
directly setting its `ProgId` without a valid hash can make the association state worse.
