#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ArcResourceGroupName,
    [Parameter(Mandatory)] [string] $PlatformResourceGroupName,
    [Parameter(Mandatory)] [string] $HostPoolName,
    [Parameter(Mandatory)] [string] $ApplicationGroupName,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $RequestedForUpn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')" }
    if ([string]::IsNullOrWhiteSpace(($result -join "`n"))) { return $null }
    return (($result -join "`n") | ConvertFrom-Json -Depth 100)
}

$null = Invoke-AzJson -Arguments @('account', 'set', '--subscription', $SubscriptionId)
$account = Invoke-AzJson -Arguments @('account', 'show')
if ($account.tenantId -ine $TenantId) { throw "Authenticated tenant does not match '$TenantId'." }

$user = Invoke-AzJson -Arguments @('ad', 'user', 'show', '--id', $RequestedForUpn)
if (-not $user.accountEnabled) { throw "Requested user '$RequestedForUpn' is disabled." }

$arc = Invoke-AzJson -Arguments @('connectedmachine', 'show', '--subscription', $SubscriptionId, '--resource-group', $ArcResourceGroupName, '--name', $VmName)
if ($arc.status -ne 'Connected') { throw "Arc machine '$VmName' is not connected." }

$appGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/applicationGroups/$ApplicationGroupName"
$vmLoginRoleId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/1c0163c0-47e6-4577-8991-ea5c82e286e4"
$desktopUserRoleId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63"

function Ensure-RoleAssignment {
    param([string] $Scope, [string] $RoleDefinitionId)
    $name = [guid]::NewGuid().Guid
    $existing = Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--scope', $Scope, '--assignee-object-id', $user.id, '--include-inherited', '--query', "[?roleDefinitionId=='$RoleDefinitionId']")
    if (@($existing).Count -eq 0) {
        $null = Invoke-AzJson -Arguments @(
            'role', 'assignment', 'create', '--name', $name,
            '--assignee-object-id', $user.id, '--assignee-principal-type', 'User',
            '--role', $RoleDefinitionId, '--scope', $Scope
        )
    }
}

Ensure-RoleAssignment -Scope $arc.id -RoleDefinitionId $vmLoginRoleId
Ensure-RoleAssignment -Scope $appGroupId -RoleDefinitionId $desktopUserRoleId

$hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$sessionHostResponse = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://management.azure.com$hostPoolId/sessionHosts?api-version=2024-04-03")
$sessionHost = @($sessionHostResponse.value | Where-Object { $_.name.Split('/')[-1].Split('.')[0] -ieq $VmName }) | Select-Object -First 1
if (-not $sessionHost) { throw "AVD session host for '$VmName' was not found." }

$sessionHostName = $sessionHost.name.Split('/')[-1]
$encodedSessionHost = [uri]::EscapeDataString($sessionHostName)
$sessionHostUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName/sessionHosts/$encodedSessionHost?api-version=2024-04-03"
$body = @{ properties = @{ assignedUser = $RequestedForUpn; allowNewSession = $true } } | ConvertTo-Json -Depth 5 -Compress
$updated = Invoke-AzJson -Arguments @('rest', '--method', 'PATCH', '--url', $sessionHostUri, '--body', $body)
if ($updated.properties.assignedUser -ine $RequestedForUpn) { throw "Personal desktop assignment was not applied to '$sessionHostName'." }

Write-Host "Assigned '$RequestedForUpn' to hybrid session host '$sessionHostName'."
