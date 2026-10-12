#requires -Version 5.1
<#
.SYNOPSIS
Exports devices with an app into non-overlapping rollout phases.

.DESCRIPTION
Finds devices either from one Intune managed app's install status report
(-JoinAppId) or from Intune discovered-app inventory by name wildcard and
version range (-AppName). Resolves each device's current Intune primary user
and Entra identity, sorts by EntraDeviceId, and splits them into disjoint
10%, 30%, and 60% phases by default.
Only reads tenant data; exports local CSVs for review and manual group import.
GUID ordering is deterministic for the same device population, not a shuffle.
Changing the population can move devices across phase boundaries.
WhatIf still reads Graph; it suppresses only the local exports.

.PARAMETER JoinAppId
Intune managed app (mobileApp) ID. Devices with an installed status qualify.

.PARAMETER AppName
Case-insensitive -like wildcard matched against discovered app display names,
for example '7-Zip*'. Matched app records and device counts are listed first.

.PARAMETER MinVersion
Inclusive lower version bound for -AppName matches, such as 9 or 9.20.

.PARAMETER MaxVersion
Exclusive upper version bound for -AppName matches; 12 means "below 12".
When a bound is set, records whose version cannot be parsed are excluded.

.PARAMETER Platform
Discovered app platform to match. Defaults to windows.

.PARAMETER MaxDevices
Resolves only the first N matching Intune devices (sorted by Intune device
ID) for a quick validation run. Discovery still reads the full population.

.PARAMETER ActiveWithinDays
Devices whose last Intune check-in (lastSyncDateTime) is older than this many
days, or that never checked in, are exported as Inactive instead of being
placed in a phase. Defaults to 90; 0 disables the filter.

.PARAMETER DeviceLookup
How matched devices are resolved to primary users and Entra object IDs.
Batch looks up each device (20 per $batch call); Bulk lists all Intune and
Entra devices once (1,000 per page). Auto uses Bulk above 1,000 devices.

.PARAMETER RequirePrimaryUser
Skips devices without an Intune primary user instead of exporting a blank UPN.

.PARAMETER PhasePercentages
Positive whole-number percentages totaling 100. Rounding uses largest
remainders (earlier phases win ties), so every device belongs to one phase.

.PARAMETER ExportDirectory
Folder for the detail CSV and one Entra device bulk-import CSV per phase.

.EXAMPLE
.\phased-rollout-creator.ps1 -JoinAppId <app-guid> -ExportDirectory C:\Temp\Rollout

.EXAMPLE
.\phased-rollout-creator.ps1 -JoinAppId <app-guid> -PhasePercentages 10,30,60 -UseDeviceCode -WhatIf

.EXAMPLE
.\phased-rollout-creator.ps1 -AppName '7-Zip*' -MaxVersion 12 -ExportDirectory C:\Temp\7zip -MaxDevices 10
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ManagedApp')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ManagedApp')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $JoinAppId,

    [Parameter(Mandatory, ParameterSetName = 'DetectedApp')]
    [ValidateNotNullOrEmpty()]
    [string] $AppName,

    [Parameter(ParameterSetName = 'DetectedApp')]
    [ValidatePattern('^\d+(\.\d+){0,3}$')]
    [string] $MinVersion,

    [Parameter(ParameterSetName = 'DetectedApp')]
    [ValidatePattern('^\d+(\.\d+){0,3}$')]
    [string] $MaxVersion,

    [Parameter(ParameterSetName = 'DetectedApp')]
    [ValidateSet('windows', 'macOS', 'androidWorkProfile', 'androidDeviceAdministrator', 'ios', 'chromeOS', 'unknown')]
    [string] $Platform = 'windows',

    [ValidateNotNullOrEmpty()]
    [string] $ExportDirectory = '.',

    [ValidateNotNullOrEmpty()]
    [ValidateRange(1, 100)]
    [int[]] $PhasePercentages = @(10, 30, 60),

    [ValidateRange(1, [int]::MaxValue)]
    [int] $MaxDevices,

    [switch] $RequirePrimaryUser,

    [ValidateRange(0, 3650)]
    [int] $ActiveWithinDays = 90,

    [ValidateSet('Auto', 'Batch', 'Bulk')]
    [string] $DeviceLookup = 'Auto',

    [string] $TenantId,
    [switch] $UseDeviceCode,

    [Parameter(ParameterSetName = 'ManagedApp')]
    [ValidateSet('retrieveDeviceAppInstallationStatusReport', 'getDeviceInstallStatusReport')]
    [string] $InstallReportAction = 'retrieveDeviceAppInstallationStatusReport'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if (($PhasePercentages | Measure-Object -Sum).Sum -ne 100) {
    throw 'PhasePercentages must contain positive percentages totaling 100.'
}

$script:graphRoot = 'https://graph.microsoft.com'
$script:graphBase = "$script:graphRoot/v1.0"
$script:graphSession = $null
$script:maxGraphAttempts = 5
$script:retryableStatusCodes = @(429, 502, 503, 504, 509)
$script:emptyGuid = '00000000-0000-0000-0000-000000000000'
$script:bulkLookupThreshold = 1000
$script:graphCallCount = 0
$script:batchSubrequestCount = 0
$requiredScopes = @('DeviceManagementApps.Read.All', 'DeviceManagementManagedDevices.Read.All', 'Device.Read.All')

