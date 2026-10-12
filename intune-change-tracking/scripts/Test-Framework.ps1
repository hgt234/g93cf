[CmdletBinding()]
param([string]$FrameworkRoot = (Join-Path $PSScriptRoot '..'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($FrameworkRoot)

$required = @(
    'azure-pipelines.yml',
    'config/resources.json',
    'config/normalization.json',
    'scripts/Export-IntuneState.ps1',
    'scripts/Export-IntuneAudit.ps1',
    'scripts/Compare-IntuneState.ps1',
    'scripts/Sync-IntuneState.ps1',
    'scripts/New-ChangeRecord.ps1'
)
foreach ($relative in $required) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file missing: $relative" }
}

foreach ($jsonRelative in @('config/resources.json', 'config/normalization.json')) {
    $jsonPath = Join-Path $root $jsonRelative
    try { $null = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json }
    catch { throw "Invalid JSON in $jsonRelative`: $($_.Exception.Message)" }
}

$resourceConfig = Get-Content -LiteralPath (Join-Path $root 'config/resources.json') -Raw | ConvertFrom-Json
$duplicates = @($resourceConfig.resources | Group-Object name | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) { throw "Duplicate resource names: $($duplicates.Name -join ', ')" }
foreach ($resource in $resourceConfig.resources) {
    foreach ($property in @('name', 'apiVersion', 'listPath', 'detailPath')) {
        if (-not $resource.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$resource.$property)) {
            throw "Resource is missing '$property': $($resource | ConvertTo-Json -Compress)"
        }
    }
    if ([string]$resource.detailPath -notmatch '\{id\}') { throw "detailPath must contain {id}: $($resource.name)" }
}

$parseFailures = [System.Collections.Generic.List[string]]::new()
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) { $parseFailures.Add("$($script.Name): $($parseError.Message)") }
}
if ($parseFailures.Count -gt 0) { throw ($parseFailures -join [Environment]::NewLine) }

Write-Host "Framework validation passed ($($resourceConfig.resources.Count) resource categories)."

