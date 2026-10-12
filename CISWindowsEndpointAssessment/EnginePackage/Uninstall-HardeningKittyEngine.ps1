#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$engineVersion = '0.9.4'

try {
    $programFiles64 = if (-not [string]::IsNullOrWhiteSpace($env:ProgramW6432)) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $productRoot = Join-Path $programFiles64 'CISWindowsEndpointAssessment\HardeningKitty'
    $targetRoot = Join-Path $productRoot $engineVersion
    if (Test-Path -LiteralPath $targetRoot) {
        Remove-Item -LiteralPath $targetRoot -Recurse -Force -ErrorAction Stop
    }
    if ((Test-Path -LiteralPath $productRoot) -and @(Get-ChildItem -LiteralPath $productRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $productRoot -Force -ErrorAction Stop
    }
    Write-Output "Removed HardeningKitty engine $engineVersion. Assessment reports were retained."
    exit 0
}
catch {
    Write-Output "Unable to remove HardeningKitty engine ${engineVersion}: $($_.Exception.Message)"
    exit 1
}
