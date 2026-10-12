#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$PocId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$ApplicationGroupName,
    [Parameter(Mandatory)][string]$WorkspaceResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$RitmNumber,
    [Parameter(Mandatory)][string]$VmName,
    [switch]$Execute,
    [string]$ConfirmationText = 'PLAN-ONLY',
    [string]$ReportPath = (Join-Path $PWD 'avd-hybrid-decommission.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$ArgumentList, [switch]$AllowEmpty)
    $raw = & az @ArgumentList --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($ArgumentList -join ' ')`n$($raw -join [Environment]::NewLine)" }
    $text = $raw -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($AllowEmpty) { return $null }
        throw "Azure CLI returned no JSON: az $($ArgumentList -join ' ')"
    }
    return $text | ConvertFrom-Json -Depth 100
}

if ($RitmNumber -notmatch '^RITM(?<number>[0-9]+)$') { throw "RITM number '$RitmNumber' is invalid." }
$expectedVmName = "AVD$($Matches.number)".ToUpperInvariant()
if ($VmName.ToUpperInvariant() -ne $expectedVmName) { throw "VM '$VmName' does not match RITM-derived name '$expectedVmName'." }

$null = & az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Unable to select subscription '$SubscriptionId'." }
$account = Invoke-AzJson @('account', 'show')
if ([string]$account.tenantId -ine $TenantId) { throw "Authenticated tenant does not match '$TenantId'." }

$group = Invoke-AzJson @('group', 'show', '--name', $ResourceGroupName, '--subscription', $SubscriptionId)
$requiredTags = @{
    ManagedBy = 'AzureVirtualDesktopPoc'
    PocId = $PocId
    HostingPlatform = 'Proxmox'
}
foreach ($tag in $requiredTags.GetEnumerator()) {
    if ([string]$group.tags.($tag.Key) -cne [string]$tag.Value) {
        throw "Resource group '$ResourceGroupName' failed safety tag '$($tag.Key)=$($tag.Value)'."
    }
}

$arc = Invoke-AzJson @('connectedmachine', 'show', '--subscription', $SubscriptionId, '--resource-group', $ResourceGroupName, '--name', $VmName)
$hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$appGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/applicationGroups/$ApplicationGroupName"
$hostPool = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://management.azure.com${hostPoolId}?api-version=2024-04-03")
$appGroup = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://management.azure.com${appGroupId}?api-version=2024-04-03")
$workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$WorkspaceResourceGroupName/providers/Microsoft.DesktopVirtualization/workspaces/$WorkspaceName"
$workspace = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://management.azure.com${workspaceId}?api-version=2024-04-03")
$hostResponse = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://management.azure.com${hostPoolId}/sessionHosts?api-version=2024-04-03")
$sessionHost = @($hostResponse.value | Where-Object { (([string]$_.name -split '/')[-1] -split '\.')[0] -ieq $VmName }) | Select-Object -First 1
$arcAssignments = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', $arc.id))
$appAssignments = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', $appGroup.id))
$resources = @(Invoke-AzJson @('resource', 'list', '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId))
$otherArcMachines = @($resources | Where-Object { $_.type -ieq 'Microsoft.HybridCompute/machines' -and $_.name -ine $VmName })
$otherSessionHosts = @($hostResponse.value | Where-Object { (([string]$_.name -split '/')[-1] -split '\.')[0] -ine $VmName })
$safetyBlockers = [System.Collections.Generic.List[string]]::new()
if ($otherArcMachines.Count -gt 0) { $safetyBlockers.Add("Hybrid group contains other Arc machines: $($otherArcMachines.name -join ', ')") }
if ($otherSessionHosts.Count -gt 0) { $safetyBlockers.Add("Hybrid host pool contains other session hosts: $($otherSessionHosts.name -join ', ')") }

$report = [ordered]@{
    mode = if ($Execute) { 'Execute' } else { 'PlanOnly' }
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    pocId = $PocId
    ritmNumber = $RitmNumber
    resourceGroup = @{ id = $group.id; name = $group.name; tags = $group.tags }
    arcMachine = @{ id = $arc.id; name = $arc.name; status = $arc.status }
    hostPool = @{ id = $hostPool.id; name = $hostPool.name }
    applicationGroup = @{ id = $appGroup.id; name = $appGroup.name }
    workspace = @{ id = $workspace.id; name = $workspace.name; containsApplicationGroup = @($workspace.properties.applicationGroupReferences) -contains $appGroup.id }
    safetyBlockers = @($safetyBlockers)
    sessionHost = if ($sessionHost) { @{ id = $sessionHost.id; name = $sessionHost.name; assignedUser = $sessionHost.properties.assignedUser } } else { $null }
    arcRoleAssignments = @($arcAssignments | Select-Object id, principalId, roleDefinitionId)
    applicationGroupRoleAssignments = @($appAssignments | Select-Object id, principalId, roleDefinitionId)
    resourceInventory = @($resources | Select-Object id, name, type)
    proxmoxVmAction = 'Preserve; manual handling required'
}
$parent = Split-Path -Parent $ReportPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ReportPath -Encoding utf8

if (-not $Execute) {
    Write-Host "Plan only. Inventory written to '$ReportPath'. No resource was changed."
    if ($safetyBlockers.Count -gt 0) { Write-Warning ($safetyBlockers -join [Environment]::NewLine) }
    return
}
if ($safetyBlockers.Count -gt 0) { throw ("Decommission safety blockers: " + ($safetyBlockers -join "; ")) }

$requiredConfirmation = "DELETE HYBRID $PocId"
if ($ConfirmationText -cne $requiredConfirmation) { throw "Confirmation must exactly equal '$requiredConfirmation'." }
if (-not $PSCmdlet.ShouldProcess("$ResourceGroupName and Azure registration for $VmName", 'Decommission AVD Hybrid Azure resources')) { return }

if ($sessionHost) {
    $drainBody = @{ properties = @{ allowNewSession = $false } } | ConvertTo-Json -Compress
    [void](Invoke-AzJson @('rest', '--method', 'PATCH', '--url', "https://management.azure.com$($sessionHost.id)?api-version=2024-04-03", '--headers', 'Content-Type=application/json', '--body', $drainBody))

    foreach ($assignment in @($arcAssignments + $appAssignments)) {
        $roleId = ([string]$assignment.roleDefinitionId -split '/')[-1]
        if ($roleId -in @('1c0163c0-47e6-4577-8991-ea5c82e286e4', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')) {
            & az role assignment delete --ids $assignment.id --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw "Unable to remove role assignment '$($assignment.id)'." }
        }
    }

    $encodedName = [Uri]::EscapeDataString(([string]$sessionHost.name -split '/')[-1])
    [void](Invoke-AzJson @('rest', '--method', 'DELETE', '--url', "https://management.azure.com${hostPoolId}/sessionHosts/${encodedName}?api-version=2024-04-03") -AllowEmpty)
}

$remainingReferences = @($workspace.properties.applicationGroupReferences | Where-Object { $_ -ine $appGroup.id })
if ($remainingReferences.Count -ne @($workspace.properties.applicationGroupReferences).Count) {
    $workspaceBody = @{ properties = @{ applicationGroupReferences = $remainingReferences } } | ConvertTo-Json -Depth 10 -Compress
    [void](Invoke-AzJson @('rest', '--method', 'PATCH', '--url', "https://management.azure.com${workspaceId}?api-version=2024-04-03", '--headers', 'Content-Type=application/json', '--body', $workspaceBody))
}

if ([string]$arc.status -ieq 'Connected') {
    $disconnectScript = @'
$agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
if (-not (Test-Path -LiteralPath $agent)) { throw 'Azure Connected Machine agent executable was not found.' }
& $agent disconnect --force-local-only
if ($LASTEXITCODE -ne 0) { throw 'azcmagent disconnect failed.' }
'@
    & az connectedmachine run-command create `
        --name 'avd-hybrid-disconnect' --machine-name $VmName --resource-group $ResourceGroupName `
        --subscription $SubscriptionId --location $arc.location --script $disconnectScript `
        --timeout-in-seconds 600 --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Arc disconnect lost contact or failed; Azure resource-group removal will continue. The Proxmox VM is not powered off or deleted.' }
}

