#requires -Version 5.1

[CmdletBinding()]
param()

$expectedVersion = '1.0.0'
$installPath = Join-Path $env:ProgramData 'ManagedDriveMapper'
$requiredFiles = @(
    'Invoke-DriveMapper.ps1',
    'Mappings.json',
    'Register-DriveMapperTask.ps1',
    'Test-DriveMapperTask.ps1',
    'Version.json'
)

try {
    $installedVersion = [string](Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\ManagedDriveMapper' -Name Version -ErrorAction Stop)
    if ($installedVersion -ne $expectedVersion) { exit 1 }
    $registeredInstallPath = [string](Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\ManagedDriveMapper' -Name InstallPath -ErrorAction Stop)
    if ($registeredInstallPath -ine $installPath) { exit 1 }

    foreach ($file in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $installPath $file) -PathType Leaf)) { exit 1 }
    }

    $payloadVersion = Get-Content -LiteralPath (Join-Path $installPath 'Version.json') -Raw | ConvertFrom-Json
    if ([string]$payloadVersion.Version -ne $expectedVersion) { exit 1 }

    & (Join-Path $installPath 'Invoke-DriveMapper.ps1') `
        -ConfigurationPath (Join-Path $installPath 'Mappings.json') -ValidateOnly | Out-Null
    & (Join-Path $installPath 'Test-DriveMapperTask.ps1') -InstallPath $installPath

    Write-Output "ManagedDriveMapper $installedVersion is installed and scheduled."
    exit 0
}
catch { exit 1 }
