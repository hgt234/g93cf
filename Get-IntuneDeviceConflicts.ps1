#Requires -Version 7.0

<#
.SYNOPSIS
Read-only Intune configuration conflict investigation for one Windows device.
.DESCRIPTION
Uses interactive browser authentication through Microsoft Graph PowerShell and
requests only DeviceManagementManagedDevices.Read.All and
DeviceManagementConfiguration.Read.All. GET reads device/configuration states;
POST is restricted to three report retrieval actions. No sync, remediation,
policy/assignment changes, export jobs, module installation, or report files.

Requires Microsoft.Graph.Authentication 2.35.1. The version is pinned because
later releases can require System.Text.Json 10 on older PowerShell 7 runtimes.

Returns Device, Policies, PolicyObservations, PolicyConflicts, Settings,
Conflicts, UnclassifiedSettings, Issues, and HasInvestigationGaps.
ConflictReview joins policy identity with conflicting setting details, and
includes unresolved policy conflicts. ExportPath writes it to ConflictReview.csv.
Contributing policies are shown only when reported by Intune; matching setting
names do not establish which two policies conflict with one another.
Policy conflict rollups are never stamped onto individual settings.
Legacy and modern observations may overlap; counts are not unique settings.

Connect-MgGraph uses the system browser, allowing Conditional Access policies
that block device-code authentication to run normally. Authentication can
create normal sign-in/audit records. This script is read-only with respect to
Intune configuration and the managed device.

Modern reports use beta APIs. Numeric status codes are preserved, not guessed.
An empty conflict list is not proof that the device is conflict-free. Results
depend on RBAC/scope tags and the last reported device state, not live state.
Contributing policies/current values are returned only when the API supplies
them; matching setting names alone do not prove a conflicting policy pair.

Review validation: mock-tested; not executed against a tenant.
.PARAMETER ManagedDeviceId
Intune managed device ID, NOT the Entra device ID.
.PARAMETER TenantId
Tenant GUID or verified tenant domain. Microsoft public cloud only.
.PARAMETER ExportPath
Optional directory for a timestamped CSV export bundle. When supplied, export is
enabled automatically. CSV files contain configuration and assignment data and
should be handled as sensitive.
.EXAMPLE
$r = .\Get-IntuneDeviceConflicts.ps1 -TenantId contoso.onmicrosoft.com -DeviceName PC-123
$r.Conflicts | Format-List *
$r.PolicyConflicts | Format-List *
$r.Issues | Format-Table -Wrap
.EXAMPLE
$r = .\Get-IntuneDeviceConflicts.ps1 -TenantId contoso.onmicrosoft.com -ManagedDeviceId '11111111-2222-3333-4444-555555555555'
$r.Settings | Where-Object SettingId -eq 'SETTING-ID' | Format-List *
.EXAMPLE
.\Get-IntuneDeviceConflicts.ps1 -TenantId contoso.onmicrosoft.com -DeviceName PC-123 -ExportPath C:\Temp\IntuneReports
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
    [guid] $ManagedDeviceId,

    [ValidateNotNullOrEmpty()]
    [string] $ExportPath
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

if ($ExportPath -and [IO.Path]::GetExtension($ExportPath) -ieq '.csv') {
    throw "ExportPath must be a directory, not a CSV filename. Use a path such as 'C:\Temp\IntuneReports'."
}

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

function ConvertTo-ExportValue {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -isnot [string] -and $Value.GetType().IsPrimitive) { return $Value }
    if ($Value -is [decimal]) { return $Value }

    $text = if ($Value -is [string] -or $Value -is [guid]) {
        [string]$Value
    }
    else {
        ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    }
    # Prevent values supplied by Graph from becoming formulas when opened in Excel.
    if ($text -match '^[=+\-@\t\r]') { return "'$text" }
    return $text
}

function ConvertTo-ExportRow {
    param([Parameter(Mandatory)][object] $InputObject)
    $row = [ordered]@{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $row[[string]$key] = ConvertTo-ExportValue $InputObject[$key]
        }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.MemberType -in @('NoteProperty', 'Property', 'AliasProperty')) {
                $row[$property.Name] = ConvertTo-ExportValue $property.Value
            }
        }
    }
    return [pscustomobject]$row
}

function Export-DataSet {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][string] $Path
    )
    if ($Data.Count -eq 0) { return }
    @($Data | ForEach-Object { ConvertTo-ExportRow $_ }) |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8NoBOM
}

