#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$productName = 'ManagedDriveMapper'
$taskName = 'Managed Drive Mapper'
$installPath = Join-Path $env:ProgramData $productName
$payloadPath = Join-Path $PSScriptRoot 'Payload'
$requiredFiles = @(
    'Invoke-DriveMapper.ps1',
    'Mappings.json',
    'Register-DriveMapperTask.ps1',
    'Version.json'
)

foreach ($file in $requiredFiles) {
    $source = Join-Path $payloadPath $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Package payload is incomplete. Missing: $source"
    }
}

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask -and $existingTask.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $installPath -PathType Container)) {
    New-Item -Path $installPath -ItemType Directory -Force | Out-Null
}

foreach ($file in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $payloadPath $file) -Destination (Join-Path $installPath $file) -Force
}

# Standard users require read/execute access but must not be able to alter the engine or
# entitlement configuration. ProgramData normally inherits this ACL; make it explicit.
& icacls.exe $installPath '/inheritance:e' '/grant:r' '*S-1-5-32-545:(OI)(CI)(RX)' '/T' '/C' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set read/execute permissions on $installPath."
}

& (Join-Path $installPath 'Register-DriveMapperTask.ps1') -InstallPath $installPath

$version = Get-Content -LiteralPath (Join-Path $installPath 'Version.json') -Raw | ConvertFrom-Json
$registryPath = 'HKLM:\SOFTWARE\ManagedDriveMapper'
if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}
New-ItemProperty -Path $registryPath -Name Version -Value ([string]$version.Version) -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name InstallPath -Value $installPath -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name InstalledUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null

Write-Output "Installed $productName version $($version.Version) to $installPath."