& az group delete --name $ResourceGroupName --subscription $SubscriptionId --yes --no-wait --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Unable to start deletion of '$ResourceGroupName'." }
& az group wait --name $ResourceGroupName --subscription $SubscriptionId --deleted --interval 15 --timeout 3600 --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Timed out waiting for '$ResourceGroupName' deletion." }

$roleNames = @(
    "AVD Hybrid POC Deployment $PocId",
    "AVD Hybrid POC Readiness $PocId",
    "AVD Hybrid POC Assignment $PocId"
)
foreach ($roleName in $roleNames) {
    $definition = Invoke-AzJson @('role', 'definition', 'list', '--name', $roleName, '--subscription', $SubscriptionId)
    if (@($definition).Count -eq 0) { continue }
    $scope = @($definition[0].assignableScopes)
    if ($scope.Count -ne 1 -or [string]$scope[0] -ine [string]$group.id) {
        throw "Custom role '$roleName' has an unexpected assignable scope; it was not removed."
    }
    & az role definition delete --name $roleName --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to remove custom role '$roleName'." }
}

$report.completedUtc = [DateTime]::UtcNow.ToString('o')
$report.azureResourcesRemoved = $true
$report.proxmoxVmAction = 'Preserved; Azure agent disconnected locally when reachable'
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ReportPath -Encoding utf8
Write-Host "Hybrid Azure resources were removed. Proxmox VM '$VmName' was preserved."
