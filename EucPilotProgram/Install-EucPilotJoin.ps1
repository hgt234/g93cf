#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$registryPath = 'HKLM:\EucPilotProgram'
$programVersion = '1.0.0'

# Remove markers written by the original SOFTWARE-based deployment, including
# the WOW6432Node copy produced when the 32-bit Intune Management Extension
# ran the installer before the path moved to the WOW64-shared HKLM root.
foreach ($legacyPath in @(
    'HKLM:\SOFTWARE\EucPilotProgram',
    'HKLM:\SOFTWARE\WOW6432Node\EucPilotProgram'
)) {
    if (Test-Path -LiteralPath $legacyPath) {
        Remove-Item -LiteralPath $legacyPath -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

New-ItemProperty -Path $registryPath -Name Status -Value 'Joined' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name Version -Value $programVersion -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name JoinedUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null

Write-Output "EUC Early Adopter opt-in marker written to $registryPath."