# Intune application factory

This folder is a reference implementation for managing a small required baseline and a
large, user-driven application catalog. It deliberately does not force every application
through PSAppDeployToolkit (PSADT). The application manifest selects the lifecycle that
best preserves automatic updates.

## The five examples

| Application | Assignment | Delivery | Update owner | PSADT |
|---|---|---|---|---|
| 7-Zip | Required, all devices | Enterprise App Catalog | Intune catalog auto-update | No |
| Notepad++ | Available, all users | Win32 | Git pipeline creates superseding versions | Yes |
| Visual Studio Code | Available, all users | Microsoft Store (new) | Microsoft Store/Intune | No |
| LOB App 1 | Required, baseline device group | Win32 | Git pipeline | Yes |
| Complex LOB App 2 | Available, all users | Win32 | Git pipeline creates superseding versions | Yes |

The 7-Zip example is required because Enterprise App Catalog's fully automatic update
mode currently applies only to required assignments. If 7-Zip should be optional, change
it to the same `psadtWin32` and supersedence model used by Notepad++, or use a verified
Microsoft Store listing if one becomes available. Do not silently substitute a similarly
named Store application without verifying its publisher.

## Lifecycle rules

1. Prefer `microsoftStore` for a verified Store application. Once a user installs an
   available Store app, its native lifecycle keeps it current.
2. Prefer `enterpriseCatalogAutoUpdate` for simple required applications covered by the
   Enterprise App Catalog.
3. Use `psadtWin32` when an application needs customization, a controlled installer, or
   is available but has no trustworthy native self-update path.
4. Every available Win32 version supersedes the prior version, and the available
   assignment has Intune's **Auto-update** option enabled. The pipeline creates the new
   version; clients that previously chose the app receive it without choosing it again.
5. Never deploy the same product concurrently through Store, Enterprise App Catalog and
   custom Win32. Pick one authority per application.

## Repository layout

```text
IntuneAppFactory/
  apps/<app>/app.json          Lifecycle and Intune metadata
  apps/<app>/Package/          PSADT-specific configuration and hooks
  apps/<app>/Payload/          Local build input; binaries are ignored by Git
  config/targets.example.json  Friendly target names mapped to tenant objects
  pipelines/                   Validation/build pipeline example
  scripts/                     Validation, planning and package-build scripts
  templates/PSADT/             Shared PSADT entry script
```

Catalog and Store manifests intentionally have no `Package` directory: those payloads
must remain under their native update authority.

## Initial setup

Requirements for a packaging workstation or Windows build agent:

- Windows PowerShell 5.1 or PowerShell 7
- PSAppDeployToolkit 4.1.8 deployment template, extracted outside Git
- Microsoft Win32 Content Prep Tool (`IntuneWinAppUtil.exe`)
- Code-signing access for production PowerShell scripts
- Microsoft Graph authentication in the later publishing stage

Copy `config/targets.example.json` to `config/targets.json` and replace the example group
IDs. `targets.json`, payloads, build directories and generated `.intunewin` files are
ignored by Git.

Validate all manifests and view the proposed Intune objects:

```powershell
Set-Location D:\Git\CPF\g93cf\IntuneAppFactory
./scripts/Test-AppManifests.ps1
./scripts/Get-AppDeploymentPlan.ps1 -Format Table
```

## Building a PSADT application

Put the vendor installer in the application's `Payload` folder and update its manifest
and `Package/PackageConfig.psd1`. Do not commit the binary.

```powershell
./scripts/New-PSADTPackage.ps1 `
    -AppPath ./apps/lob-app-1 `
    -PSADTTemplatePath C:\BuildTools\PSADT-4.1.8\Toolkit `
    -IntuneWinAppUtilPath C:\BuildTools\IntuneWinAppUtil.exe `
    -OutputPath C:\BuildOutput
```

The build script:

- refuses to build catalog or Store applications;
- validates the application manifest and PSADT configuration;
- checks the payload hash and/or Authenticode publisher when configured;
- overlays the shared entry script and application hooks onto a clean PSADT template;
- creates an `.intunewin` artifact without adding the payload to Git.

For a new release, update the manifest version and payload evidence, build and test the
package, then have the publishing stage create a new Intune Win32 application. Prefer
immutable versioned application objects over replacing content in place. The new object
should supersede the previous one, preserve the friendly assignment target, and enable
`autoUpdate` for available assignments.

Use these standardized Intune program commands for PSADT packages:

```text
Install:   Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Auto
Uninstall: Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent
```

For required ESP-sensitive applications, use `-DeployMode Silent`. Map exit codes `0` to
success, `3010` to soft reboot and `1641` to hard reboot; unrecognized PSADT exit codes
remain failures.

## Publishing boundary

This example stops before making tenant changes. `Get-AppDeploymentPlan.ps1` produces the
normalized input for a Graph publishing job, but tenant identifiers, approval gates and
authentication must be supplied for the client. This boundary prevents a cloned example
from modifying production Intune accidentally.

The intended release stages are:

```text
discover release -> verify publisher/hash -> build -> test install/upgrade/uninstall
  -> pilot approval -> publish version -> create supersedence -> assign -> production
```

For Store apps, the publishing adapter should create or reconcile the Store object by
product ID. For Enterprise App Catalog apps, it should reconcile the selected catalog
branch and required auto-update assignment. For Win32 apps, it should upload the generated
artifact and configure detection, supersedence and assignments from `app.json`.

Available-app supersedence auto-update requires the user to have originally installed the
app from Company Portal and to be signed in when Intune processes the update. Avoid
removing and recreating its available assignment because doing so can remove the consent
state Intune uses to track automatic updates.

## Logging and update visibility

PSADT installation logs use the toolkit configuration (normally
`C:\Windows\Logs\Software`). Store and Enterprise App Catalog update executions are not
PSADT sessions, so monitor them using Intune detected-version reporting, IME/Store event
logs and vendor logs. Standardize reporting and ownership across all apps; do not weaken a
native update mechanism merely to produce an identical local log format.
