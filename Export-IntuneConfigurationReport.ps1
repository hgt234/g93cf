#requires -Version 7.0

<#
.SYNOPSIS
Exports Intune Windows configuration policies, settings, and assignments to CSV and HTML.

.DESCRIPTION
Reads modern Settings Catalog/endpoint-security configuration policies, legacy device
configuration profiles, and legacy Administrative Templates through Microsoft Graph.
The script is read-only. It creates:

  IntunePolicySettings.csv
  IntunePolicyAssignments.csv
  IntuneSettingOverlap.csv
  IntuneConfigurationReport.html

The HTML file is a self-contained, searchable report. Values that look like secrets or
certificate payloads are redacted unless -ShowSensitiveValues is specified.

.PARAMETER OutputPath
Directory in which report files are created.

.PARAMETER TenantId
Optional Entra tenant ID or verified domain. If omitted, interactive sign-in selects it.

.PARAMETER IncludeNonWindows
Also include non-Windows policies. The default is Windows-focused.

.PARAMETER SkipLegacyAdministrativeTemplates
Do not query the older groupPolicyConfigurations resource family.

.PARAMETER ShowSensitiveValues
Do not redact likely secrets, certificate payloads, or unusually long values. Treat the
resulting report as sensitive if this option is used.

.EXAMPLE
./Export-IntuneConfigurationReport.ps1 -OutputPath C:\Reports\IntuneBaseline

.EXAMPLE
./Export-IntuneConfigurationReport.ps1 -TenantId contoso.onmicrosoft.com

.NOTES
Required delegated permissions:
  DeviceManagementConfiguration.Read.All
  Group.Read.All

