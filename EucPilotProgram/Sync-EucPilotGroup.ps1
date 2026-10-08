#requires -Version 5.1
<#
.SYNOPSIS
Reconciles an Entra pilot device group from Intune app install status.

.DESCRIPTION
State-based reconciler for the EUC Early Adopter pilot program.

- Devices whose Join app reports 'installed' are added to the pilot group.
- Devices reporting 'notInstalled' or 'notApplicable', or that no longer
  appear in the report or in Intune, are removed.
- Transient states ('pendingInstall', 'failed', 'uninstallFailed', 'unknown')
  hold the device where it is: kept if already a member, not added if not.

Safety rails:
- Any Graph failure halts the run before or between writes; an error is never
  treated as an empty desired state.
- A report with zero rows never removes anyone.
- Removals above -MaxRemovals (pilot or comms) abort the run before any write.
- Dynamic, on-premises-synced, or Microsoft 365 pilot groups are rejected.

Authentication branches:
- Azure Automation (production): system-assigned managed identity via
  IDENTITY_ENDPOINT, raw REST, no module dependencies.
- Interactive (POC): Connect-MgGraph with MFA/Conditional Access; requires
  the Microsoft.Graph.Authentication module.

.PARAMETER TeamsWebhookUri
A Teams Workflows webhook URL to post the run summary to. Convenient for
local runs; do NOT use this in Azure Automation, where parameter values are
recorded in job history - use -TeamsWebhookVariable there instead.

.PARAMETER TeamsWebhookVariable
Name of an Azure Automation encrypted variable (or, for local runs, an
environment variable) holding a Teams Workflows webhook URL. The URL itself
is never passed as a parameter so it does not appear in job history.

.EXAMPLE
.\Sync-EucPilotGroup.ps1 -JoinAppId <mobileApp-guid> -PilotGroupId <group-guid> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $JoinAppId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $PilotGroupId,

    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $CommsGroupId,

    # Maximum pilot devices. 0 = no cap.
    [ValidateRange(0, 100000)]
    [int] $MemberCap = 50,

    # Abort the whole run if more than this many removals are planned for
    # either group. 0 = abort on any removal.
    [ValidateRange(0, 100000)]
    [int] $MaxRemovals = 10,

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

$script:graphRoot = 'https://graph.microsoft.com'
$script:graphBase = "$script:graphRoot/v1.0"
$script:graphSession = $null
$script:maxGraphAttempts = 5
$script:retryableStatusCodes = @(429, 503, 504)
$script:emptyGuid = '00000000-0000-0000-0000-000000000000'

$requiredScopes = @(
    'DeviceManagementApps.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'Device.Read.All'
    'User.Read.All'
    'GroupMember.ReadWrite.All'
)

# ---------------------------------------------------------------------------
# Helpers. Functions never write to the output stream except their return
# value; diagnostics go to Write-Verbose / Write-Warning.
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
        Write-Output ('Signing in with the device code flow ({0}).' -f $parameterName)
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
        $retryAfter = 0
        if ($null -ne $response.Headers.RetryAfter -and $null -ne $response.Headers.RetryAfter.Delta) {
            $retryAfter = [int]$response.Headers.RetryAfter.Delta.TotalSeconds
        }
        $content = ''
        if ($null -ne $response.Content) {
            $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; RetryAfter = $retryAfter; Content = $content }
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

        $retryAfter = 0
        try {
            if ($errorResponse.Headers -is [System.Net.WebHeaderCollection]) {
                # Windows PowerShell 5.1: HttpWebResponse
                $rawRetryAfter = $errorResponse.Headers['Retry-After']
                $parsedRetryAfter = 0
                if ([int]::TryParse([string]$rawRetryAfter, [ref]$parsedRetryAfter)) { $retryAfter = $parsedRetryAfter }
            }
            elseif ($null -ne $errorResponse.Headers.RetryAfter -and $null -ne $errorResponse.Headers.RetryAfter.Delta) {
                # PowerShell 7: HttpResponseMessage
                $retryAfter = [int]$errorResponse.Headers.RetryAfter.Delta.TotalSeconds
            }
        }
        catch {
            Write-Verbose ('Could not read Retry-After header: {0}' -f $_.Exception.Message)
            $retryAfter = 0
        }

        $content = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $content = $_.ErrorDetails.Message }
        return [pscustomobject]@{ StatusCode = [int]$errorResponse.StatusCode; RetryAfter = $retryAfter; Content = $content }
    }
}

