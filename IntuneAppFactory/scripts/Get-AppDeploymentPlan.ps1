#requires -Version 5.1

[CmdletBinding()]
param(
    [string] $AppsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'apps'),
    [ValidateSet('Table', 'Json')]
    [string] $Format = 'Table'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AppFactory.Common.ps1')

$manifests = @(Get-AppFactoryManifest -RootPath $AppsPath)
$errors = @($manifests | ForEach-Object { Test-AppFactoryManifest -Manifest $_ } |
    Where-Object Severity -eq 'Error')
if ($errors.Count -gt 0) {
    $errors | Format-Table -AutoSize | Out-Host
    throw 'Deployment plan cannot be generated until manifest errors are corrected.'
}

$plan = foreach ($app in $manifests) {
    $strategy = $app.lifecycle.strategy
    $version = if ($app.lifecycle.PSObject.Properties.Name -contains 'version') {
        $app.lifecycle.version
    } elseif ($strategy -eq 'enterpriseCatalogAutoUpdate') {
        '<catalog-latest>'
    } else {
        '<store-latest>'
    }
    $updateMechanism = switch ($strategy) {
        'microsoftStore' { 'Store/Intune native update' }
        'enterpriseCatalogAutoUpdate' { 'Enterprise Catalog required auto-update' }
        'psadtWin32' {
            if ($app.assignment.intent -eq 'available') { 'Win32 supersedence + assignment auto-update' }
            else { 'New required superseding Win32 version' }
        }
    }
    [pscustomobject]@{
        AppId = $app.id
        DisplayName = $app.displayName
        Version = $version
        Classification = $app.classification
        Delivery = $strategy
        Intent = $app.assignment.intent
        Target = $app.assignment.target
        UpdateMechanism = $updateMechanism
        UsesPSADT = ($strategy -eq 'psadtWin32')
    }
}

if ($Format -eq 'Json') {
    $plan | ConvertTo-Json -Depth 6
} else {
    $plan | Sort-Object Classification, DisplayName | Format-Table -AutoSize
}