The Microsoft.Graph.Authentication module is required. Install it once with:
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string] $OutputPath = (Join-Path (Get-Location) ("IntuneConfigurationReport_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    [Parameter()]
    [string] $TenantId,

    [Parameter()]
    [switch] $IncludeNonWindows,

    [Parameter()]
    [switch] $SkipLegacyAdministrativeTemplates,

    [Parameter()]
    [switch] $ShowSensitiveValues
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-ObjectValue {
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject[$Name]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [switch] $Optional
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri

    try {
        while ($nextLink) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink -OutputType PSObject
            foreach ($item in @(Get-ObjectValue -InputObject $response -Name 'value')) {
                if ($null -ne $item) { $items.Add($item) }
            }
            $nextLink = Get-ObjectValue -InputObject $response -Name '@odata.nextLink'
        }
    }
    catch {
        if ($Optional) {
            Write-Warning "Optional Graph query failed: $Uri`n$($_.Exception.Message)"
            return @()
        }
        throw
    }

    return $items.ToArray()
}

function Test-IsWindowsPolicy {
    param(
        [AllowNull()] $Policy,
        [Parameter(Mandatory)] [ValidateSet('Modern', 'LegacyDeviceConfiguration', 'AdministrativeTemplate')] [string] $Family
    )

    if ($IncludeNonWindows) { return $true }
    if ($Family -eq 'AdministrativeTemplate') { return $true }

    if ($Family -eq 'Modern') {
        return [string](Get-ObjectValue $Policy 'platforms') -match '(?i)windows'
    }

    $odataType = [string](Get-ObjectValue $Policy '@odata.type')
    return $odataType -match '(?i)(windows|editionUpgrade|sharedPC|deliveryOptimization|defender|bitLocker|kiosk|networkBoundary)'
}

function Protect-ReportValue {
    param(
        [string] $Name,
        [AllowNull()] $Value
    )

    if ($null -eq $Value) { return '' }
    $text = if ($Value -is [string]) { $Value } else { $Value | ConvertTo-Json -Depth 12 -Compress }
    if ($ShowSensitiveValues) { return $text }

    if ($Name -match '(?i)(password|secret|token|pre.?shared|shared.?key|private.?key|certificate(Content|Data)?|payload)') {
        return '[redacted]'
    }
    if ($text.Length -gt 1000) {
        return "[long value omitted: $($text.Length) characters]"
    }
    return $text
}

function Get-ChoiceDisplayValue {
    param(
        [AllowNull()] $Definition,
        [AllowNull()] $RawValue
    )

    if ($null -eq $RawValue) { return '' }
    foreach ($option in @(Get-ObjectValue $Definition 'options')) {
        $optionId = Get-ObjectValue $option 'itemId'
        if ([string]$optionId -eq [string]$RawValue) {
            $displayName = Get-ObjectValue $option 'displayName'
            if ($displayName) { return [string]$displayName }
        }
    }
    return [string]$RawValue
}

function Convert-SettingInstance {
    param(
        [Parameter(Mandatory)] $Instance,
        [Parameter(Mandatory)] [hashtable] $Definitions,
        [string] $ParentPath = ''
    )

    $definitionId = [string](Get-ObjectValue $Instance 'settingDefinitionId')
    $definition = if ($Definitions.ContainsKey($definitionId)) { $Definitions[$definitionId] } else { $null }
    $displayName = [string](Get-ObjectValue $definition 'displayName')
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $definitionId }
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = '[unnamed setting]' }
    $settingPath = if ($ParentPath) { "$ParentPath > $displayName" } else { $displayName }

    $emitted = $false
    $simple = Get-ObjectValue $Instance 'simpleSettingValue'
    if ($null -ne $simple) {
        [pscustomobject]@{ SettingPath = $settingPath; SettingName = $displayName; SettingId = $definitionId; SettingValue = (Protect-ReportValue $definitionId (Get-ObjectValue $simple 'value')) }
        $emitted = $true
        foreach ($child in @(Get-ObjectValue $simple 'children')) {
            Convert-SettingInstance -Instance $child -Definitions $Definitions -ParentPath $settingPath
        }
    }

    $choice = Get-ObjectValue $Instance 'choiceSettingValue'
    if ($null -ne $choice) {
        $raw = Get-ObjectValue $choice 'value'
        $friendly = Get-ChoiceDisplayValue -Definition $definition -RawValue $raw
        [pscustomobject]@{ SettingPath = $settingPath; SettingName = $displayName; SettingId = $definitionId; SettingValue = (Protect-ReportValue $definitionId $friendly) }
        $emitted = $true
        foreach ($child in @(Get-ObjectValue $choice 'children')) {
            Convert-SettingInstance -Instance $child -Definitions $Definitions -ParentPath $settingPath
        }
    }

    $simpleCollection = @(Get-ObjectValue $Instance 'simpleSettingCollectionValue')
    if ($simpleCollection.Count -gt 0) {
        $values = @($simpleCollection | ForEach-Object { Get-ObjectValue $_ 'value' })
        [pscustomobject]@{ SettingPath = $settingPath; SettingName = $displayName; SettingId = $definitionId; SettingValue = (Protect-ReportValue $definitionId ($values -join '; ')) }
        $emitted = $true
    }

    $choiceCollection = @(Get-ObjectValue $Instance 'choiceSettingCollectionValue')
    if ($choiceCollection.Count -gt 0) {
        $values = foreach ($item in $choiceCollection) {
            Get-ChoiceDisplayValue -Definition $definition -RawValue (Get-ObjectValue $item 'value')
        }
        [pscustomobject]@{ SettingPath = $settingPath; SettingName = $displayName; SettingId = $definitionId; SettingValue = (Protect-ReportValue $definitionId ($values -join '; ')) }
        $emitted = $true
        foreach ($item in $choiceCollection) {
            foreach ($child in @(Get-ObjectValue $item 'children')) {
                Convert-SettingInstance -Instance $child -Definitions $Definitions -ParentPath $settingPath
            }
        }
    }

    $group = Get-ObjectValue $Instance 'groupSettingValue'
    if ($null -ne $group) {
        foreach ($child in @(Get-ObjectValue $group 'children')) {
            Convert-SettingInstance -Instance $child -Definitions $Definitions -ParentPath $settingPath
        }
    }

    $groupCollection = @(Get-ObjectValue $Instance 'groupSettingCollectionValue')
    for ($index = 0; $index -lt $groupCollection.Count; $index++) {
        $groupPath = if ($groupCollection.Count -gt 1) { "$settingPath [$($index + 1)]" } else { $settingPath }
        foreach ($child in @(Get-ObjectValue $groupCollection[$index] 'children')) {
            Convert-SettingInstance -Instance $child -Definitions $Definitions -ParentPath $groupPath
        }
    }

    if (-not $emitted -and $null -eq $group -and $groupCollection.Count -eq 0) {
        [pscustomobject]@{ SettingPath = $settingPath; SettingName = $displayName; SettingId = $definitionId; SettingValue = '[configured; value shape not recognized]' }
    }
}