# Read-only Graph helpers. This tool is standalone and shares no code with the
# EUC pilot program; the read-only boundary below is enforced in this file.
function Get-PilotProperty {
    param($InputObject, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-PilotBrokenAuthVersion {
    param([Parameter(Mandatory)] [version] $Version)
    $normalized = [version]('{0}.{1}.{2}' -f $Version.Major, $Version.Minor, [Math]::Max(0, $Version.Build))
    return ($normalized -ge [version]'2.41.0' -and $normalized -le [version]'2.41.1')
}

function Import-PilotAuthModule {
    # Remove-Module cannot unload assemblies; an already-loaded version wins.
    $loadedAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.Graph.Authentication' } |
        Select-Object -First 1
    if ($loadedAssembly) {
        $loadedVersion = $loadedAssembly.GetName().Version
        if (Test-PilotBrokenAuthVersion -Version $loadedVersion) {
            throw ('Microsoft.Graph.Authentication {0} is already loaded and cannot sign in (System.Text.Json bug #3810). Start a NEW PowerShell session (pwsh -NoProfile).' -f $loadedVersion)
        }
        if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
            $matching = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
                Where-Object { $_.Version.Major -eq $loadedVersion.Major -and $_.Version.Minor -eq $loadedVersion.Minor -and $_.Version.Build -eq $loadedVersion.Build } |
                Select-Object -First 1
            if (-not $matching) { throw "Microsoft.Graph.Authentication $loadedVersion is loaded but not installed. Start a new PowerShell session." }
            Import-Module $matching.Path
        }
        return
    }
    $installed = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)
    if ($installed.Count -eq 0) {
        throw 'Microsoft.Graph.Authentication is required. Run: Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser'
    }
    $usable = @($installed | Where-Object { -not (Test-PilotBrokenAuthVersion -Version $_.Version) } | Sort-Object Version -Descending)
    if ($usable.Count -eq 0) {
        throw 'Installed Microsoft.Graph.Authentication versions cannot sign in (System.Text.Json bug #3810). Run: Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser -Force'
    }
    if ($usable.Count -lt $installed.Count) {
        Write-Warning "Ignoring broken Microsoft.Graph.Authentication versions; using $($usable[0].Version)."
    }
    Import-Module $usable[0].Path
}

function Connect-PilotGraph {
    param([string] $TenantId, [string[]] $Scopes, [switch] $DeviceCode)
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }
        $tokenUri = '{0}?resource={1}/' -f $env:IDENTITY_ENDPOINT, $script:graphRoot
        $response = Invoke-RestMethod -Method Get -Uri $tokenUri -Headers $headers -UseBasicParsing
        $accessToken = Get-PilotProperty $response 'access_token'
        if (-not $accessToken) { throw 'Managed identity endpoint returned no access token.' }
        return [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = [string]$accessToken; Account = 'managed identity' }
    }
    Import-PilotAuthModule
    $connectArgs = @{ Scopes = $Scopes; NoWelcome = $true }
    if ($TenantId) { $connectArgs.TenantId = $TenantId }
    if ($DeviceCode) {
        $parameterName = if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('UseDeviceCode')) { 'UseDeviceCode' } else { 'UseDeviceAuthentication' }
        Write-Verbose "Signing in with device code flow ($parameterName)."
        $connectArgs[$parameterName] = $true
    }
    Connect-MgGraph @connectArgs | Out-Null
    $context = Get-MgContext
    if (-not $context -or -not $context.Account) { throw 'Connect-MgGraph did not produce an authenticated context.' }
    $missingScopes = @($Scopes | Where-Object { @($context.Scopes) -notcontains $_ })
    if ($missingScopes.Count -gt 0) { throw ('Missing required scopes: {0}' -f ($missingScopes -join ', ')) }
    return [pscustomobject]@{ Mode = 'MgGraph'; Token = $null; Account = [string]$context.Account }
}

function Send-PilotGraphRequest {
    param([Parameter(Mandatory)] [string] $Method, [Parameter(Mandatory)] [string] $Uri, [string] $BodyJson)
    $requestBody = if ($BodyJson) { $BodyJson | ConvertFrom-Json } else { $null }
    Assert-PilotReadRequest -Method $Method -Uri $Uri -Body $requestBody
    if ($script:graphSession.Mode -eq 'MgGraph') {
        $requestArgs = @{ Method = $Method; Uri = $Uri; OutputType = 'HttpResponseMessage'; SkipHttpErrorCheck = $true }
        if ($BodyJson) { $requestArgs.Body = $BodyJson; $requestArgs.ContentType = 'application/json' }
        $response = Invoke-MgGraphRequest @requestArgs
        try {
            $retryAfter = 0
            if ($null -ne $response.Headers.RetryAfter -and $null -ne $response.Headers.RetryAfter.Delta) {
                $retryAfter = [int]$response.Headers.RetryAfter.Delta.TotalSeconds
            }
            elseif ($null -ne $response.Headers.RetryAfter -and $null -ne $response.Headers.RetryAfter.Date) {
                $retryAfter = [int][Math]::Max(0, [Math]::Ceiling(($response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds))
            }
            $content = ''
            if ($null -ne $response.Content) { $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
            return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; RetryAfter = $retryAfter; Content = $content }
        }
        finally { $response.Dispose() }
    }
    $webArgs = @{
        Method = $Method; Uri = $Uri
        Headers = @{ Authorization = "Bearer $($script:graphSession.Token)" }
        UseBasicParsing = $true; ErrorAction = 'Stop'
    }
    if ($BodyJson) {
        $webArgs.Body = [System.Text.Encoding]::UTF8.GetBytes($BodyJson)
        $webArgs.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $response = Invoke-WebRequest @webArgs
        $content = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; RetryAfter = 0; Content = $content }
    }
    catch {
        $errorResponse = Get-PilotProperty $_.Exception 'Response'
        if ($null -eq $errorResponse) { throw }
        $retryAfter = 0
        try {
            if ($errorResponse.Headers -is [System.Net.WebHeaderCollection]) {
                $parsedRetryAfter = 0
                if ([int]::TryParse([string]$errorResponse.Headers['Retry-After'], [ref]$parsedRetryAfter)) { $retryAfter = $parsedRetryAfter }
            }
            elseif ($null -ne $errorResponse.Headers.RetryAfter -and $null -ne $errorResponse.Headers.RetryAfter.Delta) {
                $retryAfter = [int]$errorResponse.Headers.RetryAfter.Delta.TotalSeconds
            }
        }
        catch { Write-Verbose "Could not read Retry-After: $($_.Exception.Message)" }
        $content = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $content = $_.ErrorDetails.Message }
        return [pscustomobject]@{ StatusCode = [int]$errorResponse.StatusCode; RetryAfter = $retryAfter; Content = $content }
    }
}

