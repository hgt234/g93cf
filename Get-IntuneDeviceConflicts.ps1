#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
Read-only Intune configuration conflict investigation for one Windows device.
.DESCRIPTION
Requests only DeviceManagementManagedDevices.Read.All and
DeviceManagementConfiguration.Read.All. GET reads device/configuration states;
POST is restricted to three report retrieval actions. No sync, remediation,
policy/assignment changes, export jobs, module installation, or report files.

Returns Device, Policies, PolicyObservations, PolicyConflicts, Settings,
Conflicts, UnclassifiedSettings, Issues, and HasInvestigationGaps.
Policy conflict rollups are never stamped onto individual settings.
Legacy and modern observations may overlap; counts are not unique settings.

Use a dedicated PowerShell session: Connect-MgGraph changes its authentication
context. Authentication can create normal sign-in/audit records. This script
is read-only with respect to Intune configuration and the managed device.

Modern reports use beta APIs. Numeric status codes are preserved, not guessed.
An empty conflict list is not proof that the device is conflict-free. Results
depend on RBAC/scope tags and the last reported device state, not live state.
Contributing policies/current values are returned only when the API supplies
them; matching setting names alone do not prove a conflicting policy pair.

Review validation: statically reviewed; not executed against a tenant.
.PARAMETER ManagedDeviceId
Intune managed device ID, NOT the Entra device ID.
.PARAMETER TenantId
Tenant GUID or verified tenant domain. Microsoft public cloud only.
.EXAMPLE
$r = .\Get-IntuneDeviceConflicts.ps1 -TenantId contoso.onmicrosoft.com -DeviceName PC-123
$r.Conflicts | Format-List *
$r.PolicyConflicts | Format-List *
$r.Issues | Format-Table -Wrap
.EXAMPLE
$r = .\Get-IntuneDeviceConflicts.ps1 -TenantId contoso.onmicrosoft.com -ManagedDeviceId '11111111-2222-3333-4444-555555555555'
$r.Settings | Where-Object SettingId -eq 'SETTING-ID' | Format-List *
.LINK
https://learn.microsoft.com/en-us/graph/api/resources/intune-deviceconfig-deviceconfigurationsettingstate?view=graph-rest-1.0
.LINK
https://techcommunity.microsoft.com/blog/intunecustomersuccess/announcing-updated-policy-reporting-experience-in-microsoft-endpoint-manager/3261347/
#>

[CmdletBinding(DefaultParameterSetName = 'Name')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [Parameter(Mandatory, ParameterSetName = 'Name')]
    [ValidateNotNullOrEmpty()]
    [string] $DeviceName,

    [Parameter(Mandatory, ParameterSetName = 'Id')]
    [guid] $ManagedDeviceId
)

$ErrorActionPreference = 'Stop'
$graph = 'https://graph.microsoft.com'
$issues = [System.Collections.Generic.List[object]]::new()
$settings = [System.Collections.Generic.List[object]]::new()
$policyObservations = [System.Collections.Generic.List[object]]::new()
$reportActions = @(
    'getConfigurationPoliciesReportForDevice'
    'getConfigurationSettingsReport'
    'getConfigurationSettingNonComplianceReport'
)

function Add-Issue {
    param([string] $Area, [string] $Message)
    $issues.Add([pscustomobject]@{ Area = $Area; Message = $Message })
    Write-Warning "${Area}: $Message"
}

function Get-Field {
    param($Row, [string[]] $Names)
    foreach ($name in $Names) {
        $value = $Row[$name]
        if ($null -ne $value -and [string]$value -ne '') { return $value }
    }
    return $null
}

