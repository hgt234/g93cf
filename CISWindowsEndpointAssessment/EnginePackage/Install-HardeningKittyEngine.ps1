#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$engineVersion = '0.9.4'
$expectedManifestHash = '6EC3F28E8FC111C5DEC510B62F465BD5B2F0F8290EC8DFA294EC423137D0C848'
$sourceRoot = Join-Path $PSScriptRoot "Payload\HardeningKitty\$engineVersion"
$programFiles64 = if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) { $env:ProgramW6432 } else { $env:ProgramFiles }
$productRoot = Join-Path $programFiles64 'CISWindowsEndpointAssessment\HardeningKitty'
$targetRoot = Join-Path $productRoot $engineVersion
$stagingRoot = Join-Path $productRoot ('.staging-{0}' -f [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $productRoot ('.backup-{0}' -f [guid]::NewGuid().ToString('N'))

function Test-EngineTree {
    param([Parameter(Mandatory)] [string]$Root)

    $manifestPath = Join-Path $Root 'PackageManifest.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $expectedManifestHash) { return $false }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ($manifest.EngineVersion -ne $engineVersion) { return $false }
    foreach ($entry in $manifest.Files.GetEnumerator()) {
        $path = Join-Path $Root ([string]$entry.Key)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$entry.Value) { return $false }
    }
    return $true
}

try {
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run the installer in 64-bit Windows PowerShell.'
    }
    if (-not (Test-EngineTree -Root $sourceRoot)) {
        throw 'The packaged HardeningKitty payload failed integrity validation.'
    }
    if (Test-EngineTree -Root $targetRoot) {
        Write-Output "HardeningKitty engine $engineVersion is already installed and verified."
        exit 0
    }

    $null = New-Item -Path $stagingRoot -ItemType Directory -Force
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $sourceRoot 'PackageManifest.psd1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'PackageManifest.psd1') -Destination (Join-Path $stagingRoot 'PackageManifest.psd1') -Force
    foreach ($entry in $manifest.Files.GetEnumerator()) {
        $sourcePath = Join-Path $sourceRoot ([string]$entry.Key)
        $destinationPath = Join-Path $stagingRoot ([string]$entry.Key)
        $destinationDirectory = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            $null = New-Item -Path $destinationDirectory -ItemType Directory -Force
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
    if (-not (Test-EngineTree -Root $stagingRoot)) {
        throw 'The staged HardeningKitty engine failed integrity validation.'
    }

    if (Test-Path -LiteralPath $targetRoot) {
        Move-Item -LiteralPath $targetRoot -Destination $backupRoot -Force
    }
    Move-Item -LiteralPath $stagingRoot -Destination $targetRoot -Force
    if (-not (Test-EngineTree -Root $targetRoot)) {
        throw 'The installed HardeningKitty engine failed post-install validation.'
    }
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $reportRoot = Join-Path $env:ProgramData 'CISWindowsEndpointAssessment\Reports\Machine'
        $null = New-Item -Path $reportRoot -ItemType Directory -Force
    }
    Write-Output "Installed and verified HardeningKitty engine $engineVersion."
    exit 0
}
catch {
    if (-not (Test-Path -LiteralPath $targetRoot) -and (Test-Path -LiteralPath $backupRoot)) {
        Move-Item -LiteralPath $backupRoot -Destination $targetRoot -Force -ErrorAction SilentlyContinue
    }
    Write-Output "HardeningKitty engine installation failed: $($_.Exception.Message)"
    exit 1
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

