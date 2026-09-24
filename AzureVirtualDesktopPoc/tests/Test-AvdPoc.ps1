#Requires -Version 7.2

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$parseFailures = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -Path $root -Filter '*.ps1' -Recurse | ForEach-Object {
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) {
        [void]$parseFailures.Add("$($_.FullName): $($parseError.Message)")
    }
}
if ($parseFailures.Count -gt 0) { throw ($parseFailures -join [Environment]::NewLine) }

$requestScript = Join-Path $root 'scripts/Test-AvdRequest.ps1'
$validJson = ((& $requestScript `
    -RitmNumber 'RITM001234' `
    -RequestedHostName 'AVD001234' `
    -RequestedForUpn 'user@contoso.com' `
    -RitmSysId '0123456789abcdef0123456789abcdef') -join [Environment]::NewLine)
$valid = $validJson | ConvertFrom-Json
if ($valid.hostName -cne 'AVD001234') { throw 'Leading-zero hostname mapping failed.' }

$rejected = $false
try {
    & $requestScript `
        -RitmNumber 'RITM1234' `
        -RequestedHostName 'AVD9999' `
        -RequestedForUpn 'user@contoso.com' `
        -RitmSysId '0123456789abcdef0123456789abcdef' | Out-Null
}
catch { $rejected = $_.Exception.Message -like '*requires the exact host name*' }
if (-not $rejected) { throw 'Mismatched hostname was not rejected.' }

$sessionHostTemplate = Get-Content -LiteralPath (Join-Path $root 'infra/session-host.bicep') -Raw
if ($sessionHostTemplate -match 'Microsoft\.Network/publicIPAddresses') {
    throw 'The session-host template must not create a public IP address.'
}

$normalDeploymentFiles = @(
    (Join-Path $root 'infra/main.bicep'),
    (Join-Path $root 'infra/hybrid-main.bicep'),
    (Join-Path $root 'infra/hybrid-access.bicep'),
    (Join-Path $root 'infra/session-host.bicep'),
    (Join-Path $root 'infra/image-main.bicep'),
    (Join-Path $root 'infra/access.bicep'),
    (Join-Path $root 'pipelines/azure-pipelines-platform.yml'),
    (Join-Path $root 'pipelines/azure-pipelines-session-host.yml'),
    (Join-Path $root 'pipelines/azure-pipelines-image.yml'),
    (Join-Path $root 'pipelines/azure-pipelines-access.yml'),
    (Join-Path $root 'pipelines/azure-pipelines-hybrid-platform.yml'),
    (Join-Path $root 'pipelines/azure-pipelines-hybrid-access.yml'),
    (Join-Path $root 'pipelines/azure-pipelines-hybrid-onboard.yml'),
    (Join-Path $root 'scripts/Register-AvdResourceProviders.ps1')
)
foreach ($path in $normalDeploymentFiles) {
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -match '(?im)--mode\s+Complete|\bgroup\s+delete\b|\bresource\s+delete\b') {
        throw "Normal deployment file contains a destructive operation: $path"
    }
}

$hybridTemplate = Get-Content -LiteralPath (Join-Path $root 'infra/hybrid-main.bicep') -Raw
$hybridModule = Get-Content -LiteralPath (Join-Path $root 'infra/modules/hybrid-platform.bicep') -Raw
$hybridInfrastructure = $hybridTemplate + $hybridModule
if ($hybridInfrastructure -match 'Microsoft\.Network/(?:publicIPAddresses|natGateways|virtualNetworks|networkSecurityGroups)') {
    throw 'The Proxmox hybrid foundation must not create Azure network or public-IP resources.'
}
foreach ($requiredTag in @('ManagedBy', 'PocId', 'HostingPlatform')) {
    if ($hybridTemplate -notmatch [regex]::Escape($requiredTag)) { throw "Hybrid foundation is missing required safety tag '$requiredTag'." }
}

