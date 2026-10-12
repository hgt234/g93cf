#requires -Version 5.1
<#
.SYNOPSIS
Reconciles an Entra pilot device group from Intune app install status.

.DESCRIPTION
State-based reconciler for the EUC Early Adopter pilot program.

- Devices whose Join app reports 'installed' and that checked in to Intune
  within -ActiveWithinDays are added to the pilot group, first come first
  served up to -MemberCap.
- Devices reporting 'notInstalled' or 'notApplicable', that no longer appear
  in the report or in Intune, or that have not checked in within
  -ActiveWithinDays, are removed.
- Transient states ('pendingInstall', 'failed', 'uninstallFailed', 'unknown')
  hold an active device where it is: kept if already a member, not added if not.
- The optional comms group holds the Intune primary users of the planned
  pilot devices (owners are never removed).

Safety rails:
- Any Graph failure halts the run before or between writes; an error is never
  treated as an empty desired state.
- The install report must return a valid TotalRowCount that stays constant
  across pages, with no repeated rows, or the run stops before any write.
- A report with zero rows never removes anyone.
- Removals above -MaxRemovals (pilot or comms) abort the run before any write.
- Dynamic, on-premises-synced, or Microsoft 365 pilot groups are rejected.
- Every membership change goes through ShouldProcess with ConfirmImpact High:
  interactive runs prompt unless -Force or -Confirm:$false is given.

Authentication branches:
- Azure Automation (production): system-assigned managed identity via
  IDENTITY_ENDPOINT, raw REST, no module dependencies. Requires -Force (the
  Automation host cannot answer confirmation prompts).
- Interactive (POC): Connect-MgGraph with MFA/Conditional Access; requires
  the Microsoft.Graph.Authentication module.

.PARAMETER JoinAppId
Intune Join app (mobileApp) object ID.

.PARAMETER PilotGroupId
Assigned security group that receives pilot devices. Required unless -ReadOnly.

.PARAMETER CommsGroupId
Optional dedicated user group for pilot communications.

.PARAMETER ActiveWithinDays
Devices whose last Intune check-in (lastSyncDateTime) is older than this many
days, or that never checked in, are treated as inactive: never added, and
removed if already members, so they do not hold MemberCap slots. 0 disables.

.PARAMETER DeviceLookup
How devices are resolved. Batch looks up each device (20 per $batch call);
Bulk lists all Intune and Entra devices once (1,000 per page). Auto uses Bulk
above 1,000 devices.

.PARAMETER Force
Suppresses confirmation prompts for membership changes and exports. Required
for unattended runs such as Azure Automation schedules.

.PARAMETER TeamsWebhookUri
A Teams Workflows webhook URL to post the run summary to. Convenient for
local runs; do NOT use this in Azure Automation, where parameter values are
recorded in job history - use -TeamsWebhookVariable there instead.

.PARAMETER TeamsWebhookVariable
Name of an Azure Automation encrypted variable (or, for local runs, an
environment variable) holding a Teams Workflows webhook URL. The URL itself
is never passed as a parameter so it does not appear in job history.

.PARAMETER ReadOnly
Exports resolved, active, installed devices without reading or changing
groups. Requests only Intune app/managed-device and Entra device read scopes.
Writes local CSVs.

.PARAMETER ExportDirectory
Directory for the detail and Entra bulk-import CSVs in ReadOnly mode. Defaults
to the current directory. MemberCap does not limit this export.

.EXAMPLE
.\Sync-EucPilotGroup.ps1 -JoinAppId <mobileApp-guid> -PilotGroupId <group-guid> -WhatIf

.EXAMPLE
.\Sync-EucPilotGroup.ps1 -JoinAppId <mobileApp-guid> -PilotGroupId <group-guid> -CommsGroupId <group-guid> -Force

.EXAMPLE
.\Sync-EucPilotGroup.ps1 -JoinAppId <mobileApp-guid> -ReadOnly -ExportDirectory C:\Temp\EucPilot
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $JoinAppId,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $PilotGroupId,

    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $CommsGroupId,

    [switch] $ReadOnly,

    [ValidateNotNullOrEmpty()]
    [string] $ExportDirectory = '.',

    # Maximum pilot devices. 0 = no cap.
    [ValidateRange(0, 100000)]
    [int] $MemberCap = 50,

    # Abort the whole run if more than this many removals are planned for
    # either group. 0 = abort on any removal.
    [ValidateRange(0, 100000)]
    [int] $MaxRemovals = 10,

    [ValidateRange(0, 3650)]
    [int] $ActiveWithinDays = 30,

    [ValidateSet('Auto', 'Batch', 'Bulk')]
    [string] $DeviceLookup = 'Auto',

    [switch] $Force,

    [string] $TeamsWebhookUri,

    [string] $TeamsWebhookVariable,

    [string] $TenantId,

    # Sign in with the device code flow (type a code at a URL) instead of the
    # interactive browser/WAM prompt, which can hang on locked-down hosts.
    [switch] $UseDeviceCode,

    [ValidateSet('retrieveDeviceAppInstallationStatusReport', 'getDeviceInstallStatusReport')]
    [string] $InstallReportAction = 'retrieveDeviceAppInstallationStatusReport'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $ReadOnly -and -not $PilotGroupId) {
    throw 'PilotGroupId is required unless -ReadOnly is specified.'
}
# Standard -Force pattern: an explicit -Confirm still wins.
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $ConfirmPreference = 'None'
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

$requiredScopes = @(
    'DeviceManagementApps.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'Device.Read.All'
)
if (-not $ReadOnly) {
    # User.Read.All: without a user read permission, group member listings
    # return users with only id and @odata.type (Graph "limited information").
    $requiredScopes += @('User.Read.All', 'GroupMember.ReadWrite.All')
}

# ---------------------------------------------------------------------------
# Helpers. Functions never write to the output stream except their return
# value; diagnostics go to Write-Verbose / Write-Warning.
# This runbook is intentionally self-contained (single-file Automation import).
# PhasedRollout/phased-rollout-creator.ps1 carries its own read-only copy of
# the Graph layer; keep fixes to shared logic in step by hand.
# ---------------------------------------------------------------------------

function Get-PilotProperty {
    # StrictMode-safe property read for PSCustomObject and dictionaries.
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

function ConvertTo-PilotGuid {
    # Canonical lowercase 'D' form, or '' for missing, malformed, or empty GUIDs.
    param($Value)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) { return '' }
    return $parsed.ToString('D')
}

function Test-PilotBrokenAuthVersion {
    # Microsoft.Graph.Authentication 2.41.0/2.41.1 fail Connect-MgGraph with
    # "Could not load file or assembly 'System.Text.Json, Version=10.0.0.0'"
    # (microsoftgraph/msgraph-sdk-powershell#3810).
    param([Parameter(Mandatory)] [version] $Version)
    $normalized = [version]('{0}.{1}.{2}' -f $Version.Major, $Version.Minor, [Math]::Max(0, $Version.Build))
    return ($normalized -ge [version]'2.41.0' -and $normalized -le [version]'2.41.1')
}

