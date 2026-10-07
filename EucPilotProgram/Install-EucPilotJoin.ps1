#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The marker is written under SOFTWARE because writing to the root of HKLM is
# not permitted in this environment. The Intune Management Extension runs the
# install as a 32-bit process, so WOW64 redirects this key to
# HKLM:\SOFTWARE\WOW6432Node\EucPilotProgram - which is where the detection
# script reads it.
$markerKeyPath = 'HKLM:\SOFTWARE\EucPilotProgram'
$programVersion = '1.0.0'

if (-not (Test-Path -LiteralPath $markerKeyPath)) {
    New-Item -Path $markerKeyPath | Out-Null
}

New-ItemProperty -Path $markerKeyPath -Name Status -Value 'Joined' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $markerKeyPath -Name Version -Value $programVersion -PropertyType String -Force | Out-Null
New-ItemProperty -Path $markerKeyPath -Name JoinedUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null

Write-Output "EUC Early Adopter opt-in marker written to $markerKeyPath."