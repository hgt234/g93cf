#requires -Version 5.1

[CmdletBinding()]
param(
    [string] $AppsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'apps'),
    [switch] $WarningsAsErrors
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AppFactory.Common.ps1')

$manifests = @(Get-AppFactoryManifest -RootPath $AppsPath)
if ($manifests.Count -eq 0) { throw "No app.json manifests were found below '$AppsPath'." }

$issues = [System.Collections.Generic.List[object]]::new()
$manifests | ForEach-Object {
    foreach ($issue in @(Test-AppFactoryManifest -Manifest $_)) { $issues.Add($issue) }
}

$duplicateIds = $manifests | Group-Object id | Where-Object Count -gt 1
foreach ($duplicate in $duplicateIds) {
    $issues.Add([pscustomobject]@{
        Severity = 'Error'
        AppId = $duplicate.Name
        Message = "Application ID occurs $($duplicate.Count) times."
    })
}

if ($issues.Count -gt 0) {
    $issues | Sort-Object Severity, AppId, Message | Format-Table -AutoSize | Out-Host
}

$errorCount = @($issues | Where-Object Severity -eq 'Error').Count
$warningCount = @($issues | Where-Object Severity -eq 'Warning').Count
Write-Host "Validated $($manifests.Count) application manifests: $errorCount error(s), $warningCount warning(s)."

if ($errorCount -gt 0 -or ($WarningsAsErrors -and $warningCount -gt 0)) { exit 1 }