function Invoke-PilotGraph {
    param([Parameter(Mandatory)] [string] $Method, [Parameter(Mandatory)] [string] $Uri, [object] $Body, [int[]] $AllowStatus = @())
    $resolvedUri = if ($Uri.StartsWith('https://')) { $Uri } else { "$script:graphBase$Uri" }
    Assert-PilotReadRequest -Method $Method -Uri $resolvedUri -Body $Body
    $bodyJson = $null
    if ($null -ne $Body) { $bodyJson = $Body | ConvertTo-Json -Depth 10 -Compress }
    $authRefreshed = $false
    for ($attempt = 1; ; $attempt++) {
        $script:graphCallCount++
        $result = Send-PilotGraphRequest -Method $Method -Uri $resolvedUri -BodyJson $bodyJson
        if ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300) {
            if ([string]::IsNullOrWhiteSpace($result.Content)) { return $null }
            return ($result.Content | ConvertFrom-Json)
        }
        # Callers that can fall back (an unsupported filter) see these as $null.
        if ($AllowStatus -contains $result.StatusCode) { return $null }
        if ($result.StatusCode -eq 401 -and $script:graphSession.Mode -eq 'ManagedIdentity' -and -not $authRefreshed) {
            $script:graphSession = Connect-PilotGraph
            $authRefreshed = $true
            continue
        }
        if ($script:retryableStatusCodes -contains $result.StatusCode -and $attempt -lt $script:maxGraphAttempts) {
            $delay = Get-PilotRetryDelay -Attempt $attempt -RetryAfter $result.RetryAfter
            Write-Warning "Graph returned HTTP $($result.StatusCode); retrying in ${delay}s."
            Start-Sleep -Seconds $delay
            continue
        }
        throw "Graph $Method $resolvedUri failed with HTTP $($result.StatusCode): $($result.Content)"
    }
}

# Fail closed at the Graph boundary: only these report queries, discovered-app
# inventory GETs, Intune/Entra device list GETs, and GET-only device batches are
# allowed. POST to exportJobs/group membership and device actions are rejected.
function Assert-PilotReadRequest {
    param([string] $Method, [string] $Uri, $Body)
    if ($Method -eq 'Get' -and $null -eq $Body -and (
        $Uri -match '^https://graph\.microsoft\.com/beta/deviceManagement/detectedApps(/[^/?]+/managedDevices)?(\?.*)?$' -or
        $Uri -match '^https://graph\.microsoft\.com/v1\.0/deviceManagement/managedDevices(\?.*)?$' -or
        $Uri -match '^https://graph\.microsoft\.com/v1\.0/devices(\?.*)?$')) { return }
    if ($Method -eq 'Post' -and $Uri -match '^https://graph\.microsoft\.com/beta/deviceManagement/reports/(retrieveDeviceAppInstallationStatusReport|getDeviceInstallStatusReport)$') { return }
    if ($Method -eq 'Post' -and $Uri -eq "$script:graphBase/`$batch") {
        $requests = @(Get-PilotProperty $Body 'requests')
        if ($requests.Count -lt 1 -or $requests.Count -gt 20) { throw 'Read-only batch must contain 1 to 20 GET requests.' }
        foreach ($request in $requests) {
            $url = [string](Get-PilotProperty $request 'url')
            $readUrl = $url -match '^/deviceManagement/managedDevices/[^/?]+\?\$select=id,azureADDeviceId,deviceName,userPrincipalName,lastSyncDateTime$' -or
                $url -match "^/devices\(deviceId='[0-9a-fA-F-]{36}'\)\?\`$select=id,deviceId,approximateLastSignInDateTime$"
            if ((Get-PilotProperty $request 'method') -ne 'GET' -or -not $readUrl -or (Get-PilotProperty $request 'body')) {
                throw "Read-only Graph boundary rejected batch request: $url"
            }
        }
        return
    }
    throw "Read-only Graph boundary rejected $Method $Uri"
}

function Get-PilotGraphPaged {
    # Walks @odata.nextLink. A response without a 'value' collection throws
    # rather than being treated as an empty page.
    param([Parameter(Mandatory)] [string] $Uri)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $nextUri = $Uri
    while ($nextUri) {
        $response = Invoke-PilotGraph -Method Get -Uri $nextUri
        if ($null -eq $response -or -not $response.PSObject.Properties['value']) {
            throw "Unexpected Graph response from $nextUri (no 'value' collection)."
        }
        foreach ($item in $response.value) { $items.Add($item) }
        $nextUri = [string](Get-PilotProperty $response '@odata.nextLink')
    }
    return $items.ToArray()
}

function Get-PilotRetryDelay {
    param([int] $Attempt, [int] $RetryAfter = 0)
    # Never shorten the service's Retry-After. Jitter applies to fallback only.
    if ($RetryAfter -gt 0) { return $RetryAfter }
    return [Math]::Min(60, 5 * [Math]::Pow(2, $Attempt - 1) + (Get-Random -Minimum 0 -Maximum 4))
}

function Invoke-PilotGraphBatch {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Requests)
    $results = @{}
    for ($offset = 0; $offset -lt $Requests.Count; $offset += 20) {
        $last = [Math]::Min($offset + 19, $Requests.Count - 1)
        $pending = @($Requests[$offset..$last])
        $authRefreshed = $false
        for ($attempt = 1; $pending.Count -gt 0; $attempt++) {
            $script:batchSubrequestCount += $pending.Count
            $response = Invoke-PilotGraph -Method Post -Uri '/$batch' -Body @{ requests = $pending }
            $responses = Get-PilotProperty $response 'responses'
            if ($null -eq $responses) { throw 'Graph $batch response had no responses collection.' }
            $retry = New-Object 'System.Collections.Generic.List[object]'
            $delay = 0
            $refreshAuth = $false
            $seenIds = @{}
            foreach ($item in $responses) {
                $id = [string](Get-PilotProperty $item 'id')
                $status = [int](Get-PilotProperty $item 'status')
                $request = $pending | Where-Object { $_.id -eq $id } | Select-Object -First 1
                if (-not $request -or $seenIds.ContainsKey($id)) { throw "Graph batch returned an unexpected or duplicate response id: $id" }
                $seenIds[$id] = $true
                if ($status -eq 401 -and $script:graphSession.Mode -eq 'ManagedIdentity' -and -not $authRefreshed) {
                    $refreshAuth = $true
                    $retry.Add($request)
                    continue
                }
                if ($script:retryableStatusCodes -contains $status -and $attempt -lt $script:maxGraphAttempts) {
                    $retry.Add($request)
                    $parsedRetryAfter = 0
                    $retryAfterHeader = Get-PilotProperty (Get-PilotProperty $item 'headers') 'Retry-After'
                    if ([int]::TryParse([string]$retryAfterHeader, [ref]$parsedRetryAfter)) { $delay = [Math]::Max($delay, $parsedRetryAfter) }
                    continue
                }
                $results[$id] = [pscustomobject]@{ Status = $status; Body = (Get-PilotProperty $item 'body') }
            }
            foreach ($request in $pending) {
                if (-not $seenIds.ContainsKey([string]$request.id)) { throw "Graph batch omitted response $($request.id)." }
            }
            if ($refreshAuth) {
                $script:graphSession = Connect-PilotGraph
                $authRefreshed = $true
            }
            if ($retry.Count -gt 0) {
                $delay = Get-PilotRetryDelay -Attempt $attempt -RetryAfter $delay
                Write-Warning "$($retry.Count) batched request(s) will be retried in ${delay}s."
                Start-Sleep -Seconds $delay
            }
            $pending = @($retry.ToArray())
        }
    }
    foreach ($request in $Requests) {
        if (-not $results.ContainsKey([string]$request.id)) { throw "Graph batch returned no response for request $($request.id) ($($request.url))." }
    }
    return $results
}