function Invoke-PilotGraph {
    # Graph call with throttling retry. Returns the parsed JSON body ($null
    # for empty bodies). Non-retryable or exhausted failures throw an
    # exception whose Data carries StatusCode, ErrorCode, and ErrorMessage.
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body
    )
    $resolvedUri = if ($Uri.StartsWith('https://')) { $Uri } else { "$script:graphBase$Uri" }
    $bodyJson = $null
    if ($null -ne $Body) { $bodyJson = $Body | ConvertTo-Json -Depth 10 -Compress }

    for ($attempt = 1; ; $attempt++) {
        $result = Send-PilotGraphRequest -Method $Method -Uri $resolvedUri -BodyJson $bodyJson

        if ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300) {
            if ([string]::IsNullOrWhiteSpace($result.Content)) { return $null }
            return ($result.Content | ConvertFrom-Json)
        }

        if ($script:retryableStatusCodes -contains $result.StatusCode -and $attempt -lt $script:maxGraphAttempts) {
            $delay = if ($result.RetryAfter -gt 0) { $result.RetryAfter } else { [Math]::Min(60, 5 * [Math]::Pow(2, $attempt - 1)) }
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
    # hashtable of request id -> { Status; Body }. Throttled sub-requests are
    # retried; anything else is returned for the caller to judge.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Requests
    )
    $results = @{}
    for ($offset = 0; $offset -lt $Requests.Count; $offset += 20) {
        $last = [Math]::Min($offset + 19, $Requests.Count - 1)
        $pending = @($Requests[$offset..$last])
        for ($attempt = 1; $pending.Count -gt 0; $attempt++) {
            $response = Invoke-PilotGraph -Method Post -Uri '/$batch' -Body @{ requests = $pending }
            $responses = Get-PilotProperty $response 'responses'
            if ($null -eq $responses) { throw 'Graph $batch response had no responses collection.' }

            $retry = New-Object 'System.Collections.Generic.List[object]'
            $delay = 0
            foreach ($item in $responses) {
                $id = [string](Get-PilotProperty $item 'id')
                $status = [int](Get-PilotProperty $item 'status')
                if ($script:retryableStatusCodes -contains $status -and $attempt -lt $script:maxGraphAttempts) {
                    $retry.Add(($pending | Where-Object { $_.id -eq $id } | Select-Object -First 1))
                    $parsedRetryAfter = 0
                    $retryAfterHeader = Get-PilotProperty (Get-PilotProperty $item 'headers') 'Retry-After'
                    if ([int]::TryParse([string]$retryAfterHeader, [ref]$parsedRetryAfter)) {
                        $delay = [Math]::Max($delay, $parsedRetryAfter)
                    }
                    continue
                }
                $results[$id] = [pscustomobject]@{ Status = $status; Body = (Get-PilotProperty $item 'body') }
            }
            if ($retry.Count -gt 0) {
                if ($delay -le 0) { $delay = [Math]::Min(60, 5 * [Math]::Pow(2, $attempt - 1)) }
                Write-Warning ('{0} batched request(s) throttled; retrying in {1}s.' -f $retry.Count, $delay)
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
    # Pages with skip/top and requires the collected row count to equal
    # TotalRowCount, so a partial report can never drive removals.
    param(
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [string] $Action
    )
    $uri = "$script:graphRoot/beta/deviceManagement/reports/$Action"
    $pageSize = 500
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $totalRows = -1

    for ($skip = 0; ; $skip += $pageSize) {
        $body = @{
            filter  = "(ApplicationId eq '$AppId')"
            select  = @('DeviceId', 'DeviceName', 'UserPrincipalName', 'InstallState', 'LastModifiedDateTime')
            skip    = $skip
            top     = $pageSize
            orderBy = @()
        }
        $response = Invoke-PilotGraph -Method Post -Uri $uri -Body $body
        $schemaProperty = if ($null -ne $response) { $response.PSObject.Properties['Schema'] } else { $null }
        $valuesProperty = if ($null -ne $response) { $response.PSObject.Properties['Values'] } else { $null }
        if (-not $schemaProperty -or -not $valuesProperty) {
            throw 'Install status report response is missing Schema or Values.'
        }

        $columnIndex = @{}
        $index = 0
        foreach ($column in $schemaProperty.Value) {
            $columnIndex[[string](Get-PilotProperty $column 'Column')] = $index
            $index++
        }
        foreach ($required in @('DeviceId', 'InstallState')) {
            if (-not $columnIndex.ContainsKey($required)) {
                throw "Install status report is missing the '$required' column."
            }
        }

        $pageCount = 0
        foreach ($row in $valuesProperty.Value) {
            $pageCount++
            $rows.Add([pscustomobject]@{
                    DeviceId          = [string]$row[$columnIndex['DeviceId']]
                    DeviceName        = if ($columnIndex.ContainsKey('DeviceName')) { [string]$row[$columnIndex['DeviceName']] } else { '' }
                    UserPrincipalName = if ($columnIndex.ContainsKey('UserPrincipalName')) { [string]$row[$columnIndex['UserPrincipalName']] } else { '' }
                    InstallState      = ConvertTo-PilotInstallState $row[$columnIndex['InstallState']]
                    LastModified      = if ($columnIndex.ContainsKey('LastModifiedDateTime')) { $row[$columnIndex['LastModifiedDateTime']] } else { $null }
                })
        }

        $reportedTotal = Get-PilotProperty $response 'TotalRowCount'
        if ($null -ne $reportedTotal) { $totalRows = [int]$reportedTotal }

        if ($totalRows -ge 0) {
            if ($rows.Count -ge $totalRows -or $pageCount -eq 0) { break }
        }
        elseif ($pageCount -lt $pageSize) {
            break
        }
    }

    if ($totalRows -ge 0 -and $rows.Count -ne $totalRows) {
        throw ('Install status report is incomplete: collected {0} of {1} rows. Refusing to reconcile on partial data.' -f
            $rows.Count, $totalRows)
    }
    return $rows.ToArray()
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
    # Adds or removes one directory object. Returns 'added', 'removed', or
    # 'absorbed' (already in the target state). All other failures throw.
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
        $cardBody = @(@{ type = 'TextBlock'; text = 'EUC pilot group sync'; weight = 'Bolder'; size = 'Medium' })
        foreach ($line in $Lines) { $cardBody += @{ type = 'TextBlock'; text = $line; wrap = $true } }
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

$pilotGroupName = Assert-PilotGroupWritable -GroupId $PilotGroupId -Purpose 'Pilot' -RequireSecurityGroup
if ($CommsGroupId) {
    $commsGroupName = Assert-PilotGroupWritable -GroupId $CommsGroupId -Purpose 'Comms'
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
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$row.LastModified, [ref]$parsed) -and $parsed -lt $entry.FirstInstalled) {
            $entry.FirstInstalled = $parsed
        }
    }
    elseif ($holdStates -contains $row.InstallState -and $entry.Disposition -ne 'installed') {
        $entry.Disposition = 'hold'
    }
}

