[CmdletBinding()]
param(
    [Parameter(Mandatory)][datetime]$SinceUtc,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$AccessToken = $env:GRAPH_ACCESS_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Graph.Common.ps1')

function Get-PropertyValue {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$headers = New-GraphHeaders -AccessToken $AccessToken
$stamp = $SinceUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$filter = [Uri]::EscapeDataString("activityDateTime ge $stamp")
$uri = 'https://graph.microsoft.com/v1.0/deviceManagement/auditEvents?$filter=' + $filter
$events = @(Get-GraphCollection -Uri $uri -Headers $headers)

$normalizedEvents = @(
    foreach ($event in $events) {
        $actor = Get-PropertyValue -InputObject $event -Name 'actor'
        [ordered]@{
            id = Get-PropertyValue -InputObject $event -Name 'id'
            activityDateTime = Get-PropertyValue -InputObject $event -Name 'activityDateTime'
            activity = Get-PropertyValue -InputObject $event -Name 'activity'
            componentName = Get-PropertyValue -InputObject $event -Name 'componentName'
            result = Get-PropertyValue -InputObject $event -Name 'activityResult'
            actor = [ordered]@{
                userPrincipalName = Get-PropertyValue -InputObject $actor -Name 'userPrincipalName'
                servicePrincipalName = Get-PropertyValue -InputObject $actor -Name 'servicePrincipalName'
                applicationDisplayName = Get-PropertyValue -InputObject $actor -Name 'applicationDisplayName'
            }
            resources = @(
                foreach ($resource in @(Get-PropertyValue -InputObject $event -Name 'resources')) {
                    [ordered]@{
                        id = Get-PropertyValue -InputObject $resource -Name 'resourceId'
                        displayName = Get-PropertyValue -InputObject $resource -Name 'displayName'
                        type = Get-PropertyValue -InputObject $resource -Name 'type'
                    }
                }
            )
        }
    }
)

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$document = [ordered]@{
    sinceUtc = $stamp
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    events = @($normalizedEvents | Sort-Object activityDateTime -Descending)
}
$document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Exported $($normalizedEvents.Count) recent Intune audit events."
