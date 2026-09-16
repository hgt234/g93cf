#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string] $SetupPath = (Join-Path $PSScriptRoot 'MicrosoftEdgeSetup.exe'),

    [uri] $DownloadUri = 'https://go.microsoft.com/fwlink/?linkid=2108834&Channel=Stable&language=en&brand=M100',

    [ValidateRange(30, 600)]
    [int] $ValidationTimeoutSeconds = 180,

    [ValidateRange(60, 3600)]
    [int] $InstallerTimeoutSeconds = 900
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$downloadedSetupPath = $null
$downloadRoot = $null
$logRoot = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
$logPath = Join-Path $logRoot 'MicrosoftEdgeRepair.log'

function Write-RepairLog {
    param([Parameter(Mandatory)] [string] $Message)

    $entry = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $entry
    Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
}

function Get-EdgeExecutablePath {
    $candidatePaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($registryView in @(
            [Microsoft.Win32.RegistryView]::Registry64,
            [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = $null
        $appPathKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                $registryView
            )
            $appPathKey = $baseKey.OpenSubKey(
                'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
            )
            if ($null -ne $appPathKey) {
                $registeredPath = [Environment]::ExpandEnvironmentVariables(
                    [string]$appPathKey.GetValue('')
                ).Trim().Trim('"')
                if (-not [string]::IsNullOrWhiteSpace($registeredPath)) {
                    $candidatePaths.Add($registeredPath)
                }
            }
        }
        catch {
            # Fall back to the standard machine-wide paths.
        }
        finally {
            if ($null -ne $appPathKey) { $appPathKey.Dispose() }
            if ($null -ne $baseKey) { $baseKey.Dispose() }
        }
    }

    $basePaths = @(
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
        [Environment]::GetEnvironmentVariable('ProgramW6432'),
        [Environment]::GetEnvironmentVariable('ProgramFiles')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($basePath in $basePaths) {
        $candidatePaths.Add((Join-Path $basePath 'Microsoft\Edge\Application\msedge.exe'))
    }

    return $candidatePaths |
        Select-Object -Unique |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

function Test-EdgeUpdateRegistration {
    param([Parameter(Mandatory)] [version] $Version)

    $stableAppId = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    foreach ($registryView in @(
            [Microsoft.Win32.RegistryView]::Registry64,
            [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = $null
        $clientKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                $registryView
            )
            $clientKey = $baseKey.OpenSubKey("SOFTWARE\Microsoft\EdgeUpdate\Clients\$stableAppId")
            if ($null -ne $clientKey) {
                $registeredVersionText = [string]$clientKey.GetValue('pv')
                [version] $registeredVersion = $null
                if ([version]::TryParse($registeredVersionText, [ref]$registeredVersion) -and
                    $registeredVersion -eq $Version) {
                    return $true
                }
            }
        }
        catch {
            # Try the other registry view before reporting missing registration.
        }
        finally {
            if ($null -ne $clientKey) { $clientKey.Dispose() }
            if ($null -ne $baseKey) { $baseKey.Dispose() }
        }
    }

    return $false
}

function Get-EdgeHealth {
    $edgePath = Get-EdgeExecutablePath

    if ([string]::IsNullOrWhiteSpace($edgePath)) {
        return [pscustomobject]@{ Healthy = $false; Reason = 'msedge.exe is missing'; Version = $null }
    }

    $edgeRoot = Split-Path -Path $edgePath -Parent
    $edgeItem = Get-Item -LiteralPath $edgePath -ErrorAction Stop
    try {
        $edgeVersion = [version]$edgeItem.VersionInfo.FileVersion
    }
    catch {
        return [pscustomobject]@{ Healthy = $false; Reason = 'msedge.exe has an invalid version'; Version = $null }
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $edgePath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notlike '*Microsoft Corporation*') {
        return [pscustomobject]@{
            Healthy = $false
            Reason  = 'msedge.exe does not have a valid Microsoft signature'
            Version = $edgeVersion.ToString()
        }
    }

    if (-not (Test-EdgeUpdateRegistration -Version $edgeVersion)) {
        return [pscustomobject]@{
            Healthy = $false
            Reason  = "Edge Updater registration is missing or does not match version $edgeVersion"
            Version = $edgeVersion.ToString()
        }
    }

    $versionRoot = Join-Path $edgeRoot $edgeVersion.ToString()
    foreach ($requiredFile in @('msedge.dll', 'resources.pak', 'icudtl.dat')) {
        $requiredPath = Join-Path $versionRoot $requiredFile
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf) -or
            (Get-Item -LiteralPath $requiredPath).Length -eq 0) {
            return [pscustomobject]@{
                Healthy = $false
                Reason  = "Version $edgeVersion is missing a non-empty $requiredFile"
                Version = $edgeVersion.ToString()
            }
        }
    }

    try {
        $dllVersion = [version](Get-Item -LiteralPath (Join-Path $versionRoot 'msedge.dll')).VersionInfo.FileVersion
    }
    catch {
        $dllVersion = $null
    }
    if ($dllVersion -ne $edgeVersion) {
        return [pscustomobject]@{
            Healthy = $false
            Reason  = "msedge.dll does not match executable version $edgeVersion"
            Version = $edgeVersion.ToString()
        }
    }

    $localesRoot = Join-Path $versionRoot 'locales'
    if (-not (Test-Path -LiteralPath $localesRoot -PathType Container) -or
        $null -eq (Get-ChildItem -LiteralPath $localesRoot -Filter '*.pak' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 } |
            Select-Object -First 1)) {
        return [pscustomobject]@{
            Healthy = $false
            Reason  = "Version $edgeVersion has no locale resources"
            Version = $edgeVersion.ToString()
        }
    }

    return [pscustomobject]@{
        Healthy = $true
        Reason  = 'Critical Edge runtime files and updater registration passed validation'
        Version = $edgeVersion.ToString()
    }
}

