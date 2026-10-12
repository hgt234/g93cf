#requires -Version 5.1
<#
.SYNOPSIS
Offline rollout, pagination, retry, and read-only boundary checks.
.DESCRIPTION
Loads production functions through the PowerShell AST. Mocks authentication
and the HTTP transport only; no Graph calls, tenant credentials, or consent.
Exercises the full script against fixtures and deletes its temporary CSVs.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'phased-rollout-creator.ps1') -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Production script does not parse.' }
$functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }

function Assert-RolloutTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-RolloutFailure {
    param([scriptblock] $Action, [string] $MessagePattern)
    $failed = $false
    try { & $Action | Out-Null }
    catch {
        $failed = $true
        if ($_.Exception.Message -notlike $MessagePattern) { throw "Unexpected failure: $($_.Exception.Message)" }
    }
    Assert-RolloutTest $failed "Expected failure: $MessagePattern"
}

$script:graphRoot = 'https://graph.microsoft.com'
$script:graphBase = "$script:graphRoot/v1.0"
$script:maxGraphAttempts = 5
$script:retryableStatusCodes = @(429, 502, 503, 504, 509)
$script:graphSession = [pscustomobject]@{ Mode = 'Mock'; Account = 'offline' }
$script:graphCallCount = 0
$script:batchSubrequestCount = 0
$appId = '11111111-1111-1111-1111-111111111111'
$reportUri = "$script:graphRoot/beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport"
$readRequest = @{ id = '0'; method = 'GET'; url = '/deviceManagement/managedDevices/test-id?$select=id,azureADDeviceId,deviceName,userPrincipalName,lastSyncDateTime' }

# Prevent a future direct HTTP call from bypassing the guarded transport.
$networkCalls = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -in @('Invoke-MgGraphRequest', 'Invoke-WebRequest', 'Invoke-RestMethod')
}, $true))
Assert-RolloutTest ($networkCalls.Count -eq 3) 'Unexpected network call added to production script'
foreach ($call in $networkCalls) {
    $parent = $call.Parent
    while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
    if ($call.GetCommandName() -eq 'Invoke-RestMethod') {
        Assert-RolloutTest ($parent.Name -eq 'Connect-PilotGraph' -and $call.Extent.Text -match '-Method Get') 'Token acquisition must be GET-only'
    }
    else { Assert-RolloutTest ($parent.Name -eq 'Send-PilotGraphRequest') 'HTTP call bypasses guarded transport' }
}

# Real transport must reject writes before touching an HTTP client.
foreach ($method in @('Post', 'Put', 'Patch', 'Delete')) {
    Assert-RolloutFailure { Send-PilotGraphRequest -Method $method -Uri "$script:graphBase/groups/test/members/`$ref" } '*Read-only Graph boundary rejected*'
}
Assert-RolloutFailure { Invoke-PilotGraph -Method Post -Uri '/deviceManagement/reports/exportJobs' -Body @{ reportName = 'OrgDeviceInstallStatus' } } '*Read-only Graph boundary rejected*'
Assert-RolloutFailure { Invoke-PilotGraph -Method Post -Uri 'https://example.test/$batch' } '*Read-only Graph boundary rejected*'
foreach ($request in @(
    @{ id = '0'; method = 'POST'; url = $readRequest.url },
    @{ id = '0'; method = 'GET'; url = '/groups/test/members' },
    @{ id = '0'; method = 'GET'; url = $readRequest.url; body = @{ unexpected = 'data' } }
)) {
    Assert-RolloutFailure { Invoke-PilotGraph -Method Post -Uri '/$batch' -Body @{ requests = @($request) } } '*Read-only Graph boundary rejected*'
}
foreach ($uri in @(
    "$script:graphRoot/beta/deviceManagement/detectedApps/abc/managedDevices/extra",
    "$script:graphRoot/beta/deviceManagement/managedDevices",
    "$script:graphRoot/beta/groups",
    'https://example.test/beta/deviceManagement/detectedApps'
)) {
    Assert-RolloutFailure { Assert-PilotReadRequest -Method Get -Uri $uri } '*Read-only Graph boundary rejected*'
}
foreach ($uri in @(
    "$script:graphBase/deviceManagement/managedDevices/abc/retire",
    "$script:graphBase/deviceManagement/managedDevices/abc",
    "$script:graphBase/devices/abc",
    "$script:graphBase/devices/abc/registeredOwners",
    "$script:graphRoot/beta/devices"
)) {
    Assert-RolloutFailure { Assert-PilotReadRequest -Method Get -Uri $uri } '*Read-only Graph boundary rejected*'
}
foreach ($uri in @("$script:graphBase/deviceManagement/managedDevices", "$script:graphBase/devices")) {
    Assert-RolloutFailure { Assert-PilotReadRequest -Method Post -Uri $uri } '*Read-only Graph boundary rejected*'
    Assert-RolloutFailure { Assert-PilotReadRequest -Method Get -Uri $uri -Body @{ x = 1 } } '*Read-only Graph boundary rejected*'
    Assert-PilotReadRequest -Method Get -Uri "$uri`?`$select=id&`$top=999&`$skiptoken=abc"
}
Assert-RolloutFailure { Assert-PilotReadRequest -Method Post -Uri "$script:graphRoot/beta/deviceManagement/detectedApps" } '*Read-only Graph boundary rejected*'
Assert-RolloutFailure { Invoke-PilotGraph -Method Post -Uri '/$batch' -Body @{ requests = @(@{ id = '0'; method = 'GET'; url = ($readRequest.url + ',notes') }) } } '*Read-only Graph boundary rejected*'
Assert-PilotReadRequest -Method Post -Uri "$script:graphBase/`$batch" -Body @{ requests = @(@{ id = '0'; method = 'GET'; url = "/devices(deviceId='00000001-0000-0000-0000-000000000000')?`$select=id,deviceId,approximateLastSignInDateTime" }) }
Assert-RolloutFailure { Assert-PilotReadRequest -Method Get -Uri "$script:graphRoot/beta/deviceManagement/detectedApps" -Body @{ x = 1 } } '*Read-only Graph boundary rejected*'
Assert-PilotReadRequest -Method Get -Uri "$script:graphRoot/beta/deviceManagement/detectedApps?`$top=50"
Assert-PilotReadRequest -Method Get -Uri "$script:graphRoot/beta/deviceManagement/detectedApps/abc%3D/managedDevices?`$select=id"
Write-Output 'PASS: real transport rejects mutations, exportJobs, foreign hosts, and unsafe batches before HTTP'

