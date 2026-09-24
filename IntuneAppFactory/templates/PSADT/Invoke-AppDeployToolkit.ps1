<#
.SYNOPSIS
Runs a manifest-driven PSAppDeployToolkit 4.1.8 deployment.

.DESCRIPTION
The build script overlays this entry point and an application's PackageConfig.psd1 on a
clean PSADT 4.1.8 template. Application-specific actions belong in the optional hook
scripts rather than in this shared file.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string] $DeploymentType,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [string] $DeployMode,

    [Parameter(Mandatory = $false)]
    [switch] $SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [switch] $TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [switch] $DisableLogging
)

$packageConfigPath = Join-Path $PSScriptRoot 'PackageConfig.psd1'
if (-not (Test-Path -LiteralPath $packageConfigPath -PathType Leaf)) {
    $Host.UI.WriteErrorLine("Missing package configuration '$packageConfigPath'.")
    exit 60008
}
$packageConfig = Import-PowerShellDataFile -LiteralPath $packageConfigPath

$adtSession = @{
    AppVendor = $packageConfig.AppVendor
    AppName = $packageConfig.AppName
    AppVersion = $packageConfig.AppVersion
    AppArch = $packageConfig.AppArch
    AppLang = $packageConfig.AppLang
    AppRevision = $packageConfig.AppRevision
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @($packageConfig.ProcessesToClose)
    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-09-08'
    AppScriptAuthor = 'Endpoint Engineering'
    RequireAdmin = $true
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

function Invoke-AppFactoryHook {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)

    if (-not $packageConfig.ContainsKey('Hooks') -or -not $packageConfig.Hooks.ContainsKey($Name)) { return }
    $hookPath = Join-Path $PSScriptRoot (Join-Path 'Scripts' $packageConfig.Hooks[$Name])
    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) { throw "Configured hook '$hookPath' was not found." }
    Write-ADTLogEntry -Message "Running application hook '$Name' from '$hookPath'."
    . $hookPath
}

function Install-ADTDeployment {
    [CmdletBinding()]
    param()

    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        if ($packageConfig.AllowDeferral) {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -AllowDeferCloseProcesses -DeferTimes 3 -PersistPrompt
        } else {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
        }
    }
    Show-ADTInstallationProgress
    Invoke-AppFactoryHook -Name 'PreInstall'

    $adtSession.InstallPhase = $adtSession.DeploymentType
    $installerPath = Join-Path $adtSession.DirFiles $packageConfig.Installer.FileName
    switch ($packageConfig.Installer.Type) {
        'Msi' {
            Start-ADTMsiProcess -Action Install -FilePath $installerPath -ArgumentList $packageConfig.Installer.InstallArguments
        }
        'Exe' {
            Start-ADTProcess -FilePath $installerPath -ArgumentList $packageConfig.Installer.InstallArguments
        }
        default { throw "Unsupported installer type '$($packageConfig.Installer.Type)'." }
    }

    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
    Invoke-AppFactoryHook -Name 'PostInstall'
}

function Uninstall-ADTDeployment {
    [CmdletBinding()]
    param()

    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress
    Invoke-AppFactoryHook -Name 'PreUninstall'

    $adtSession.InstallPhase = $adtSession.DeploymentType
    switch ($packageConfig.Installer.Type) {
        'Msi' {
            Start-ADTMsiProcess -Action Uninstall -ProductCode $packageConfig.Installer.ProductCode -ArgumentList $packageConfig.Installer.UninstallArguments
        }
        'Exe' {
            $uninstallerPath = [Environment]::ExpandEnvironmentVariables($packageConfig.Installer.UninstallFilePath)
            Start-ADTProcess -FilePath $uninstallerPath -ArgumentList $packageConfig.Installer.UninstallArguments
        }
        default { throw "Unsupported installer type '$($packageConfig.Installer.Type)'." }
    }

    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
    Invoke-AppFactoryHook -Name 'PostUninstall'
}

function Repair-ADTDeployment {
    [CmdletBinding()]
    param()

    $adtSession.InstallPhase = $adtSession.DeploymentType
    if ($packageConfig.Installer.Type -ne 'Msi') { throw 'Repair is only configured for MSI examples.' }
    Start-ADTMsiProcess -Action Repair -ProductCode $packageConfig.Installer.ProductCode
}

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try {
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf) {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{
            ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"
            Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'
            ModuleVersion = '4.1.8'
        } -Force
    } else {
        Import-Module -FullyQualifiedName @{
            ModuleName = 'PSAppDeployToolkit'
            Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'
            ModuleVersion = '4.1.8'
        } -Force
    }
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
} catch {
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([int]::MaxValue)))
    exit 60008
}

try {
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
} catch {
    Write-ADTLogEntry -Message "Unhandled deployment error:`n$(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 3
    Close-ADTSession -ExitCode 60001
}