function ConvertTo-PilotInstallState {
    param($Value)
    if ($null -eq $Value) { return 'unknown' }
    $text = ([string]$Value).Trim()
    $number = 0
    if ([int]::TryParse($text, [ref]$number)) {
        switch ($number) {
            1 { return 'installed' }
            2 { return 'failed' }
            3 { return 'notInstalled' }
            4 { return 'uninstallFailed' }
            5 { return 'pendingInstall' }
            -1 { return 'notApplicable' }
            default { return 'unknown' }
        }
    }
    switch ($text.Replace(' ', '').ToLowerInvariant()) {
        'installed' { return 'installed' }
        'failed' { return 'failed' }
        'notinstalled' { return 'notInstalled' }
        'uninstallfailed' { return 'uninstallFailed' }
        'pendinginstall' { return 'pendingInstall' }
        'notapplicable' { return 'notApplicable' }
        default { return 'unknown' }
    }
}

function Get-PilotInstallReport {
    param([Parameter(Mandatory)] [string] $AppId, [Parameter(Mandatory)] [string] $Action)
    $uri = "$script:graphRoot/beta/deviceManagement/reports/$Action"
    $pageSize = 500
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seenRows = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $totalRows = -1
    for ($skip = 0; ; ) {
        $body = @{
            filter = "(ApplicationId eq '$AppId')"
            select = @('DeviceId', 'DeviceName', 'UserPrincipalName', 'InstallState', 'LastModifiedDateTime')
            skip = $skip; top = $pageSize; orderBy = @('DeviceId asc', 'UserPrincipalName asc')
        }
        $response = Invoke-PilotGraph -Method Post -Uri $uri -Body $body
        $schemaProperty = if ($null -ne $response) { $response.PSObject.Properties['Schema'] } else { $null }
        $valuesProperty = if ($null -ne $response) { $response.PSObject.Properties['Values'] } else { $null }
        if (-not $schemaProperty -or -not $valuesProperty) { throw 'Install status report response is missing Schema or Values.' }
        $reportedTotal = 0
        $totalValue = Get-PilotProperty $response 'TotalRowCount'
        if ($null -eq $totalValue -or -not [int]::TryParse([string]$totalValue, [ref]$reportedTotal) -or $reportedTotal -lt 0) {
            throw 'Install status report is missing a valid TotalRowCount. Refusing to export unverified data.'
        }
        if ($totalRows -ge 0 -and $totalRows -ne $reportedTotal) { throw 'Install status report changed during pagination. Rerun after reporting settles.' }
        $totalRows = $reportedTotal
        $columnIndex = @{}
        $index = 0
        foreach ($column in $schemaProperty.Value) { $columnIndex[[string](Get-PilotProperty $column 'Column')] = $index; $index++ }
        foreach ($required in @('DeviceId', 'InstallState', 'UserPrincipalName')) {
            if (-not $columnIndex.ContainsKey($required)) { throw "Install status report is missing the '$required' column." }
        }
        $pageCount = 0
        foreach ($row in $valuesProperty.Value) {
            $pageCount++
            $mappedRow = [pscustomobject]@{
                DeviceId = [string]$row[$columnIndex['DeviceId']]
                DeviceName = if ($columnIndex.ContainsKey('DeviceName')) { [string]$row[$columnIndex['DeviceName']] } else { '' }
                UserPrincipalName = if ($columnIndex.ContainsKey('UserPrincipalName')) { [string]$row[$columnIndex['UserPrincipalName']] } else { '' }
                InstallState = ConvertTo-PilotInstallState $row[$columnIndex['InstallState']]
                LastModified = if ($columnIndex.ContainsKey('LastModifiedDateTime')) { $row[$columnIndex['LastModifiedDateTime']] } else { $null }
            }
            # A device can legitimately appear once per signed-in user. Do not
            # dedupe by DeviceId alone; repeated complete rows indicate unstable
            # paging. The report UPN is used only here, never exported.
            $rowKey = '{0}|{1}|{2}|{3}|{4}' -f $mappedRow.DeviceId, $mappedRow.DeviceName, $mappedRow.UserPrincipalName, $mappedRow.InstallState, [string]$mappedRow.LastModified
            if (-not $seenRows.Add($rowKey)) { throw 'Install status report contains repeated rows. Refusing a potentially incomplete population; rerun the query.' }
            $rows.Add($mappedRow)
        }
        if ($rows.Count -ge $totalRows -or $pageCount -eq 0) { break }
        # Advance by actual rows returned; some report actions cap top below 500.
        $skip += $pageCount
    }
    if ($totalRows -ge 0 -and $rows.Count -ne $totalRows) {
        throw "Install status report is incomplete: collected $($rows.Count) of $totalRows rows. Refusing to export partial data."
    }
    return $rows.ToArray()
}