# A shared fixture state keeps assertions outside the production pipeline.
$script:recentSync = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
function Initialize-RolloutFixture {
    param([int] $DeviceCount = 1)
    $script:rolloutTestState = @{
        Rows = @(); Devices = @{}; Calls = (New-Object 'System.Collections.Generic.List[object]')
        Sleeps = (New-Object 'System.Collections.Generic.List[int]'); AuthCount = 0
        PageCap = 500; Fault = ''; StatusQueue = (New-Object 'System.Collections.Generic.Queue[int]')
        BatchStatusQueue = (New-Object 'System.Collections.Generic.Queue[int]')
        LastFilterTerm = ''; DetectedApps = @(); DetectedDevices = @{}; DetectedPageSize = 2; ListPageSize = 7; ListFault = ''
    }
    $script:rolloutTestState.Rows = @(for ($i = $DeviceCount; $i -ge 1; $i--) {
        $id = 'intune-{0:D4}' -f $i
        $guid = '{0:x8}-0000-0000-0000-000000000000' -f $i
        $script:rolloutTestState.Devices[$id] = @{ azureADDeviceId = $guid; deviceName = "org-serial$i"; userPrincipalName = "assigned$i@example.test"; lastSyncDateTime = $script:recentSync }
        ,@($id, "org-serial$i", "report$i@example.test", 1, '2026-01-02T00:00:00Z')
    })
}

function Initialize-MixedFixture {
    Initialize-RolloutFixture 100
    $state = $script:rolloutTestState
    # Two legitimate users on one device, including a non-installed row.
    $state.Rows += ,@('intune-0001', 'same-device', 'other@example.test', 3, '')
    # Separate Intune record for the same Entra identity, earlier timestamp.
    $state.Devices['duplicate'] = $state.Devices['intune-0001']
    $state.Rows += ,@('duplicate', 'same-device', 'another@example.test', 1, '2026-01-01T00:00:00Z')
    $state.Rows += ,@('stale', '', '', 1, '')
    $state.Rows += ,@('no-id', '', '', 1, '')
    $state.Devices['no-id'] = @{ azureADDeviceId = ''; deviceName = 'none' }
    $state.Rows += ,@('missing-entra', '', '', 1, '')
    $state.Devices['missing-entra'] = @{ azureADDeviceId = 'ffffffff-0000-0000-0000-000000000000'; deviceName = 'gone'; userPrincipalName = '' }
    $state.PageCap = 50
}