# ---------------------------------------------------------------------------
# 2. Map installed/held Intune devices to Entra device IDs (batched)
# ---------------------------------------------------------------------------
$lookupIds = @($intuneDevices.Keys | Where-Object { $intuneDevices[$_].Disposition -ne 'optedOut' })
$lookupRequests = @()
for ($i = 0; $i -lt $lookupIds.Count; $i++) {
    $lookupRequests += @{
        id     = [string]$i
        method = 'GET'
        url    = "/deviceManagement/managedDevices/$($lookupIds[$i])?`$select=id,azureADDeviceId,deviceName,userPrincipalName"
    }
}
$lookupResults = Invoke-PilotGraphBatch -Requests $lookupRequests

# Entra deviceId -> device info. keep = installed or hold; desired = installed.
$entraDevices = @{}
for ($i = 0; $i -lt $lookupIds.Count; $i++) {
    $result = $lookupResults[[string]$i]
    if ($result.Status -eq 404) {
        Write-Output ('SKIP (stale report entry, managed device gone): {0}' -f $lookupIds[$i])
        continue
    }
    if ($result.Status -ne 200) {
        throw ('Managed device lookup for {0} failed with HTTP {1}.' -f $lookupIds[$i], $result.Status)
    }
    $azureAdDeviceId = [string](Get-PilotProperty $result.Body 'azureADDeviceId')
    $deviceName = [string](Get-PilotProperty $result.Body 'deviceName')
    if (-not $azureAdDeviceId -or $azureAdDeviceId -eq $script:emptyGuid) {
        Write-Output ('SKIP (no Entra device id): {0}' -f $deviceName)
        continue
    }
    $reportEntry = $intuneDevices[$lookupIds[$i]]
    $existing = if ($entraDevices.ContainsKey($azureAdDeviceId)) { $entraDevices[$azureAdDeviceId] } else { $null }
    # Duplicate Intune records for one Entra device: installed wins.
    if ($null -eq $existing -or ($existing.Disposition -ne 'installed' -and $reportEntry.Disposition -eq 'installed')) {
        $entraDevices[$azureAdDeviceId] = [pscustomobject]@{
            Disposition       = $reportEntry.Disposition
            FirstInstalled    = $reportEntry.FirstInstalled
            DeviceName        = $deviceName
            UserPrincipalName = [string](Get-PilotProperty $result.Body 'userPrincipalName')
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Current pilot group device members
# ---------------------------------------------------------------------------
Write-Output "Reading pilot group '$pilotGroupName' membership..."
$current = @{}
foreach ($member in (Get-PilotGraphPaged -Uri "/groups/$PilotGroupId/members")) {
    if ((Get-PilotProperty $member '@odata.type') -ne '#microsoft.graph.device') { continue }
    $memberDeviceId = [string](Get-PilotProperty $member 'deviceId')
    if (-not $memberDeviceId) { continue }
    $current[$memberDeviceId] = [pscustomobject]@{
        ObjectId    = [string](Get-PilotProperty $member 'id')
        DisplayName = [string](Get-PilotProperty $member 'displayName')
    }
}
Write-Output ('Devices currently in group: {0}' -f $current.Count)

# ---------------------------------------------------------------------------
# 4. Plan: removals first, then FCFS adds within the cap
# ---------------------------------------------------------------------------
$toRemove = @($current.Keys | Where-Object { -not $entraDevices.ContainsKey($_) } | Sort-Object)
$addCandidateIds = @($entraDevices.Keys | Where-Object {
        $entraDevices[$_].Disposition -eq 'installed' -and -not $current.ContainsKey($_)
    })

# Resolve Entra object IDs before applying the cap so unresolvable devices
# never consume a slot.
$entraRequests = @()
for ($i = 0; $i -lt $addCandidateIds.Count; $i++) {
    $entraRequests += @{
        id     = [string]$i
        method = 'GET'
        url    = "/devices(deviceId='$($addCandidateIds[$i])')?`$select=id,deviceId"
    }
}
$entraResults = Invoke-PilotGraphBatch -Requests $entraRequests
$addCandidates = New-Object 'System.Collections.Generic.List[object]'
for ($i = 0; $i -lt $addCandidateIds.Count; $i++) {
    $azureAdDeviceId = $addCandidateIds[$i]
    $info = $entraDevices[$azureAdDeviceId]
    $result = $entraResults[[string]$i]
    if ($result.Status -eq 404) {
        Write-Output ('SKIP (no Entra device object): {0} ({1})' -f $info.DeviceName, $azureAdDeviceId)
        continue
    }
    if ($result.Status -ne 200) {
        throw ('Entra device lookup for {0} failed with HTTP {1}.' -f $azureAdDeviceId, $result.Status)
    }
    $addCandidates.Add([pscustomobject]@{
            AzureAdDeviceId   = $azureAdDeviceId
            ObjectId          = [string](Get-PilotProperty $result.Body 'id')
            DeviceName        = $info.DeviceName
            UserPrincipalName = $info.UserPrincipalName
            FirstInstalled    = $info.FirstInstalled
        })
}

$sortedCandidates = @($addCandidates | Sort-Object FirstInstalled, DeviceName)
$toAdd = $sortedCandidates
$deferredCount = 0
if ($MemberCap -gt 0) {
    $allowedAdds = [Math]::Max(0, $MemberCap - ($current.Count - $toRemove.Count))
    if ($sortedCandidates.Count -gt $allowedAdds) {
        $toAdd = if ($allowedAdds -gt 0) { @($sortedCandidates[0..($allowedAdds - 1)]) } else { @() }
        $deferredCount = $sortedCandidates.Count - $toAdd.Count
    }
}

# ---------------------------------------------------------------------------
# 5. Plan comms group from the planned final pilot membership
# ---------------------------------------------------------------------------
$commsToAdd = @()
$commsToRemove = @()
if ($CommsGroupId) {
    $finalUpns = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($azureAdDeviceId in $current.Keys) {
        if ($toRemove -contains $azureAdDeviceId) { continue }
        $upn = $entraDevices[$azureAdDeviceId].UserPrincipalName
        if ($upn) { [void]$finalUpns.Add($upn) }
    }
    foreach ($candidate in $toAdd) {
        if ($candidate.UserPrincipalName) { [void]$finalUpns.Add($candidate.UserPrincipalName) }
    }

    $wantedUpns = @($finalUpns)
    $userRequests = @()
    for ($i = 0; $i -lt $wantedUpns.Count; $i++) {
        $userRequests += @{
            id     = [string]$i
            method = 'GET'
            url    = "/users/$([uri]::EscapeDataString($wantedUpns[$i]))?`$select=id,userPrincipalName"
        }
    }
    $userResults = Invoke-PilotGraphBatch -Requests $userRequests
    $wantedUsers = @{}
    $unresolvedUsers = 0
    for ($i = 0; $i -lt $wantedUpns.Count; $i++) {
        $result = $userResults[[string]$i]
        if ($result.Status -eq 404) {
            Write-Output ('SKIP (user not found): {0}' -f $wantedUpns[$i])
            $unresolvedUsers++
            continue
        }
        if ($result.Status -ne 200) {
            throw ('User lookup for {0} failed with HTTP {1}.' -f $wantedUpns[$i], $result.Status)
        }
        $wantedUsers[[string](Get-PilotProperty $result.Body 'id')] = [string](Get-PilotProperty $result.Body 'userPrincipalName')
    }

    $commsMembers = @{}
    foreach ($member in (Get-PilotGraphPaged -Uri "/groups/$CommsGroupId/members")) {
        if ((Get-PilotProperty $member '@odata.type') -eq '#microsoft.graph.user') {
            $commsMembers[[string](Get-PilotProperty $member 'id')] = [string](Get-PilotProperty $member 'userPrincipalName')
        }
    }
    $commsOwners = @{}
    foreach ($owner in (Get-PilotGraphPaged -Uri "/groups/$CommsGroupId/owners")) {
        $commsOwners[[string](Get-PilotProperty $owner 'id')] = $true
    }

    $commsToAdd = @($wantedUsers.Keys | Where-Object { -not $commsMembers.ContainsKey($_) })
    if ($unresolvedUsers -gt 0) {
        Write-Warning ('{0} pilot user(s) could not be resolved; comms removals are skipped this run.' -f $unresolvedUsers)
    }
    else {
        $commsToRemove = @($commsMembers.Keys | Where-Object {
                -not $wantedUsers.ContainsKey($_) -and -not $commsOwners.ContainsKey($_)
            })
    }
}

# ---------------------------------------------------------------------------
# 6. Guards - evaluated before any write
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

Write-Output ('Plan: remove {0}, add {1}, deferred by cap {2}{3}.' -f $toRemove.Count, $toAdd.Count, $deferredCount,
    $(if ($CommsGroupId) { ', comms +{0}/-{1}' -f $commsToAdd.Count, $commsToRemove.Count } else { '' }))

# ---------------------------------------------------------------------------
# 7. Execute
# ---------------------------------------------------------------------------
$removedCount = 0
$addedCount = 0
$commsAddedCount = 0
$commsRemovedCount = 0
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
    $finalDeviceCount++
}

if ($deferredCount -gt 0) {
    Write-Output ('CAP REACHED ({0}): {1} device(s) deferred to a later run.' -f $MemberCap, $deferredCount)
}

if ($CommsGroupId) {
    foreach ($userId in $commsToAdd) {
        if (-not $PSCmdlet.ShouldProcess($wantedUsers[$userId], "Add user to comms group '$commsGroupName'")) { continue }
        $result = Invoke-PilotMembershipChange -Action Add -GroupId $CommsGroupId -ObjectId $userId
        Write-Output ('COMMS ADD ({0}): {1}' -f $result, $wantedUsers[$userId])
        if ($result -eq 'added') { $commsAddedCount++ }
    }
    foreach ($userId in $commsToRemove) {
        if (-not $PSCmdlet.ShouldProcess($commsMembers[$userId], "Remove user from comms group '$commsGroupName'")) { continue }
        $result = Invoke-PilotMembershipChange -Action Remove -GroupId $CommsGroupId -ObjectId $userId
        Write-Output ('COMMS REMOVE ({0}): {1}' -f $result, $commsMembers[$userId])
        if ($result -eq 'removed') { $commsRemovedCount++ }
    }
}

# ---------------------------------------------------------------------------
# 8. Summary and optional Teams notification
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
$summaryLines = @(
    ('{0}: pilot +{1} added, -{2} removed, {3} deferred by cap; {4} device(s) in group.' -f
        $timestamp, $addedCount, $removedCount, $deferredCount, $finalDeviceCount)
)
if ($CommsGroupId) {
    $summaryLines += ('Comms: +{0} added, -{1} removed.' -f $commsAddedCount, $commsRemovedCount)
}
if ($WhatIfPreference) {
    $summaryLines += 'WhatIf run: no changes were made.'
}
$summaryLines | Write-Output

$changeCount = $addedCount + $removedCount + $commsAddedCount + $commsRemovedCount
$hasWebhook = $TeamsWebhookUri -or $TeamsWebhookVariable
if ($hasWebhook -and -not $WhatIfPreference -and ($changeCount -gt 0 -or $deferredCount -gt 0)) {
    Send-PilotTeamsNotification -Uri $TeamsWebhookUri -VariableName $TeamsWebhookVariable -Lines $summaryLines
}