function Import-PilotAuthModule {
    # Loads a working Microsoft.Graph.Authentication. A .NET process can hold
    # only one version of the module's assemblies, and Remove-Module does not
    # unload them, so whatever this session already loaded decides the outcome.
    $loadedAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.Graph.Authentication' } |
        Select-Object -First 1
    if ($loadedAssembly) {
        $loadedVersion = $loadedAssembly.GetName().Version
        if (Test-PilotBrokenAuthVersion -Version $loadedVersion) {
            throw ('This PowerShell session already loaded Microsoft.Graph.Authentication {0}, which cannot sign in (System.Text.Json bug #3810), and it cannot be unloaded. Close this window and run the script from a NEW PowerShell session (pwsh -NoProfile); it will load a working version.' -f
                $loadedVersion)
        }
        if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
            # Assemblies remain from an earlier Remove-Module; re-import the
            # matching installed version so the cmdlets bind to them.
            $matching = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
                Where-Object { $_.Version.Major -eq $loadedVersion.Major -and $_.Version.Minor -eq $loadedVersion.Minor -and $_.Version.Build -eq $loadedVersion.Build } |
                Select-Object -First 1
            if (-not $matching) {
                throw ('Microsoft.Graph.Authentication {0} assemblies are loaded but that version is not installed. Start a new PowerShell session.' -f $loadedVersion)
            }
            Import-Module $matching.Path
        }
        return
    }

    $installed = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)
    if ($installed.Count -eq 0) {
        throw 'Microsoft.Graph.Authentication is required for interactive sign-in. Run: Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser'
    }
    $usable = @($installed | Where-Object { -not (Test-PilotBrokenAuthVersion -Version $_.Version) } | Sort-Object Version -Descending)
    $broken = @($installed | Where-Object { Test-PilotBrokenAuthVersion -Version $_.Version } | ForEach-Object { $_.Version.ToString() })
    if ($usable.Count -eq 0) {
        throw ('Microsoft.Graph.Authentication {0} cannot sign in (System.Text.Json bug #3810). Install a working release alongside it: Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser -Force' -f
            ($broken -join ', '))
    }
    if ($broken.Count -gt 0) {
        Write-Warning ('Ignoring Microsoft.Graph.Authentication {0} (System.Text.Json bug #3810); using {1}.' -f
            ($broken -join ', '), $usable[0].Version)
    }
    Import-Module $usable[0].Path
}

function Connect-PilotGraph {
    param([string] $TenantId, [string[]] $Scopes, [switch] $DeviceCode)

    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $headers = @{
            'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
            'Metadata'          = 'True'
        }
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
        Write-Verbose ('Signing in with the device code flow ({0}).' -f $parameterName)
        $connectArgs[$parameterName] = $true
    }
    Connect-MgGraph @connectArgs | Out-Null

    $context = Get-MgContext
    if (-not $context -or -not $context.Account) {
        throw 'Connect-MgGraph did not produce an authenticated context.'
    }
    $missingScopes = @($Scopes | Where-Object { @($context.Scopes) -notcontains $_ })
    if ($missingScopes.Count -gt 0) {
        throw ('Signed-in session is missing required scopes: {0}' -f ($missingScopes -join ', '))
    }
    return [pscustomobject]@{ Mode = 'MgGraph'; Token = $null; Account = [string]$context.Account }
}

function ConvertFrom-PilotRetryAfter {
    # Retry-After is either delta-seconds or an HTTP-date (RFC 9110 10.2.3).
    # Returns whole seconds to wait, 0 when absent or unparseable.
    param($Value)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return 0 }
    $seconds = 0
    if ([int]::TryParse($text.Trim(), [ref]$seconds)) { return [Math]::Max(0, $seconds) }
    $date = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
        return [int][Math]::Max(0, [Math]::Ceiling(($date - [DateTimeOffset]::UtcNow).TotalSeconds))
    }
    return 0
}

function Get-PilotRetryAfterDelay {
    # Reads Retry-After from either header shape: WebHeaderCollection (Windows
    # PowerShell 5.1 HttpWebResponse) or HttpResponseHeaders (PowerShell 7 and
    # Invoke-MgGraphRequest), whose RetryAfter carries a Delta or a Date.
    param($Headers)
    try {
        if ($null -eq $Headers) { return 0 }
        if ($Headers -is [System.Net.WebHeaderCollection]) { return ConvertFrom-PilotRetryAfter $Headers['Retry-After'] }
        $retryAfter = Get-PilotProperty $Headers 'RetryAfter'
        if ($null -eq $retryAfter) { return 0 }
        if ($null -ne $retryAfter.Delta) { return [int][Math]::Max(0, [Math]::Ceiling($retryAfter.Delta.TotalSeconds)) }
        if ($null -ne $retryAfter.Date) { return [int][Math]::Max(0, [Math]::Ceiling(($retryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)) }
    }
    catch {
        Write-Verbose ('Could not read Retry-After header: {0}' -f $_.Exception.Message)
    }
    return 0
}

function Send-PilotGraphRequest {
    # One HTTP attempt. Returns status, Retry-After seconds, and raw body text
    # for both success and HTTP-error responses; throws only on transport
    # failures (DNS, TLS, connection reset).
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [string] $BodyJson
    )

    if ($script:graphSession.Mode -eq 'MgGraph') {
        $requestArgs = @{
            Method             = $Method
            Uri                = $Uri
            OutputType         = 'HttpResponseMessage'
            SkipHttpErrorCheck = $true
        }
        if ($BodyJson) {
            $requestArgs.Body = $BodyJson
            $requestArgs.ContentType = 'application/json'
        }
        $response = Invoke-MgGraphRequest @requestArgs
        try {
            $content = ''
            if ($null -ne $response.Content) {
                $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                RetryAfter = (Get-PilotRetryAfterDelay $response.Headers)
                Content    = $content
            }
        }
        finally {
            $response.Dispose()
        }
    }

    $webArgs = @{
        Method          = $Method
        Uri             = $Uri
        Headers         = @{ Authorization = "Bearer $($script:graphSession.Token)" }
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
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
        $content = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $content = $_.ErrorDetails.Message }
        return [pscustomobject]@{
            StatusCode = [int]$errorResponse.StatusCode
            RetryAfter = (Get-PilotRetryAfterDelay $errorResponse.Headers)
            Content    = $content
        }
    }
}

function Get-PilotRetryDelay {
    # Never shorten the service's Retry-After. Jitter applies to fallback only.
    param([int] $Attempt, [int] $RetryAfter = 0)
    if ($RetryAfter -gt 0) { return $RetryAfter }
    return [int][Math]::Min(60, 5 * [Math]::Pow(2, $Attempt - 1) + (Get-Random -Minimum 0 -Maximum 4))
}

