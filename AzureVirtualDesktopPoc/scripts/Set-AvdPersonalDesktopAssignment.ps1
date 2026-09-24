#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$SessionHostResourceGroupName,
    [Parameter(Mandatory)][string]$PlatformResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$DesktopAppGroupName,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$RequestedForUpn,
    [string]$UserObjectId
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $raw = & az @ArgumentList --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($ArgumentList -join ' ')`n$($raw -join [Environment]::NewLine)"
    }
    $text = $raw -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 100
}

function Ensure-RoleAssignment {
    param([string]$Scope, [string]$RoleDefinitionId)
    $expectedRoleId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$RoleDefinitionId"
    $listArguments = @(
        'role', 'assignment', 'list', '--assignee-object-id', $UserObjectId,
        '--scope', $Scope, '--subscription', $SubscriptionId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'
    )
    $existing = @(Invoke-AzCliJson -ArgumentList $listArguments) | Where-Object roleDefinitionId -IEQ $expectedRoleId
    if (-not $existing) {
        try {
            [void](Invoke-AzCliJson -ArgumentList @(
                'role', 'assignment', 'create',
                '--assignee-object-id', $UserObjectId,
                '--assignee-principal-type', 'User',
                '--role', $RoleDefinitionId,
                '--scope', $Scope,
                '--subscription', $SubscriptionId
            ))
        }
        catch {
            # A concurrent idempotent request can win the create race. Re-read
            # the exact scope and role before deciding that this is a failure.
            $existing = @(Invoke-AzCliJson -ArgumentList $listArguments) | Where-Object roleDefinitionId -IEQ $expectedRoleId
            if (-not $existing) { throw }
        }
    }
}

$vmId = "/subscriptions/$SubscriptionId/resourceGroups/$SessionHostResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName"
$appGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/applicationGroups/$DesktopAppGroupName"
$hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"

if ([string]::IsNullOrWhiteSpace($UserObjectId)) {
    $encodedUpn = [Uri]::EscapeDataString($RequestedForUpn)
    $user = Invoke-AzCliJson -ArgumentList @(
        'rest', '--method', 'GET',
        '--url', "https://graph.microsoft.com/v1.0/users/${encodedUpn}?`$select=id,accountEnabled"
    )
    if (-not $user.id -or $user.accountEnabled -ne $true) {
        throw "Entra user '$RequestedForUpn' was not found or is disabled."
    }
    $UserObjectId = [string]$user.id
}

# Built-in roles: Virtual Machine User Login and Desktop Virtualization User.
Ensure-RoleAssignment -Scope $vmId -RoleDefinitionId 'fb879df8-f326-4884-b1cf-06f3ad86be52'
Ensure-RoleAssignment -Scope $appGroupId -RoleDefinitionId '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

$sessionHostResponse = Invoke-AzCliJson -ArgumentList @(
    'rest', '--method', 'GET',
    '--url', "https://management.azure.com$hostPoolId/sessionHosts?api-version=2024-04-03"
)
$sessionHost = @($sessionHostResponse.value) | Where-Object {
    $leaf = (([string]$_.name -split '/')[-1] -split '\.')[0]
    $leaf -ieq $VmName
} | Select-Object -First 1
if (-not $sessionHost) { throw "AVD session host '$VmName' was not found in '$HostPoolName'." }
if ([string]$sessionHost.properties.status -ine 'Available') {
    throw "AVD session host '$VmName' is '$($sessionHost.properties.status)', not Available."
}
if ($sessionHost.properties.assignedUser -and [string]$sessionHost.properties.assignedUser -ine $RequestedForUpn) {
    throw "Session host '$VmName' is already assigned to '$($sessionHost.properties.assignedUser)'."
}

$assignmentBody = @{ properties = @{ assignedUser = $RequestedForUpn; allowNewSession = $true } } | ConvertTo-Json -Compress
$assignmentBodyPath = Join-Path ([IO.Path]::GetTempPath()) "avd-assignment-$([Guid]::NewGuid().ToString('N')).json"
try {
    $assignmentBody | Set-Content -LiteralPath $assignmentBodyPath -Encoding utf8
    [void](Invoke-AzCliJson -ArgumentList @(
        'rest', '--method', 'PATCH',
        '--url', "https://management.azure.com$($sessionHost.id)?api-version=2024-04-03",
        '--headers', 'Content-Type=application/json',
        '--body', "@$assignmentBodyPath"
    ))
}
finally {
    Remove-Item -LiteralPath $assignmentBodyPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Assigned '$RequestedForUpn' to personal session host '$VmName'."
