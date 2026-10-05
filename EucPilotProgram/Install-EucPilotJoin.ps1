#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$registryPath = 'HKLM:\SOFTWARE\EucPilotProgram'
$programVersion = '1.0.0'

if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

New-ItemProperty -Path $registryPath -Name Status -Value 'Joined' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name Version -Value $programVersion -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name JoinedUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null

Write-Output "EUC Early Adopter opt-in marker written to $registryPath."