function Invoke-PilotGraph {
    # Graph call with throttling/transient retry and one managed-identity
    # token refresh on HTTP 401. Returns the parsed JSON body ($null for empty
    # bodies). Non-retryable or exhausted failures throw an exception whose
    # Data carries StatusCode, ErrorCode, and ErrorMessage.
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body
    )
    $resolvedUri = if ($Uri.StartsWith('https://')) { $Uri } else { "$script:graphBase$Uri" }
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

        # Managed-identity tokens expire during long Automation jobs. A 401
        # means the request was not applied, so re-sending it is safe.
        if ($result.StatusCode -eq 401 -and $script:graphSession.Mode -eq 'ManagedIdentity' -and -not $authRefreshed) {
            Write-Warning 'Graph returned HTTP 401; refreshing the managed identity token once.'
            $script:graphSession = Connect-PilotGraph
            $authRefreshed = $true
            continue
        }

        if ($script:retryableStatusCodes -contains $result.StatusCode -and $attempt -lt $script:maxGraphAttempts) {
            $delay = Get-PilotRetryDelay -Attempt $attempt -RetryAfter $result.RetryAfter
            Write-Warning ('Graph {0} {1} returned HTTP {2}; retry {3} of {4} in {5}s.' -f
                $Method, $resolvedUri, $result.StatusCode, $attempt, ($script:maxGraphAttempts - 1), $delay)
            Start-Sleep -Seconds $delay
            continue
        }

        $errorCode = $null
        $errorMessage = $result.Content
        try {
            $errorBody = Get-PilotProperty ($result.Content | ConvertFrom-Json) 'error'
            if ($errorBody) {
                $errorCode = Get-PilotProperty $errorBody 'code'
                $errorMessage = Get-PilotProperty $errorBody 'message'
            }
        }
        catch {
            Write-Verbose 'Graph error body was not JSON.'
        }
        $exception = New-Object System.Exception ('Graph {0} {1} failed with HTTP {2} ({3}): {4}' -f
            $Method, $resolvedUri, $result.StatusCode, $errorCode, $errorMessage)
        $exception.Data['StatusCode'] = $result.StatusCode
        $exception.Data['ErrorCode'] = $errorCode
        $exception.Data['ErrorMessage'] = [string]$errorMessage
        throw $exception
    }
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

function Invoke-PilotGraphBatch {
    # Sends GET requests through /$batch in chunks of 20 and returns a
    # hashtable of request id -> { Status; Body }. Throttled/transient
    # sub-requests are retried and a 401 refreshes managed-identity auth once;
    # anything else is returned for the caller to judge. Unexpected, duplicate,
    # or missing response ids throw.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Requests
    )
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

            $pendingById = @{}
            foreach ($request in $pending) { $pendingById[[string]$request.id] = $request }
            $retry = New-Object 'System.Collections.Generic.List[object]'
            $delay = 0
            $refreshAuth = $false
            $seenIds = @{}
            foreach ($item in $responses) {
                $id = [string](Get-PilotProperty $item 'id')
                if (-not $pendingById.ContainsKey($id) -or $seenIds.ContainsKey($id)) {
                    throw "Graph batch returned an unexpected or duplicate response id: $id"
                }
                $seenIds[$id] = $true
                $request = $pendingById[$id]
                $status = [int](Get-PilotProperty $item 'status')
                if ($status -eq 401 -and $script:graphSession.Mode -eq 'ManagedIdentity' -and -not $authRefreshed) {
                    $refreshAuth = $true
                    $retry.Add($request)
                    continue
                }
                if ($script:retryableStatusCodes -contains $status -and $attempt -lt $script:maxGraphAttempts) {
                    $retry.Add($request)
                    $retryAfter = ConvertFrom-PilotRetryAfter (Get-PilotProperty (Get-PilotProperty $item 'headers') 'Retry-After')
                    $delay = [Math]::Max($delay, $retryAfter)
                    continue
                }
                $results[$id] = [pscustomobject]@{ Status = $status; Body = (Get-PilotProperty $item 'body') }
            }
            foreach ($id in $pendingById.Keys) {
                if (-not $seenIds.ContainsKey($id)) { throw "Graph batch omitted response $id." }
            }
            if ($refreshAuth) {
                $script:graphSession = Connect-PilotGraph
                $authRefreshed = $true
            }
            if ($retry.Count -gt 0) {
                $delay = Get-PilotRetryDelay -Attempt $attempt -RetryAfter $delay
                Write-Warning ('{0} batched request(s) will be retried in {1}s.' -f $retry.Count, $delay)
                Start-Sleep -Seconds $delay
            }
            $pending = @($retry.ToArray())
        }
    }
    foreach ($request in $Requests) {
        if (-not $results.ContainsKey([string]$request.id)) {
            throw ('Graph $batch returned no response for request {0} ({1}).' -f $request.id, $request.url)
        }
    }
    return $results
}