function Convert-LegacyObjectToSettings {
    param(
        [Parameter(Mandatory)] $InputObject,
        [string] $Path = '',
        [int] $Depth = 0
    )

    if ($Depth -gt 12 -or $null -eq $InputObject) { return }
    $excluded = @(
        '@odata.type', 'id', 'displayName', 'description', 'version', 'createdDateTime',
        'lastModifiedDateTime', 'roleScopeTagIds', 'supportsScopeTags', 'assignments',
        'deviceStatusOverview', 'userStatusOverview', 'deviceStatuses', 'userStatuses'
    )

    $properties = if ($InputObject -is [System.Collections.IDictionary]) {
        $InputObject.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $InputObject[$_] } }
    }
    else {
        $InputObject.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }
    }

    foreach ($property in $properties) {
        if ($excluded -contains $property.Name -or $property.Name -like '*@odata*') { continue }
        $currentPath = if ($Path) { "$Path > $($property.Name)" } else { $property.Name }
        $value = $property.Value
        if ($null -eq $value) { continue }

        if ($value -is [string] -or $value -is [ValueType]) {
            [pscustomobject]@{ SettingPath = $currentPath; SettingName = $property.Name; SettingId = $currentPath; SettingValue = (Protect-ReportValue $currentPath $value) }
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [System.Collections.IDictionary]) {
            $array = @($value)
            if ($array.Count -eq 0) { continue }
            if (@($array | Where-Object { $_ -isnot [string] -and $_ -isnot [ValueType] }).Count -eq 0) {
                [pscustomobject]@{ SettingPath = $currentPath; SettingName = $property.Name; SettingId = $currentPath; SettingValue = (Protect-ReportValue $currentPath ($array -join '; ')) }
            }
            else {
                for ($index = 0; $index -lt $array.Count; $index++) {
                    Convert-LegacyObjectToSettings -InputObject $array[$index] -Path "$currentPath [$($index + 1)]" -Depth ($Depth + 1)
                }
            }
            continue
        }

        Convert-LegacyObjectToSettings -InputObject $value -Path $currentPath -Depth ($Depth + 1)
    }
}

function Get-AssignmentRows {
    param(
        [Parameter(Mandatory)] [string] $PolicyId,
        [Parameter(Mandatory)] [string] $PolicyName,
        [Parameter(Mandatory)] [string] $PolicyType,
        [Parameter(Mandatory)] [string] $AssignmentsUri,
        [Parameter(Mandatory)] [hashtable] $GroupMap,
        [Parameter(Mandatory)] [hashtable] $FilterMap
    )

    $assignments = @(Get-GraphCollection -Uri $AssignmentsUri -Optional)
    if ($assignments.Count -eq 0) {
        return ,([pscustomobject]@{
            PolicyType = $PolicyType; PolicyName = $PolicyName; PolicyId = $PolicyId
            Intent = 'Unassigned'; AssignedTo = 'Unassigned'; GroupId = ''; FilterType = ''; FilterName = ''; FilterRule = ''; Source = ''
        })
    }

    $rows = foreach ($assignment in $assignments) {
        $target = Get-ObjectValue $assignment 'target'
        $targetType = [string](Get-ObjectValue $target '@odata.type')
        $groupId = [string](Get-ObjectValue $target 'groupId')
        if (-not $groupId) { $groupId = [string](Get-ObjectValue $target 'entraObjectId') }

        $intent = if ($targetType -match '(?i)exclusion') { 'Exclude' } else { 'Include' }
        $assignedTo = switch -Regex ($targetType) {
            '(?i)allDevices'       { 'All devices'; break }
            '(?i)allLicensedUsers' { 'All users'; break }
            '(?i)group|scopeTag'   {
                if ($groupId -and $GroupMap.ContainsKey($groupId)) { $GroupMap[$groupId] }
                elseif ($groupId) { "Unresolved/deleted group [$groupId]" }
                else { $targetType -replace '^#?microsoft\.graph\.', '' }
                break
            }
            default { $targetType -replace '^#?microsoft\.graph\.', '' }
        }

        $filterId = [string](Get-ObjectValue $target 'deviceAndAppManagementAssignmentFilterId')
        $filterType = [string](Get-ObjectValue $target 'deviceAndAppManagementAssignmentFilterType')
        $filter = if ($filterId -and $FilterMap.ContainsKey($filterId)) { $FilterMap[$filterId] } else { $null }
        $filterName = if ($filter) { [string](Get-ObjectValue $filter 'displayName') } elseif ($filterId) { "Unresolved filter [$filterId]" } else { '' }
        $filterRule = if ($filter) { [string](Get-ObjectValue $filter 'rule') } else { '' }

        [pscustomobject]@{
            PolicyType = $PolicyType
            PolicyName = $PolicyName
            PolicyId = $PolicyId
            Intent = $intent
            AssignedTo = $assignedTo
            GroupId = $groupId
            FilterType = $filterType
            FilterName = $filterName
            FilterRule = $filterRule
            Source = [string](Get-ObjectValue $assignment 'source')
        }
    }
    return @($rows)
}

