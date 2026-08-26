#requires -Version 5.1

[CmdletBinding()]
param()

$installPath = Join-Path $env:ProgramData 'ManagedDriveMapper'
$requiredFiles = @(
    'Invoke-DriveMapper.ps1',
    'Mappings.json',
    'Register-DriveMapperTask.ps1',
    'Test-DriveMapperTask.ps1',
    'Version.json'
)

try {
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $installPath $file) -PathType Leaf)) {
            Write-Output 'Drive mapper installation is incomplete; Win32 app repair is required.'
            exit 1
        }
    }

    & (Join-Path $installPath 'Invoke-DriveMapper.ps1') `
        -ConfigurationPath (Join-Path $installPath 'Mappings.json') -ValidateOnly | Out-Null
    & (Join-Path $installPath 'Test-DriveMapperTask.ps1') -InstallPath $installPath

    Write-Output 'Drive mapper scheduled task is healthy.'
    exit 0
}
catch {
    Write-Output "Drive mapper health check failed: $($_.Exception.Message)"
    exit 1
}