function ConvertTo-PilotInstallState {
    # Normalizes report InstallState (resultantAppState enum, numeric or
    # string) to a name. Anything unrecognized becomes 'unknown' (= hold).
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
    # Reads every row of the Intune device install status report for one app.
    # Fails closed: requires a valid TotalRowCount that stays constant across
    # pages, a stable sort, no repeated rows, and a final row count equal to
    # the total, so a partial report can never drive removals.
    param(
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [string] $Action
    )
    $uri = "$script:graphRoot/beta/deviceManagement/reports/$Action"
    $pageSize = 500
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seenRows = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $totalRows = -1

    for ($skip = 0; ; ) {
        $body = @{
            filter  = "(ApplicationId eq '$AppId')"
            select  = @('DeviceId', 'DeviceName', 'UserPrincipalName', 'InstallState', 'LastModifiedDateTime')
            skip    = $skip
            top     = $pageSize
            orderBy = @('DeviceId asc', 'UserPrincipalName asc')
        }
        $response = Invoke-PilotGraph -Method Post -Uri $uri -Body $body
        $schemaProperty = if ($null -ne $response) { $response.PSObject.Properties['Schema'] } else { $null }
        $valuesProperty = if ($null -ne $response) { $response.PSObject.Properties['Values'] } else { $null }
        if (-not $schemaProperty -or -not $valuesProperty) {
            throw 'Install status report response is missing Schema or Values.'
        }

        $reportedTotal = 0
        $totalValue = Get-PilotProperty $response 'TotalRowCount'
        if ($null -eq $totalValue -or -not [int]::TryParse([string]$totalValue, [ref]$reportedTotal) -or $reportedTotal -lt 0) {
            throw 'Install status report is missing a valid TotalRowCount. Refusing to reconcile on unverified data.'
        }
        if ($totalRows -ge 0 -and $totalRows -ne $reportedTotal) {
            throw 'Install status report changed during pagination. Nothing was changed; rerun after reporting settles.'
        }
        $totalRows = $reportedTotal

        $columnIndex = @{}
        $index = 0
        foreach ($column in $schemaProperty.Value) {
            $columnIndex[[string](Get-PilotProperty $column 'Column')] = $index
            $index++
        }
        foreach ($required in @('DeviceId', 'InstallState', 'UserPrincipalName')) {
            if (-not $columnIndex.ContainsKey($required)) {
                throw "Install status report is missing the '$required' column."
            }
        }

        $pageCount = 0
        foreach ($row in $valuesProperty.Value) {
            $pageCount++
            $mappedRow = [pscustomobject]@{
                DeviceId          = [string]$row[$columnIndex['DeviceId']]
                DeviceName        = if ($columnIndex.ContainsKey('DeviceName')) { [string]$row[$columnIndex['DeviceName']] } else { '' }
                UserPrincipalName = [string]$row[$columnIndex['UserPrincipalName']]
                InstallState      = ConvertTo-PilotInstallState $row[$columnIndex['InstallState']]
                LastModified      = if ($columnIndex.ContainsKey('LastModifiedDateTime')) { $row[$columnIndex['LastModifiedDateTime']] } else { $null }
            }
            # A device legitimately appears once per signed-in user, so rows are
            # not deduplicated by DeviceId. A repeated complete row means the
            # pages overlapped, which implies another row was skipped.
            $rowKey = '{0}|{1}|{2}|{3}|{4}' -f $mappedRow.DeviceId, $mappedRow.DeviceName, $mappedRow.UserPrincipalName, $mappedRow.InstallState, [string]$mappedRow.LastModified
            if (-not $seenRows.Add($rowKey)) {
                throw 'Install status report returned repeated rows (unstable paging). Nothing was changed; rerun.'
            }
            $rows.Add($mappedRow)
        }
        if ($rows.Count -ge $totalRows -or $pageCount -eq 0) { break }
        # Advance by the rows actually returned; the service can cap top below 500.
        $skip += $pageCount
    }

    if ($rows.Count -ne $totalRows) {
        throw ('Install status report is incomplete: collected {0} of {1} rows. Refusing to reconcile on partial data.' -f
            $rows.Count, $totalRows)
    }
    return $rows.ToArray()
}

function ConvertTo-PilotTimestamp {
    # Graph timestamps may arrive as ISO strings or, after PowerShell 7's
    # ConvertFrom-Json, as DateTime. Parsing is culture-invariant. Missing,
    # unparseable, or year-1 ("never") values return MinValue.
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

function Get-PilotLookupMode {
    # Per-device batches cost one throttled subrequest per device; listing a
    # directory costs one call per 1,000 objects regardless of match count.
    param([Parameter(Mandatory)] [string] $Requested, [Parameter(Mandatory)] [int] $Count)
    if ($Requested -ne 'Auto') { return $Requested }
    if ($Count -gt $script:bulkLookupThreshold) { return 'Bulk' }
    return 'Batch'
}

function Get-PilotDeviceIndex {
    # Lists a whole device collection once and keys it for in-memory lookups.
    param([Parameter(Mandatory)] [string] $Uri, [Parameter(Mandatory)] [string] $KeyProperty, [switch] $GuidKey)
    $index = @{}
    foreach ($item in @(Get-PilotGraphPaged -Uri $Uri)) {
        $key = [string](Get-PilotProperty $item $KeyProperty)
        if ($GuidKey) { $key = ConvertTo-PilotGuid $key }
        if (-not $key) { continue }
        if ($index.ContainsKey($key)) {
            throw "Device listing returned duplicate $KeyProperty '$key'. Refusing a potentially unstable population; rerun."
        }
        $index[$key] = $item
    }
    return $index
}

function Resolve-PilotManagedDevice {
    # Returns Intune id -> managed device (or $null when it no longer exists).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Ids, [Parameter(Mandatory)] [string] $Mode)
    $select = 'id,azureADDeviceId,deviceName,userPrincipalName,userId,lastSyncDateTime'
    $resolved = @{}
    if ($Ids.Count -eq 0) { return $resolved }
    if ($Mode -eq 'Bulk') {
        $index = Get-PilotDeviceIndex -Uri "/deviceManagement/managedDevices?`$select=$select&`$top=1000" -KeyProperty 'id'
        foreach ($id in $Ids) { $resolved[$id] = if ($index.ContainsKey($id)) { $index[$id] } else { $null } }
        return $resolved
    }
    $requests = @(for ($i = 0; $i -lt $Ids.Count; $i++) {
            @{ id = [string]$i; method = 'GET'; url = "/deviceManagement/managedDevices/$($Ids[$i])?`$select=$select" }
        })
    $results = Invoke-PilotGraphBatch -Requests $requests
    for ($i = 0; $i -lt $Ids.Count; $i++) {
        $result = $results[[string]$i]
        if ($result.Status -eq 404) { $resolved[$Ids[$i]] = $null; continue }
        if ($result.Status -ne 200) { throw ('Managed device lookup for {0} failed with HTTP {1}.' -f $Ids[$i], $result.Status) }
        $resolved[$Ids[$i]] = $result.Body
    }
    return $resolved
}

function Resolve-PilotEntraDevice {
    # Returns canonical Entra deviceId -> device object (or $null when missing).
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $DeviceIds, [Parameter(Mandatory)] [string] $Mode)
    $resolved = @{}
    if ($DeviceIds.Count -eq 0) { return $resolved }
    if ($Mode -eq 'Bulk') {
        $index = Get-PilotDeviceIndex -Uri "/devices?`$select=id,deviceId&`$top=999" -KeyProperty 'deviceId' -GuidKey
        foreach ($id in $DeviceIds) { $resolved[$id] = if ($index.ContainsKey($id)) { $index[$id] } else { $null } }
        return $resolved
    }
    $requests = @(for ($i = 0; $i -lt $DeviceIds.Count; $i++) {
            @{ id = [string]$i; method = 'GET'; url = "/devices(deviceId='$($DeviceIds[$i])')?`$select=id,deviceId" }
        })
    $results = Invoke-PilotGraphBatch -Requests $requests
    for ($i = 0; $i -lt $DeviceIds.Count; $i++) {
        $result = $results[[string]$i]
        if ($result.Status -eq 404) { $resolved[$DeviceIds[$i]] = $null; continue }
        if ($result.Status -ne 200) { throw ('Entra device lookup for {0} failed with HTTP {1}.' -f $DeviceIds[$i], $result.Status) }
        $resolved[$DeviceIds[$i]] = $result.Body
    }
    return $resolved
}

