#requires -Version 5.1

[CmdletBinding()]
param()

$expectedVersion = '1.0.0'
$installPath = Join-Path $env:ProgramData 'ManagedDriveMapper'
$requiredFiles = @('Invoke-DriveMapper.ps1', 'Mappings.json', 'Register-DriveMapperTask.ps1', 'Version.json')

try {
    $installedVersion = [string](Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\ManagedDriveMapper' -Name Version -ErrorAction Stop)
    if ($installedVersion -ne $expectedVersion) { exit 1 }

    foreach ($file in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $installPath $file) -PathType Leaf)) { exit 1 }
    }

    $task = Get-ScheduledTask -TaskName 'Managed Drive Mapper' -ErrorAction Stop
    if ($task.State -eq 'Disabled') { exit 1 }
    $expectedEngine = Join-Path $installPath 'Invoke-DriveMapper.ps1'
    $taskArguments = [string](@($task.Actions)[0].Arguments)
    if ($taskArguments -notlike "*$expectedEngine*") { exit 1 }

    Write-Output "ManagedDriveMapper $installedVersion is installed and scheduled."
    exit 0
}
catch { exit 1 }
