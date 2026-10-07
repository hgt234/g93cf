#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The opt-in marker lives in its own key at the root of the HKLM hive so it
# is shared between the 32-bit and 64-bit registry views.
$markerKeyPath = 'HKLM:\EucPilotProgram'
$programVersion = '1.0.0'

# Remove markers left by the earlier SOFTWARE-based deployment, including the
# WOW6432Node copy the 32-bit Intune agent wrote there.
foreach ($legacyKeyPath in @(
    'HKLM:\SOFTWARE\EucPilotProgram',
    'HKLM:\SOFTWARE\WOW6432Node\EucPilotProgram'
)) {
    if (Test-Path -LiteralPath $legacyKeyPath) {
        Remove-Item -LiteralPath $legacyKeyPath -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $markerKeyPath)) {
    New-Item -Path $markerKeyPath | Out-Null
}

New-ItemProperty -Path $markerKeyPath -Name Status -Value 'Joined' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $markerKeyPath -Name Version -Value $programVersion -PropertyType String -Force | Out-Null
New-ItemProperty -Path $markerKeyPath -Name JoinedUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null

Write-Output "EUC Early Adopter opt-in marker written to $markerKeyPath."