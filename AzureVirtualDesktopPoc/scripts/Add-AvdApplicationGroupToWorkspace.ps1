#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$WorkspaceResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$ApplicationGroupId
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$WorkspaceResourceGroupName/providers/Microsoft.DesktopVirtualization/workspaces/$WorkspaceName"
$workspaceJson = & az rest --method GET --url "https://management.azure.com${workspaceId}?api-version=2024-04-03" --output json --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) { throw "Unable to read AVD workspace '$WorkspaceName': $($workspaceJson -join [Environment]::NewLine)" }
$workspace = ($workspaceJson -join [Environment]::NewLine) | ConvertFrom-Json -Depth 50
$current = @($workspace.properties.applicationGroupReferences | ForEach-Object { [string]$_ })
if ($current -icontains $ApplicationGroupId) {
    Write-Host "Application group is already registered with workspace '$WorkspaceName'."
    return
}

$updated = @($current + $ApplicationGroupId | Sort-Object -Unique)
if ($updated.Count -lt $current.Count) { throw 'The additive workspace update would remove an existing application group.' }
$body = @{ properties = @{ applicationGroupReferences = $updated } } | ConvertTo-Json -Depth 10 -Compress
& az rest `
    --method PATCH `
    --url "https://management.azure.com${workspaceId}?api-version=2024-04-03" `
    --headers 'Content-Type=application/json' `
    --body $body `
    --output none `
    --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Unable to add the hybrid application group to '$WorkspaceName'." }
Write-Host "Added '$ApplicationGroupId' to '$WorkspaceName' without removing existing references."