function Quote-FilterValue {
    param([AllowEmptyString()][string] $Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-ReadRequest {
    param(
        [ValidateSet('GET', 'POST')][string] $Method,
        [string] $Uri,
        [hashtable] $Body
    )
    $address = [uri]$Uri
    if ($address.Scheme -ne 'https' -or
        $address.Host -ne 'graph.microsoft.com' -or
        -not $address.IsDefaultPort -or $address.UserInfo -or $address.Fragment) {
        throw "Blocked unexpected Graph address: $Uri"
    }
    if ($Method -eq 'GET') {
        if ($address.AbsolutePath -notmatch
            '^/v1\.0/deviceManagement/managedDevices(?:/[^/]+(?:/deviceConfigurationStates(?:/[^/]+)?)?)?$') {
            throw "GET path is outside the read allowlist: $Uri"
        }
    }
    else {
        $allowed = @($reportActions | ForEach-Object {
            "/beta/deviceManagement/reports/$_"
        })
        if ($address.AbsolutePath -notin $allowed -or $address.Query) {
            throw "POST is permitted only for allowlisted reports: $Uri"
        }
    }
    $request = @{
        Method = $Method
        Uri = $Uri
        OutputType = 'Json'
        Headers = @{ 'Accept-Language' = 'en-US' }
        ErrorAction = 'Stop'
    }
    if ($Method -eq 'POST') {
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 10
        $request.ContentType = 'application/json'
    }
    $json = Invoke-MgGraphRequest @request
    return ($json | ConvertFrom-Json -AsHashtable)
}

function Get-Collection {
    param([string] $Uri)
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    while ($Uri) {
        if (-not $visited.Add($Uri)) { throw 'Repeated nextLink; retrieval incomplete.' }
        $page = Invoke-ReadRequest -Method GET -Uri $Uri
        if (-not $page.ContainsKey('value')) { throw 'Collection response missing value.' }
        foreach ($item in $page.value) { $item }
        $Uri = $page['@odata.nextLink']
    }
}

function Get-Report {
    param([string] $Action, [string] $Filter)
    $skip = 0
    $pageSize = 100
    $previousPage = $null
    while ($true) {
        $page = Invoke-ReadRequest -Method POST `
            -Uri "$graph/beta/deviceManagement/reports/$Action" `
            -Body @{ select = @(); filter = $Filter; skip = $skip; top = $pageSize; orderBy = @() }
        if (-not $page.ContainsKey('Schema') -or -not $page.ContainsKey('Values')) {
            throw "Unexpected response schema from $Action."
        }
        $rows = @($page.Values)
        if ($null -eq $page.Values) { $rows = @() }
        $hasTotal = $page.ContainsKey('TotalRowCount') -and $null -ne $page.TotalRowCount
        if ($rows.Count -eq 0) {
            if ($hasTotal -and $skip -lt [long]$page.TotalRowCount) {
                throw "$Action returned an empty page before the reported total."
            }
            break
        }
        $signature = ConvertTo-Json -InputObject $rows -Depth 30 -Compress
        if ($signature -eq $previousPage) { throw "$Action repeated a page; retrieval incomplete." }
        $previousPage = $signature
        foreach ($row in $rows) {
            if ($row.Count -ne $page.Schema.Count) { throw "Column count mismatch in $Action." }
            $record = @{}
            for ($i = 0; $i -lt $page.Schema.Count; $i++) {
                $column = [string]$page.Schema[$i].Column
                if (-not $column -or $record.ContainsKey($column)) {
                    throw "Missing or duplicate column name in $Action."
                }
                $record[$column] = $row[$i]
            }
            $record
        }
        $skip += $rows.Count
        if ($hasTotal) {
            if ($skip -ge [long]$page.TotalRowCount) { break }
        }
        elseif ($rows.Count -lt $pageSize) { break }
        if ($skip -ge 100000) { throw "$Action exceeded the paging safety limit." }
    }
}

function Get-StateClassification {
    param([AllowEmptyString()][string] $State)
    switch -Regex ($State.Trim()) {
        '^conflict$' { return 'Conflict' }
        '^(success|succeeded|compliant|remediated|error|not.?applicable|not.?assigned|non.?compliant|pending|unknown)$' {
            return 'Other'
        }
        default { return 'Unclassified' }
    }
}

Import-Module Microsoft.Graph.Authentication
Connect-MgGraph -TenantId $TenantId -Environment Global `
    -Scopes @('DeviceManagementManagedDevices.Read.All', 'DeviceManagementConfiguration.Read.All') `
    -ContextScope Process -NoWelcome | Out-Null

$select = 'id,deviceName,operatingSystem,osVersion,userPrincipalName,lastSyncDateTime,azureADDeviceId,serialNumber'
if ($PSCmdlet.ParameterSetName -eq 'Id') {
    $device = Invoke-ReadRequest -Method GET -Uri (
        "$graph/v1.0/deviceManagement/managedDevices/${ManagedDeviceId}?`$select=$select"
    )
}
else {
    $filter = [uri]::EscapeDataString("deviceName eq $(Quote-FilterValue $DeviceName)")
    $matches = @(Get-Collection "$graph/v1.0/deviceManagement/managedDevices?`$filter=$filter&`$select=$select")
    if ($matches.Count -eq 0) { throw "No accessible device found with exact name '$DeviceName'." }
    if ($matches.Count -gt 1) {
        $matches | ForEach-Object { [pscustomobject]$_ } |
            Format-Table deviceName, id, serialNumber, lastSyncDateTime | Out-Host
        throw 'Multiple matching devices. Run again with -ManagedDeviceId.'
    }
    $device = $matches[0]
}
if ($device.operatingSystem -notlike 'Windows*') {
    throw "Selected device runs '$($device.operatingSystem)', not Windows."
}
if (-not $device.id) { throw 'Device lookup returned no Intune managed device ID.' }
$id = [string]$device.id
Write-Host "`nDevice: $($device.deviceName) [$id]"
Write-Host "Last Intune sync: $($device.lastSyncDateTime)"
Write-Host 'Reading policy and setting reports...'

$policies = @()
try {
    $policies = @(Get-Report -Action getConfigurationPoliciesReportForDevice `
        -Filter "(IntuneDeviceId eq $(Quote-FilterValue $id))")
    if ($policies.Count -eq 0) { Add-Issue 'Policy report' 'No policy rows returned; coverage is unverified.' }
}
catch { Add-Issue 'Policy report' $_.Exception.Message }

foreach ($policy in $policies) {
    $policyId = [string]$policy.PolicyId
    $policyName = [string]$policy.PolicyName
    $userId = [string]$policy.UserId
    $type = [string]$policy.PolicyBaseTypeName
    $area = "$policyName [$policyId], user '$userId'"
    $policyStatus = [string](Get-Field $policy @('PolicyStatus_loc', 'PolicyStatus'))
    $observation = [pscustomobject]@{
        Source = 'getConfigurationPoliciesReportForDevice'
        PolicyName = $policyName; PolicyId = $policyId; StateRecordId = $null
        UserId = $userId; UPN = $policy.UPN; State = $policyStatus
        Classification = Get-StateClassification $policyStatus
        SettingRows = 0; ConflictSettingRows = 0; Raw = $policy
    }
    $policyObservations.Add($observation)
    if ($observation.Classification -eq 'Unclassified') {
        Add-Issue $area "Unrecognized policy status '$policyStatus'; inspect the raw policy record."
    }
    if (-not $policyId -or -not $policy.ContainsKey('UserId') -or $null -eq $policy.UserId) {
        Add-Issue $area 'Policy ID or user context is missing; setting lookup skipped.'
        continue
    }
    # Preserve the exact reported user context, including empty strings and system GUIDs.
    $filter = "(PolicyId eq $(Quote-FilterValue $policyId)) and " +
              "(DeviceId eq $(Quote-FilterValue $id)) and " +
              "(UserId eq $(Quote-FilterValue $userId))"
    $action = switch -Regex ($type) {
        '(^|\.)(DeviceManagementConfigurationPolicy|DeviceManagementIntent)$' {
            'getConfigurationSettingsReport'; break
        }
        '(^|\.)(DeviceConfiguration|DeviceConfigurationAdmxPolicy)$' {
            'getConfigurationSettingNonComplianceReport'; break
        }
        default { $null }
    }
    if (-not $action) {
        Add-Issue $area "Unsupported policy type '$type'; setting lookup skipped."
        continue
    }
    try {
        $rows = @(Get-Report -Action $action -Filter $filter)
        $observation.SettingRows = $rows.Count
        if ($rows.Count -eq 0) { Add-Issue $area 'No setting rows returned; coverage is unverified.' }
        foreach ($row in $rows) {
            $state = [string](Get-Field $row @(
                'SettingStatus_loc', 'SettingState_loc', 'State_loc',
                'SettingStatus', 'SettingState', 'State', 'Status'
            ))
            $classification = Get-StateClassification $state
            if ($classification -eq 'Conflict') { $observation.ConflictSettingRows++ }
            $settings.Add([pscustomobject]@{
                Source = $action; PolicyName = $policyName; PolicyId = $policyId
                StateRecordId = $null; PolicyStatus = $policyStatus
                SettingName = Get-Field $row @('SettingName_loc', 'SettingName', 'Name')
                SettingId = Get-Field $row @('SettingId', 'SettingDefinitionId', 'Setting')
                Instance = Get-Field $row @('InstanceDisplayName', 'SettingInstanceId')
                State = $state; Classification = $classification
                UserId = $userId; UPN = $policy.UPN
                CurrentValue = Get-Field $row @('CurrentValue')
                ErrorCode = Get-Field $row @('ErrorCode')
                ErrorDescription = Get-Field $row @('ErrorDescription', 'ErrorMessage')
                ReportedContributors = $null; Raw = $row
            })
        }
        if ($observation.Classification -eq 'Conflict' -and $observation.ConflictSettingRows -eq 0) {
            Add-Issue $area 'Policy reports Conflict, but no explicit conflicted setting was resolved.'
        }
    }
    catch { Add-Issue $area $_.Exception.Message }
}

# Legacy states may provide explicit contributing policies and current values.
try {
    $states = @(Get-Collection "$graph/v1.0/deviceManagement/managedDevices/$id/deviceConfigurationStates")
    foreach ($stateRecord in $states) {
        try {
            $key = [uri]::EscapeDataString([string]$stateRecord.id)
            $detail = Invoke-ReadRequest -Method GET -Uri (
                "$graph/v1.0/deviceManagement/managedDevices/$id/deviceConfigurationStates/$key"
            )
            $legacySettings = @($detail.settingStates | Where-Object { $null -ne $_ })
            $legacyConflicts = @($legacySettings | Where-Object { $_.state -eq 'conflict' })
            $policyObservations.Add([pscustomobject]@{
                Source = 'Legacy deviceConfigurationStates'
                PolicyName = $detail.displayName; PolicyId = $null; StateRecordId = $detail.id
                UserId = $null; UPN = $null; State = $detail.state
                Classification = Get-StateClassification ([string]$detail.state)
                SettingRows = $legacySettings.Count; ConflictSettingRows = $legacyConflicts.Count
                Raw = $detail
            })
            if ($legacySettings.Count -eq 0 -and [int]$detail.settingCount -gt 0) {
                Add-Issue ([string]$detail.displayName) 'Legacy state reports settings but returns no details.'
            }
            if ($detail.state -eq 'conflict' -and $legacyConflicts.Count -eq 0) {
                Add-Issue ([string]$detail.displayName) 'Legacy policy reports Conflict without a resolved conflicted setting.'
            }
            foreach ($setting in $legacySettings) {
                $contributors = @(
                    foreach ($source in $setting.sources) {
                        if ($null -ne $source) {
                            "$($source.displayName) [$($source.id)] ($($source.sourceType))"
                        }
                    }
                ) -join '; '
                $settings.Add([pscustomobject]@{
                    Source = 'Legacy deviceConfigurationStates'; PolicyName = $detail.displayName
                    # State-record identifiers are not assumed to be policy GUIDs.
                    PolicyId = $null; StateRecordId = $detail.id; PolicyStatus = $detail.state
                    SettingName = $setting.settingName; SettingId = $setting.setting
                    Instance = $setting.instanceDisplayName; State = $setting.state
                    Classification = Get-StateClassification ([string]$setting.state)
                    UserId = $setting.userId; UPN = $setting.userPrincipalName
                    CurrentValue = $setting.currentValue; ErrorCode = $setting.errorCode
                    ErrorDescription = $setting.errorDescription
                    ReportedContributors = $contributors; Raw = $setting
                })
            }
        }
        catch { Add-Issue "Legacy state $($stateRecord.id)" $_.Exception.Message }
    }
}
catch { Add-Issue 'Legacy configuration states' $_.Exception.Message }

$conflicts = @($settings | Where-Object Classification -eq 'Conflict')
$policyConflicts = @($policyObservations | Where-Object Classification -eq 'Conflict')
$unclassified = @($settings | Where-Object Classification -eq 'Unclassified')
if ($unclassified.Count -gt 0) {
    Add-Issue 'Status interpretation' (
        "$($unclassified.Count) setting rows have unrecognized status labels. " +
        'Inspect UnclassifiedSettings and Raw; numeric codes were not guessed.'
    )
}
Write-Host "`nPolicy/user report records: $($policies.Count)"
Write-Host "Policy conflict observations: $($policyConflicts.Count)"
Write-Host "Setting observations: $($settings.Count)"
Write-Host "Explicit conflict setting observations: $($conflicts.Count)"
Write-Host "Retrieval/interpretation issues: $($issues.Count)"
if ($policyConflicts.Count -gt 0) {
    $policyConflicts | Format-Table PolicyName, PolicyId, State, SettingRows, ConflictSettingRows -Wrap | Out-Host
}
if ($conflicts.Count -gt 0) {
    $conflicts | Format-List PolicyName, PolicyId, SettingName, SettingId,
        Instance, State, UPN, UserId, CurrentValue, ReportedContributors,
        ErrorCode, ErrorDescription | Out-Host
}
else {
    Write-Warning ('No explicit conflict setting rows returned. This is not proof the device is ' +
        'conflict-free. Check PolicyConflicts, Issues, report visibility, and last sync time.')
}

[pscustomobject]@{
    RetrievedAtUtc = [datetime]::UtcNow
    Device = [pscustomobject]$device
    Policies = @($policies | ForEach-Object { [pscustomobject]$_ })
    PolicyObservations = $policyObservations.ToArray()
    PolicyConflicts = $policyConflicts
    Settings = $settings.ToArray()
    Conflicts = $conflicts
    UnclassifiedSettings = $unclassified
    Issues = $issues.ToArray()
    # False means no detected retrieval/interpretation gap, not guaranteed full coverage.
    HasInvestigationGaps = ($issues.Count -gt 0)
}