function Get-ConflictReview {
    param([object[]] $Settings, [object[]] $PolicyObservations)
    $conflictedSettings = @($Settings | Where-Object Classification -eq 'Conflict')
    foreach ($setting in $conflictedSettings) {
        [pscustomobject][ordered]@{
            Finding = 'Setting conflict'
            PolicyName = $setting.PolicyName
            PolicyId = $setting.PolicyId
            StateRecordId = $setting.StateRecordId
            SettingName = $setting.SettingName
            SettingId = $setting.SettingId
            Instance = $setting.Instance
            ReportedValue = $setting.CurrentValue
            ReportedContributingPolicies = $setting.ReportedContributors
            UserId = $setting.UserId
            UPN = $setting.UPN
            Source = $setting.Source
            NextAction = 'Review this setting in the identified policy and any reported contributing policies; verify intended values and assignments.'
        }
    }
    foreach ($policy in @($PolicyObservations | Where-Object Classification -eq 'Conflict')) {
        $resolved = @($conflictedSettings | Where-Object {
            $_.Source -eq $policy.Source -and
            (($policy.PolicyId -and $_.PolicyId -eq $policy.PolicyId -and $_.UserId -eq $policy.UserId) -or
             ($policy.StateRecordId -and $_.StateRecordId -eq $policy.StateRecordId))
        })
        # Modern policy and setting reports have different action names.
        if ($policy.PolicyId) {
            $resolved = @($conflictedSettings | Where-Object {
                $_.PolicyId -eq $policy.PolicyId -and $_.UserId -eq $policy.UserId
            })
        }
        if ($resolved.Count) { continue }
        [pscustomobject][ordered]@{
            Finding = 'Setting unresolved'
            PolicyName = $policy.PolicyName
            PolicyId = $policy.PolicyId
            StateRecordId = $policy.StateRecordId
            SettingName = $null
            SettingId = $null
            Instance = $null
            ReportedValue = $null
            ReportedContributingPolicies = $null
            UserId = $policy.UserId
            UPN = $policy.UPN
            Source = $policy.Source
            NextAction = 'Policy reports conflict but no conflicting setting was retrieved. Check Issues.csv and the device per-setting status in Intune.'
        }
    }
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
    try {
        $json = Invoke-MgGraphRequest @request
    }
    catch {
        $detail = $null
        $candidates = @($_.ErrorDetails.Message, $_.Exception.Message) | Where-Object { $_ }
        if ($_.Exception.Response -and $_.Exception.Response.Content) {
            try {
                $responseText = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($responseText) { $candidates = @($responseText) + $candidates }
            }
            catch { }
        }
        foreach ($candidate in $candidates) {
            try {
                $errorDocument = $candidate | ConvertFrom-Json
                if ($errorDocument.error.message) { $detail = [string]$errorDocument.error.message; break }
            }
            catch { }
            if (-not $detail) { $detail = [string]$candidate }
        }
        throw "Microsoft Graph $Method $($address.AbsolutePath) failed: $detail"
    }
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
    param(
        [string] $Action,
        [string] $Filter,
        [string[]] $Select = @(),
        [string[]] $OrderBy = @()
    )
    $skip = 0
    $pageSize = 100
    $previousPage = $null
    while ($true) {
        $page = Invoke-ReadRequest -Method POST `
            -Uri "$graph/beta/deviceManagement/reports/$Action" `
            -Body @{ select = $Select; filter = $Filter; skip = $skip; top = $pageSize; orderBy = $OrderBy }
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
        '^(conflict|6)$' { return 'Conflict' }
        '^([1-5]|success|succeeded|compliant|remediated|error|not.?applicable|not.?assigned|non.?compliant|pending|unknown)$' {
            return 'Other'
        }
        default { return 'Unclassified' }
    }
}

$requiredGraphAuthVersion = [version]'2.35.1'
$loadedGraphAuth = Get-Module -Name Microsoft.Graph.Authentication
if ($loadedGraphAuth -and $loadedGraphAuth.Version -ne $requiredGraphAuthVersion) {
    throw (
        "Microsoft.Graph.Authentication $($loadedGraphAuth.Version) is already loaded, but this script requires " +
        "$requiredGraphAuthVersion to avoid the System.Text.Json 10 load failure. Close this PowerShell session " +
        'and run the script in a new session.'
    )
}
$graphAuthModule = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
    Where-Object Version -eq $requiredGraphAuthVersion |
    Select-Object -First 1
if (-not $graphAuthModule) {
    throw (
        "Microsoft.Graph.Authentication $requiredGraphAuthVersion is required. Install it, then start a new " +
        "PowerShell session: Install-Module Microsoft.Graph.Authentication -RequiredVersion " +
        "$requiredGraphAuthVersion -Scope CurrentUser -Force -AllowClobber"
    )
}
Import-Module -FullyQualifiedName @{
    ModuleName = 'Microsoft.Graph.Authentication'
    RequiredVersion = $requiredGraphAuthVersion
} -ErrorAction Stop

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
    $supportedPolicyTypes = @(
        "(PolicyBaseTypeName eq 'Microsoft.Management.Services.Api.DeviceConfiguration')"
        "(PolicyBaseTypeName eq 'DeviceManagementConfigurationPolicy')"
        "(PolicyBaseTypeName eq 'DeviceConfigurationAdmxPolicy')"
        "(PolicyBaseTypeName eq 'Microsoft.Management.Services.Api.DeviceManagementIntent')"
    ) -join ' or '
    $policies = @(Get-Report -Action getConfigurationPoliciesReportForDevice `
        -Filter "(($supportedPolicyTypes) and (IntuneDeviceId eq $(Quote-FilterValue $id)))" `
        -Select @(
            'IntuneDeviceId', 'PolicyBaseTypeName', 'PolicyId', 'PolicyStatus',
            'UPN', 'UserId', 'PspdpuLastModifiedTimeUtc', 'PolicyName', 'UnifiedPolicyType'
        ) -OrderBy @('PolicyName'))
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

