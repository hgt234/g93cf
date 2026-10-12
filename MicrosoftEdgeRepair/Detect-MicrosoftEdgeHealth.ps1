#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

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
    $requiredFiles = @('msedge.dll', 'resources.pak', 'icudtl.dat')
    foreach ($requiredFile in $requiredFiles) {
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

try {
    $health = Get-EdgeHealth
    if (-not $health.Healthy) {
        Write-Output ("Microsoft Edge is unhealthy: {0}." -f $health.Reason)
        exit 1
    }

    Write-Output ("Microsoft Edge {0} is healthy." -f $health.Version)
    exit 0
}
catch {
    Write-Output ("Unable to validate Microsoft Edge: {0}" -f $_.Exception.Message)
    exit 1
}