$hybridOnboarding = Get-Content -LiteralPath (Join-Path $root 'pipelines/azure-pipelines-hybrid-onboard.yml') -Raw
if ($hybridOnboarding -match '(?im)\baz\s+(?:group|resource|vm)\s+delete\b|\b(?:qm|pvesh)\s+(?:stop|destroy)\b') {
    throw 'Hybrid onboarding contains a prohibited Azure deletion or Proxmox power/deletion command.'
}
$hybridDecommission = Get-Content -LiteralPath (Join-Path $root 'scripts/Remove-AvdHybridPoc.ps1') -Raw
if ($hybridDecommission -notmatch 'DELETE HYBRID \$PocId' -or $hybridDecommission -notmatch 'HostingPlatform') {
    throw 'Hybrid decommission is missing exact confirmation or hosting-platform safety validation.'
}

$decommissionPath = Join-Path $root 'scripts/Remove-AvdPoc.ps1'
$decommission = Get-Content -LiteralPath $decommissionPath -Raw
$requiredTeardownLiterals = @(
    'POC01',
    '57383abf-70be-4ada-aad8-c939d04bd112',
    'ce5eca28-c365-424f-b2cf-9e5633886631',
    'rg-avd-poc01',
    'rg-avd-poc01-aib-stage',
    'vdpool-avd-poc01',
    'AVD0000001',
    'DELETE POC01'
)
foreach ($literal in $requiredTeardownLiterals) {
    if ($decommission -notmatch [regex]::Escape($literal)) { throw "Fixed teardown literal is missing: $literal" }
}
foreach ($removedScopeParameter in @('PocId', 'SubscriptionId', 'TenantId', 'ResourceGroupName', 'HostPoolName', 'HostPoolResourceGroupName')) {
    $pattern = '(?m)^\s*\[[^\r\n]*\]\s*\$' + [regex]::Escape($removedScopeParameter) + '\b|(?m)^\s*\$' + [regex]::Escape($removedScopeParameter) + '\s*[,=]'
    $paramBlock = $decommission.Substring(0, $decommission.IndexOf('Set-StrictMode'))
    if ($paramBlock -match $pattern) { throw "Destructive scope must not be exposed as parameter '$removedScopeParameter'." }
}
if ($decommission -notmatch [regex]::Escape("`$ResourceGroupNames = @('rg-avd-poc01', 'rg-avd-poc01-aib-stage')") -or
    $decommission -notmatch 'Strict plan requires exactly one session host' -or
    $decommission -notmatch 'Strict plan requires exactly one VM' -or
    $decommission -notmatch [regex]::Escape('$inventory.virtualMachines = ,([ordered]@{') -or
    $decommission -notmatch 'properties\.resourceId' -or
    $decommission -notmatch 'unapproved extra session hosts') {
    throw 'Teardown must enforce exact group, VM, and complete host-pool cardinality/resource matching.'
}
if ($decommission -notmatch "'account', 'get-access-token', '--resource', 'https://graph.microsoft.com'" -or
    $decommission -notmatch 'Invoke-RestMethod' -or
    $decommission -match "(?s)'rest'.{0,180}graph\.microsoft\.com" -or
    $decommission -notmatch 'Where-Object displayName -CEQ \$VmName' -or
    $decommission -notmatch 'Where-Object deviceName -CEQ \$VmName') {
    throw 'Graph must use a CLI-acquired token, direct HTTP, and case-sensitive exact names.'
}
if ($decommission -notmatch 'ApprovedPlanPath is required for Execute' -or
    $decommission -notmatch 'Directory-cleanup selection differs from the approved plan' -or
    $decommission -notmatch "Assert-ApprovedSubset 'Custom-role IDs'" -or
    $decommission -notmatch 'Resource IDs in' -or
    $decommission -notmatch 'Lock IDs in' -or
    $decommission -notmatch 'Locks before deletion' -or
    $decommission -notmatch 'Resource fingerprints before deletion' -or
    $decommission -notmatch 'createdTime = \$_.createdTime') {
    throw 'Execution must bind all immutable scope and recheck reviewed locks against ApprovedPlanPath.'
}
$firstMutationIndex = $decommission.IndexOf("'Set AVD drain mode'")
$drainVerifyIndex = $decommission.IndexOf('Live host did not verify in drain mode after PATCH')
$postDrainInventoryIndex = $decommission.IndexOf('$postDrainSessions = Get-SessionInventory')
$postDrainRefusalIndex = $decommission.IndexOf('Refusing destructive mutation while')
$deallocateIndex = $decommission.IndexOf("'Deallocate exact VM'")
$sessionLogoffIndex = $decommission.IndexOf("'Log off exact reviewed disconnected AVD session'")
$hostDeleteIndex = $decommission.IndexOf("'Remove exact AVD session host'")
$groupConfirmationIndex = $decommission.IndexOf("result = 'ConfirmedAbsent'")
$intuneDeleteIndex = $decommission.IndexOf("'Delete reviewed exact Intune record'")
$entraDeleteIndex = $decommission.IndexOf("'Delete reviewed exact Entra record'")
if ($firstMutationIndex -lt 0 -or $drainVerifyIndex -lt $firstMutationIndex -or
    $postDrainInventoryIndex -lt $drainVerifyIndex -or $postDrainRefusalIndex -lt $postDrainInventoryIndex -or
    $deallocateIndex -lt $postDrainRefusalIndex -or $sessionLogoffIndex -lt $deallocateIndex -or
    $hostDeleteIndex -lt $sessionLogoffIndex -or
    $intuneDeleteIndex -lt $groupConfirmationIndex -or $entraDeleteIndex -lt $intuneDeleteIndex) {
    throw 'Drain verification, session refusal, resource deletion, and directory deletion are not in the required order.'
}
if ($decommission -notmatch [regex]::Escape("Assert-ApprovedSubset 'Disconnected AVD sessions after drain'") -or
    $decommission -notmatch 'LogoffDisconnectedSession') {
    throw 'Execution must reject unplanned sessions and log off only reviewed disconnected sessions.'
}
if ($decommission -notmatch [regex]::Escape('''--body'', "@$bodyPath"') -or
    $decommission -match "'--body',\s*'\{") {
    throw 'Drain PATCH must use an @file JSON body rather than inline JSON.'
}
if ($decommission -match '(?i)conditional\s*access|identity/conditionalAccess|conditionalAccess/policies') {
    throw 'Teardown implementation must never contain Conditional Access operations.'
}
foreach ($recoveryInvariant in @(
    'Assert-ApprovedSubset', 'AlreadyAbsent', 'Recovery',
    '$select=id%2CdisplayName%2CdeviceId', '$select=id%2CdeviceName%2CazureADDeviceId',
    'requires exactly one exact Entra', 'not linked to the approved Entra deviceId',
    'All Graph reads occur during preflight'
)) {
    if ($decommission -notmatch [regex]::Escape($recoveryInvariant)) { throw "Recovery/directory invariant is missing: $recoveryInvariant" }
}
$unsuppressedAdds = @([regex]::Matches($decommission, '(?m)^(?=[^\r\n]*\.Add\()(?![^\r\n]*\[void\])[^\r\n]+$'))
if ($unsuppressedAdds.Count -gt 0) { throw 'List<T>.Add outputs must be suppressed with [void].' }

$pipelinePath = Join-Path $root 'pipelines/azure-pipelines-decommission.yml'
$pipeline = Get-Content -LiteralPath $pipelinePath -Raw
$parameterMatches = [regex]::Matches($pipeline, '(?m)^\s{2}- name:\s*([^\s]+)\s*$')
$parameterNames = @($parameterMatches | ForEach-Object { $_.Groups[1].Value })
$expectedParameterNames = @('removeDirectoryRecords', 'execute', 'confirmationText')
if ((Compare-Object ($parameterNames | Sort-Object) ($expectedParameterNames | Sort-Object))) {
    throw "Decommission pipeline exposes unexpected parameters: $($parameterNames -join ', ')"
}
foreach ($requiredPipelineText in @(
    'azureSubscription: sc-avd-poc-readiness',
    'azureSubscription: sc-avd-poc-decommission',
    'buildType: current',
    'artifactName: avd-poc-decommission-plan',
    'artifact: avd-poc-decommission-execution-$(System.JobAttempt)',
    'environment: avd-poc-decommission',
    'ApprovedPlanPath = $env:APPROVED_PLAN_PATH',
    "`$env:CONFIRMATION_TEXT -cne 'DELETE POC01'"
)) {
    if ($pipeline -notmatch [regex]::Escape($requiredPipelineText)) { throw "Decommission pipeline is missing: $requiredPipelineText" }
}
$pipelineLines = @($pipeline -split "`r?`n")
for ($lineIndex = 0; $lineIndex -lt $pipelineLines.Count; $lineIndex++) {
    if ($pipelineLines[$lineIndex] -notmatch '^(\s*)inlineScript:\s*\|\s*$') { continue }
    $baseIndent = $Matches[1].Length
    $body = [Collections.Generic.List[string]]::new()
    for ($bodyIndex = $lineIndex + 1; $bodyIndex -lt $pipelineLines.Count; $bodyIndex++) {
        $line = $pipelineLines[$bodyIndex]
        if ($line.Trim().Length -gt 0 -and ($line.Length - $line.TrimStart().Length) -le $baseIndent) { break }
        [void]$body.Add($line)
    }
    $source = $body -join [Environment]::NewLine
    if ($source.Contains('${{') -or $source -match '\$\([A-Za-z]') {
        throw 'Template parameters or pipeline macros must not be interpolated into PowerShell source.'
    }
}
if ([regex]::Matches($pipeline, '(?m)^\s+azureSubscription: sc-avd-poc-readiness\s*$').Count -ne 1 -or
    [regex]::Matches($pipeline, '(?m)^\s+azureSubscription: sc-avd-poc-decommission\s*$').Count -ne 1 -or
    $pipeline -match 'planAzureServiceConnection|executeAzureServiceConnection') {
    throw 'Plan and execution service connections must be hardcoded exactly once and not exposed as parameters.'
}

$accessTemplate = Get-Content -LiteralPath (Join-Path $root 'infra/access.bicep') -Raw
foreach ($planningRoleInvariant in @(
    "guid(subscription().id, pocId, 'avd-planning-inventory')",
    'AVD POC Planning Inventory ${pocId}',
    "'*/read'",
    'planningInventoryRoleAssignment',
    'principalId: readinessPrincipalId',
    'planningInventoryRoleDefinitionId'
)) {
    if ($accessTemplate -notmatch [regex]::Escape($planningRoleInvariant)) { throw "Planning-inventory role invariant is missing: $planningRoleInvariant" }
}
$planningRoleStart = $accessTemplate.IndexOf("resource planningInventoryRole '")
$planningAssignmentStart = $accessTemplate.IndexOf("resource planningInventoryRoleAssignment '")
$planningRoleBlock = $accessTemplate.Substring($planningRoleStart, $planningAssignmentStart - $planningRoleStart)
if ($planningRoleBlock -match '(?i)/write|/delete|/action|dataActions:\s*\[\s*''[^'']') {
    throw 'Subscription planning-inventory role must remain read-only and contain no write, delete, action, or data-plane access.'
}
if ($decommission.Contains('AVD POC Planning Inventory')) {
    throw 'Persistent planning-inventory role must not be a teardown target.'
}

$serviceNowConfig = Get-Content -LiteralPath (Join-Path $root 'scripts/Set-ServiceNowAvdCatalogIntegration.ps1') -Raw
foreach ($serviceNowInvariant in @(
    "-Table 'item_option_new'",
    "name = 'requested_for'",
    "question_text = 'Requested for'",
    "reference = 'sys_user'",
    'mandatory = $true',
    "current.variables.requested_for",
    "update.setValue('requested_for', requestedFor.getUniqueValue())"
)) {
    if ($serviceNowConfig -notmatch [regex]::Escape($serviceNowInvariant)) { throw "ServiceNow requested-for invariant is missing: $serviceNowInvariant" }
}

$teardownDoc = Get-Content -LiteralPath (Join-Path $root 'docs/TEARDOWN-REBUILD-VALIDATION.md') -Raw
foreach ($docLiteral in @(
    'Device.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All',
    'aeed229047801200e0ef563dbb9a71c2', 'AVDtest01@keepitsimple.business',
    'Standard_E4bs_v5', 'Standard_D4s_v6', 'ThomasWillmus0350', 'KITSLAB'
)) {
    if ($teardownDoc -notmatch [regex]::Escape($docLiteral)) { throw "Teardown documentation is missing: $docLiteral" }
}
Write-Host 'AVD POC static tests passed.'