function Get-PilotGroupMember {
    # Lists direct members of one directory object type with only the needed
    # properties, 999 per page. OData type casts (/members/microsoft.graph.user)
    # are avoided on purpose: they require ConsistencyLevel=eventual, which reads
    # an index that can lag recent membership changes.
    param(
        [Parameter(Mandatory)] [string] $GroupId,
        [Parameter(Mandatory)] [ValidateSet('members', 'owners')] [string] $Relationship,
        [Parameter(Mandatory)] [string] $ODataType,
        [Parameter(Mandatory)] [string] $Select
    )
    $uri = "/groups/$GroupId/$Relationship`?`$select=$Select&`$top=999"
    return @(Get-PilotGraphPaged -Uri $uri | Where-Object { (Get-PilotProperty $_ '@odata.type') -eq $ODataType })
}

function Assert-PilotGroupWritable {
    # Rejects groups whose membership this script cannot or must not manage.
    param(
        [Parameter(Mandatory)] [string] $GroupId,
        [Parameter(Mandatory)] [string] $Purpose,
        [switch] $RequireSecurityGroup
    )
    $group = Invoke-PilotGraph -Method Get -Uri "/groups/$($GroupId)?`$select=id,displayName,groupTypes,onPremisesSyncEnabled,securityEnabled"
    $groupTypes = @(Get-PilotProperty $group 'groupTypes')
    $name = Get-PilotProperty $group 'displayName'
    if ($groupTypes -contains 'DynamicMembership') {
        throw "$Purpose group '$name' uses dynamic membership; it must be an assigned group."
    }
    if ((Get-PilotProperty $group 'onPremisesSyncEnabled') -eq $true) {
        throw "$Purpose group '$name' is synced from on-premises; membership cannot be managed in the cloud."
    }
    if ($RequireSecurityGroup -and ($groupTypes -contains 'Unified' -or (Get-PilotProperty $group 'securityEnabled') -ne $true)) {
        throw "$Purpose group '$name' must be a security group (devices cannot join Microsoft 365 groups)."
    }
    return [string]$name
}

function Invoke-PilotMembershipChange {
    # Adds or removes one directory object. Returns 'added', 'removed',
    # 'absorbed' (already in the target state), or 'notFound' (the object to
    # add no longer exists, e.g. a deleted user). All other failures throw.
    param(
        [Parameter(Mandatory)] [ValidateSet('Add', 'Remove')] [string] $Action,
        [Parameter(Mandatory)] [string] $GroupId,
        [Parameter(Mandatory)] [string] $ObjectId
    )
    try {
        if ($Action -eq 'Add') {
            $body = @{ '@odata.id' = "$script:graphBase/directoryObjects/$ObjectId" }
            Invoke-PilotGraph -Method Post -Uri "/groups/$GroupId/members/`$ref" -Body $body | Out-Null
            return 'added'
        }
        Invoke-PilotGraph -Method Delete -Uri "/groups/$GroupId/members/$ObjectId/`$ref" | Out-Null
        return 'removed'
    }
    catch {
        $statusCode = $_.Exception.Data['StatusCode']
        $errorMessage = [string]$_.Exception.Data['ErrorMessage']
        if ($Action -eq 'Add' -and $statusCode -eq 400 -and $errorMessage -match 'already exist') { return 'absorbed' }
        if ($Action -eq 'Add' -and $statusCode -eq 404) { return 'notFound' }
        if ($Action -eq 'Remove' -and $statusCode -eq 404) { return 'absorbed' }
        throw
    }
}