function ConvertTo-PilotVersion {
    # Parses the leading dotted number of an inventory version string:
    # '23.01' -> 23.1, '12' -> 12.0, '1.2.3-beta' -> 1.2.3. Returns $null otherwise.
    param([AllowNull()] [AllowEmptyString()] [string] $Value)
    if ($null -eq $Value -or $Value.Trim() -notmatch '^\d+(\.\d+){0,3}') { return $null }
    $parts = @($Matches[0].Split('.'))
    if ($parts.Count -eq 1) { $parts += '0' }
    $parsed = $null
    if ([version]::TryParse(($parts -join '.'), [ref]$parsed)) { return $parsed }
    return $null
}

function Test-PilotLowerVersion {
    # $null sorts above every parsed version, so a parsed version always wins.
    param([version] $Candidate, [version] $Current)
    if ($null -eq $Candidate) { return $false }
    return ($null -eq $Current -or $Candidate -lt $Current)
}

function Get-PilotSearchTerm {
    # Longest literal run in a -like pattern ('7-Zip*' -> '7-Zip'), used only to
    # narrow the server query. Returns '' when nothing useful remains.
    param([Parameter(Mandatory)] [string] $Pattern)
    $term = @($Pattern -split '[*?\[\]`]' | Sort-Object Length -Descending | Select-Object -First 1)[0]
    if ($null -eq $term -or $term.Trim().Length -lt 2) { return '' }
    return $term
}

function Get-PilotDetectedApp {
    # Discovered-app inventory has one record per name/version/platform. The
    # server-side contains() filter only narrows the download; the -like,
    # platform, and version checks below decide what matches.
    param(
        [Parameter(Mandatory)] [string] $NamePattern,
        [Parameter(Mandatory)] [string] $Platform,
        [version] $MinVersion,
        [version] $MaxVersion
    )
    $baseUri = "$script:graphRoot/beta/deviceManagement/detectedApps?`$select=id,displayName,version,platform,deviceCount&`$top=1000"
    $term = Get-PilotSearchTerm -Pattern $NamePattern
    $apps = $null
    if ($term) {
        $filter = [uri]::EscapeDataString("contains(displayName,'$($term.Replace("'", "''"))')")
        $first = Invoke-PilotGraph -Method Get -Uri "$baseUri&`$filter=$filter" -AllowStatus 400
        if ($null -ne $first -and $first.PSObject.Properties['value']) {
            $apps = @($first.value)
            $nextUri = [string](Get-PilotProperty $first '@odata.nextLink')
            if ($nextUri) { $apps += @(Get-PilotGraphPaged -Uri $nextUri) }
            # An empty filtered result may mean the filter is case-sensitive or
            # ignored; confirm against the full inventory rather than trust it.
            if ($apps.Count -eq 0) { $apps = $null }
        }
        if ($null -eq $apps) { Write-Warning "Server-side search for '$term' returned nothing usable; scanning the full discovered-app inventory." }
    }
    if ($null -eq $apps) { $apps = @(Get-PilotGraphPaged -Uri $baseUri) }
    $matched = New-Object 'System.Collections.Generic.List[object]'
    $unparsed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($app in $apps) {
        $name = [string](Get-PilotProperty $app 'displayName')
        if ($name -notlike $NamePattern -or [string](Get-PilotProperty $app 'platform') -ne $Platform) { continue }
        $versionText = [string](Get-PilotProperty $app 'version')
        $version = ConvertTo-PilotVersion $versionText
        if ($MinVersion -or $MaxVersion) {
            if ($null -eq $version) { $unparsed.Add("$name ($versionText)"); continue }
            if ($MinVersion -and $version -lt $MinVersion) { continue }
            if ($MaxVersion -and $version -ge $MaxVersion) { continue }
        }
        $matched.Add([pscustomobject]@{
            Id = [string](Get-PilotProperty $app 'id')
            DisplayName = $name
            Version = $versionText
            ParsedVersion = $version
            DeviceCount = Get-PilotProperty $app 'deviceCount'
        })
    }
    if ($unparsed.Count -gt 0) {
        Write-Warning ('Excluded {0} matching app record(s) with unparseable versions: {1}' -f $unparsed.Count, ($unparsed -join '; '))
    }
    return $matched.ToArray()
}

