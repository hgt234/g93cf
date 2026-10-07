#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$registryPath = 'HKLM:\EucPilotProgram'

foreach ($pathToRemove in @(
    $registryPath,
    'HKLM:\SOFTWARE\EucPilotProgram',
    'HKLM:\SOFTWARE\WOW6432Node\EucPilotProgram'
)) {
    if (Test-Path -LiteralPath $pathToRemove) {
        Remove-Item -LiteralPath $pathToRemove -Recurse -Force
    }
}

Write-Output 'EUC Early Adopter opt-in marker removed.'