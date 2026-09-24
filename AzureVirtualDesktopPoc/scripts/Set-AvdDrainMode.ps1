#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$PlatformResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$VmName
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$raw = & az rest --method GET --url "https://management.azure.com$hostPoolId/sessionHosts?api-version=2024-04-03" --only-show-errors --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Unable to inspect AVD session hosts: $($raw -join [Environment]::NewLine)"
    return
}
$response = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
$sessionHost = @($response.value) | Where-Object {
    $leaf = (([string]$_.name -split '/')[-1] -split '\.')[0]
    $leaf -ieq $VmName
} | Select-Object -First 1
if (-not $sessionHost) {
    Write-Host "No AVD registration exists for '$VmName'; no drain-mode change was required."
    return
}

$body = @{ properties = @{ allowNewSession = $false } } | ConvertTo-Json -Compress
$raw = & az rest --method PATCH --url "https://management.azure.com$($sessionHost.id)?api-version=2024-04-03" --headers 'Content-Type=application/json' --body $body --only-show-errors --output none 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Unable to place '$VmName' in drain mode: $($raw -join [Environment]::NewLine)"
}
Write-Host "Placed '$VmName' in drain mode after provisioning failure."