$authMock = @'
function Connect-PilotGraph {
    param($TenantId, $Scopes, [switch] $DeviceCode)
    $script:rolloutTestState.AuthCount++
    if ($Scopes) {
        if ($Scopes.Count -ne 3 -or @($Scopes | Where-Object { $_ -notlike '*.Read.All' }).Count -gt 0) { throw 'Unexpected write scope' }
    }
    $mode = if ($Scopes) { 'Mock' } else { 'ManagedIdentity' }
    return [pscustomobject]@{ Mode = $mode; Account = 'offline'; Token = 'test-token' }
}
'@
$sendMock = @'
function Start-Sleep {
    param([int] $Seconds)
    $script:rolloutTestState.Sleeps.Add($Seconds)
}
function Send-PilotGraphRequest {
    param($Method, $Uri, $BodyJson)
    $body = if ($BodyJson) { $BodyJson | ConvertFrom-Json } else { $null }
    Assert-PilotReadRequest -Method $Method -Uri $Uri -Body $body
    $state = $script:rolloutTestState
    $state.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $body })
    if ($state.StatusQueue.Count -gt 0) {
        $status = $state.StatusQueue.Dequeue()
        if ($status -ne 200) { return [pscustomobject]@{ StatusCode = $status; RetryAfter = 77; Content = 'test failure' } }
    }
    if ($Uri -match '/reports/') {
        if (($body.orderBy -join ',') -ne 'DeviceId asc,UserPrincipalName asc') { throw 'Unstable report order' }
        $values = @($state.Rows | Select-Object -Skip $body.skip -First ([Math]::Min($body.top, $state.PageCap)))
        if ($state.Fault -eq 'repeat' -and $body.skip -gt 0) { $values = @(,$state.Rows[0]) }
        $content = @{
            Schema = @('DeviceId','DeviceName','UserPrincipalName','InstallState','LastModifiedDateTime' | ForEach-Object { @{ Column = $_ } })
            Values = $values; TotalRowCount = $state.Rows.Count
        }
        if ($state.Fault -eq 'missing-total') { $content.Remove('TotalRowCount') }
        if ($state.Fault -eq 'changing-total' -and $body.skip -gt 0) { $content.TotalRowCount++ }
        if ($state.Fault -eq 'partial') { $content.TotalRowCount++ }
    }
    elseif ($Uri -match '/detectedApps/([^/?]+)/managedDevices') {
        $content = @{ value = @($state.DetectedDevices[[uri]::UnescapeDataString($Matches[1])] | ForEach-Object { @{ id = $_; deviceName = "name-$_" } }) }
    }
    elseif ($Uri -match '/detectedApps\?') {
        $apps = @($state.DetectedApps)
        if ($Uri -match 'filter=([^&]+)') {
            if ($state.Fault -eq 'filter-400') { return [pscustomobject]@{ StatusCode = 400; RetryAfter = 0; Content = 'unsupported filter' } }
            $filter = [uri]::UnescapeDataString($Matches[1])
            if ($filter -notmatch "^contains\(displayName,'(.*)'\)$") { throw "Unexpected filter $filter" }
            $state.LastFilterTerm = $Matches[1].Replace("''", "'")
            if ($state.Fault -eq 'filter-empty') { $apps = @() }
            else { $apps = @($apps | Where-Object { $_.displayName.IndexOf($state.LastFilterTerm, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
        }
        if ($Uri -notmatch '&skip=(\d+)') { $skip = 0 } else { $skip = [int]$Matches[1] }
        $content = @{ value = @($apps | Select-Object -Skip $skip -First $state.DetectedPageSize) }
        if ($skip + $state.DetectedPageSize -lt $apps.Count) {
            $content['@odata.nextLink'] = ($Uri -replace '&skip=\d+', '') + "&skip=$($skip + $state.DetectedPageSize)"
        }
    }
    elseif ($Uri -match '/v1\.0/deviceManagement/managedDevices\?' -or $Uri -match '/v1\.0/devices\?') {
        if ($Uri -match '/managedDevices\?') {
            $items = @($state.Devices.Keys | Sort-Object | ForEach-Object {
                $d = $state.Devices[$_]
                @{ id = $_; azureADDeviceId = $d.azureADDeviceId; deviceName = $d.deviceName; userPrincipalName = $(if ($d.ContainsKey('userPrincipalName')) { $d.userPrincipalName } else { $null }); lastSyncDateTime = $(if ($d.ContainsKey('lastSyncDateTime')) { $d.lastSyncDateTime } else { $null }) }
            })
        }
        else {
            $items = @($state.Devices.Values | ForEach-Object { [string]$_.azureADDeviceId } |
                Where-Object { $_ -and $_ -ne 'ffffffff-0000-0000-0000-000000000000' } | Sort-Object -Unique |
                ForEach-Object { @{ id = ('object-' + $_); deviceId = $_.ToUpperInvariant(); approximateLastSignInDateTime = '2026-01-05T00:00:00Z' } })
            # Unrelated Entra devices and one without a deviceId are ignored.
            $items += @{ id = 'object-unrelated'; deviceId = 'eeeeeeee-0000-0000-0000-000000000000' }
            $items += @{ id = 'object-noid'; deviceId = $null }
        }
        if ($state.ListFault -eq 'duplicate' -and $items.Count -gt 0) { $items += $items[0] }
        if ($Uri -notmatch '&skip=(\d+)') { $skip = 0 } else { $skip = [int]$Matches[1] }
        $content = @{ value = @($items | Select-Object -Skip $skip -First $state.ListPageSize) }
        if ($skip + $state.ListPageSize -lt $items.Count) {
            $content['@odata.nextLink'] = ($Uri -replace '&skip=\d+', '') + "&skip=$($skip + $state.ListPageSize)"
        }
    }
    elseif ($Uri.EndsWith('/$batch')) {
        $status = if ($state.BatchStatusQueue.Count -gt 0) { $state.BatchStatusQueue.Dequeue() } else { 200 }
        $responses = @(foreach ($request in $body.requests) {
            $url = [string]$request.url
            if ($status -ne 200) { @{ id = $request.id; status = $status; headers = @{ 'Retry-After' = '77' }; body = @{} }; continue }
            if ($url -match '/managedDevices/([^?]+)') {
                $key = $Matches[1]
                if ($key -eq 'stale') { @{ id = $request.id; status = 404; body = @{} }; continue }
                @{ id = $request.id; status = 200; body = $state.Devices[$key] }
            }
            elseif ($url -match "deviceId='([^']+)'") {
                $key = $Matches[1]
                if ($key -eq 'ffffffff-0000-0000-0000-000000000000') { @{ id = $request.id; status = 404; body = @{} }; continue }
                @{ id = $request.id; status = 200; body = @{ id = ('object-' + $key); deviceId = $key; approximateLastSignInDateTime = '2026-01-05T00:00:00Z' } }
            }
        })
        if ($state.Fault -eq 'unexpected-batch') { $responses[0].id = 'not-requested' }
        if ($state.Fault -eq 'missing-batch') { $responses = @() }
        $content = @{ responses = $responses }
    }
    else { throw "Unexpected endpoint $Uri" }
    return [pscustomobject]@{ StatusCode = 200; RetryAfter = 0; Content = ($content | ConvertTo-Json -Depth 20 -Compress) }
}
'@
. ([scriptblock]::Create($authMock))
. ([scriptblock]::Create($sendMock))

# Use the full production entry point with only auth and HTTP/sleep mocked.
$replacements = @{ 'Connect-PilotGraph' = $authMock; 'Send-PilotGraphRequest' = $sendMock }
$mockSource = $source
foreach ($fn in @($functions | Where-Object { $replacements.ContainsKey($_.Name) } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    $mockSource = $mockSource.Remove($fn.Extent.StartOffset, $fn.Extent.EndOffset - $fn.Extent.StartOffset).Insert($fn.Extent.StartOffset, $replacements[$fn.Name])
}
$entryPoint = [scriptblock]::Create($mockSource)
$root = Join-Path ([IO.Path]::GetTempPath()) ('phased-rollout-test-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $root -ItemType Directory | Out-Null
$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    foreach ($count in @(0, 1, 2, 7, 10, 100, 501)) {
        $counts = @(Get-RolloutPhaseCount -DeviceCount $count -Percentages 10,30,60)
        Assert-RolloutTest (($counts | Measure-Object -Sum).Sum -eq $count) 'Phase counts do not sum to population'
    }
    Assert-RolloutTest ((@(Get-RolloutPhaseCount -DeviceCount 1 -Percentages 50,50) -join ',') -eq '1,0') 'Remainder ties must favor earlier phases'
    Assert-RolloutTest ((@(Get-RolloutPhaseCount -DeviceCount 100 -Percentages 10,30,60) -join ',') -eq '10,30,60') 'Incorrect 10/30/60 partition'

    foreach ($culture in @('en-US', 'tr-TR')) {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
        Initialize-MixedFixture
        $state = $script:rolloutTestState
        $out = Join-Path $root $culture
        $pipelineOutput = @(& $entryPoint -JoinAppId $appId -ExportDirectory $out 6>$null)
        Assert-RolloutTest ($pipelineOutput.Count -eq 0) 'Diagnostics leaked into success pipeline'
        $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
        Assert-RolloutTest ($rows.Count -eq 100) 'Installed-device aggregation or deduplication failed'
        Assert-RolloutTest ($rows[0].PrimaryUserPrincipalName -eq 'assigned1@example.test') 'UPN must be the managed device primary user'
        Assert-RolloutTest (@($rows | Where-Object { $_.PrimaryUserPrincipalName -like 'report*' -or $_.PrimaryUserPrincipalName -like 'other*' -or $_.PrimaryUserPrincipalName -like 'another*' }).Count -eq 0) 'Signed-in report UPN leaked into export'
        Assert-RolloutTest ($rows[0].StatusLastModified -like '2026-01-01*') 'Earliest timestamp across duplicate Intune records lost'
        [string[]] $expectedOrder = $rows.EntraDeviceId
        [Array]::Sort($expectedOrder, [StringComparer]::Ordinal)
        Assert-RolloutTest (($expectedOrder -join ',') -eq ($rows.EntraDeviceId -join ',')) 'GUID order is not ordinal'
        $ids = @(foreach ($phase in 1..3) {
            $file = Get-ChildItem $out -Filter "Phase$phase-EntraGroupImport*"
            $lines = @(Get-Content $file.FullName)
            Assert-RolloutTest ($lines[0] -eq 'Member object ID or user principal name [memberObjectIdOrUpn] Required') 'Invalid import header'
            $phaseIds = @($lines | Select-Object -Skip 1)
            $detailIds = @($rows | Where-Object { [int]$_.Phase -eq $phase } | ForEach-Object { $_.EntraObjectId })
            Assert-RolloutTest (($phaseIds -join ',') -eq ($detailIds -join ',')) 'Import differs from detail CSV'
            Assert-RolloutTest ($phaseIds.Count -eq @(10,30,60)[$phase-1]) 'Incorrect phase size'
            $phaseIds
        })
        Assert-RolloutTest (@($ids | Select-Object -Unique).Count -eq 100) 'Phase overlap or missing device'
        Assert-RolloutTest (@($state.Calls | Where-Object { $_.Uri -match '/reports/' }).Count -eq 3) 'Server page-cap handling failed'
        Write-Output "PASS: $culture full export, 50-row pages, assigned UPN, duplicate records, skips, disjoint phases"
    }

    foreach ($fault in @('missing-total', 'changing-total', 'partial', 'repeat')) {
        Initialize-RolloutFixture 2
        $script:rolloutTestState.PageCap = 1
        $script:rolloutTestState.Fault = $fault
        $out = Join-Path $root $fault
        Assert-RolloutFailure { & $entryPoint -JoinAppId $appId -ExportDirectory $out 6>$null } '*report*'
        Assert-RolloutTest (-not (Test-Path $out)) 'Unverified report wrote CSVs'
    }
    foreach ($fault in @('unexpected-batch', 'missing-batch')) {
        Initialize-RolloutFixture
        $script:rolloutTestState.Fault = $fault
        Assert-RolloutFailure { Invoke-PilotGraphBatch -Requests @($readRequest) } '*Graph*batch*'
    }
    foreach ($status in @(429, 502, 503, 504, 509)) {
        Initialize-RolloutFixture
        $script:rolloutTestState.StatusQueue.Enqueue($status)
        Get-PilotInstallReport -AppId $appId -Action 'retrieveDeviceAppInstallationStatusReport' | Out-Null
        Assert-RolloutTest ($script:rolloutTestState.Sleeps[0] -eq 77) 'Retry-After was shortened'
        Initialize-RolloutFixture
        $script:rolloutTestState.BatchStatusQueue.Enqueue($status)
        Invoke-PilotGraphBatch -Requests @($readRequest) | Out-Null
        Assert-RolloutTest ($script:rolloutTestState.Sleeps[0] -eq 77) 'Batch Retry-After was shortened'
    }
    $delay = Get-PilotRetryDelay -Attempt 1
    Assert-RolloutTest ($delay -ge 5 -and $delay -le 8) 'Fallback jitter outside expected range'
    Initialize-RolloutFixture
    1..5 | ForEach-Object { $script:rolloutTestState.StatusQueue.Enqueue(503) }
    Assert-RolloutFailure { Get-PilotInstallReport -AppId $appId -Action 'retrieveDeviceAppInstallationStatusReport' } '*HTTP 503*'
    Assert-RolloutTest ($script:rolloutTestState.Calls.Count -eq 5) 'Retries not bounded'

    Initialize-RolloutFixture
    $script:graphSession = [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = 'expired' }
    $script:rolloutTestState.StatusQueue.Enqueue(401)
    Invoke-PilotGraph -Method Post -Uri $reportUri -Body @{ skip = 0; top = 500; orderBy = @('DeviceId asc','UserPrincipalName asc') } | Out-Null
    Assert-RolloutTest ($script:rolloutTestState.AuthCount -eq 1) 'Managed identity not refreshed on 401'
    Initialize-RolloutFixture
    $script:graphSession = [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = 'expired' }
    $script:rolloutTestState.BatchStatusQueue.Enqueue(401)
    Invoke-PilotGraphBatch -Requests @($readRequest) | Out-Null
    Assert-RolloutTest ($script:rolloutTestState.AuthCount -eq 1) 'Batch 401 did not refresh identity'
    Initialize-RolloutFixture
    $script:graphSession = [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = 'expired' }
    1..2 | ForEach-Object { $script:rolloutTestState.StatusQueue.Enqueue(401) }
    Assert-RolloutFailure { Invoke-PilotGraph -Method Post -Uri $reportUri -Body @{} } '*HTTP 401*'
    Assert-RolloutTest ($script:rolloutTestState.AuthCount -eq 1 -and $script:rolloutTestState.Calls.Count -eq 2) '401 refresh must be bounded'
    Initialize-RolloutFixture
    $script:graphSession = [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = 'expired' }
    1..2 | ForEach-Object { $script:rolloutTestState.BatchStatusQueue.Enqueue(401) }
    $failedAuth = Invoke-PilotGraphBatch -Requests @($readRequest)
    Assert-RolloutTest ($failedAuth['0'].Status -eq 401 -and $script:rolloutTestState.AuthCount -eq 1) 'Batch 401 refresh must be bounded'

    # Bulk listing must produce exactly the same export as per-device batches.
    $exports = @{}
    foreach ($mode in @('Batch', 'Bulk')) {
        Initialize-MixedFixture
        $out = Join-Path $root "lookup-$mode"
        & $entryPoint -JoinAppId $appId -ExportDirectory $out -DeviceLookup $mode 6>$null 3>$null
        $exports[$mode] = Get-Content -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName -Raw
        $calls = $script:rolloutTestState.Calls
        $batchCalls = @($calls | Where-Object { $_.Uri.EndsWith('/$batch') }).Count
        $listCalls = @($calls | Where-Object { $_.Uri -match '/v1\.0/(deviceManagement/managedDevices|devices)\?' }).Count
        if ($mode -eq 'Batch') { Assert-RolloutTest ($batchCalls -gt 0 -and $listCalls -eq 0) 'Batch mode used list calls' }
        else { Assert-RolloutTest ($batchCalls -eq 0 -and $listCalls -eq 30) 'Bulk mode should page both lists and skip batches' }
    }
    Assert-RolloutTest ($exports.Batch -ceq $exports.Bulk) 'Bulk and Batch lookups produced different exports'
    Initialize-RolloutFixture 1001
    $script:rolloutTestState.ListPageSize = 1000
    & $entryPoint -JoinAppId $appId -ExportDirectory (Join-Path $root 'auto-bulk') -WhatIf 6>$null | Out-Null
    $calls = $script:rolloutTestState.Calls
    Assert-RolloutTest (@($calls | Where-Object { $_.Uri.EndsWith('/$batch') }).Count -eq 0) 'Auto should pick Bulk above the threshold'
    Assert-RolloutTest (@($calls | Where-Object { $_.Uri -match '/v1\.0/' }).Count -eq 4) 'Bulk lookups should take two pages per list'
    Initialize-MixedFixture
    $script:rolloutTestState.ListFault = 'duplicate'
    Assert-RolloutFailure { & $entryPoint -JoinAppId $appId -DeviceLookup Bulk -WhatIf 6>$null } '*duplicate*'
    Write-Output 'PASS: Bulk lookup matches Batch, Auto threshold, duplicate list rows rejected'

    # Only devices with a recent Intune check-in are phased; the rest are Inactive.
    function Initialize-ActivityFixture {
        Initialize-RolloutFixture 10
        $devices = $script:rolloutTestState.Devices
        foreach ($n in 2, 5, 8) { $devices['intune-{0:D4}' -f $n].lastSyncDateTime = [DateTimeOffset]::UtcNow.AddDays(-200).ToString('o') }
        $devices['intune-0003'].lastSyncDateTime = '0001-01-01T00:00:00Z'
        $devices['intune-0004'].lastSyncDateTime = [DateTimeOffset]::UtcNow.AddDays(-89).ToString('o')
    }
    foreach ($mode in @('Batch', 'Bulk')) {
        Initialize-ActivityFixture
        $out = Join-Path $root "activity-$mode"
        & $entryPoint -JoinAppId $appId -ExportDirectory $out -DeviceLookup $mode 6>$null 3>$null
        $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
        $active = @($rows | Where-Object { $_.ActivityState -eq 'Active' })
        $inactive = @($rows | Where-Object { $_.ActivityState -eq 'Inactive' })
        Assert-RolloutTest ($active.Count -eq 6 -and $inactive.Count -eq 4) "Activity split wrong ($mode)"
        Assert-RolloutTest ((@(1..3 | ForEach-Object { $p = $_; @($active | Where-Object { [int]$_.Phase -eq $p }).Count }) -join ',') -eq '1,2,3') "Active phase split wrong ($mode)"
        Assert-RolloutTest (@($inactive | Where-Object { $_.Phase -ne '0' -or $_.PhaseLabel -ne 'Inactive (no check-in for 90+ days)' }).Count -eq 0) "Inactive rows must not be phased ($mode)"
        Assert-RolloutTest ((@($inactive.IntuneManagedDeviceId | Sort-Object) -join ',') -eq 'intune-0002,intune-0003,intune-0005,intune-0008') "Wrong inactive devices ($mode)"
        Assert-RolloutTest ((@($rows | Where-Object { $_.IntuneManagedDeviceId -eq 'intune-0003' }).LastCheckIn) -eq '') "Never-synced device should have blank LastCheckIn ($mode)"
        Assert-RolloutTest ((@($rows | Where-Object { $_.IntuneManagedDeviceId -eq 'intune-0001' }).EntraApproxLastSignIn) -like '2026-01-05T00:00:00*') "Entra sign-in reference missing ($mode)"
        $inactiveIds = @(Get-Content (Get-ChildItem $out -Filter 'Inactive-EntraGroupImport*').FullName | Select-Object -Skip 1)
        Assert-RolloutTest ((@($inactiveIds | Sort-Object) -join ',') -eq (@($inactive.EntraObjectId | Sort-Object) -join ',')) "Inactive import file mismatch ($mode)"
        $phasedIds = @(Get-ChildItem $out -Filter 'Phase*-EntraGroupImport*' | ForEach-Object { Get-Content $_.FullName | Select-Object -Skip 1 })
        Assert-RolloutTest ($phasedIds.Count -eq 6 -and @($phasedIds | Where-Object { $inactiveIds -contains $_ }).Count -eq 0) "Inactive device leaked into a phase ($mode)"
    }
    Initialize-ActivityFixture
    $out = Join-Path $root 'activity-off'
    & $entryPoint -JoinAppId $appId -ExportDirectory $out -ActiveWithinDays 0 6>$null
    $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
    Assert-RolloutTest (@($rows | Where-Object { [int]$_.Phase -ge 1 }).Count -eq 10) 'ActiveWithinDays 0 should phase every device'
    Initialize-ActivityFixture
    $state = $script:rolloutTestState
    # A stale and a recent Intune record for one Entra device: the recent one wins.
    $state.Devices['dup-recent'] = @{ azureADDeviceId = $state.Devices['intune-0002'].azureADDeviceId; deviceName = 'org-serial2'; userPrincipalName = 'assigned2@example.test'; lastSyncDateTime = $script:recentSync }
    $state.Rows += ,@('dup-recent', 'org-serial2', 'x@example.test', 1, '')
    $out = Join-Path $root 'activity-dup'
    & $entryPoint -JoinAppId $appId -ExportDirectory $out 6>$null 3>$null
    $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
    Assert-RolloutTest ((@($rows | Where-Object { $_.DeviceName -eq 'org-serial2' }).ActivityState) -eq 'Active') 'Most recent check-in across Intune records must win'
    foreach ($case in @(
        @{ Value = '2026-01-02T03:04:05Z'; Expected = '2026-01-02T03:04:05.0000000+00:00' },
        @{ Value = [DateTime]::SpecifyKind([DateTime]'2026-01-02T03:04:05', [DateTimeKind]::Utc); Expected = '2026-01-02T03:04:05.0000000+00:00' },
        @{ Value = '0001-01-01T00:00:00Z'; Expected = '' }, @{ Value = $null; Expected = '' }, @{ Value = 'garbage'; Expected = '' }
    )) {
        Assert-RolloutTest ((Format-PilotTimestamp (ConvertTo-PilotTimestamp $case.Value)) -eq $case.Expected) "Timestamp parse failed for '$($case.Value)'"
    }
    Write-Output 'PASS: active/inactive split by Intune check-in, inactive import file, newest check-in wins, filter off'

    # Version parsing for inventory strings.
    $versionCases = @{ '23.01' = '23.1'; '9.20' = '9.20'; '12' = '12.0'; '19.00.00.0' = '19.0.0.0'; '1.2.3-beta' = '1.2.3'; ' 4.5 ' = '4.5' }
    foreach ($case in $versionCases.GetEnumerator()) {
        Assert-RolloutTest ((ConvertTo-PilotVersion $case.Key) -eq [version]$case.Value) "Version parse failed for '$($case.Key)'"
    }
    foreach ($bad in @('', 'weird', 'v2', $null)) { Assert-RolloutTest ($null -eq (ConvertTo-PilotVersion $bad)) "Unparseable version accepted: '$bad'" }
    Write-Output 'PASS: inventory version parsing'

    # Discovered-app search: wildcard, exclusive MaxVersion, platform, unparseable versions, lowest version wins.
    function Initialize-DetectedFixture {
        Initialize-RolloutFixture 6
        $state = $script:rolloutTestState
        $state.DetectedApps = @(
            @{ id = 'zip920'; displayName = '7-Zip 9.20'; version = '9.20'; platform = 'windows'; deviceCount = 2 },
            @{ id = 'zip1900'; displayName = '7-Zip 19.00 (x64)'; version = '19.00'; platform = 'windows'; deviceCount = 3 },
            @{ id = 'zip2301'; displayName = '7-Zip 23.01 (x64)'; version = '23.01'; platform = 'windows'; deviceCount = 1 },
            @{ id = 'zipmac'; displayName = '7-Zip'; version = '9.0'; platform = 'macOS'; deviceCount = 1 },
            @{ id = 'zipbeta'; displayName = '7-Zip Beta'; version = 'weird'; platform = 'windows'; deviceCount = 1 },
            @{ id = 'npp'; displayName = 'Notepad++'; version = '8.1'; platform = 'windows'; deviceCount = 1 }
        )
        $state.DetectedDevices = @{
            zip920 = @('intune-0001', 'intune-0002'); zip1900 = @('intune-0002', 'intune-0003', 'intune-0004')
            zip2301 = @('intune-0005'); zipmac = @('intune-0006'); zipbeta = @('intune-0006'); npp = @('intune-0006')
        }
    }
    Initialize-DetectedFixture
    $out = Join-Path $root 'detected-under12'
    $warnings = @(& $entryPoint -AppName '7-zip*' -MaxVersion 12 -ExportDirectory $out 6>$null 3>&1)
    $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
    Assert-RolloutTest ((@($rows.IntuneManagedDeviceId | Sort-Object) -join ',') -eq 'intune-0001,intune-0002') 'MaxVersion 12 should match only 9.20 devices'
    Assert-RolloutTest (@($rows | Where-Object { $_.AppVersion -ne '9.20' -or $_.InstallState -ne 'detected' }).Count -eq 0) 'Detected app version/state missing'
    Assert-RolloutTest (@($warnings | Where-Object { "$_" -like '*unparseable*7-Zip Beta*' }).Count -eq 1) 'Unparseable version must warn'
    Assert-RolloutTest (@($script:rolloutTestState.Calls | Where-Object { $_.Uri -match 'detectedApps\?' }).Count -eq 3) 'Detected app paging not followed'
    Assert-RolloutTest (@($script:rolloutTestState.Calls | Where-Object { $_.Uri -match 'detectedApps\?' -and $_.Uri -notmatch 'filter=' }).Count -eq 0) 'Filtered search should not scan the full inventory'
    Assert-RolloutTest ($script:rolloutTestState.LastFilterTerm -eq '7-zip') 'Server filter term not derived from pattern'
    Assert-RolloutTest (@($script:rolloutTestState.Calls | Where-Object { $_.Uri -match '/managedDevices\?' }).Count -eq 1) 'Device list should be read only for matched apps'

    Initialize-DetectedFixture
    $out = Join-Path $root 'detected-under20'
    & $entryPoint -AppName '7-Zip*' -MaxVersion 20 -ExportDirectory $out 6>$null 3>$null
    $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
    Assert-RolloutTest ($rows.Count -eq 4) 'Union of matching versions should be distinct devices'
    Assert-RolloutTest ((@($rows | Where-Object { $_.IntuneManagedDeviceId -eq 'intune-0002' }).AppVersion) -eq '9.20') 'Device with two versions must report the lowest'
    Assert-RolloutTest (@($rows | Where-Object { $_.IntuneManagedDeviceId -eq 'intune-0006' }).Count -eq 0) 'macOS/unparseable/other apps must not match'

    Initialize-DetectedFixture
    $out = Join-Path $root 'detected-nobound'
    & $entryPoint -AppName '7-Zip*' -ExportDirectory $out 6>$null 3>$null
    $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
    Assert-RolloutTest ($rows.Count -eq 6) 'Without version bounds every Windows 7-Zip record should match'
    Assert-RolloutTest ((@($rows | Where-Object { $_.IntuneManagedDeviceId -eq 'intune-0006' }).AppName) -eq '7-Zip Beta') 'Unparseable record should match when no bound is set'

    foreach ($fault in @('filter-400', 'filter-empty')) {
        Initialize-DetectedFixture
        $script:rolloutTestState.Fault = $fault
        $out = Join-Path $root "detected-$fault"
        $warnings = @(& $entryPoint -AppName '7-Zip*' -MaxVersion 12 -ExportDirectory $out 6>$null 3>&1)
        $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
        Assert-RolloutTest ($rows.Count -eq 2) "Fallback after $fault lost matches"
        Assert-RolloutTest (@($warnings | Where-Object { "$_" -like '*scanning the full*' }).Count -eq 1) "Fallback after $fault must warn"
    }
    Initialize-DetectedFixture
    & $entryPoint -AppName '*' -WhatIf 6>$null 3>$null | Out-Null
    Assert-RolloutTest (@($script:rolloutTestState.Calls | Where-Object { $_.Uri -match 'filter=' }).Count -eq 0) 'Pattern without a literal should skip the server filter'
    $searchCases = @{ '7-Zip*' = '7-Zip'; '*Notepad++*' = 'Notepad++'; '*O''Brien*Tool?' = 'O''Brien'; '*' = ''; 'a*' = ''; '[7]-Zip*' = '-Zip' }
    foreach ($case in $searchCases.GetEnumerator()) {
        Assert-RolloutTest ((Get-PilotSearchTerm -Pattern $case.Key) -ceq $case.Value) "Search term for '$($case.Key)'"
    }
    Initialize-DetectedFixture
    $script:rolloutTestState.DetectedApps += @{ id = 'obrien'; displayName = "O'Brien Tool"; version = '1.0'; platform = 'windows'; deviceCount = 1 }
    $script:rolloutTestState.DetectedDevices['obrien'] = @('intune-0006')
    & $entryPoint -AppName "O'Brien*" -WhatIf 6>$null | Out-Null
    Assert-RolloutTest ($script:rolloutTestState.LastFilterTerm -ceq "O'Brien") 'Quote in filter term not escaped'

    Initialize-DetectedFixture
    Assert-RolloutFailure { & $entryPoint -AppName 'Nothing*' -ExportDirectory (Join-Path $root 'no-match') 6>$null 3>$null } '*No discovered*'
    Assert-RolloutFailure { & $entryPoint -AppName '7-Zip*' -MinVersion 12 -MaxVersion 12 6>$null } '*MinVersion must be lower*'
    Assert-RolloutFailure { & $entryPoint -AppName '7-Zip*' -JoinAppId $appId 6>$null } '*parameter set*'
    Write-Output 'PASS: discovered-app wildcard, version range, platform, paging, lowest version per device'

    # -MaxDevices samples the first N sorted Intune ids and labels the files.
    Initialize-RolloutFixture 100
    $out = Join-Path $root 'sample'
    & $entryPoint -JoinAppId $appId -ExportDirectory $out -MaxDevices 10 6>$null
    $detail = Get-ChildItem $out -Filter 'PhasedRolloutDetail-sample10-*'
    $rows = @(Import-Csv -LiteralPath $detail.FullName)
    Assert-RolloutTest ($rows.Count -eq 10) 'MaxDevices should resolve exactly N devices'
    Assert-RolloutTest ((@($rows.IntuneManagedDeviceId | Sort-Object) -join ',') -eq ((1..10 | ForEach-Object { 'intune-{0:D4}' -f $_ }) -join ',')) 'Sample must be the first N sorted Intune ids'
    Assert-RolloutTest ((@(1..3 | ForEach-Object { $p = $_; @($rows | Where-Object { [int]$_.Phase -eq $p }).Count }) -join ',') -eq '1,3,6') 'Sample phase split'
    Assert-RolloutTest (@(Get-ChildItem $out -Filter 'Phase*-EntraGroupImport-sample10-*').Count -eq 3) 'Sample import files must be labelled'
    Assert-RolloutTest (@($script:rolloutTestState.Calls | Where-Object { $_.Uri.EndsWith('/$batch') }).Count -eq 2) 'Sample should only look up N devices'
    Initialize-RolloutFixture 5
    $script:rolloutTestState.Devices['intune-0001'] = @{ azureADDeviceId = ''; deviceName = 'none' }
    $warnings = @(& $entryPoint -JoinAppId $appId -ExportDirectory (Join-Path $root 'sample-skip') -MaxDevices 3 6>$null 3>&1)
    Assert-RolloutTest (@($warnings | Where-Object { "$_" -like '*resolved 2 of 3*' }).Count -eq 1) 'Shrunken sample must warn'
    Write-Output 'PASS: MaxDevices deterministic sample, labelled exports, bounded lookups'

    # Only the current primary user is exported, once per device.
    Initialize-RolloutFixture 2
    $state = $script:rolloutTestState
    $state.Rows += ,@('intune-0001', 'org-serial1', 'joe@example.test', 1, '2026-01-03T00:00:00Z')
    $state.Rows += ,@('intune-0001', 'org-serial1', 'bob@example.test', 1, '2026-01-04T00:00:00Z')
    $state.Devices['intune-0001'].userPrincipalName = 'carol@example.test'
    $state.Devices['intune-0002'].userPrincipalName = ''
    $out = Join-Path $root 'primary'
    $warnings = @(& $entryPoint -JoinAppId $appId -ExportDirectory $out 6>$null 3>&1)
    $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
    $device1 = @($rows | Where-Object { $_.IntuneManagedDeviceId -eq 'intune-0001' })
    Assert-RolloutTest ($device1.Count -eq 1 -and $device1[0].PrimaryUserPrincipalName -eq 'carol@example.test') 'Device must appear once with its primary user'
    Assert-RolloutTest ((@($rows | Where-Object { $_.IntuneManagedDeviceId -eq 'intune-0002' }).PrimaryUserPrincipalName) -eq '') 'No primary user should export blank'
    Assert-RolloutTest (@($warnings | Where-Object { "$_" -like '*no Intune primary user*' }).Count -eq 1) 'Blank primary user must warn'
    Initialize-RolloutFixture 2
    $script:rolloutTestState.Devices['intune-0002'].userPrincipalName = ''
    $out = Join-Path $root 'require-primary'
    & $entryPoint -JoinAppId $appId -ExportDirectory $out -RequirePrimaryUser 6>$null
    $rows = @(Import-Csv -LiteralPath (Get-ChildItem $out -Filter 'PhasedRolloutDetail*').FullName)
    Assert-RolloutTest ((@($rows.IntuneManagedDeviceId) -join ',') -eq 'intune-0001') 'RequirePrimaryUser must skip devices without one'
    Write-Output 'PASS: primary user only, one row per device, RequirePrimaryUser'

    Initialize-RolloutFixture
    $out = Join-Path $root 'whatif'
    & $entryPoint -JoinAppId $appId -ExportDirectory $out -WhatIf 6>$null
    Assert-RolloutTest (-not (Test-Path $out)) 'WhatIf wrote exports'
    Assert-RolloutTest ($script:rolloutTestState.Calls.Count -gt 0) 'WhatIf should still gather read-only data'
    Initialize-RolloutFixture
    $script:rolloutTestState.Rows = @(,@('noinstall','','',3,''))
    $out = Join-Path $root 'headers'
    & $entryPoint -JoinAppId $appId -ExportDirectory $out 6>$null 3>$null
    Assert-RolloutTest (@(Get-ChildItem $out -File).Count -eq 5) 'Expected detail CSV, three phase CSVs, and the inactive CSV'
    foreach ($file in @(Get-ChildItem $out -File)) { Assert-RolloutTest (@(Get-Content $file.FullName).Count -eq 1) 'Empty CSV should contain only header' }
    Initialize-RolloutFixture 0
    Assert-RolloutFailure { & $entryPoint -JoinAppId $appId -ExportDirectory (Join-Path $root 'empty-report') 6>$null } '*no rows*'
    Assert-RolloutFailure { & $entryPoint -JoinAppId $appId -PhasePercentages 10,30,50 } '*totaling 100*'
    Assert-RolloutFailure { & $entryPoint -JoinAppId $appId -PhasePercentages @() } '*PhasePercentages*'
    Write-Output 'PASS: report completeness, repeated rows, batch integrity, bounded retries, token refresh, WhatIf, empty exports'
}
finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    Remove-Item -LiteralPath $root -Recurse -Force
}
