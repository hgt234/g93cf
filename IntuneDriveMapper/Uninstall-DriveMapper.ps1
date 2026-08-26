#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$taskName = 'Managed Drive Mapper'
$installPath = Join-Path $env:ProgramData 'ManagedDriveMapper'
$registryPath = 'HKLM:\SOFTWARE\ManagedDriveMapper'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

if (Test-Path -LiteralPath $installPath) {
    Remove-Item -LiteralPath $installPath -Recurse -Force
}

if (Test-Path -LiteralPath $registryPath) {
    Remove-Item -LiteralPath $registryPath -Recurse -Force
}

Write-Output 'Uninstalled ManagedDriveMapper. Existing per-user mappings and logs were preserved.'