function ConvertTo-PilotTimestamp {
    # Graph timestamps may arrive as ISO strings or, after PowerShell 7's
    # ConvertFrom-Json, as DateTime. Missing or year-1 values ("never") -> MinValue.
    param($Value)
    $parsed = [DateTimeOffset]::MinValue
    if ($Value -is [DateTime]) {
        $utc = if ($Value.Kind -eq [DateTimeKind]::Unspecified) { [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
        $parsed = [DateTimeOffset]$utc
    }
    elseif ($Value -is [DateTimeOffset]) { $parsed = $Value }
    elseif (-not [DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return [DateTimeOffset]::MinValue
    }
    if ($parsed.Year -le 1) { return [DateTimeOffset]::MinValue }
    return $parsed
}

function Format-PilotTimestamp {
    param([DateTimeOffset] $Value)
    if ($Value -eq [DateTimeOffset]::MinValue -or $Value -eq [DateTimeOffset]::MaxValue) { return '' }
    return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-PilotDeviceIndex {
    # Lists a whole device collection once and keys it for in-memory lookups.
    param([Parameter(Mandatory)] [string] $Uri, [Parameter(Mandatory)] [string] $KeyProperty, [switch] $GuidKey)
    $index = @{}
    foreach ($item in @(Get-PilotGraphPaged -Uri $Uri)) {
        $key = [string](Get-PilotProperty $item $KeyProperty)
        if ($GuidKey) {
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse($key, [ref]$parsed)) { continue }
            $key = $parsed.ToString('D')
        }
        if (-not $key) { continue }
        if ($index.ContainsKey($key)) { throw "Device listing returned duplicate $KeyProperty '$key'. Refusing a potentially unstable population; rerun." }
        $index[$key] = $item
    }
    return $index
}

function Resolve-PilotManagedDevice {
    # Returns Intune id -> managed device (or $null when it no longer exists).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Ids, [Parameter(Mandatory)] [string] $Mode)
    $resolved = @{}
    if ($Mode -eq 'Bulk') {
        $index = Get-PilotDeviceIndex -Uri "$script:graphBase/deviceManagement/managedDevices?`$select=id,azureADDeviceId,deviceName,userPrincipalName,lastSyncDateTime&`$top=1000" -KeyProperty 'id'
        foreach ($id in $Ids) { $resolved[$id] = if ($index.ContainsKey($id)) { $index[$id] } else { $null } }
        return $resolved
    }
    $requests = @(for ($i = 0; $i -lt $Ids.Count; $i++) {
        @{ id = [string]$i; method = 'GET'; url = "/deviceManagement/managedDevices/$($Ids[$i])?`$select=id,azureADDeviceId,deviceName,userPrincipalName,lastSyncDateTime" }
    })
    $results = Invoke-PilotGraphBatch -Requests $requests
    for ($i = 0; $i -lt $Ids.Count; $i++) {
        $result = $results[[string]$i]
        if ($result.Status -eq 404) { $resolved[$Ids[$i]] = $null; continue }
        if ($result.Status -ne 200) { throw "Managed device lookup for $($Ids[$i]) failed with HTTP $($result.Status)." }
        $resolved[$Ids[$i]] = $result.Body
    }
    return $resolved
}

function Resolve-PilotEntraDevice {
    # Returns canonical Entra deviceId -> device object (or $null when missing).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $DeviceIds, [Parameter(Mandatory)] [string] $Mode)
    $resolved = @{}
    if ($Mode -eq 'Bulk') {
        $index = Get-PilotDeviceIndex -Uri "$script:graphBase/devices?`$select=id,deviceId,approximateLastSignInDateTime&`$top=999" -KeyProperty 'deviceId' -GuidKey
        foreach ($id in $DeviceIds) { $resolved[$id] = if ($index.ContainsKey($id)) { $index[$id] } else { $null } }
        return $resolved
    }
    $requests = @(for ($i = 0; $i -lt $DeviceIds.Count; $i++) {
        @{ id = [string]$i; method = 'GET'; url = "/devices(deviceId='$($DeviceIds[$i])')?`$select=id,deviceId,approximateLastSignInDateTime" }
    })
    $results = Invoke-PilotGraphBatch -Requests $requests
    for ($i = 0; $i -lt $DeviceIds.Count; $i++) {
        $result = $results[[string]$i]
        if ($result.Status -eq 404) { $resolved[$DeviceIds[$i]] = $null; continue }
        if ($result.Status -ne 200) { throw "Entra device lookup for $($DeviceIds[$i]) failed with HTTP $($result.Status)." }
        $resolved[$DeviceIds[$i]] = $result.Body
    }
    return $resolved
}

function Get-RolloutPhaseCount {
    param([int] $DeviceCount, [int[]] $Percentages)
    $allocations = @(for ($i = 0; $i -lt $Percentages.Count; $i++) {
        $product = [long]$DeviceCount * $Percentages[$i]
        [pscustomobject]@{ Index = $i; Count = [int][Math]::Floor($product / 100.0); Remainder = $product % 100 }
    })
    $remaining = $DeviceCount - ($allocations | Measure-Object Count -Sum).Sum
    $ranked = @($allocations | Sort-Object @{ Expression = 'Remainder'; Descending = $true }, Index)
    for ($i = 0; $i -lt $remaining; $i++) { $ranked[$i].Count++ }
    return @($allocations | ForEach-Object { $_.Count })
}

Write-Information 'Phased rollout creator' -InformationAction Continue
$script:graphSession = Connect-PilotGraph -TenantId $TenantId -Scopes $requiredScopes -DeviceCode:$UseDeviceCode
Write-Information ('Connected to Microsoft Graph as {0} ({1}).' -f $script:graphSession.Account, $script:graphSession.Mode) -InformationAction Continue
# Intune lastSyncDateTime ("Last check-in") decides activity; Entra's
# approximateLastSignInDateTime lags by up to ~14 days and is reference only.
$activeCutoff = if ($ActiveWithinDays -gt 0) { [DateTimeOffset]::UtcNow.AddDays(-$ActiveWithinDays) } else { [DateTimeOffset]::MinValue }
if ($ActiveWithinDays -gt 0) { Write-Information "Active cutoff: Intune check-in on or after $(Format-PilotTimestamp $activeCutoff) ($ActiveWithinDays days)." -InformationAction Continue }
# Report/inventory rows only decide which devices qualify. Signed-in user UPNs
# from those rows are discarded; the exported UPN is the device's current Intune
# primary user, read from the managed device below.
$intuneDevices = @{}
if ($PSCmdlet.ParameterSetName -eq 'DetectedApp') {
    # Version parameters are strings so '-MaxVersion 12' works; [version] needs two parts.
    $minBound = if ($MinVersion) { ConvertTo-PilotVersion $MinVersion } else { $null }
    $maxBound = if ($MaxVersion) { ConvertTo-PilotVersion $MaxVersion } else { $null }
    if ($minBound -and $maxBound -and $minBound -ge $maxBound) { throw 'MinVersion must be lower than MaxVersion.' }
    $apps = @(Get-PilotDetectedApp -NamePattern $AppName -Platform $Platform -MinVersion $minBound -MaxVersion $maxBound)
    if ($apps.Count -eq 0) { throw "No discovered $Platform apps match '$AppName' in the requested version range." }
    Write-Information "Matched $($apps.Count) discovered app record(s):" -InformationAction Continue
    foreach ($app in @($apps | Sort-Object ParsedVersion, DisplayName)) {
        Write-Information ('  {0} | {1} | {2} device(s)' -f $app.DisplayName, $app.Version, $app.DeviceCount) -InformationAction Continue
    }
    foreach ($app in $apps) {
        $deviceUri = "$script:graphRoot/beta/deviceManagement/detectedApps/$([uri]::EscapeDataString($app.Id))/managedDevices?`$select=id,deviceName"
        foreach ($device in @(Get-PilotGraphPaged -Uri $deviceUri)) {
            $managedId = [string](Get-PilotProperty $device 'id')
            if (-not $managedId) { continue }
            $existing = if ($intuneDevices.ContainsKey($managedId)) { $intuneDevices[$managedId] } else { $null }
            # A device with several matching versions reports its lowest one.
            if ($existing -and -not (Test-PilotLowerVersion -Candidate $app.ParsedVersion -Current $existing.ParsedVersion)) { continue }
            $intuneDevices[$managedId] = [pscustomobject]@{
                StatusLastModified = [DateTimeOffset]::MaxValue
                AppName = $app.DisplayName; AppVersion = $app.Version; ParsedVersion = $app.ParsedVersion
                InstallState = 'detected'
            }
        }
    }
}
else {
    $reportRows = @(Get-PilotInstallReport -AppId $JoinAppId -Action $InstallReportAction)
    Write-Information "Report rows: $($reportRows.Count)" -InformationAction Continue
    if ($reportRows.Count -eq 0) { throw 'Install status report returned no rows. Check JoinAppId and InstallReportAction.' }
    # Any installed row qualifies the device; retain the earliest status timestamp.
    foreach ($row in $reportRows) {
        if (-not $row.DeviceId -or $row.InstallState -ne 'installed') { continue }
        if (-not $intuneDevices.ContainsKey($row.DeviceId)) {
            $intuneDevices[$row.DeviceId] = [pscustomobject]@{
                StatusLastModified = [DateTimeOffset]::MaxValue
                AppName = ''; AppVersion = ''; ParsedVersion = $null
                InstallState = 'installed'
            }
        }
        $parsed = ConvertTo-PilotTimestamp $row.LastModified
        if ($parsed -ne [DateTimeOffset]::MinValue -and $parsed -lt $intuneDevices[$row.DeviceId].StatusLastModified) {
            $intuneDevices[$row.DeviceId].StatusLastModified = $parsed
        }
    }
}
[string[]] $lookupIds = @($intuneDevices.Keys)
[Array]::Sort($lookupIds, [StringComparer]::OrdinalIgnoreCase)
$matchingCount = $lookupIds.Count
Write-Information "Matching Intune devices: $matchingCount" -InformationAction Continue
if ($MaxDevices -and $matchingCount -gt $MaxDevices) {
    # Sorted ids keep the sample stable between validation runs.
    $lookupIds = @($lookupIds[0..($MaxDevices - 1)])
    Write-Information "Sampled $($lookupIds.Count) of $matchingCount matching devices (-MaxDevices)." -InformationAction Continue
}
# Per-device batches cost one throttled request per device; listing both
# directories costs one call per 1,000 devices regardless of match count.
$lookupMode = $DeviceLookup
if ($lookupMode -eq 'Auto') { $lookupMode = if ($lookupIds.Count -gt $script:bulkLookupThreshold) { 'Bulk' } else { 'Batch' } }
Write-Information "Device lookup: $lookupMode ($($lookupIds.Count) device(s); -DeviceLookup $DeviceLookup)." -InformationAction Continue
$managedDevices = Resolve-PilotManagedDevice -Ids $lookupIds -Mode $lookupMode
$entraDevices = @{}
for ($i = 0; $i -lt $lookupIds.Count; $i++) {
    $managed = $managedDevices[$lookupIds[$i]]
    if ($null -eq $managed) { Write-Information "SKIP (managed device gone): $($lookupIds[$i])" -InformationAction Continue; continue }
    $deviceId = [string](Get-PilotProperty $managed 'azureADDeviceId')
    $deviceName = [string](Get-PilotProperty $managed 'deviceName')
    if (-not $deviceId -or $deviceId -eq $script:emptyGuid) { Write-Information "SKIP (no Entra device id): $deviceName" -InformationAction Continue; continue }
    $deviceId = ([guid]$deviceId).ToString('D')
    $match = $intuneDevices[$lookupIds[$i]]
    $primaryUser = [string](Get-PilotProperty $managed 'userPrincipalName')
    $lastCheckIn = ConvertTo-PilotTimestamp (Get-PilotProperty $managed 'lastSyncDateTime')
    # Deduplicate Entra identity across Intune records before phase allocation.
    if (-not $entraDevices.ContainsKey($deviceId)) {
        $entraDevices[$deviceId] = [pscustomobject]@{
            DeviceName = $deviceName
            PrimaryUserPrincipalName = $primaryUser
            IntuneManagedDeviceId = $lookupIds[$i]
            StatusLastModified = $match.StatusLastModified
            AppName = $match.AppName; AppVersion = $match.AppVersion; ParsedVersion = $match.ParsedVersion
            InstallState = $match.InstallState
            LastCheckIn = $lastCheckIn
        }
        continue
    }
    $entry = $entraDevices[$deviceId]
    if (-not $entry.PrimaryUserPrincipalName) { $entry.PrimaryUserPrincipalName = $primaryUser }
    # The most recent check-in across Intune records represents the device.
    if ($lastCheckIn -gt $entry.LastCheckIn) { $entry.LastCheckIn = $lastCheckIn }
    if ($match.StatusLastModified -lt $entry.StatusLastModified) { $entry.StatusLastModified = $match.StatusLastModified }
    if (Test-PilotLowerVersion -Candidate $match.ParsedVersion -Current $entry.ParsedVersion) {
        $entry.AppName = $match.AppName; $entry.AppVersion = $match.AppVersion; $entry.ParsedVersion = $match.ParsedVersion
    }
}
$noPrimaryUser = @($entraDevices.Keys | Where-Object { -not $entraDevices[$_].PrimaryUserPrincipalName })
if ($noPrimaryUser.Count -gt 0) {
    if ($RequirePrimaryUser) {
        foreach ($key in $noPrimaryUser) {
            Write-Information "SKIP (no primary user): $($entraDevices[$key].DeviceName)" -InformationAction Continue
            $entraDevices.Remove($key)
        }
    }
    else { Write-Warning "$($noPrimaryUser.Count) device(s) have no Intune primary user; their UPN is blank. Use -RequirePrimaryUser to skip them." }
}
[string[]] $deviceIds = @($entraDevices.Keys)
[Array]::Sort($deviceIds, [StringComparer]::Ordinal)
$entraObjects = Resolve-PilotEntraDevice -DeviceIds $deviceIds -Mode $lookupMode
$resolvedRows = New-Object 'System.Collections.Generic.List[object]'
for ($i = 0; $i -lt $deviceIds.Count; $i++) {
    $info = $entraDevices[$deviceIds[$i]]
    $entraObject = $entraObjects[$deviceIds[$i]]
    if ($null -eq $entraObject) { Write-Information "SKIP (no Entra device object): $($info.DeviceName) ($($deviceIds[$i]))" -InformationAction Continue; continue }
    $objectId = [string](Get-PilotProperty $entraObject 'id')
    if (-not $objectId) { throw "Entra device lookup for $($deviceIds[$i]) returned no object ID." }
    $resolvedRows.Add([pscustomobject]@{
        Phase = 0
        PhaseLabel = ''
        DeviceName = $info.DeviceName
        EntraObjectId = $objectId
        EntraDeviceId = $deviceIds[$i]
        IntuneManagedDeviceId = $info.IntuneManagedDeviceId
        PrimaryUserPrincipalName = $info.PrimaryUserPrincipalName
        AppName = $info.AppName
        AppVersion = $info.AppVersion
        InstallState = $info.InstallState
        StatusLastModified = if ($info.StatusLastModified -ne [DateTimeOffset]::MaxValue) { $info.StatusLastModified.ToString('o') } else { '' }
        ActivityState = if ($ActiveWithinDays -eq 0 -or ($info.LastCheckIn -ne [DateTimeOffset]::MinValue -and $info.LastCheckIn -ge $activeCutoff)) { 'Active' } else { 'Inactive' }
        LastCheckIn = Format-PilotTimestamp $info.LastCheckIn
        EntraApproxLastSignIn = Format-PilotTimestamp (ConvertTo-PilotTimestamp (Get-PilotProperty $entraObject 'approximateLastSignInDateTime'))
    })
}
# deviceIds are canonical GUID strings, sorted ordinally before resolution.
# Filtering that sequence preserves its culture-independent order.
# Only active devices are phased; inactive ones follow, still in GUID order.
$activeRows = @($resolvedRows | Where-Object { $_.ActivityState -eq 'Active' })
$inactiveRows = @($resolvedRows | Where-Object { $_.ActivityState -eq 'Inactive' })
$inactiveLabel = 'Inactive (no check-in for {0}+ days)' -f $ActiveWithinDays
foreach ($row in $inactiveRows) { $row.PhaseLabel = $inactiveLabel }
$exportRows = @($activeRows + $inactiveRows)
if ($exportRows.Count -eq 0) { Write-Warning 'No matching devices resolved. Exports will contain headers only.' }
Write-Information "Active: $($activeRows.Count), Inactive: $($inactiveRows.Count)." -InformationAction Continue
if ($MaxDevices -and $exportRows.Count -lt [Math]::Min($MaxDevices, $matchingCount)) {
    Write-Warning "Sample resolved $($exportRows.Count) of $([Math]::Min($MaxDevices, $matchingCount)) requested device(s); see SKIP lines."
}
$phaseCounts = @(Get-RolloutPhaseCount -DeviceCount $activeRows.Count -Percentages $PhasePercentages)
$offset = 0
for ($phase = 0; $phase -lt $PhasePercentages.Count; $phase++) {
    for ($i = 0; $i -lt $phaseCounts[$phase]; $i++) {
        $activeRows[$offset].Phase = $phase + 1
        $activeRows[$offset].PhaseLabel = 'Phase {0} ({1}%)' -f ($phase + 1), $PhasePercentages[$phase]
        $offset++
    }
    Write-Information ('Phase {0} ({1}%): {2} device(s).' -f ($phase + 1), $PhasePercentages[$phase], $phaseCounts[$phase]) -InformationAction Continue
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
# Label sample exports so they are not mistaken for a full population.
if ($MaxDevices) { $stamp = "sample$MaxDevices-$stamp" }
$detailColumns = @('Phase', 'PhaseLabel', 'DeviceName', 'EntraObjectId', 'EntraDeviceId', 'IntuneManagedDeviceId',
    'PrimaryUserPrincipalName', 'AppName', 'AppVersion', 'InstallState', 'StatusLastModified', 'ActivityState', 'LastCheckIn', 'EntraApproxLastSignIn')
$detailPath = Join-Path $ExportDirectory "PhasedRolloutDetail-$stamp.csv"
$importHeader = 'Member object ID or user principal name [memberObjectIdOrUpn] Required'
if ($PSCmdlet.ShouldProcess($ExportDirectory, 'Export phased device detail, per-phase, and inactive Entra bulk-import CSVs')) {
    if (-not (Test-Path -LiteralPath $ExportDirectory -PathType Container)) {
        New-Item -Path $ExportDirectory -ItemType Directory -Force | Out-Null
    }
    if ($exportRows.Count -gt 0) { $exportRows | Select-Object $detailColumns | Export-Csv -LiteralPath $detailPath -NoTypeInformation -Encoding UTF8 }
    else { ($detailColumns | ForEach-Object { '"{0}"' -f $_ }) -join ',' | Set-Content -LiteralPath $detailPath -Encoding UTF8 }
    Write-Information "Detail CSV: $detailPath" -InformationAction Continue
    for ($phase = 1; $phase -le $PhasePercentages.Count; $phase++) {
        $importPath = Join-Path $ExportDirectory "Phase$phase-EntraGroupImport-$stamp.csv"
        @($importHeader) + @($exportRows | Where-Object { $_.Phase -eq $phase } | ForEach-Object { $_.EntraObjectId }) |
            Set-Content -LiteralPath $importPath -Encoding UTF8
        Write-Information "Phase $phase import CSV: $importPath" -InformationAction Continue
    }
    $inactivePath = Join-Path $ExportDirectory "Inactive-EntraGroupImport-$stamp.csv"
    @($importHeader) + @($inactiveRows | ForEach-Object { $_.EntraObjectId }) | Set-Content -LiteralPath $inactivePath -Encoding UTF8
    Write-Information "Inactive import CSV: $inactivePath" -InformationAction Continue
}
Write-Information "Resolved devices: $($exportRows.Count)" -InformationAction Continue
Write-Information "Graph HTTP calls: $script:graphCallCount (batch subrequests: $script:batchSubrequestCount)." -InformationAction Continue