function New-PolicySettingRows {
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [string] $PolicyType,
        [Parameter(Mandatory)] [object[]] $Settings,
        [Parameter(Mandatory)] [object[]] $Assignments,
        [string] $Platform,
        [string] $Technology
    )

    $policyName = if (Get-ObjectValue $Policy 'name') { [string](Get-ObjectValue $Policy 'name') } else { [string](Get-ObjectValue $Policy 'displayName') }
    $policyId = [string](Get-ObjectValue $Policy 'id')
    $assignmentText = @($Assignments | ForEach-Object {
        $text = "$($_.Intent): $($_.AssignedTo)"
        if ($_.FilterName) { $text += " [filter $($_.FilterType): $($_.FilterName)]" }
        $text
    }) -join ' | '

    if ($Settings.Count -eq 0) {
        $Settings = @([pscustomobject]@{ SettingPath = '[No settings returned]'; SettingName = '[No settings returned]'; SettingId = ''; SettingValue = '' })
    }

    foreach ($setting in $Settings) {
        [pscustomobject]@{
            PolicyType = $PolicyType
            PolicyName = $policyName
            PolicyId = $policyId
            Platform = $Platform
            Technology = $Technology
            SettingPath = $setting.SettingPath
            SettingName = $setting.SettingName
            SettingId = $setting.SettingId
            SettingValue = $setting.SettingValue
            Assignments = $assignmentText
            LastModified = [string](Get-ObjectValue $Policy 'lastModifiedDateTime')
        }
    }
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()] $Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-ReportTable {
    param(
        [Parameter(Mandatory)] [object[]] $Rows,
        [Parameter(Mandatory)] [string[]] $Columns,
        [Parameter(Mandatory)] [string] $Id
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append("<div class='table-wrap'><table id='$Id'><thead><tr>")
    foreach ($column in $Columns) { [void]$builder.Append("<th>$(ConvertTo-HtmlEncoded $column)</th>") }
    [void]$builder.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        [void]$builder.Append('<tr>')
        foreach ($column in $Columns) {
            [void]$builder.Append("<td>$(ConvertTo-HtmlEncoded (Get-ObjectValue $row $column))</td>")
        }
        [void]$builder.Append('</tr>')
    }
    [void]$builder.Append('</tbody></table></div>')
    return $builder.ToString()
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Microsoft.Graph.Authentication is required. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}
Import-Module Microsoft.Graph.Authentication

$connectParameters = @{
    Scopes = @('DeviceManagementConfiguration.Read.All', 'Group.Read.All')
    ContextScope = 'Process'
    NoWelcome = $true
}
if ($TenantId) { $connectParameters.TenantId = $TenantId }
Connect-MgGraph @connectParameters | Out-Null

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$OutputPath = (Resolve-Path $OutputPath).Path
Write-Host "Reading Intune policy inventory..." -ForegroundColor Cyan

