#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$engineVersion = '0.9.4'
$expectedManifestHash = '6EC3F28E8FC111C5DEC510B62F465BD5B2F0F8290EC8DFA294EC423137D0C848'

try {
    $programFiles64 = if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $root = Join-Path $programFiles64 "CISWindowsEndpointAssessment\HardeningKitty\$engineVersion"
    $manifestPath = Join-Path $root 'PackageManifest.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Package manifest missing.' }
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $expectedManifestHash) { throw 'Package manifest hash mismatch.' }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    foreach ($entry in $manifest.Files.GetEnumerator()) {
        $path = Join-Path $root ([string]$entry.Key)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $($entry.Key)." }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$entry.Value) { throw "Hash mismatch for $($entry.Key)." }
    }
    Write-Output "HardeningKitty engine $engineVersion is installed and verified."
    exit 0
}
catch {
    Write-Output "HardeningKitty engine $engineVersion is not installed or failed validation."
    exit 1
}

