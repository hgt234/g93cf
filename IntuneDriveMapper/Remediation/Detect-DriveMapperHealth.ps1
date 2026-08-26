#requires -Version 5.1

[CmdletBinding()]
param()

$installPath = Join-Path $env:ProgramData 'ManagedDriveMapper'
$enginePath = Join-Path $installPath 'Invoke-DriveMapper.ps1'
$registerPath = Join-Path $installPath 'Register-DriveMapperTask.ps1'

try {
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $registerPath -PathType Leaf)) {
        Write-Output 'Drive mapper installation is incomplete; Win32 app repair is required.'
        exit 1
    }

    $task = Get-ScheduledTask -TaskName 'Managed Drive Mapper' -ErrorAction Stop
    if ($task.State -eq 'Disabled') { throw 'Scheduled task is disabled.' }
    if ([string](@($task.Actions)[0].Arguments) -notlike "*$enginePath*") { throw 'Scheduled task action is incorrect.' }

    Write-Output 'Drive mapper scheduled task is healthy.'
    exit 0
}
catch {
    Write-Output "Drive mapper health check failed: $($_.Exception.Message)"
    exit 1
}
