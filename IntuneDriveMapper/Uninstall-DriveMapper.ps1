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
    $installDirectory = Get-Item -LiteralPath $installPath -Force
    if (-not $installDirectory.PSIsContainer -or
        ($installDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recursively remove an invalid or redirected install path: $installPath"
    }
    $nestedReparsePoint = Get-ChildItem -LiteralPath $installPath -Force -Recurse |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($null -ne $nestedReparsePoint) {
        throw "Refusing to remove an install directory containing a reparse point: $($nestedReparsePoint.FullName)"
    }
    Remove-Item -LiteralPath $installPath -Recurse -Force
}

if (Test-Path -LiteralPath $registryPath) {
    Remove-Item -LiteralPath $registryPath -Recurse -Force
}

Write-Output 'Uninstalled ManagedDriveMapper. Existing per-user mappings and logs were preserved.'
