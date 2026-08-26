#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$installPath = Join-Path $env:ProgramData 'ManagedDriveMapper'
$registerPath = Join-Path $installPath 'Register-DriveMapperTask.ps1'

if (-not (Test-Path -LiteralPath $registerPath -PathType Leaf)) {
    throw 'Register-DriveMapperTask.ps1 is missing. Let the required Win32 app reinstall the package.'
}

& $registerPath -InstallPath $installPath
Write-Output 'Drive mapper scheduled task was repaired.'