function Test-MicrosoftSignedFile {
    param([Parameter(Mandatory)] [string] $Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return $signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
        $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -like '*Microsoft Corporation*'
}

try {
    $null = New-Item -Path $logRoot -ItemType Directory -Force

    $health = Get-EdgeHealth
    if ($health.Healthy) {
        Write-RepairLog ("Microsoft Edge {0} is already healthy; no repair is required." -f $health.Version)
        exit 0
    }
    Write-RepairLog ("Repair required: {0}." -f $health.Reason)

    if (Test-Path -LiteralPath $SetupPath -PathType Leaf) {
        $installerPath = (Resolve-Path -LiteralPath $SetupPath).Path
        Write-RepairLog ("Using packaged installer: {0}" -f $installerPath)
    }
    else {
        # The IME log directory is SYSTEM-controlled, which prevents a standard user from
        # replacing the downloaded executable between signature validation and execution.
        $downloadRoot = Join-Path $logRoot ("MicrosoftEdgeRepair-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $downloadRoot -ItemType Directory -Force
        $downloadedSetupPath = Join-Path $downloadRoot 'MicrosoftEdgeSetup.exe'
        Write-RepairLog ("Downloading the current Edge Stable installer from {0}" -f $DownloadUri.AbsoluteUri)

        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DownloadUri.AbsoluteUri -OutFile $downloadedSetupPath `
            -UseBasicParsing -TimeoutSec 300
        $installerPath = $downloadedSetupPath
    }

    if (-not (Test-MicrosoftSignedFile -Path $installerPath)) {
        throw 'The Edge installer does not have a valid Microsoft Authenticode signature.'
    }

    Write-RepairLog 'Starting MicrosoftEdgeSetup.exe /silent /install.'
    $process = Start-Process -FilePath $installerPath -ArgumentList '/silent', '/install' `
        -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($InstallerTimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "MicrosoftEdgeSetup.exe exceeded the $InstallerTimeoutSeconds second timeout."
    }
    $process.Refresh()
    $setupExitCode = $process.ExitCode
    Write-RepairLog ("MicrosoftEdgeSetup.exe exited with code {0}." -f $setupExitCode)

    $deadline = (Get-Date).AddSeconds($ValidationTimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $health = Get-EdgeHealth
    } while (-not $health.Healthy -and (Get-Date) -lt $deadline)

    if (-not $health.Healthy) {
        throw ("Edge is still unhealthy after setup exit code {0}: {1}." -f $setupExitCode, $health.Reason)
    }

    Write-RepairLog ("Microsoft Edge {0} was installed and passed validation." -f $health.Version)
    if ($setupExitCode -eq 3010) {
        Write-RepairLog 'Setup requested a restart, but Edge already passed validation; returning success.'
    }
    exit 0
}
catch {
    $message = "Microsoft Edge repair failed: {0}" -f $_.Exception.Message
    if (Test-Path -LiteralPath $logRoot -PathType Container) {
        Write-RepairLog $message
    }
    else {
        Write-Output $message
    }
    exit 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($downloadRoot)) {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