$retrievedAtUtc = [datetime]::UtcNow
$conflicts = @($settings | Where-Object Classification -eq 'Conflict')
$policyConflicts = @($policyObservations | Where-Object Classification -eq 'Conflict')
$conflictReview = @(Get-ConflictReview -Settings $settings.ToArray() -PolicyObservations $policyObservations.ToArray())
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
if ($conflictReview.Count) {
    Write-Host "`nCONFLICT REVIEW — policy objects and underlying settings"
    $conflictReview | Format-List Finding, PolicyName, PolicyId, StateRecordId,
        SettingName, SettingId, Instance, ReportedValue, ReportedContributingPolicies,
        UPN, UserId, NextAction | Out-Host
}
if ($conflicts.Count -eq 0) {
    Write-Warning ('No explicit conflict setting rows returned. This is not proof the device is ' +
        'conflict-free. Check PolicyConflicts, Issues, report visibility, and last sync time.')
}

$result = [pscustomobject]@{
    RetrievedAtUtc = $retrievedAtUtc
    Device = [pscustomobject]$device
    Policies = @($policies | ForEach-Object { [pscustomobject]$_ })
    PolicyObservations = $policyObservations.ToArray()
    PolicyConflicts = $policyConflicts
    Settings = $settings.ToArray()
    Conflicts = $conflicts
    ConflictReview = $conflictReview
    UnclassifiedSettings = $unclassified
    Issues = $issues.ToArray()
    # False means no detected retrieval/interpretation gap, not guaranteed full coverage.
    HasInvestigationGaps = ($issues.Count -gt 0)
    ExportPath = $null
}

if ($ExportPath) {
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExportPath)
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $safeDeviceName = ([string]$device.deviceName -replace '[^a-zA-Z0-9._-]', '_').Trim('_')
    if (-not $safeDeviceName) { $safeDeviceName = $id }
    $runName = '{0}-{1}' -f $safeDeviceName, $retrievedAtUtc.ToString('yyyyMMdd-HHmmssfffZ')
    $runPath = Join-Path $root $runName
    New-Item -ItemType Directory -Path $runPath -ErrorAction Stop | Out-Null

    $summary = [pscustomobject]@{
        RetrievedAtUtc = $retrievedAtUtc
        DeviceName = $device.deviceName
        ManagedDeviceId = $id
        LastIntuneSync = $device.lastSyncDateTime
        PolicyRecords = $policies.Count
        PolicyConflictObservations = $policyConflicts.Count
        SettingObservations = $settings.Count
        ExplicitConflictSettings = $conflicts.Count
        UnclassifiedSettings = $unclassified.Count
        Issues = $issues.Count
        HasInvestigationGaps = ($issues.Count -gt 0)
    }
    Export-DataSet -Data @($summary) -Path (Join-Path $runPath 'Summary.csv')
    Export-DataSet -Data @([pscustomobject]$device) -Path (Join-Path $runPath 'Device.csv')
    Export-DataSet -Data @($policies) -Path (Join-Path $runPath 'Policies.csv')
    Export-DataSet -Data @($policyObservations) -Path (Join-Path $runPath 'PolicyObservations.csv')
    Export-DataSet -Data @($policyConflicts) -Path (Join-Path $runPath 'PolicyConflicts.csv')
    Export-DataSet -Data @($settings) -Path (Join-Path $runPath 'Settings.csv')
    Export-DataSet -Data @($conflicts) -Path (Join-Path $runPath 'Conflicts.csv')
    Export-DataSet -Data @($conflictReview) -Path (Join-Path $runPath 'ConflictReview.csv')
    Export-DataSet -Data @($unclassified) -Path (Join-Path $runPath 'UnclassifiedSettings.csv')
    Export-DataSet -Data @($issues) -Path (Join-Path $runPath 'Issues.csv')
    $result.ExportPath = $runPath
    Write-Host "`nExported Excel-compatible CSV files to: $runPath"
    Get-ChildItem -LiteralPath $runPath -Filter '*.csv' -File |
        ForEach-Object { Write-Host "  $($_.FullName)" }
}

$result
