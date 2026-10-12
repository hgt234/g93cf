#requires -Version 5.1

[CmdletBinding()]
param()

$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'scripts\Test-AppManifests.ps1')
if (-not $?) { throw 'Manifest validation failed.' }

$json = & (Join-Path $root 'scripts\Get-AppDeploymentPlan.ps1') -Format Json
$plan = $json | ConvertFrom-Json
if (@($plan).Count -ne 5) { throw "Expected five example applications, found $(@($plan).Count)." }

$available = @($plan | Where-Object Intent -eq 'available')
if ($available.Count -ne 3) { throw "Expected three self-service applications, found $($available.Count)." }
if (@($available | Where-Object Target -ne 'allUsers').Count -ne 0) {
    throw 'All example self-service applications must target allUsers.'
}

$vscode = $plan | Where-Object AppId -eq 'vscode'
if ($vscode.Delivery -ne 'microsoftStore' -or $vscode.UsesPSADT) {
    throw 'Visual Studio Code must remain Store-native in the example.'
}

$sevenZip = $plan | Where-Object AppId -eq '7zip'
if ($sevenZip.Intent -ne 'required' -or $sevenZip.Delivery -ne 'enterpriseCatalogAutoUpdate') {
    throw '7-Zip must demonstrate required Enterprise App Catalog auto-update.'
}

Write-Host 'App factory tests passed.'