function Send-PilotTeamsNotification {
    # Best effort: a notification failure never fails the run.
    param(
        [string] $Uri,
        [string] $VariableName,
        [Parameter(Mandatory)] [string[]] $Lines
    )
    try {
        $webhookUri = $Uri
        if ([string]::IsNullOrWhiteSpace($webhookUri) -and $VariableName) {
            if (Get-Command -Name Get-AutomationVariable -ErrorAction SilentlyContinue) {
                $webhookUri = [string](Get-AutomationVariable -Name $VariableName)
            }
            else {
                $webhookUri = [Environment]::GetEnvironmentVariable($VariableName)
            }
        }
        if ([string]::IsNullOrWhiteSpace($webhookUri)) {
            Write-Warning 'No Teams webhook URL provided; notification skipped.'
            return
        }
        $cardBody = @(@{ type = 'TextBlock'; text = 'EUC pilot group sync'; weight = 'Bolder'; size = 'Medium' }) +
            @($Lines | ForEach-Object { @{ type = 'TextBlock'; text = $_; wrap = $true } })
        $payload = @{
            type        = 'message'
            attachments = @(
                @{
                    contentType = 'application/vnd.microsoft.card.adaptive'
                    contentUrl  = $null
                    content     = @{
                        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                        type      = 'AdaptiveCard'
                        version   = '1.4'
                        body      = $cardBody
                    }
                }
            )
        }
        Invoke-RestMethod -Method Post -Uri $webhookUri -UseBasicParsing `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10))) | Out-Null
    }
    catch {
        Write-Warning ('Teams notification failed: {0}' -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 0. Connect and validate targets
# ---------------------------------------------------------------------------
Write-Output 'EUC Pilot Group Reconciler'
$script:graphSession = Connect-PilotGraph -TenantId $TenantId -Scopes $requiredScopes -DeviceCode:$UseDeviceCode
Write-Output ('Connected to Microsoft Graph as {0} ({1}).' -f $script:graphSession.Account, $script:graphSession.Mode)

# The Automation host cannot answer ShouldProcess prompts; fail before any
# Graph read rather than at the first write.
if ($script:graphSession.Mode -eq 'ManagedIdentity' -and -not $WhatIfPreference -and $ConfirmPreference -ne 'None') {
    throw 'Unattended managed-identity runs must pass -Force (set Force = true on the runbook schedule) or -WhatIf. Nothing was changed.'
}

$pilotGroupName = ''
$commsGroupName = ''
if (-not $ReadOnly) {
    $pilotGroupName = Assert-PilotGroupWritable -GroupId $PilotGroupId -Purpose 'Pilot' -RequireSecurityGroup
    if ($CommsGroupId) {
        $commsGroupName = Assert-PilotGroupWritable -GroupId $CommsGroupId -Purpose 'Comms'
    }
}

# Intune lastSyncDateTime ("Last check-in") decides activity; Entra's
# approximateLastSignInDateTime lags by up to ~14 days and is not used.
$activeCutoff = if ($ActiveWithinDays -gt 0) { [DateTimeOffset]::UtcNow.AddDays(-$ActiveWithinDays) } else { [DateTimeOffset]::MinValue }
if ($ActiveWithinDays -gt 0) {
    Write-Output ('Active cutoff: Intune check-in on or after {0} ({1} days).' -f (Format-PilotTimestamp $activeCutoff), $ActiveWithinDays)
}

# ---------------------------------------------------------------------------
# 1. Install status per Intune device
# ---------------------------------------------------------------------------
Write-Output "Reading install status report for app $JoinAppId..."
$reportRows = @(Get-PilotInstallReport -AppId $JoinAppId -Action $InstallReportAction)
$stateSummary = ($reportRows | Group-Object InstallState | Sort-Object Name |
        ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
Write-Output ('Report rows: {0} ({1})' -f $reportRows.Count, $stateSummary)

# Aggregate per Intune device (a device can have one row per user):
# any installed -> installed; else any transient -> hold; else opted out.
# FirstInstalled is the earliest status timestamp among installed rows and
# orders first-come-first-served adds under MemberCap.
$holdStates = @('pendingInstall', 'failed', 'uninstallFailed', 'unknown')
$intuneDevices = @{}
foreach ($row in $reportRows) {
    if (-not $row.DeviceId) { continue }
    if (-not $intuneDevices.ContainsKey($row.DeviceId)) {
        $intuneDevices[$row.DeviceId] = [pscustomobject]@{ Disposition = 'optedOut'; FirstInstalled = [DateTimeOffset]::MaxValue }
    }
    $entry = $intuneDevices[$row.DeviceId]
    if ($row.InstallState -eq 'installed') {
        $entry.Disposition = 'installed'
        $parsed = ConvertTo-PilotTimestamp $row.LastModified
        if ($parsed -ne [DateTimeOffset]::MinValue -and $parsed -lt $entry.FirstInstalled) {
            $entry.FirstInstalled = $parsed
        }
    }
    elseif ($holdStates -contains $row.InstallState -and $entry.Disposition -ne 'installed') {
        $entry.Disposition = 'hold'
    }
}

# ---------------------------------------------------------------------------
# 2. Map installed/held Intune devices to Entra identities and primary users
# ---------------------------------------------------------------------------
[string[]] $lookupIds = @($intuneDevices.Keys | Where-Object {
        if ($ReadOnly) { $intuneDevices[$_].Disposition -eq 'installed' }
        else { $intuneDevices[$_].Disposition -ne 'optedOut' }
    })
[Array]::Sort($lookupIds, [StringComparer]::OrdinalIgnoreCase)
$managedLookupMode = Get-PilotLookupMode -Requested $DeviceLookup -Count $lookupIds.Count
Write-Output ('Resolving {0} Intune device(s) ({1} lookup).' -f $lookupIds.Count, $managedLookupMode)
$managedDevices = Resolve-PilotManagedDevice -Ids $lookupIds -Mode $managedLookupMode

# Entra deviceId -> device info. Duplicate Intune records for one Entra device
# merge: installed wins, the earliest install and latest check-in count.
$entraDevices = @{}
foreach ($intuneId in $lookupIds) {
    $managed = $managedDevices[$intuneId]
    if ($null -eq $managed) {
        Write-Output ('SKIP (stale report entry, managed device gone): {0}' -f $intuneId)
        continue
    }
    $deviceName = [string](Get-PilotProperty $managed 'deviceName')
    $azureAdDeviceId = ConvertTo-PilotGuid (Get-PilotProperty $managed 'azureADDeviceId')
    if (-not $azureAdDeviceId) {
        Write-Output ('SKIP (no Entra device id): {0}' -f $deviceName)
        continue
    }
    $reportEntry = $intuneDevices[$intuneId]
    $record = [pscustomobject]@{
        Disposition           = $reportEntry.Disposition
        FirstInstalled        = $reportEntry.FirstInstalled
        DeviceName            = $deviceName
        UserPrincipalName     = [string](Get-PilotProperty $managed 'userPrincipalName')
        UserId                = ConvertTo-PilotGuid (Get-PilotProperty $managed 'userId')
        IntuneManagedDeviceId = $intuneId
        LastCheckIn           = ConvertTo-PilotTimestamp (Get-PilotProperty $managed 'lastSyncDateTime')
    }
    if (-not $entraDevices.ContainsKey($azureAdDeviceId)) {
        $entraDevices[$azureAdDeviceId] = $record
        continue
    }
    $existing = $entraDevices[$azureAdDeviceId]
    $lastCheckIn = if ($record.LastCheckIn -gt $existing.LastCheckIn) { $record.LastCheckIn } else { $existing.LastCheckIn }
    if ($record.Disposition -eq 'installed' -and $existing.Disposition -ne 'installed') {
        $entraDevices[$azureAdDeviceId] = $record
        $existing = $record
    }
    elseif ($record.Disposition -eq 'installed' -and $record.FirstInstalled -lt $existing.FirstInstalled) {
        $existing.FirstInstalled = $record.FirstInstalled
    }
    $existing.LastCheckIn = $lastCheckIn
    if (-not $existing.UserId -and $record.UserId) {
        $existing.UserId = $record.UserId
        $existing.UserPrincipalName = $record.UserPrincipalName
    }
}

# Inactive devices are never added and are removed if present, so a shelved or
# reimaged device cannot hold a MemberCap slot.
$inactiveCount = 0
if ($ActiveWithinDays -gt 0) {
    foreach ($azureAdDeviceId in @($entraDevices.Keys)) {
        $info = $entraDevices[$azureAdDeviceId]
        if ($info.LastCheckIn -ne [DateTimeOffset]::MinValue -and $info.LastCheckIn -ge $activeCutoff) { continue }
        $lastSeen = Format-PilotTimestamp $info.LastCheckIn
        if (-not $lastSeen) { $lastSeen = 'never' }
        Write-Output ('INACTIVE (last check-in {0}): {1} ({2})' -f $lastSeen, $info.DeviceName, $azureAdDeviceId)
        $info.Disposition = 'inactive'
        $inactiveCount++
    }
}

# ---------------------------------------------------------------------------
# 3. ReadOnly export
# ---------------------------------------------------------------------------
if ($ReadOnly) {
    [string[]] $exportDeviceIds = @($entraDevices.Keys | Where-Object { $entraDevices[$_].Disposition -eq 'installed' })
    [Array]::Sort($exportDeviceIds, [StringComparer]::Ordinal)
    $entraObjects = Resolve-PilotEntraDevice -DeviceIds $exportDeviceIds -Mode (Get-PilotLookupMode -Requested $DeviceLookup -Count $exportDeviceIds.Count)
    $resolved = New-Object 'System.Collections.Generic.List[object]'
    foreach ($deviceId in $exportDeviceIds) {
        $info = $entraDevices[$deviceId]
        $entraObject = $entraObjects[$deviceId]
        if ($null -eq $entraObject) {
            Write-Output ('SKIP (no Entra device object): {0} ({1})' -f $info.DeviceName, $deviceId)
            continue
        }
        $objectId = [string](Get-PilotProperty $entraObject 'id')
        if (-not $objectId) { throw "Entra device lookup for $deviceId returned no object ID." }
        $resolved.Add([pscustomobject]@{ Info = $info; DeviceId = $deviceId; ObjectId = $objectId })
    }
    $exportRows = @($resolved.ToArray() | Sort-Object @{ Expression = { $_.Info.FirstInstalled } }, @{ Expression = { $_.Info.DeviceName } } |
            ForEach-Object {
                [pscustomobject]@{
                    DeviceName                = $_.Info.DeviceName
                    EntraObjectId             = $_.ObjectId
                    EntraDeviceId             = $_.DeviceId
                    IntuneManagedDeviceId     = $_.Info.IntuneManagedDeviceId
                    AssignedUserPrincipalName = $_.Info.UserPrincipalName
                    InstallState              = 'installed'
                    FirstInstalled            = Format-PilotTimestamp $_.Info.FirstInstalled
                    LastCheckIn               = Format-PilotTimestamp $_.Info.LastCheckIn
                }
            })
    $detailColumns = @('DeviceName', 'EntraObjectId', 'EntraDeviceId', 'IntuneManagedDeviceId', 'AssignedUserPrincipalName', 'InstallState', 'FirstInstalled', 'LastCheckIn')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $detailPath = Join-Path $ExportDirectory "EucPilotCandidates-$stamp.csv"
    $importPath = Join-Path $ExportDirectory "EntraGroupImport-$stamp.csv"
    $importHeader = 'Member object ID or user principal name [memberObjectIdOrUpn] Required'
    if ($PSCmdlet.ShouldProcess($ExportDirectory, 'Export installed-device detail and Entra bulk-import CSVs')) {
        if (-not (Test-Path -LiteralPath $ExportDirectory -PathType Container)) {
            New-Item -Path $ExportDirectory -ItemType Directory -Force | Out-Null
        }
        if ($exportRows.Count -gt 0) {
            $exportRows | Select-Object $detailColumns | Export-Csv -LiteralPath $detailPath -NoTypeInformation -Encoding UTF8
        }
        else {
            ($detailColumns | ForEach-Object { '"{0}"' -f $_ }) -join ',' | Set-Content -LiteralPath $detailPath -Encoding UTF8
        }
        @($importHeader) + @($exportRows | ForEach-Object { $_.EntraObjectId }) |
            Set-Content -LiteralPath $importPath -Encoding UTF8
        Write-Output "Detail CSV: $detailPath"
        Write-Output "Entra import CSV: $importPath"
    }
    Write-Output ('ReadOnly: {0} resolved active installed device(s), {1} inactive skipped; no group operations. MemberCap is not applied.' -f
        $exportRows.Count, $inactiveCount)
    Write-Output ('Graph HTTP calls: {0} (batch subrequests: {1}).' -f $script:graphCallCount, $script:batchSubrequestCount)
    return
}

# ---------------------------------------------------------------------------
# 4. Current pilot group device members
# ---------------------------------------------------------------------------
Write-Output "Reading pilot group '$pilotGroupName' membership..."
$current = @{}
foreach ($member in (Get-PilotGroupMember -GroupId $PilotGroupId -Relationship members -ODataType '#microsoft.graph.device' -Select 'id,deviceId,displayName')) {
    $memberDeviceId = ConvertTo-PilotGuid (Get-PilotProperty $member 'deviceId')
    if (-not $memberDeviceId) { continue }
    $current[$memberDeviceId] = [pscustomobject]@{
        ObjectId    = [string](Get-PilotProperty $member 'id')
        DisplayName = [string](Get-PilotProperty $member 'displayName')
    }
}
Write-Output ('Devices currently in group: {0}' -f $current.Count)

# ---------------------------------------------------------------------------
# 5. Plan: removals first, then FCFS adds within the cap
# ---------------------------------------------------------------------------
$toRemove = @($current.Keys | Where-Object {
        -not $entraDevices.ContainsKey($_) -or $entraDevices[$_].Disposition -eq 'inactive'
    } | Sort-Object)
[string[]] $addCandidateIds = @($entraDevices.Keys | Where-Object {
        $entraDevices[$_].Disposition -eq 'installed' -and -not $current.ContainsKey($_)
    })
[Array]::Sort($addCandidateIds, [StringComparer]::Ordinal)

# Resolve Entra object IDs before applying the cap so unresolvable devices
# never consume a slot.
$entraObjects = Resolve-PilotEntraDevice -DeviceIds $addCandidateIds -Mode (Get-PilotLookupMode -Requested $DeviceLookup -Count $addCandidateIds.Count)
$addCandidates = New-Object 'System.Collections.Generic.List[object]'
foreach ($azureAdDeviceId in $addCandidateIds) {
    $info = $entraDevices[$azureAdDeviceId]
    $entraObject = $entraObjects[$azureAdDeviceId]
    if ($null -eq $entraObject) {
        Write-Output ('SKIP (no Entra device object): {0} ({1})' -f $info.DeviceName, $azureAdDeviceId)
        continue
    }
    $objectId = [string](Get-PilotProperty $entraObject 'id')
    if (-not $objectId) { throw "Entra device lookup for $azureAdDeviceId returned no object ID." }
    $addCandidates.Add([pscustomobject]@{
            AzureAdDeviceId   = $azureAdDeviceId
            ObjectId          = $objectId
            DeviceName        = $info.DeviceName
            UserPrincipalName = $info.UserPrincipalName
            UserId            = $info.UserId
            FirstInstalled    = $info.FirstInstalled
        })
}

$sortedCandidates = @($addCandidates.ToArray() | Sort-Object FirstInstalled, DeviceName)
$toAdd = $sortedCandidates
$deferredCount = 0
if ($MemberCap -gt 0) {
    $allowedAdds = [Math]::Max(0, $MemberCap - ($current.Count - $toRemove.Count))
    if ($sortedCandidates.Count -gt $allowedAdds) {
        # @() around the whole statement: an empty array returned from an if
        # statement unrolls to $null, and $null.Count throws under StrictMode.
        $toAdd = @(if ($allowedAdds -gt 0) { $sortedCandidates[0..($allowedAdds - 1)] })
        $deferredCount = $sortedCandidates.Count - $toAdd.Count
    }
}

# ---------------------------------------------------------------------------
# 6. Plan comms group from the planned final pilot membership. Users come
#    from each device's Intune primary user object ID (managedDevice.userId),
#    so no per-user lookup is needed.
# ---------------------------------------------------------------------------
$commsToAdd = @()
$commsToRemove = @()
$wantedUsers = @{}
$commsMembers = @{}
if ($CommsGroupId) {
    $removeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $toRemove) { [void]$removeSet.Add($id) }
    foreach ($azureAdDeviceId in $current.Keys) {
        if ($removeSet.Contains($azureAdDeviceId)) { continue }
        $info = $entraDevices[$azureAdDeviceId]
        if ($info.UserId) { $wantedUsers[$info.UserId] = $info.UserPrincipalName }
    }
    foreach ($candidate in $toAdd) {
        if ($candidate.UserId) { $wantedUsers[$candidate.UserId] = $candidate.UserPrincipalName }
    }

    foreach ($member in (Get-PilotGroupMember -GroupId $CommsGroupId -Relationship members -ODataType '#microsoft.graph.user' -Select 'id,userPrincipalName')) {
        $memberId = ConvertTo-PilotGuid (Get-PilotProperty $member 'id')
        if ($memberId) { $commsMembers[$memberId] = [string](Get-PilotProperty $member 'userPrincipalName') }
    }
    $commsOwners = @{}
    foreach ($owner in (Get-PilotGraphPaged -Uri "/groups/$CommsGroupId/owners?`$select=id&`$top=999")) {
        $ownerId = ConvertTo-PilotGuid (Get-PilotProperty $owner 'id')
        if ($ownerId) { $commsOwners[$ownerId] = $true }
    }

    $commsToAdd = @($wantedUsers.Keys | Where-Object { -not $commsMembers.ContainsKey($_) } | Sort-Object)
    $commsToRemove = @($commsMembers.Keys | Where-Object {
            -not $wantedUsers.ContainsKey($_) -and -not $commsOwners.ContainsKey($_)
        } | Sort-Object)
}

# ---------------------------------------------------------------------------
# 7. Guards - evaluated before any write
# ---------------------------------------------------------------------------
if ($reportRows.Count -eq 0 -and $current.Count -gt 0) {
    throw ('Install report for app {0} returned no rows; refusing to remove {1} device(s). Check the app ID, its assignment, and -InstallReportAction.' -f
        $JoinAppId, $current.Count)
}
if ($toRemove.Count -gt $MaxRemovals) {
    throw ('{0} pilot removals planned, above -MaxRemovals {1}. Nothing was changed. Review the report, then rerun with a higher -MaxRemovals if intended.' -f
        $toRemove.Count, $MaxRemovals)
}
if ($commsToRemove.Count -gt $MaxRemovals) {
    throw ('{0} comms removals planned, above -MaxRemovals {1}. Nothing was changed.' -f $commsToRemove.Count, $MaxRemovals)
}

Write-Output ('Plan: remove {0}, add {1}, deferred by cap {2}, inactive {3}{4}.' -f $toRemove.Count, $toAdd.Count, $deferredCount, $inactiveCount,
    $(if ($CommsGroupId) { ', comms +{0}/-{1}' -f $commsToAdd.Count, $commsToRemove.Count } else { '' }))

# ---------------------------------------------------------------------------
# 8. Execute
# ---------------------------------------------------------------------------
$removedCount = 0
$addedCount = 0
$commsAddedCount = 0
$commsRemovedCount = 0
$notFoundCount = 0
# Absorbed results mean the group was already in the target state, so they
# still move the final count.
$finalDeviceCount = $current.Count

foreach ($azureAdDeviceId in $toRemove) {
    $member = $current[$azureAdDeviceId]
    if (-not $PSCmdlet.ShouldProcess("$($member.DisplayName) ($azureAdDeviceId)", "Remove device from pilot group '$pilotGroupName'")) { continue }
    $result = Invoke-PilotMembershipChange -Action Remove -GroupId $PilotGroupId -ObjectId $member.ObjectId
    Write-Output ('REMOVE ({0}): {1} ({2})' -f $result, $member.DisplayName, $azureAdDeviceId)
    if ($result -eq 'removed') { $removedCount++ }
    $finalDeviceCount--
}

foreach ($candidate in $toAdd) {
    if (-not $PSCmdlet.ShouldProcess("$($candidate.DeviceName) ($($candidate.AzureAdDeviceId))", "Add device to pilot group '$pilotGroupName'")) { continue }
    $result = Invoke-PilotMembershipChange -Action Add -GroupId $PilotGroupId -ObjectId $candidate.ObjectId
    Write-Output ('ADD ({0}): {1} [{2}]' -f $result, $candidate.DeviceName, $candidate.UserPrincipalName)
    if ($result -eq 'added') { $addedCount++ }
    if ($result -eq 'notFound') { $notFoundCount++; continue }
    $finalDeviceCount++
}

if ($deferredCount -gt 0) {
    Write-Output ('CAP REACHED ({0}): {1} device(s) deferred to a later run.' -f $MemberCap, $deferredCount)
}

if ($CommsGroupId) {
    foreach ($userId in $commsToAdd) {
        $label = if ($wantedUsers[$userId]) { $wantedUsers[$userId] } else { $userId }
        if (-not $PSCmdlet.ShouldProcess($label, "Add user to comms group '$commsGroupName'")) { continue }
        $result = Invoke-PilotMembershipChange -Action Add -GroupId $CommsGroupId -ObjectId $userId
        Write-Output ('COMMS ADD ({0}): {1}' -f $result, $label)
        if ($result -eq 'added') { $commsAddedCount++ }
        if ($result -eq 'notFound') { $notFoundCount++ }
    }
    foreach ($userId in $commsToRemove) {
        $label = if ($commsMembers[$userId]) { $commsMembers[$userId] } else { $userId }
        if (-not $PSCmdlet.ShouldProcess($label, "Remove user from comms group '$commsGroupName'")) { continue }
        $result = Invoke-PilotMembershipChange -Action Remove -GroupId $CommsGroupId -ObjectId $userId
        Write-Output ('COMMS REMOVE ({0}): {1}' -f $result, $label)
        if ($result -eq 'removed') { $commsRemovedCount++ }
    }
}

# ---------------------------------------------------------------------------
# 9. Summary and optional Teams notification
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
$summaryLines = New-Object 'System.Collections.Generic.List[string]'
$summaryLines.Add(('{0}: pilot +{1} added, -{2} removed, {3} deferred by cap, {4} inactive; {5} device(s) in group.' -f
        $timestamp, $addedCount, $removedCount, $deferredCount, $inactiveCount, $finalDeviceCount))
if ($CommsGroupId) {
    $summaryLines.Add(('Comms: +{0} added, -{1} removed.' -f $commsAddedCount, $commsRemovedCount))
}
if ($notFoundCount -gt 0) {
    $summaryLines.Add(('{0} object(s) to add no longer exist in Entra and were skipped.' -f $notFoundCount))
}
if ($WhatIfPreference) {
    $summaryLines.Add('WhatIf run: no changes were made.')
}
$summaryLines | Write-Output
Write-Output ('Graph HTTP calls: {0} (batch subrequests: {1}).' -f $script:graphCallCount, $script:batchSubrequestCount)

$changeCount = $addedCount + $removedCount + $commsAddedCount + $commsRemovedCount
$hasWebhook = $TeamsWebhookUri -or $TeamsWebhookVariable
if ($hasWebhook -and -not $WhatIfPreference -and ($changeCount -gt 0 -or $deferredCount -gt 0)) {
    Send-PilotTeamsNotification -Uri $TeamsWebhookUri -VariableName $TeamsWebhookVariable -Lines $summaryLines.ToArray()
}