$groupMap = @{}
foreach ($group in @(Get-GraphCollection -Uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName')) {
    $groupMap[[string](Get-ObjectValue $group 'id')] = [string](Get-ObjectValue $group 'displayName')
}

$filterMap = @{}
foreach ($filter in @(Get-GraphCollection -Uri 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters' -Optional)) {
    $filterMap[[string](Get-ObjectValue $filter 'id')] = $filter
}

$allSettings = [System.Collections.Generic.List[object]]::new()
$allAssignments = [System.Collections.Generic.List[object]]::new()

$modernPolicies = @(Get-GraphCollection -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies') |
    Where-Object { Test-IsWindowsPolicy -Policy $_ -Family Modern }

foreach ($policy in $modernPolicies) {
    $policyId = [string](Get-ObjectValue $policy 'id')
    $policyName = [string](Get-ObjectValue $policy 'name')
    Write-Host "  Modern: $policyName"
    $assignments = @(Get-AssignmentRows -PolicyId $policyId -PolicyName $policyName -PolicyType 'Settings Catalog / Endpoint Security' -AssignmentsUri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId/assignments" -GroupMap $groupMap -FilterMap $filterMap)
    foreach ($assignment in $assignments) { $allAssignments.Add($assignment) }

    $rawSettings = @(Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId/settings?`$expand=settingDefinitions" -Optional)
    $settings = foreach ($rawSetting in $rawSettings) {
        $definitions = @{}
        foreach ($definition in @(Get-ObjectValue $rawSetting 'settingDefinitions')) {
            $definitions[[string](Get-ObjectValue $definition 'id')] = $definition
        }
        $instance = Get-ObjectValue $rawSetting 'settingInstance'
        if ($null -ne $instance) { Convert-SettingInstance -Instance $instance -Definitions $definitions }
    }

    $platform = [string](Get-ObjectValue $policy 'platforms')
    $technology = [string](Get-ObjectValue $policy 'technologies')
    foreach ($row in @(New-PolicySettingRows -Policy $policy -PolicyType 'Settings Catalog / Endpoint Security' -Settings @($settings) -Assignments $assignments -Platform $platform -Technology $technology)) {
        $allSettings.Add($row)
    }
}

$legacyPolicies = @(Get-GraphCollection -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations') |
    Where-Object { Test-IsWindowsPolicy -Policy $_ -Family LegacyDeviceConfiguration }

foreach ($policy in $legacyPolicies) {
    $policyId = [string](Get-ObjectValue $policy 'id')
    $policyName = [string](Get-ObjectValue $policy 'displayName')
    Write-Host "  Legacy device configuration: $policyName"
    $assignments = @(Get-AssignmentRows -PolicyId $policyId -PolicyName $policyName -PolicyType 'Legacy Device Configuration' -AssignmentsUri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$policyId/assignments" -GroupMap $groupMap -FilterMap $filterMap)
    foreach ($assignment in $assignments) { $allAssignments.Add($assignment) }
    $settings = @(Convert-LegacyObjectToSettings -InputObject $policy)
    $typeName = ([string](Get-ObjectValue $policy '@odata.type')) -replace '^#?microsoft\.graph\.', ''
    foreach ($row in @(New-PolicySettingRows -Policy $policy -PolicyType 'Legacy Device Configuration' -Settings $settings -Assignments $assignments -Platform 'Windows' -Technology $typeName)) {
        $allSettings.Add($row)
    }
}

if (-not $SkipLegacyAdministrativeTemplates) {
    $administrativeTemplates = @(Get-GraphCollection -Uri 'https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations' -Optional)
    foreach ($policy in $administrativeTemplates) {
        $policyId = [string](Get-ObjectValue $policy 'id')
        $policyName = [string](Get-ObjectValue $policy 'displayName')
        Write-Host "  Administrative Template: $policyName"
        $assignments = @(Get-AssignmentRows -PolicyId $policyId -PolicyName $policyName -PolicyType 'Administrative Template (legacy)' -AssignmentsUri "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/$policyId/assignments" -GroupMap $groupMap -FilterMap $filterMap)
        foreach ($assignment in $assignments) { $allAssignments.Add($assignment) }

        $definitionValues = @(Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/$policyId/definitionValues?`$expand=definition,presentationValues(`$expand=presentation)" -Optional)
        $settings = foreach ($definitionValue in $definitionValues) {
            $definition = Get-ObjectValue $definitionValue 'definition'
            $name = [string](Get-ObjectValue $definition 'displayName')
            if (-not $name) { $name = [string](Get-ObjectValue $definitionValue 'id') }
            $category = [string](Get-ObjectValue $definition 'categoryPath')
            $state = if ([bool](Get-ObjectValue $definitionValue 'enabled')) { 'Enabled' } else { 'Disabled' }
            $presentations = foreach ($presentationValue in @(Get-ObjectValue $definitionValue 'presentationValues')) {
                $presentation = Get-ObjectValue $presentationValue 'presentation'
                $label = [string](Get-ObjectValue $presentation 'label')
                $value = Get-ObjectValue $presentationValue 'value'
                if ($null -ne $value) { if ($label) { "$label=$value" } else { [string]$value } }
            }
            if (@($presentations).Count -gt 0) { $state += "; $($presentations -join '; ')" }
            [pscustomobject]@{
                SettingPath = if ($category) { "$category > $name" } else { $name }
                SettingName = $name
                SettingId = [string](Get-ObjectValue $definition 'id')
                SettingValue = Protect-ReportValue $name $state
            }
        }
        foreach ($row in @(New-PolicySettingRows -Policy $policy -PolicyType 'Administrative Template (legacy)' -Settings @($settings) -Assignments $assignments -Platform 'Windows' -Technology 'Group Policy / ADMX')) {
            $allSettings.Add($row)
        }
    }
}

$settingsRows = @($allSettings.ToArray() | Sort-Object PolicyType, PolicyName, SettingPath)
$assignmentRows = @($allAssignments.ToArray() | Sort-Object PolicyType, PolicyName, Intent, AssignedTo)

$overlapRows = @(
    $settingsRows |
        Where-Object { $_.SettingId -and $_.SettingPath -ne '[No settings returned]' } |
        Group-Object SettingId |
        Where-Object { @($_.Group.PolicyId | Select-Object -Unique).Count -gt 1 } |
        ForEach-Object {
            [pscustomobject]@{
                SettingId = $_.Name
                SettingName = ($_.Group.SettingName | Select-Object -First 1)
                PolicyCount = @($_.Group.PolicyId | Select-Object -Unique).Count
                Policies = (@($_.Group | ForEach-Object { "$($_.PolicyName) = $($_.SettingValue)" }) | Sort-Object -Unique) -join ' | '
            }
        } |
        Sort-Object -Property @{ Expression = 'PolicyCount'; Descending = $true }, SettingName
)

$settingsCsv = Join-Path $OutputPath 'IntunePolicySettings.csv'
$assignmentsCsv = Join-Path $OutputPath 'IntunePolicyAssignments.csv'
$overlapCsv = Join-Path $OutputPath 'IntuneSettingOverlap.csv'
$htmlPath = Join-Path $OutputPath 'IntuneConfigurationReport.html'

$settingsRows | Export-Csv -Path $settingsCsv -NoTypeInformation -Encoding utf8BOM
$assignmentRows | Export-Csv -Path $assignmentsCsv -NoTypeInformation -Encoding utf8BOM
$overlapRows | Export-Csv -Path $overlapCsv -NoTypeInformation -Encoding utf8BOM

$policyCount = @($settingsRows.PolicyId | Select-Object -Unique).Count
$assignedCount = @($assignmentRows | Where-Object Intent -ne 'Unassigned' | Select-Object -ExpandProperty PolicyId -Unique).Count
$unassignedCount = @($assignmentRows | Where-Object Intent -eq 'Unassigned').Count
$groupCount = @($assignmentRows | Where-Object GroupId | Select-Object -ExpandProperty GroupId -Unique).Count
$generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'

$settingsTable = ConvertTo-ReportTable -Rows $settingsRows -Columns @('PolicyType','PolicyName','Platform','Technology','SettingPath','SettingValue','Assignments','LastModified') -Id 'settingsTable'
$assignmentTable = ConvertTo-ReportTable -Rows $assignmentRows -Columns @('PolicyType','PolicyName','Intent','AssignedTo','FilterType','FilterName','FilterRule','Source') -Id 'assignmentsTable'
$overlapTable = ConvertTo-ReportTable -Rows $overlapRows -Columns @('SettingName','SettingId','PolicyCount','Policies') -Id 'overlapTable'

$html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Intune configuration inventory</title>
<style>
:root{--bg:#f5f7fb;--card:#fff;--ink:#172033;--muted:#60708d;--line:#dce3ee;--blue:#2563eb;--navy:#102a43}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 "Segoe UI",Arial,sans-serif}
header{background:linear-gradient(120deg,var(--navy),#174d78);color:#fff;padding:30px max(4vw,28px)}h1{margin:0 0 6px;font-size:28px}header p{margin:0;color:#d7e7f5}
main{padding:24px max(4vw,28px) 50px}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin-bottom:24px}.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px}.card b{display:block;font-size:25px;color:var(--blue)}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:0 0 22px;padding:18px}h2{margin:0 0 4px;font-size:20px}.hint{margin:0 0 14px;color:var(--muted)}
input{width:min(520px,100%);padding:10px 12px;border:1px solid #b8c4d6;border-radius:7px;margin:0 0 12px;font:inherit}.table-wrap{overflow:auto;max-height:68vh;border:1px solid var(--line);border-radius:7px}table{border-collapse:collapse;width:100%;font-size:12px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:8px 9px;max-width:460px;word-break:break-word}th{position:sticky;top:0;background:#edf3fa;color:#203650;z-index:1}tr:nth-child(even) td{background:#fafcff}tr:hover td{background:#eef6ff}.hidden{display:none}footer{color:var(--muted);padding-top:4px}
</style></head><body>
<header><h1>Intune configuration inventory</h1><p>Generated $(ConvertTo-HtmlEncoded $generated) · Read-only Microsoft Graph export</p></header>
<main><div class="cards"><div class="card"><b>$policyCount</b>policies</div><div class="card"><b>$($settingsRows.Count)</b>setting rows</div><div class="card"><b>$assignedCount</b>assigned policies</div><div class="card"><b>$unassignedCount</b>unassigned policies</div><div class="card"><b>$groupCount</b>targeted groups</div><div class="card"><b>$($overlapRows.Count)</b>overlapping settings</div></div>
<section><h2>Policy settings</h2><p class="hint">Search by policy, setting, value, platform, or assignment.</p><input type="search" placeholder="Filter settings..." oninput="filterRows('settingsTable',this.value)">$settingsTable</section>
<section><h2>Assignments</h2><p class="hint">Includes exclusions and Intune assignment filters.</p><input type="search" placeholder="Filter assignments..." oninput="filterRows('assignmentsTable',this.value)">$assignmentTable</section>
<section><h2>Consolidation candidates</h2><p class="hint">Settings present in more than one policy. Review different values carefully before combining policies.</p><input type="search" placeholder="Filter overlaps..." oninput="filterRows('overlapTable',this.value)">$overlapTable</section>
<footer>Likely secrets and certificate payloads were $(if ($ShowSensitiveValues) {'not redacted'} else {'redacted'}). CSV files in this folder provide the same data for Excel or Power BI.</footer></main>
<script>function filterRows(id,q){q=q.toLowerCase();document.querySelectorAll('#'+id+' tbody tr').forEach(r=>r.classList.toggle('hidden',!r.innerText.toLowerCase().includes(q)));}</script>
</body></html>
"@

$html | Set-Content -Path $htmlPath -Encoding utf8

Write-Host "`nReport complete:" -ForegroundColor Green
Write-Host "  $htmlPath"
Write-Host "  $settingsCsv"
Write-Host "  $assignmentsCsv"
Write-Host "  $overlapCsv"

[pscustomobject]@{
    OutputPath = $OutputPath
    HtmlReport = $htmlPath
    Policies = $policyCount
    SettingRows = $settingsRows.Count
    AssignmentRows = $assignmentRows.Count
    OverlappingSettings = $overlapRows.Count
}
