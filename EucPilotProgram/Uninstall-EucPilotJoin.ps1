#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$markerKeyPath = 'HKLM:\EucPilotProgram'

foreach ($keyPath in @(
    $markerKeyPath,
    'HKLM:\SOFTWARE\EucPilotProgram',
    'HKLM:\SOFTWARE\WOW6432Node\EucPilotProgram'
)) {
    if (Test-Path -LiteralPath $keyPath) {
        Remove-Item -LiteralPath $keyPath -Recurse -Force
    }
}

Write-Output 'EUC Early Adopter opt-in marker removed.'