[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$')]
    [string]$EnvironmentName,

    [Parameter(Mandatory)][string]$OutputPath,

    [string]$ResourceConfiguration = (Join-Path $PSScriptRoot '../config/resources.json'),

    [string]$NormalizationConfiguration = (Join-Path $PSScriptRoot '../config/normalization.json'),

    [string]$AccessToken = $env:GRAPH_ACCESS_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Graph.Common.ps1')

function ConvertTo-NormalizedValue {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$ExcludedProperties,
        [Parameter(Mandatory)][bool]$SortArrays
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double] -or
        $Value -is [single]) {
        return $Value
    }
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime().ToString('o')
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys) | Sort-Object { [string]$_ }) {
            if (-not $ExcludedProperties.Contains([string]$key)) {
                $result[[string]$key] = ConvertTo-NormalizedValue -Value $Value[$key] -ExcludedProperties $ExcludedProperties -SortArrays $SortArrays
            }
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(
            foreach ($item in $Value) {
                ConvertTo-NormalizedValue -Value $item -ExcludedProperties $ExcludedProperties -SortArrays $SortArrays
            }
        )
        if ($SortArrays) {
            $items = @($items | Sort-Object { $_ | ConvertTo-Json -Depth 100 -Compress })
        }
        return ,$items
    }

    $objectResult = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties) | Sort-Object Name) {
        if ($property.MemberType -in @('NoteProperty', 'Property', 'AliasProperty') -and
            -not $ExcludedProperties.Contains($property.Name)) {
            $objectResult[$property.Name] = ConvertTo-NormalizedValue -Value $property.Value -ExcludedProperties $ExcludedProperties -SortArrays $SortArrays
        }
    }
    return $objectResult
}

function Write-StableJson {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Path)
    $json = $Value | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath $Path -Value $json -Encoding utf8NoBOM
}

if (-not (Test-Path -LiteralPath $ResourceConfiguration -PathType Leaf)) {
    throw "Resource configuration not found: $ResourceConfiguration"
}
if (-not (Test-Path -LiteralPath $NormalizationConfiguration -PathType Leaf)) {
    throw "Normalization configuration not found: $NormalizationConfiguration"
}

$resourcesConfig = Get-Content -LiteralPath $ResourceConfiguration -Raw | ConvertFrom-Json
$normalizationConfig = Get-Content -LiteralPath $NormalizationConfiguration -Raw | ConvertFrom-Json
$excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $normalizationConfig.excludedPropertyNames) { [void]$excluded.Add([string]$name) }
$sortArrays = [bool]$normalizationConfig.sortArrays
$headers = New-GraphHeaders -AccessToken $AccessToken

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $resolvedOutput) {
    if (@(Get-ChildItem -LiteralPath $resolvedOutput -Force).Count -gt 0) {
        throw "OutputPath must be empty to prevent stale objects from surviving an export: $resolvedOutput"
    }
}
else {
    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
}

$manifestResources = [System.Collections.Generic.List[object]]::new()
foreach ($resource in $resourcesConfig.resources) {
    $resourceName = [string]$resource.name
    Write-Host "Exporting $resourceName..."
    $resourceFolder = Join-Path $resolvedOutput $resourceName
    New-Item -ItemType Directory -Path $resourceFolder -Force | Out-Null

    $baseUri = "https://graph.microsoft.com/$($resource.apiVersion)"
    $list = @(Get-GraphCollection -Uri ($baseUri + [string]$resource.listPath) -Headers $headers)
    $objectIndex = [System.Collections.Generic.List[object]]::new()

    foreach ($listItem in $list) {
        $id = [string]$listItem.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw "Resource '$resourceName' returned an object without an id."
        }

        $escapedId = [Uri]::EscapeDataString($id)
        $detailPath = ([string]$resource.detailPath).Replace('{id}', $escapedId)
        $detail = Invoke-GraphGet -Uri ($baseUri + $detailPath) -Headers $headers
        $completeObject = [ordered]@{}
        foreach ($property in $detail.PSObject.Properties) {
            $completeObject[$property.Name] = $property.Value
        }

        foreach ($child in @($resource.children)) {
            $childUri = "$baseUri$detailPath/$($child.path)"
            $completeObject[[string]$child.name] = @(Get-GraphCollection -Uri $childUri -Headers $headers)
        }

        $normalized = ConvertTo-NormalizedValue -Value $completeObject -ExcludedProperties $excluded -SortArrays $sortArrays
        $safeId = $id -replace '[^a-zA-Z0-9._-]', '_'
        $relativePath = "$resourceName/$safeId.json"
        Write-StableJson -Value $normalized -Path (Join-Path $resolvedOutput $relativePath)

        $displayNameProperty = $detail.PSObject.Properties['displayName']
        $nameProperty = $detail.PSObject.Properties['name']
        $displayName = if ($null -ne $displayNameProperty -and $displayNameProperty.Value) { [string]$displayNameProperty.Value }
            elseif ($null -ne $nameProperty -and $nameProperty.Value) { [string]$nameProperty.Value }
            else { $id }
        $objectIndex.Add([ordered]@{ id = $id; displayName = $displayName; path = $relativePath })
    }

    $manifestResources.Add([ordered]@{
        name = $resourceName
        count = $objectIndex.Count
        objects = @($objectIndex | Sort-Object displayName, id)
    })
}

$manifest = [ordered]@{
    schemaVersion = 1
    environment = $EnvironmentName
    resources = @($manifestResources | Sort-Object name)
}
Write-StableJson -Value $manifest -Path (Join-Path $resolvedOutput 'manifest.json')
Write-Host "Export complete: $resolvedOutput"

