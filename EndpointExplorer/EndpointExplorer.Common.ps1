#requires -Version 5.1
<#
.SYNOPSIS
Shared, testable logic for Export-EndpointInventory.ps1.

.DESCRIPTION
Dot-sourced by Export-EndpointInventory.ps1 and EndpointExplorer.Tests.ps1.
Contains the read-only Graph transport and boundary, paging, batching and
retry, device/app classification and aggregation, snapshot load/validation,
HTML rendering, and the Invoke-EndpointInventory orchestrator.

Graph surface (v1.0, GET only; see README.md 'Read-only boundary'):
  managedDevice  https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-manageddevice?view=graph-rest-1.0
  detectedApp    https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-detectedapp?view=graph-rest-1.0
  List managedDevices documents GET /deviceManagement/detectedApps/{id}/managedDevices.
  Entra device   https://learn.microsoft.com/en-us/graph/api/device-list?view=graph-rest-1.0
                 (Device.Read.All; supplies the device object id that Entra group
                 bulk import needs, so the report can build rollout exports offline)
  JSON batching: max 20 requests; each subrequest is throttled individually.
#>

Set-StrictMode -Version 3.0

$script:EndpointGraphRoot = 'https://graph.microsoft.com'
$script:EndpointGraphBase = "$script:EndpointGraphRoot/v1.0"
$script:EndpointMaxGraphAttempts = 5
$script:EndpointRetryableStatusCodes = @(429, 502, 503, 504, 509)
$script:EndpointRequiredScopes = @('DeviceManagementManagedDevices.Read.All', 'Device.Read.All')
$script:EndpointSchemaVersion = 2
$script:EndpointRecentDays = 7
$script:EndpointDeviceSelect = 'id,deviceName,userPrincipalName,lastSyncDateTime,managementAgent,deviceEnrollmentType,operatingSystem,osVersion,complianceState,model,manufacturer,serialNumber,azureADDeviceId,enrolledDateTime,managedDeviceOwnerType,deviceCategoryDisplayName,isEncrypted'
$script:EndpointAppSelect = 'id,displayName,version,publisher,platform,deviceCount,sizeInByte'
$script:EndpointEntraSelect = 'id,deviceId,approximateLastSignInDateTime'
$script:EndpointEmptyGuid = '00000000-0000-0000-0000-000000000000'
$script:EndpointDeviceFields = @('intuneDeviceId', 'deviceName', 'userPrincipalName', 'lastCheckIn', 'activityState', 'activityBucket',
    'managementType', 'managementAgent', 'enrollmentType', 'operatingSystem', 'osVersion', 'complianceState', 'model',
    'manufacturer', 'serialNumber', 'azureADDeviceId', 'entraObjectId', 'entraApproxLastSignIn', 'enrolledDateTime', 'ownerType', 'category',
    'isEncrypted', 'appRecordIndexes')
# detectedApp ids are opaque; allow URL-safe characters but never a bare '.' or '..' segment.
$script:EndpointAppIdPattern = '(?!\.{1,2}(?:/|\?|$))[0-9A-Za-z_.%=+-]+'

function Initialize-EndpointGraphState {
    $script:EndpointGraphState = @{ Session = $null; CallCount = 0; BatchSubrequestCount = 0 }
}
Initialize-EndpointGraphState

function Get-EndpointProperty {
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

#region Authentication (same approach as PhasedRollout/phased-rollout-creator.ps1)

function Test-EndpointBrokenAuthVersion {
    param([Parameter(Mandatory)] [version] $Version)
    $normalized = [version]('{0}.{1}.{2}' -f $Version.Major, $Version.Minor, [Math]::Max(0, $Version.Build))
    return ($normalized -ge [version]'2.41.0' -and $normalized -le [version]'2.41.1')
}

function Import-EndpointAuthModule {
    # Remove-Module cannot unload assemblies; an already-loaded version wins.
    $loadedAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.Graph.Authentication' } |
        Select-Object -First 1
    if ($loadedAssembly) {
        $loadedVersion = $loadedAssembly.GetName().Version
        if (Test-EndpointBrokenAuthVersion -Version $loadedVersion) {
            throw ('Microsoft.Graph.Authentication {0} is already loaded and cannot sign in (System.Text.Json bug #3810). Start a NEW PowerShell session.' -f $loadedVersion)
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
    $usable = @($installed | Where-Object { -not (Test-EndpointBrokenAuthVersion -Version $_.Version) } | Sort-Object Version -Descending)
    if ($usable.Count -eq 0) {
        throw 'Installed Microsoft.Graph.Authentication versions cannot sign in (System.Text.Json bug #3810). Run: Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser -Force'
    }
    if ($usable.Count -lt $installed.Count) {
        Write-Warning "Ignoring broken Microsoft.Graph.Authentication versions; using $($usable[0].Version)."
    }
    Import-Module $usable[0].Path
}

function Connect-EndpointGraph {
    param([string] $TenantId, [string[]] $Scopes, [switch] $DeviceCode)
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }
        $tokenUri = '{0}?resource={1}/' -f $env:IDENTITY_ENDPOINT, $script:EndpointGraphRoot
        $response = Invoke-RestMethod -Method Get -Uri $tokenUri -Headers $headers -UseBasicParsing
        $accessToken = Get-EndpointProperty $response 'access_token'
        if (-not $accessToken) { throw 'Managed identity endpoint returned no access token.' }
        return [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = [string]$accessToken; Account = 'managed identity' }
    }
    Import-EndpointAuthModule
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

#endregion

#region Read-only Graph transport

# Fail closed at the Graph boundary (README.md 'Read-only boundary'). Only GETs of managed
# devices, detected apps, one detected app's devices, and the Entra device
# list, plus a $batch of 1-20 bodiless GETs of a detected app's devices, are
# allowed. Everything else - writes,
# reports/exportJobs, device actions, beta, foreign hosts - throws before HTTP.
function Assert-EndpointReadRequest {
    param([string] $Method, [string] $Uri, $Body)
    $base = '^https://graph\.microsoft\.com/v1\.0/deviceManagement/'
    if ($Method -eq 'Get' -and $null -eq $Body -and (
            $Uri -match ($base + 'managedDevices(\?.*)?$') -or
            $Uri -match ($base + 'detectedApps(\?.*)?$') -or
            $Uri -match ($base + 'detectedApps/' + $script:EndpointAppIdPattern + '/managedDevices(\?.*)?$') -or
            $Uri -match '^https://graph\.microsoft\.com/v1\.0/devices(\?.*)?$')) { return }
    if ($Method -eq 'Post' -and $Uri -eq "$script:EndpointGraphBase/`$batch") {
        $requests = @(Get-EndpointProperty $Body 'requests')
        if ($requests.Count -lt 1 -or $requests.Count -gt 20) { throw 'Read-only batch must contain 1 to 20 GET requests.' }
        foreach ($request in $requests) {
            $url = [string](Get-EndpointProperty $request 'url')
            $readUrl = $url -match ('^/deviceManagement/detectedApps/' + $script:EndpointAppIdPattern + '/managedDevices\?\$select=id$')
            if ((Get-EndpointProperty $request 'method') -ne 'GET' -or -not $readUrl -or $null -ne (Get-EndpointProperty $request 'body')) {
                throw "Read-only Graph boundary rejected batch request: $url"
            }
        }
        return
    }
    throw "Read-only Graph boundary rejected $Method $Uri"
}

function Send-EndpointGraphRequest {
    # The only function that performs HTTP. Re-asserts the boundary on the
    # exact serialized body that is sent.
    param([Parameter(Mandatory)] [string] $Method, [Parameter(Mandatory)] [string] $Uri, [string] $BodyJson)
    $requestBody = if ($BodyJson) { $BodyJson | ConvertFrom-Json } else { $null }
    Assert-EndpointReadRequest -Method $Method -Uri $Uri -Body $requestBody
    $session = $script:EndpointGraphState.Session
    if ($null -eq $session) { throw 'Not connected to Microsoft Graph.' }
    if ($session.Mode -eq 'MgGraph') {
        $requestArgs = @{ Method = $Method; Uri = $Uri; OutputType = 'HttpResponseMessage'; SkipHttpErrorCheck = $true }
        if ($BodyJson) { $requestArgs.Body = $BodyJson; $requestArgs.ContentType = 'application/json' }
        $response = Invoke-MgGraphRequest @requestArgs
        if ($null -eq $response) { throw "Invoke-MgGraphRequest returned no response for $Method $Uri." }
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
        finally { if ($null -ne $response) { $response.Dispose() } }
    }
    $webArgs = @{
        Method = $Method; Uri = $Uri
        Headers = @{ Authorization = "Bearer $($session.Token)" }
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
        $errorResponse = Get-EndpointProperty $_.Exception 'Response'
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

function Get-EndpointRetryDelay {
    param([int] $Attempt, [int] $RetryAfter = 0)
    # Never shorten the service's Retry-After. Jitter applies to fallback only.
    if ($RetryAfter -gt 0) { return $RetryAfter }
    return [int][Math]::Min(60, 5 * [Math]::Pow(2, $Attempt - 1) + (Get-Random -Minimum 0 -Maximum 4))
}

function Invoke-EndpointGraph {
    param([Parameter(Mandatory)] [string] $Method, [Parameter(Mandatory)] [string] $Uri, [object] $Body, [int[]] $AllowStatus = @())
    $resolvedUri = if ($Uri.StartsWith('https://')) { $Uri } else { "$script:EndpointGraphBase$Uri" }
    Assert-EndpointReadRequest -Method $Method -Uri $resolvedUri -Body $Body
    $bodyJson = $null
    if ($null -ne $Body) { $bodyJson = $Body | ConvertTo-Json -Depth 10 -Compress }
    $authRefreshed = $false
    for ($attempt = 1; ; $attempt++) {
        $script:EndpointGraphState.CallCount++
        $result = Send-EndpointGraphRequest -Method $Method -Uri $resolvedUri -BodyJson $bodyJson
        if ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300) {
            if ([string]::IsNullOrWhiteSpace($result.Content)) { return $null }
            return ($result.Content | ConvertFrom-Json)
        }
        # Callers that can fall back (an unsupported filter) see these as $null.
        if ($AllowStatus -contains $result.StatusCode) { return $null }
        if ($result.StatusCode -eq 401 -and $script:EndpointGraphState.Session.Mode -eq 'ManagedIdentity' -and -not $authRefreshed) {
            $script:EndpointGraphState.Session = Connect-EndpointGraph
            $authRefreshed = $true
            continue
        }
        if ($script:EndpointRetryableStatusCodes -contains $result.StatusCode -and $attempt -lt $script:EndpointMaxGraphAttempts) {
            $delay = Get-EndpointRetryDelay -Attempt $attempt -RetryAfter $result.RetryAfter
            Write-Warning "Graph returned HTTP $($result.StatusCode); retrying in ${delay}s."
            Start-Sleep -Seconds $delay
            continue
        }
        throw "Graph $Method $resolvedUri failed with HTTP $($result.StatusCode): $($result.Content)"
    }
}

function Get-EndpointGraphPage {
    # Follows @odata.nextLink from an already-fetched first page (or from a URI).
    # A response without a 'value' collection throws rather than counting as empty.
    param([string] $Uri, $FirstPage)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $response = $FirstPage
    $source = $Uri
    if ($null -eq $response) { $response = Invoke-EndpointGraph -Method Get -Uri $Uri }
    while ($true) {
        if ($null -eq $response -or -not $response.PSObject.Properties['value']) {
            throw "Unexpected Graph response from $source (no 'value' collection)."
        }
        foreach ($item in @($response.value)) { $items.Add($item) }
        $nextUri = [string](Get-EndpointProperty $response '@odata.nextLink')
        if (-not $nextUri) { break }
        $source = $nextUri
        $response = Invoke-EndpointGraph -Method Get -Uri $nextUri
    }
    return $items.ToArray()
}

function Invoke-EndpointGraphBatch {
    # Sends GET subrequests 20 at a time. Retries throttled/transient
    # subrequests individually, honoring the largest Retry-After seen.
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Requests, [string] $Activity = 'Graph batch')
    $results = @{}
    for ($offset = 0; $offset -lt $Requests.Count; $offset += 20) {
        $last = [Math]::Min($offset + 19, $Requests.Count - 1)
        Write-Progress -Activity $Activity -Status "$offset of $($Requests.Count)" -PercentComplete ([int](100 * $offset / [Math]::Max(1, $Requests.Count)))
        $pending = @($Requests[$offset..$last])
        $authRefreshed = $false
        for ($attempt = 1; $pending.Count -gt 0; $attempt++) {
            $script:EndpointGraphState.BatchSubrequestCount += $pending.Count
            $response = Invoke-EndpointGraph -Method Post -Uri '/$batch' -Body @{ requests = $pending }
            $responses = Get-EndpointProperty $response 'responses'
            if ($null -eq $responses) { throw 'Graph $batch response had no responses collection.' }
            $byId = @{}
            foreach ($request in $pending) { $byId[[string]$request.id] = $request }
            $retry = New-Object 'System.Collections.Generic.List[object]'
            $delay = 0
            $throttled = $false
            $refreshAuth = $false
            $seenIds = @{}
            foreach ($item in @($responses)) {
                $id = [string](Get-EndpointProperty $item 'id')
                if (-not $byId.ContainsKey($id) -or $seenIds.ContainsKey($id)) { throw "Graph batch returned an unexpected or duplicate response id: $id" }
                $seenIds[$id] = $true
                $request = $byId[$id]
                $status = [int](Get-EndpointProperty $item 'status')
                if ($status -eq 401 -and $script:EndpointGraphState.Session.Mode -eq 'ManagedIdentity' -and -not $authRefreshed) {
                    $refreshAuth = $true
                    $retry.Add($request)
                    continue
                }
                if ($script:EndpointRetryableStatusCodes -contains $status -and $attempt -lt $script:EndpointMaxGraphAttempts) {
                    $retry.Add($request)
                    $throttled = $true
                    $parsedRetryAfter = 0
                    $retryAfterHeader = Get-EndpointProperty (Get-EndpointProperty $item 'headers') 'Retry-After'
                    if ([int]::TryParse([string]$retryAfterHeader, [ref]$parsedRetryAfter)) { $delay = [Math]::Max($delay, $parsedRetryAfter) }
                    continue
                }
                $results[$id] = [pscustomobject]@{ Status = $status; Body = (Get-EndpointProperty $item 'body') }
            }
            foreach ($request in $pending) {
                if (-not $seenIds.ContainsKey([string]$request.id)) { throw "Graph batch omitted response $($request.id)." }
            }
            if ($refreshAuth) {
                $script:EndpointGraphState.Session = Connect-EndpointGraph
                $authRefreshed = $true
            }
            # A retry caused only by a refreshed managed-identity token needs no wait.
            if ($throttled) {
                $delay = Get-EndpointRetryDelay -Attempt $attempt -RetryAfter $delay
                Write-Warning "$($retry.Count) batched request(s) will be retried in ${delay}s."
                Start-Sleep -Seconds $delay
            }
            $pending = @($retry.ToArray())
        }
    }
    Write-Progress -Activity $Activity -Completed
    foreach ($request in $Requests) {
        if (-not $results.ContainsKey([string]$request.id)) { throw "Graph batch returned no response for request $($request.id) ($($request.url))." }
    }
    return $results
}

#endregion

#region Pure helpers: timestamps, versions, classification

function ConvertTo-EndpointTimestamp {
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

function Format-EndpointTimestamp {
    param([DateTimeOffset] $Value)
    if ($Value -eq [DateTimeOffset]::MinValue -or $Value -eq [DateTimeOffset]::MaxValue) { return '' }
    return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-EndpointVersion {
    # Leading dotted number of an inventory version: '23.01' -> 23.1,
    # '12' -> 12.0, '1.2.3-beta' -> 1.2.3. Returns $null otherwise.
    param([AllowNull()] [AllowEmptyString()] [string] $Value)
    if ($null -eq $Value -or $Value.Trim() -notmatch '^\d+(\.\d+){0,3}') { return $null }
    $parts = @($Matches[0].Split('.'))
    if ($parts.Count -eq 1) { $parts += '0' }
    $parsed = $null
    if ([version]::TryParse(($parts -join '.'), [ref]$parsed)) { return $parsed }
    return $null
}

function Get-EndpointManagementType {
    # README.md 'Classification'. managementAgent values: managementAgentType enum (v1.0);
    # windowsCoManagement: managedDevice.deviceEnrollmentType (v1.0).
    param([AllowNull()] [AllowEmptyString()] [string] $ManagementAgent, [AllowNull()] [AllowEmptyString()] [string] $EnrollmentType)
    if (@('configurationManagerClientMdm', 'configurationManagerClientMdmEas') -contains $ManagementAgent) { return 'Co-managed' }
    if ($EnrollmentType -eq 'windowsCoManagement') { return 'Co-managed' }
    if ($ManagementAgent -eq 'mdm') { return 'Intune MDM' }
    if ($ManagementAgent -eq 'configurationManagerClient') { return 'ConfigMgr only' }
    if (@('eas', 'easMdm', 'intuneClient', 'easIntuneClient') -contains $ManagementAgent) { return 'EAS / legacy client' }
    return 'Other / Unknown'
}

function Get-EndpointActivity {
    # State is threshold-based (Active / Stale / Never). Bucket refines it for
    # charts: Recent (<= 7 days), Aging (older, still within the threshold),
    # Stale (beyond the threshold), Never. ActiveWithinDays 0 disables Stale.
    param([DateTimeOffset] $LastCheckIn, [Parameter(Mandatory)] [DateTimeOffset] $ReferenceTime, [int] $ActiveWithinDays)
    if ($LastCheckIn -eq [DateTimeOffset]::MinValue) { return [pscustomobject]@{ State = 'Never'; Bucket = 'Never' } }
    $age = $ReferenceTime - $LastCheckIn
    if ($ActiveWithinDays -gt 0 -and $age.TotalDays -gt $ActiveWithinDays) { return [pscustomobject]@{ State = 'Stale'; Bucket = 'Stale' } }
    if ($age.TotalDays -le $script:EndpointRecentDays) { return [pscustomobject]@{ State = 'Active'; Bucket = 'Recent' } }
    return [pscustomobject]@{ State = 'Active'; Bucket = 'Aging' }
}

function ConvertTo-EndpointDevice {
    param([Parameter(Mandatory)] $ManagedDevice, [Parameter(Mandatory)] [DateTimeOffset] $ReferenceTime, [int] $ActiveWithinDays)
    $lastCheckIn = ConvertTo-EndpointTimestamp (Get-EndpointProperty $ManagedDevice 'lastSyncDateTime')
    $activity = Get-EndpointActivity -LastCheckIn $lastCheckIn -ReferenceTime $ReferenceTime -ActiveWithinDays $ActiveWithinDays
    $agent = [string](Get-EndpointProperty $ManagedDevice 'managementAgent')
    $enrollment = [string](Get-EndpointProperty $ManagedDevice 'deviceEnrollmentType')
    $encrypted = Get-EndpointProperty $ManagedDevice 'isEncrypted'
    return [pscustomobject][ordered]@{
        intuneDeviceId = [string](Get-EndpointProperty $ManagedDevice 'id')
        deviceName = [string](Get-EndpointProperty $ManagedDevice 'deviceName')
        userPrincipalName = [string](Get-EndpointProperty $ManagedDevice 'userPrincipalName')
        lastCheckIn = Format-EndpointTimestamp $lastCheckIn
        activityState = $activity.State
        activityBucket = $activity.Bucket
        managementType = Get-EndpointManagementType -ManagementAgent $agent -EnrollmentType $enrollment
        managementAgent = $agent
        enrollmentType = $enrollment
        operatingSystem = [string](Get-EndpointProperty $ManagedDevice 'operatingSystem')
        osVersion = [string](Get-EndpointProperty $ManagedDevice 'osVersion')
        complianceState = [string](Get-EndpointProperty $ManagedDevice 'complianceState')
        model = [string](Get-EndpointProperty $ManagedDevice 'model')
        manufacturer = [string](Get-EndpointProperty $ManagedDevice 'manufacturer')
        serialNumber = [string](Get-EndpointProperty $ManagedDevice 'serialNumber')
        azureADDeviceId = [string](Get-EndpointProperty $ManagedDevice 'azureADDeviceId')
        entraObjectId = ''
        entraApproxLastSignIn = ''
        enrolledDateTime = Format-EndpointTimestamp (ConvertTo-EndpointTimestamp (Get-EndpointProperty $ManagedDevice 'enrolledDateTime'))
        ownerType = [string](Get-EndpointProperty $ManagedDevice 'managedDeviceOwnerType')
        category = [string](Get-EndpointProperty $ManagedDevice 'deviceCategoryDisplayName')
        isEncrypted = if ($null -eq $encrypted) { $null } else { [bool]$encrypted }
        appRecordIndexes = @()
    }
}

#endregion

#region Graph pulls

function Get-EndpointManagedDevice {
    # operatingSystem is not documented as filterable on managedDevice (v1.0),
    # so the server filter is an optimization only: a 400 falls back to the full
    # listing, an empty result is confirmed against it, and the client-side
    # check always decides.
    param([switch] $WindowsOnly, [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Warnings)
    $baseUri = "$script:EndpointGraphBase/deviceManagement/managedDevices?`$select=$script:EndpointDeviceSelect&`$top=1000"
    $devices = $null
    $confirmEmpty = $false
    if ($WindowsOnly) {
        $filter = [uri]::EscapeDataString("operatingSystem eq 'Windows'")
        $first = Invoke-EndpointGraph -Method Get -Uri "$baseUri&`$filter=$filter" -AllowStatus 400
        if ($null -eq $first -or -not $first.PSObject.Properties['value']) {
            $message = 'Server-side Windows filter was rejected; listed all managed devices and filtered locally.'
            Write-Warning $message
            $Warnings.Add($message)
        }
        else {
            $devices = @(Get-EndpointGraphPage -FirstPage $first -Uri "$baseUri&`$filter=$filter")
            # Empty may mean the filter was ignored or matched differently.
            if ($devices.Count -eq 0) { $devices = $null; $confirmEmpty = $true }
        }
    }
    if ($null -eq $devices) { $devices = @(Get-EndpointGraphPage -Uri $baseUri) }
    $seen = @{}
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($device in $devices) {
        $id = [string](Get-EndpointProperty $device 'id')
        if (-not $id) { continue }
        if ($WindowsOnly -and [string](Get-EndpointProperty $device 'operatingSystem') -ne 'Windows') { continue }
        if ($seen.ContainsKey($id)) { throw "Device listing returned duplicate id '$id'. Refusing a potentially unstable population; rerun." }
        $seen[$id] = $true
        $result.Add($device)
    }
    if ($confirmEmpty -and $result.Count -gt 0) {
        $message = "Server-side Windows filter returned no devices, but the full listing has $($result.Count); the filter is unreliable in this tenant."
        Write-Warning $message
        $Warnings.Add($message)
    }
    return $result.ToArray()
}

function Get-EndpointDetectedApp {
    # One detectedApp per name/version/platform. Platform filtering is local;
    # server-side filter support on detectedApps is not assumed.
    param([switch] $WindowsOnly)
    $uri = "$script:EndpointGraphBase/deviceManagement/detectedApps?`$select=$script:EndpointAppSelect"
    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($app in @(Get-EndpointGraphPage -Uri $uri)) {
        $platform = [string](Get-EndpointProperty $app 'platform')
        if ($WindowsOnly -and $platform -ne 'windows') { continue }
        $deviceCount = 0
        [void][int]::TryParse([string](Get-EndpointProperty $app 'deviceCount'), [ref]$deviceCount)
        $size = [long]0
        [void][long]::TryParse([string](Get-EndpointProperty $app 'sizeInByte'), [ref]$size)
        $records.Add([pscustomobject][ordered]@{
                id = [string](Get-EndpointProperty $app 'id')
                name = [string](Get-EndpointProperty $app 'displayName')
                version = [string](Get-EndpointProperty $app 'version')
                publisher = [string](Get-EndpointProperty $app 'publisher')
                platform = $platform
                deviceCount = $deviceCount
                sizeInByte = $size
            })
    }
    return $records.ToArray()
}

function ConvertTo-EndpointEntraKey {
    # Canonical lowercase 'D' GUID (as PhasedRollout uses), or '' when the value
    # is missing, the empty GUID, or not a GUID.
    param([AllowNull()] [AllowEmptyString()] [string] $Value)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) { return '' }
    return $parsed.ToString('D')
}

function Get-EndpointEntraDeviceIndex {
    # Lists Entra devices (999 per page) and keys them by canonical deviceId.
    # -WindowsOnly filters server-side on operatingSystem (documented $filter
    # eq on device v1.0); a 400 falls back to the full list. A deviceId listed
    # twice is ambiguous: it maps to $null so those Intune devices get no object
    # id (and are skipped by rollout exports) instead of failing the whole run.
    param([switch] $WindowsOnly)
    $baseUri = "$script:EndpointGraphBase/devices?`$select=$script:EndpointEntraSelect&`$top=999"
    $items = $null
    $filtered = $false
    if ($WindowsOnly) {
        $filterUri = "$baseUri&`$filter=$([uri]::EscapeDataString("operatingSystem eq 'Windows'"))"
        $first = Invoke-EndpointGraph -Method Get -Uri $filterUri -AllowStatus 400
        if ($null -ne $first -and $first.PSObject.Properties['value']) {
            $items = @(Get-EndpointGraphPage -FirstPage $first -Uri $filterUri)
            $filtered = $true
        }
    }
    if ($null -eq $items) { $items = @(Get-EndpointGraphPage -Uri $baseUri) }
    $index = @{}
    $duplicates = 0
    foreach ($item in $items) {
        $key = ConvertTo-EndpointEntraKey ([string](Get-EndpointProperty $item 'deviceId'))
        if (-not $key) { continue }
        if ($index.ContainsKey($key)) { $index[$key] = $null; $duplicates++; continue }
        $index[$key] = [pscustomobject]@{
            Id = [string](Get-EndpointProperty $item 'id')
            ApproxLastSignIn = Format-EndpointTimestamp (ConvertTo-EndpointTimestamp (Get-EndpointProperty $item 'approximateLastSignInDateTime'))
        }
    }
    return [pscustomobject]@{ Index = $index; Duplicates = $duplicates; Filtered = $filtered }
}

function Get-EndpointDeviceAppMap {
    # Resolves detectedApps/{id}/managedDevices for every app record through
    # $batch. Returns intuneDeviceId -> sorted record indexes. A 404 (app record
    # removed mid-run) is tolerated and counted; any other failure throws.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $AppRecords,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $DeviceIds
    )
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $DeviceIds) { [void]$known.Add($id) }
    $requests = @(for ($i = 0; $i -lt $AppRecords.Count; $i++) {
            @{ id = [string]$i; method = 'GET'; url = "/deviceManagement/detectedApps/$([uri]::EscapeDataString($AppRecords[$i].id))/managedDevices?`$select=id" }
        })
    $results = Invoke-EndpointGraphBatch -Requests $requests -Activity 'Resolving installed apps per device'
    $map = @{}
    $missingApps = 0
    $outOfScope = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $AppRecords.Count; $i++) {
        $result = $results[[string]$i]
        if ($result.Status -eq 404) { $missingApps++; continue }
        if ($result.Status -ne 200) { throw "Device lookup for detected app '$($AppRecords[$i].name)' failed with HTTP $($result.Status)." }
        $nextLink = [string](Get-EndpointProperty $result.Body '@odata.nextLink')
        $devices = if ($nextLink) { @(Get-EndpointGraphPage -FirstPage $result.Body -Uri $nextLink) } else { @(Get-EndpointProperty $result.Body 'value') }
        foreach ($device in $devices) {
            $deviceId = [string](Get-EndpointProperty $device 'id')
            if (-not $deviceId) { continue }
            if (-not $known.Contains($deviceId)) { [void]$outOfScope.Add($deviceId); continue }
            if (-not $map.ContainsKey($deviceId)) { $map[$deviceId] = New-Object 'System.Collections.Generic.List[int]' }
            $map[$deviceId].Add($i)
        }
    }
    return [pscustomobject]@{ Map = $map; MissingApps = $missingApps; OutOfScopeDevices = $outOfScope.Count }
}

#endregion

#region Snapshot model

function ConvertTo-EndpointAppSummary {
    # Groups app records by name + publisher + platform. With a device map the
    # device count is exact (distinct devices); without it, it is the sum of
    # per-version Intune counts, so a device with two versions counts twice.
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $AppRecords,
        [hashtable] $DeviceAppMap
    )
    $groups = [ordered]@{}
    for ($i = 0; $i -lt $AppRecords.Count; $i++) {
        $record = $AppRecords[$i]
        $key = ('{0}|{1}|{2}' -f $record.name, $record.publisher, $record.platform).ToLowerInvariant()
        if (-not $groups.Contains($key)) {
            $groups[$key] = @{ Record = $record; Indexes = New-Object 'System.Collections.Generic.List[int]'; Devices = $null }
        }
        $groups[$key].Indexes.Add($i)
    }
    $groupOfIndex = @{}
    foreach ($key in $groups.Keys) { foreach ($index in $groups[$key].Indexes) { $groupOfIndex[$index] = $key } }
    if ($null -ne $DeviceAppMap) {
        foreach ($key in $groups.Keys) { $groups[$key].Devices = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
        foreach ($deviceId in $DeviceAppMap.Keys) {
            foreach ($index in $DeviceAppMap[$deviceId]) { [void]$groups[$groupOfIndex[[int]$index]].Devices.Add($deviceId) }
        }
    }
    $summary = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $groups.Keys) {
        $group = $groups[$key]
        $indexes = @($group.Indexes.ToArray() | Sort-Object -Property @(
                @{ Expression = { $parsed = ConvertTo-EndpointVersion $AppRecords[$_].version; if ($null -eq $parsed) { [version]'0.0' } else { $parsed } }; Descending = $true },
                @{ Expression = { $AppRecords[$_].version }; Descending = $true }))
        $versions = New-Object 'System.Collections.Generic.List[string]'
        foreach ($index in $indexes) { if (-not $versions.Contains($AppRecords[$index].version)) { $versions.Add($AppRecords[$index].version) } }
        $count = 0
        if ($null -ne $group.Devices) { $count = $group.Devices.Count }
        else { foreach ($index in $indexes) { $count += $AppRecords[$index].deviceCount } }
        $summary.Add([pscustomobject][ordered]@{
                name = $group.Record.name
                publisher = $group.Record.publisher
                platform = $group.Record.platform
                versions = @($versions.ToArray())
                deviceCount = $count
                isInstalledVersionApprox = ($null -eq $group.Devices)
                recordIndexes = @($indexes)
            })
    }
    return @($summary.ToArray() | Sort-Object -Property @{ Expression = 'deviceCount'; Descending = $true }, @{ Expression = 'name'; Descending = $false })
}

function Get-EndpointInventorySnapshot {
    # Performs every Graph read and returns the snapshot object. No local writes.
    param([switch] $WindowsOnly, [switch] $IncludeDeviceApps, [int] $ActiveWithinDays)
    $generatedAt = [DateTimeOffset]::UtcNow
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    Write-Information 'Listing Intune managed devices...' -InformationAction Continue
    $managedDevices = @(Get-EndpointManagedDevice -WindowsOnly:$WindowsOnly -Warnings $warnings)
    $devices = @(foreach ($managed in $managedDevices) { ConvertTo-EndpointDevice -ManagedDevice $managed -ReferenceTime $generatedAt -ActiveWithinDays $ActiveWithinDays })
    Write-Information "Devices: $($devices.Count)" -InformationAction Continue
    Write-Information 'Listing Entra devices (object IDs for rollout exports)...' -InformationAction Continue
    $entra = Get-EndpointEntraDeviceIndex -WindowsOnly:$WindowsOnly
    # An Intune Windows device whose Entra object reports a different OS string
    # is missing from the filtered list; resolve those with one full listing.
    if ($entra.Filtered) {
        $missing = @($devices | Where-Object { $key = ConvertTo-EndpointEntraKey $_.azureADDeviceId; $key -and -not $entra.Index.ContainsKey($key) }).Count
        if ($missing -gt 0) {
            Write-Information "$missing device(s) not in the Windows-filtered Entra list; listing all Entra devices..." -InformationAction Continue
            $entra = Get-EndpointEntraDeviceIndex
        }
    }
    if ($entra.Duplicates -gt 0) {
        $warnings.Add("$($entra.Duplicates) Entra deviceId value(s) appear on more than one Entra device object; those devices have no Entra object ID and are skipped by rollout exports.")
    }
    $entraIndex = $entra.Index
    $unmatched = 0
    foreach ($device in $devices) {
        $key = ConvertTo-EndpointEntraKey $device.azureADDeviceId
        if ($key -and $entraIndex.ContainsKey($key) -and $null -ne $entraIndex[$key]) {
            $device.entraObjectId = $entraIndex[$key].Id
            $device.entraApproxLastSignIn = $entraIndex[$key].ApproxLastSignIn
        }
        else { $unmatched++ }
    }
    if ($unmatched -gt 0) { $warnings.Add("$unmatched device(s) have no matching Entra device object; rollout exports skip them.") }
    Write-Information 'Listing detected apps...' -InformationAction Continue
    $appRecords = @(Get-EndpointDetectedApp -WindowsOnly:$WindowsOnly)
    Write-Information "Detected app records: $($appRecords.Count)" -InformationAction Continue
    $map = $null
    if ($IncludeDeviceApps) {
        $batchCount = [Math]::Ceiling($appRecords.Count / 20)
        Write-Information "Resolving devices per app record ($($appRecords.Count) lookups in about $batchCount batch call(s))..." -InformationAction Continue
        $resolution = Get-EndpointDeviceAppMap -AppRecords $appRecords -DeviceIds @($devices | ForEach-Object { $_.intuneDeviceId })
        $map = $resolution.Map
        if ($resolution.MissingApps -gt 0) {
            $warnings.Add("$($resolution.MissingApps) detected app record(s) disappeared during the run (HTTP 404) and have no device mapping.")
        }
        if ($resolution.OutOfScopeDevices -gt 0) {
            $warnings.Add("$($resolution.OutOfScopeDevices) device(s) reported by app inventory are outside this snapshot's device scope and were ignored.")
        }
        foreach ($device in $devices) {
            if ($map.ContainsKey($device.intuneDeviceId)) {
                $device.appRecordIndexes = @($map[$device.intuneDeviceId].ToArray() | Sort-Object -Unique)
            }
        }
    }
    $apps = @(ConvertTo-EndpointAppSummary -AppRecords $appRecords -DeviceAppMap $map)
    return [pscustomobject][ordered]@{
        schemaVersion = $script:EndpointSchemaVersion
        generatedAt = Format-EndpointTimestamp $generatedAt
        scopes = @($script:EndpointRequiredScopes)
        source = [pscustomobject][ordered]@{
            windowsOnly = [bool]$WindowsOnly
            includeDeviceApps = [bool]$IncludeDeviceApps
            graphCalls = $script:EndpointGraphState.CallCount
            batchSubrequests = $script:EndpointGraphState.BatchSubrequestCount
        }
        thresholds = [pscustomobject][ordered]@{ activeWithinDays = $ActiveWithinDays; recentDays = $script:EndpointRecentDays }
        devices = @($devices)
        apps = @($apps)
        appRecords = @($appRecords)
        warnings = @($warnings.ToArray())
    }
}

function Test-EndpointSnapshot {
    # Returns a list of problems; empty means the snapshot is usable. An invalid
    # file is never rendered as an empty report.
    param($Snapshot)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Snapshot -or $Snapshot -is [string] -or $Snapshot -is [array]) { $problems.Add('Snapshot is not a JSON object.'); return $problems.ToArray() }
    foreach ($name in @('schemaVersion', 'generatedAt', 'source', 'thresholds', 'devices', 'apps', 'appRecords', 'warnings')) {
        if (-not $Snapshot.PSObject.Properties[$name]) { $problems.Add("Missing '$name'.") }
    }
    if ($problems.Count -gt 0) { return $problems.ToArray() }
    if ([string]$Snapshot.schemaVersion -ne [string]$script:EndpointSchemaVersion) { $problems.Add("Unsupported schemaVersion '$($Snapshot.schemaVersion)' (expected $script:EndpointSchemaVersion).") }
    if ((ConvertTo-EndpointTimestamp $Snapshot.generatedAt) -eq [DateTimeOffset]::MinValue) { $problems.Add('generatedAt is not a valid timestamp.') }
    foreach ($name in @('windowsOnly', 'includeDeviceApps')) {
        if (-not $Snapshot.source.PSObject.Properties[$name]) { $problems.Add("Missing 'source.$name'.") }
    }
    foreach ($name in @('devices', 'apps', 'appRecords')) {
        if ($null -eq $Snapshot.$name) { $problems.Add("'$name' is null.") }
    }
    if ($problems.Count -gt 0) { return $problems.ToArray() }
    $recordCount = @($Snapshot.appRecords).Count
    $index = 0
    foreach ($device in @($Snapshot.devices)) {
        $missing = @($script:EndpointDeviceFields | Where-Object { -not $device.PSObject.Properties[$_] })
        if ($missing.Count -gt 0) { $problems.Add("Device #$index is missing: $($missing -join ', ')."); break }
        foreach ($recordIndex in @($device.appRecordIndexes)) {
            if (($recordIndex -isnot [int] -and $recordIndex -isnot [long]) -or $recordIndex -lt 0 -or $recordIndex -ge $recordCount) {
                $problems.Add("Device #$index references an invalid app record index '$recordIndex'."); break
            }
        }
        $index++
    }
    return $problems.ToArray()
}

function Import-EndpointSnapshot {
    # Loads and validates a cached snapshot, normalizes timestamps (PowerShell 7
    # parses ISO strings to DateTime), and recomputes activity relative to the
    # snapshot time with the current -ActiveWithinDays.
    param([Parameter(Mandatory)] [string] $Path, [int] $ActiveWithinDays)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Snapshot '$Path' is empty." }
    try { $snapshot = $raw | ConvertFrom-Json }
    catch { throw "Snapshot '$Path' is not valid JSON: $($_.Exception.Message)" }
    $problems = @(Test-EndpointSnapshot -Snapshot $snapshot)
    if ($problems.Count -gt 0) { throw "Snapshot '$Path' is invalid: $($problems -join ' ')" }
    $generatedAt = ConvertTo-EndpointTimestamp $snapshot.generatedAt
    $snapshot.generatedAt = Format-EndpointTimestamp $generatedAt
    $snapshot.devices = @($snapshot.devices)
    $snapshot.apps = @($snapshot.apps)
    $snapshot.appRecords = @($snapshot.appRecords)
    $snapshot.warnings = @($snapshot.warnings)
    foreach ($device in $snapshot.devices) {
        $lastCheckIn = ConvertTo-EndpointTimestamp $device.lastCheckIn
        $device.lastCheckIn = Format-EndpointTimestamp $lastCheckIn
        $device.enrolledDateTime = Format-EndpointTimestamp (ConvertTo-EndpointTimestamp $device.enrolledDateTime)
        $device.entraApproxLastSignIn = Format-EndpointTimestamp (ConvertTo-EndpointTimestamp $device.entraApproxLastSignIn)
        $device.appRecordIndexes = @($device.appRecordIndexes)
        $activity = Get-EndpointActivity -LastCheckIn $lastCheckIn -ReferenceTime $generatedAt -ActiveWithinDays $ActiveWithinDays
        $device.activityState = $activity.State
        $device.activityBucket = $activity.Bucket
    }
    foreach ($app in $snapshot.apps) {
        $app.versions = @($app.versions)
        $app.recordIndexes = @($app.recordIndexes)
    }
    $snapshot.thresholds = [pscustomobject][ordered]@{ activeWithinDays = $ActiveWithinDays; recentDays = $script:EndpointRecentDays }
    return $snapshot
}

function Get-EndpointCacheMismatch {
    # Returns why a cached snapshot cannot satisfy the request, or '' if it can.
    param([Parameter(Mandatory)] $Snapshot, [switch] $WindowsOnly, [switch] $IncludeDeviceApps)
    if ([bool]$Snapshot.source.windowsOnly -ne [bool]$WindowsOnly) {
        $cachedScope = if ($Snapshot.source.windowsOnly) { 'Windows only' } else { 'all platforms' }
        return "cached snapshot scope is $cachedScope"
    }
    if ($IncludeDeviceApps -and -not $Snapshot.source.includeDeviceApps) { return 'cached snapshot has no per-device apps' }
    return ''
}

#endregion

#region Rendering

function ConvertTo-EndpointJson {
    # Compact JSON with '<', '>' and '&' written as JSON unicode escapes
    # (backslash, 'u', four hex digits). Those characters can only occur inside
    # JSON strings, so the replacement is lossless and a '</script>' in any
    # field cannot end the embedding element. Windows PowerShell 5.1 already
    # escapes them; PowerShell 7 does not. The escapes are built at runtime so
    # the source stays free of literal escape sequences.
    param([Parameter(Mandatory)] $InputObject)
    $json = ConvertTo-Json -InputObject $InputObject -Depth 10 -Compress
    foreach ($character in @('<', '>', '&')) {
        $json = $json.Replace($character, ('{0}u{1:x4}' -f [char]92, [int][char]$character))
    }
    return $json
}

function ConvertTo-EndpointHtml {
    param([Parameter(Mandatory)] $Snapshot)
    $template = Get-EndpointHtmlTemplate
    return $template.Replace('/*__ENDPOINT_DATA__*/', (ConvertTo-EndpointJson -InputObject $Snapshot))
}

function ConvertTo-EndpointCsvSafeRow {
    # Spreadsheet formula injection (OWASP "CSV Injection"): a text cell that
    # starts with = + - @ tab or CR is prefixed with a single quote so Excel
    # shows it as text. Device names, UPNs, and app names are user-influenced.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Row)
    $safe = [ordered]@{}
    foreach ($key in $Row.Keys) {
        $value = $Row[$key]
        if ($value -is [string] -and $value -match '^[=+\-@\t\r]') { $value = "'" + $value }
        $safe[$key] = $value
    }
    return [pscustomobject]$safe
}

function Get-EndpointDeviceCsvRow {
    param([Parameter(Mandatory)] $Snapshot)
    foreach ($device in @($Snapshot.devices)) {
        ConvertTo-EndpointCsvSafeRow ([ordered]@{
            DeviceName = $device.deviceName; UserPrincipalName = $device.userPrincipalName
            LastCheckIn = $device.lastCheckIn; ActivityState = $device.activityState; ActivityBucket = $device.activityBucket
            ManagementType = $device.managementType; ManagementAgent = $device.managementAgent; EnrollmentType = $device.enrollmentType
            OperatingSystem = $device.operatingSystem; OSVersion = $device.osVersion; ComplianceState = $device.complianceState
            Manufacturer = $device.manufacturer; Model = $device.model; SerialNumber = $device.serialNumber
            OwnerType = $device.ownerType; Category = $device.category; IsEncrypted = $device.isEncrypted
            EnrolledDateTime = $device.enrolledDateTime; IntuneDeviceId = $device.intuneDeviceId; AzureADDeviceId = $device.azureADDeviceId
            EntraObjectId = $device.entraObjectId; EntraApproxLastSignIn = $device.entraApproxLastSignIn
            AppRecordCount = @($device.appRecordIndexes).Count
        })
    }
}

function Get-EndpointAppCsvRow {
    param([Parameter(Mandatory)] $Snapshot)
    foreach ($app in @($Snapshot.apps)) {
        ConvertTo-EndpointCsvSafeRow ([ordered]@{
            Name = $app.name; Publisher = $app.publisher; Platform = $app.platform
            Versions = (@($app.versions) -join '; '); VersionCount = @($app.versions).Count
            DeviceCount = $app.deviceCount; DeviceCountIsApproximate = $app.isInstalledVersionApprox
        })
    }
}

function Get-EndpointDeviceAppCsvRow {
    param([Parameter(Mandatory)] $Snapshot)
    $records = @($Snapshot.appRecords)
    foreach ($device in @($Snapshot.devices)) {
        foreach ($index in @($device.appRecordIndexes)) {
            $record = $records[[int]$index]
            ConvertTo-EndpointCsvSafeRow ([ordered]@{
                DeviceName = $device.deviceName; UserPrincipalName = $device.userPrincipalName; IntuneDeviceId = $device.intuneDeviceId
                AppName = $record.name; Publisher = $record.publisher; Version = $record.version; Platform = $record.platform
            })
        }
    }
}

function Get-EndpointHtmlTemplate {
    # Self-contained: no external scripts, styles, fonts, or URLs. The data
    # placeholder sits inside a JSON script element and is parsed with
    # JSON.parse; all rendered values go through esc() before innerHTML.
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Endpoint Explorer</title>
<style>
:root {
  color-scheme: light;
  --surface-0: #f4f4f2; --surface-1: #fcfcfb; --surface-2: #efeeea; --border: #dcdbd5;
  --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #6f6e69;
  --series-1: #2a78d6; --accent: #1c5cab; --row-hover: #eef4fc;
  --good: #0ca30c; --warning: #b37600; --critical: #d03b3b;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --surface-0: #121211; --surface-1: #1a1a19; --surface-2: #242422; --border: #383835;
    --text-primary: #f0efec; --text-secondary: #c3c2b7; --text-muted: #9b9a91;
    --series-1: #3987e5; --accent: #86b6ef; --row-hover: #1f2a38;
    --good: #0ca30c; --warning: #fab219; --critical: #e66767;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --surface-0: #121211; --surface-1: #1a1a19; --surface-2: #242422; --border: #383835;
  --text-primary: #f0efec; --text-secondary: #c3c2b7; --text-muted: #9b9a91;
  --series-1: #3987e5; --accent: #86b6ef; --row-hover: #1f2a38;
  --good: #0ca30c; --warning: #fab219; --critical: #e66767;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--surface-0); color: var(--text-primary);
  font: 14px/1.45 "Segoe UI", system-ui, -apple-system, sans-serif; }
header { padding: 20px 24px 12px; }
h1 { margin: 0 0 4px; font-size: 22px; font-weight: 600; }
h2 { margin: 0 0 12px; font-size: 16px; font-weight: 600; }
.meta { color: var(--text-secondary); font-size: 13px; display: flex; flex-wrap: wrap; gap: 2px 14px; }
.meta span { white-space: nowrap; }
.note { color: var(--text-muted); font-size: 12px; margin-top: 6px; }
.warn { color: var(--warning); }
main { padding: 0 24px 32px; }
section { background: var(--surface-1); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-top: 16px; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; }
.card { background: var(--surface-1); border: 1px solid var(--border); border-radius: 8px; padding: 12px 14px; }
.card .label { color: var(--text-secondary); font-size: 12px; }
.card .value { font-size: 24px; font-weight: 600; font-variant-numeric: tabular-nums; }
.card .sub { color: var(--text-muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; }
.chart h3 { margin: 0 0 8px; font-size: 13px; font-weight: 600; color: var(--text-secondary); }
.bar-row { display: grid; grid-template-columns: minmax(130px, 30%) 1fr 64px; align-items: center; gap: 8px; padding: 3px 4px; border-radius: 4px; }
.bar-row.clickable { cursor: pointer; }
.bar-row.clickable:hover { background: var(--row-hover); }
.bar-label { font-size: 12px; color: var(--text-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.bar-track { height: 14px; }
.bar { height: 14px; background: var(--series-1); border-radius: 0 4px 4px 0; min-width: 2px; }
.bar-value { font-size: 12px; text-align: right; font-variant-numeric: tabular-nums; color: var(--text-primary); }
.toolbar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 10px; }
input[type=search], select { background: var(--surface-1); color: var(--text-primary); border: 1px solid var(--border);
  border-radius: 6px; padding: 6px 8px; font: inherit; }
input[type=search] { min-width: 260px; flex: 1 1 260px; max-width: 420px; }
button { background: var(--surface-2); color: var(--text-primary); border: 1px solid var(--border); border-radius: 6px; padding: 5px 10px; font: inherit; cursor: pointer; }
button:disabled { opacity: .5; cursor: default; }
.count { color: var(--text-secondary); font-size: 12px; }
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); white-space: nowrap; }
th { position: sticky; top: 0; background: var(--surface-2); cursor: pointer; user-select: none; font-weight: 600; }
th.sorted-asc::after { content: " \25B2"; font-size: 10px; }
th.sorted-desc::after { content: " \25BC"; font-size: 10px; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
tbody tr { cursor: pointer; }
tbody tr:hover { background: var(--row-hover); }
.pager { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
.pill { display: inline-block; padding: 0 6px; border-radius: 8px; font-size: 12px; border: 1px solid var(--border); }
.pill.good { color: var(--good); border-color: var(--good); }
.pill.bad { color: var(--critical); border-color: var(--critical); }
.pill.warn { color: var(--warning); border-color: var(--warning); }
/* Floating card inset from the viewport edges, so its scrollbar sits apart
   from the page scrollbar (the page stays scrollable while it is open). */
#drawer { position: fixed; top: 8px; right: 8px; bottom: 8px; width: clamp(560px, 38vw, 900px); background: var(--surface-1);
  border: 1px solid var(--border); border-radius: 10px; box-shadow: 0 8px 28px rgba(0,0,0,.28);
  transform: translateX(calc(100% + 24px)); transition: transform .15s ease-out; overflow-y: auto; padding: 16px 20px; z-index: 10;
  scrollbar-width: thin; scrollbar-color: var(--border) transparent; }
#drawer.open { transform: none; }
@media (prefers-reduced-motion: reduce) { #drawer { transition: none; } }
#drawer dl { display: grid; grid-template-columns: 150px 1fr; gap: 4px 12px; margin: 0 0 16px; font-size: 13px; }
#drawer dt { color: var(--text-secondary); }
#drawer dd { margin: 0; word-break: break-word; }
#drawer td { white-space: normal; overflow-wrap: break-word; }
.drawer-head { display: flex; justify-content: space-between; align-items: start; gap: 12px; margin-bottom: 12px; }
.empty { color: var(--text-muted); padding: 12px 0; }
.primary { background: var(--series-1); border-color: var(--series-1); color: #fff; }
input[type=text], input[type=number] { background: var(--surface-1); color: var(--text-primary); border: 1px solid var(--border);
  border-radius: 6px; padding: 5px 8px; font: inherit; }
label.inline { display: flex; gap: 6px; align-items: center; font-size: 12px; color: var(--text-secondary); }
th.check, td.check { width: 28px; }
.rollout-panel { border: 1px solid var(--border); border-radius: 8px; padding: 12px 14px; margin: 12px 0 16px; background: var(--surface-2); }
.rollout-form { display: flex; flex-wrap: wrap; gap: 12px 20px; align-items: flex-end; margin-bottom: 10px; }
.rollout-form label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--text-secondary); }
.rollout-form label.check { flex-direction: row; align-items: center; gap: 6px; }
.rollout-panel table { margin: 6px 0 10px; }
.error { color: var(--critical); }
.ok { color: var(--good); }
</style>
</head>
<body>
<header>
  <h1>Endpoint Explorer</h1>
  <div class="meta" id="meta"></div>
  <div class="note">Read-only Microsoft Graph export (GET only). App inventory comes from Intune discovered apps, which refresh about every 7 days per device, so recent installs and removals can lag. Treat this file as sensitive: it contains device names, users, and serial numbers.</div>
  <div class="note warn" id="warnings"></div>
</header>
<main>
  <div class="cards" id="cards"></div>
  <section><h2>Overview</h2><div class="charts" id="charts"></div></section>
  <section id="devices-section">
    <h2>Devices</h2>
    <div class="toolbar">
      <input type="search" id="device-search" placeholder="Search name, user, serial, model, OS version" aria-label="Search devices">
      <select id="device-mgmt" aria-label="Management type"><option value="">All management types</option></select>
      <select id="device-activity" aria-label="Activity"><option value="">All activity</option></select>
      <select id="device-compliance" aria-label="Compliance"><option value="">All compliance</option></select>
      <span class="count" id="device-count"></span>
    </div>
    <div class="table-wrap"><table id="device-table"><thead></thead><tbody></tbody></table></div>
    <div class="pager" id="device-pager"></div>
  </section>
  <section id="apps-section">
    <h2>Installed apps</h2>
    <div class="toolbar">
      <input type="search" id="app-search" placeholder="Search app name or publisher" aria-label="Search apps">
      <span class="count" id="app-count"></span>
    </div>
    <div class="table-wrap"><table id="app-table"><thead></thead><tbody></tbody></table></div>
    <div class="pager" id="app-pager"></div>
  </section>
</main>
<aside id="drawer" aria-hidden="true"></aside>
<script id="endpoint-data" type="application/json">/*__ENDPOINT_DATA__*/</script>
<script id="rollout-lib">
/* Phased rollout export, computed from the snapshot with no Graph calls.
   A port of PhasedRollout/phased-rollout-creator.ps1 (detected-app mode,
   -DeviceLookup Bulk): same device selection, lowest-version rule, Entra
   de-duplication, ordinal EntraDeviceId order, largest-remainder phases,
   Active/Inactive split, file names, columns, quoting, UTF-8 BOM, and CRLF.
   Pure (no DOM), so EndpointExplorer.Tests.ps1 runs it under Node and
   compares its files with the script's. */
var EndpointRollout = (function () {
  'use strict';
  var IMPORT_HEADER = 'Member object ID or user principal name [memberObjectIdOrUpn] Required';
  var DETAIL_COLUMNS = ['Phase', 'PhaseLabel', 'DeviceName', 'EntraObjectId', 'EntraDeviceId', 'IntuneManagedDeviceId',
    'PrimaryUserPrincipalName', 'AppName', 'AppVersion', 'InstallState', 'StatusLastModified', 'ActivityState', 'LastCheckIn', 'EntraApproxLastSignIn'];
  var GUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  var EMPTY_GUID = '00000000-0000-0000-0000-000000000000';
  var NL = String.fromCharCode(13, 10);
  var DAY_MS = 86400000;

  // ConvertTo-PilotVersion: leading dotted number; one part gets '.0'.
  // Missing components are -1, as in System.Version, so 3.0 < 3.0.0.
  function parseVersion(text) {
    if (text === null || text === undefined) { return null; }
    var m = /^\d+(\.\d+){0,3}/.exec(String(text).trim());
    if (!m) { return null; }
    var parts = m[0].split('.').map(Number);
    if (parts.length === 1) { parts.push(0); }
    for (var i = 0; i < parts.length; i++) { if (parts[i] > 2147483647) { return null; } }
    while (parts.length < 4) { parts.push(-1); }
    return parts;
  }
  function compareVersion(a, b) {
    for (var i = 0; i < 4; i++) { if (a[i] !== b[i]) { return a[i] < b[i] ? -1 : 1; } }
    return 0;
  }
  // Test-PilotLowerVersion: an unparsed version never replaces a parsed one.
  function isLower(candidate, current) {
    if (candidate === null) { return false; }
    return current === null || compareVersion(candidate, current) < 0;
  }
  function ticks(ts) {
    if (!ts) { return -Infinity; }
    var t = Date.parse(String(ts).replace(/(\.\d{3})\d+/, '$1'));
    return isNaN(t) ? -Infinity : t;
  }
  function ordinal(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
  function ordinalIgnoreCase(a, b) { return ordinal(a.toUpperCase(), b.toUpperCase()); }
  // Get-RolloutPhaseCount: floor, then largest remainders; earlier phases win ties.
  function phaseCounts(count, percentages) {
    var alloc = percentages.map(function (p, i) { var product = count * p; return { index: i, count: Math.floor(product / 100), rem: product % 100 }; });
    var remaining = count - alloc.reduce(function (sum, a) { return sum + a.count; }, 0);
    var ranked = alloc.slice().sort(function (x, y) { return (y.rem - x.rem) || (x.index - y.index); });
    for (var i = 0; i < remaining; i++) { ranked[i].count++; }
    return alloc.map(function (a) { return a.count; });
  }
  function parsePercentages(text) {
    var parts = String(text || '').split(/[\s,]+/).filter(function (x) { return x !== ''; });
    if (!parts.length) { return { error: 'Enter at least one percentage.' }; }
    var values = [], sum = 0;
    for (var i = 0; i < parts.length; i++) {
      if (!/^\d+$/.test(parts[i]) || +parts[i] < 1 || +parts[i] > 100) { return { error: 'Each percentage must be a whole number from 1 to 100.' }; }
      values.push(+parts[i]); sum += +parts[i];
    }
    if (sum !== 100) { return { error: 'Percentages must total 100 (currently ' + sum + ').' }; }
    return { values: values };
  }
  // Formula-injection guard, identical to phased-rollout-creator.ps1: text
  // starting with = + - @ tab or CR gets a leading single quote.
  function csvField(v) {
    var text = String(v === null || v === undefined ? '' : v);
    if (/^[=+\-@\t\r]/.test(text)) { text = "'" + text; }
    return '"' + text.replace(/"/g, '""') + '"';
  }
  function pad(n, w) { n = String(n); while (n.length < w) { n = '0' + n; } return n; }
  // Get-Date -Format 'yyyyMMdd-HHmmss-fff' (local time).
  function stamp(d) {
    return pad(d.getFullYear(), 4) + pad(d.getMonth() + 1, 2) + pad(d.getDate(), 2) + '-' +
      pad(d.getHours(), 2) + pad(d.getMinutes(), 2) + pad(d.getSeconds(), 2) + '-' + pad(d.getMilliseconds(), 3);
  }
  function fileSafe(name) { return String(name || 'app').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'app'; }

  // options: percentages, activeWithinDays, requirePrimaryUser, stamp,
  // referenceTime (ms; defaults to the snapshot time).
  function build(data, recordIndexes, options) {
    var percentages = options.percentages, days = options.activeWithinDays;
    var records = data.appRecords || [], devices = data.devices || [];
    var selected = {}, byIntune = {}, matches = {};
    recordIndexes.forEach(function (ri) { selected[ri] = true; });
    // Each device keeps its lowest matching version; for equal versions the
    // earlier inventory record wins, as in the script's per-app loop.
    devices.forEach(function (d) {
      byIntune[d.intuneDeviceId] = d;
      (d.appRecordIndexes || []).slice().sort(function (x, y) { return x - y; }).forEach(function (ri) {
        if (!selected[ri]) { return; }
        var r = records[ri], parsed = parseVersion(r.version), existing = matches[d.intuneDeviceId];
        if (existing && !isLower(parsed, existing.parsed)) { return; }
        matches[d.intuneDeviceId] = { appName: r.name, appVersion: r.version, parsed: parsed };
      });
    });
    var intuneIds = Object.keys(matches).sort(ordinalIgnoreCase);
    var skipped = [], entra = {};
    intuneIds.forEach(function (id) {
      var d = byIntune[id], match = matches[id];
      var deviceId = String(d.azureADDeviceId || '').toLowerCase();
      if (!deviceId || deviceId === EMPTY_GUID || !GUID.test(deviceId)) { skipped.push({ reason: 'no Entra device id', deviceName: d.deviceName }); return; }
      var entry = entra[deviceId], lastCheckIn = d.lastCheckIn || '';
      if (!entry) {
        entra[deviceId] = { deviceName: d.deviceName, upn: d.userPrincipalName || '', intuneId: id, appName: match.appName,
          appVersion: match.appVersion, parsed: match.parsed, lastCheckIn: lastCheckIn, objectId: d.entraObjectId || '', approx: d.entraApproxLastSignIn || '' };
        return;
      }
      // Several Intune records for one Entra device: keep the first record's
      // identity, fill a missing UPN, take the newest check-in and lowest version.
      if (!entry.upn) { entry.upn = d.userPrincipalName || ''; }
      if (ticks(lastCheckIn) > ticks(entry.lastCheckIn)) { entry.lastCheckIn = lastCheckIn; }
      if (isLower(match.parsed, entry.parsed)) { entry.appName = match.appName; entry.appVersion = match.appVersion; entry.parsed = match.parsed; }
    });
    var noPrimaryUser = Object.keys(entra).filter(function (k) { return !entra[k].upn; });
    if (options.requirePrimaryUser) {
      noPrimaryUser.forEach(function (k) { skipped.push({ reason: 'no primary user', deviceName: entra[k].deviceName }); delete entra[k]; });
    }
    var reference = options.referenceTime !== undefined ? options.referenceTime : ticks(data.generatedAt);
    var cutoff = days > 0 ? reference - days * DAY_MS : -Infinity;
    var rows = [];
    Object.keys(entra).sort(ordinal).forEach(function (key) {
      var e = entra[key];
      if (!e.objectId) { skipped.push({ reason: 'no Entra device object', deviceName: e.deviceName }); return; }
      var t = ticks(e.lastCheckIn);
      rows.push({
        Phase: 0, PhaseLabel: '', DeviceName: e.deviceName, EntraObjectId: e.objectId, EntraDeviceId: key, IntuneManagedDeviceId: e.intuneId,
        PrimaryUserPrincipalName: e.upn, AppName: e.appName, AppVersion: e.appVersion, InstallState: 'detected', StatusLastModified: '',
        ActivityState: (days === 0 || (t !== -Infinity && t >= cutoff)) ? 'Active' : 'Inactive',
        LastCheckIn: e.lastCheckIn, EntraApproxLastSignIn: e.approx
      });
    });
    var active = rows.filter(function (r) { return r.ActivityState === 'Active'; });
    var inactive = rows.filter(function (r) { return r.ActivityState === 'Inactive'; });
    var inactiveLabel = 'Inactive (no check-in for ' + days + '+ days)';
    inactive.forEach(function (r) { r.PhaseLabel = inactiveLabel; });
    var counts = phaseCounts(active.length, percentages), offset = 0;
    for (var p = 0; p < percentages.length; p++) {
      for (var i = 0; i < counts[p]; i++) {
        active[offset].Phase = p + 1;
        active[offset].PhaseLabel = 'Phase ' + (p + 1) + ' (' + percentages[p] + '%)';
        offset++;
      }
    }
    var exportRows = active.concat(inactive), tag = options.stamp, files = [];
    var detail = [DETAIL_COLUMNS.map(csvField).join(',')].concat(exportRows.map(function (r) {
      return DETAIL_COLUMNS.map(function (c) { return csvField(r[c]); }).join(',');
    }));
    files.push({ name: 'PhasedRolloutDetail-' + tag + '.csv', text: detail.join(NL) + NL });
    for (var phase = 1; phase <= percentages.length; phase++) {
      var ids = exportRows.filter(function (r) { return r.Phase === phase; }).map(function (r) { return r.EntraObjectId; });
      files.push({ name: 'Phase' + phase + '-EntraGroupImport-' + tag + '.csv', text: [IMPORT_HEADER].concat(ids).join(NL) + NL });
    }
    files.push({ name: 'Inactive-EntraGroupImport-' + tag + '.csv', text: [IMPORT_HEADER].concat(inactive.map(function (r) { return r.EntraObjectId; })).join(NL) + NL });
    return {
      rows: exportRows, files: files, phaseCounts: counts, active: active.length, inactive: inactive.length,
      matched: intuneIds.length, skipped: skipped, noPrimaryUser: options.requirePrimaryUser ? 0 : noPrimaryUser.length, cutoff: cutoff
    };
  }

  // Minimal ZIP writer (stored, no compression). Each CSV gets a UTF-8 BOM,
  // as Windows PowerShell 5.1 Export-Csv/Set-Content -Encoding UTF8 write.
  var CRC_TABLE = (function () {
    var table = [], c;
    for (var n = 0; n < 256; n++) {
      c = n;
      for (var k = 0; k < 8; k++) { c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); }
      table[n] = c >>> 0;
    }
    return table;
  })();
  function crc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) { c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8); }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
  function utf8WithBom(text) {
    var body = new TextEncoder().encode(text), out = new Uint8Array(body.length + 3);
    out.set([0xEF, 0xBB, 0xBF]); out.set(body, 3);
    return out;
  }
  function zip(files, date) {
    var d = date || new Date();
    var time = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
    var day = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
    var parts = [], central = [], offset = 0;
    files.forEach(function (f) {
      var name = new TextEncoder().encode(f.name), data = utf8WithBom(f.text), crc = crc32(data);
      var local = new DataView(new ArrayBuffer(30));
      local.setUint32(0, 0x04034b50, true); local.setUint16(4, 20, true); local.setUint16(6, 0, true); local.setUint16(8, 0, true);
      local.setUint16(10, time, true); local.setUint16(12, day, true); local.setUint32(14, crc, true);
      local.setUint32(18, data.length, true); local.setUint32(22, data.length, true);
      local.setUint16(26, name.length, true); local.setUint16(28, 0, true);
      parts.push(new Uint8Array(local.buffer), name, data);
      var entry = new DataView(new ArrayBuffer(46));
      entry.setUint32(0, 0x02014b50, true); entry.setUint16(4, 20, true); entry.setUint16(6, 20, true);
      entry.setUint16(8, 0, true); entry.setUint16(10, 0, true); entry.setUint16(12, time, true); entry.setUint16(14, day, true);
      entry.setUint32(16, crc, true); entry.setUint32(20, data.length, true); entry.setUint32(24, data.length, true);
      entry.setUint16(28, name.length, true); entry.setUint16(30, 0, true); entry.setUint16(32, 0, true);
      entry.setUint16(34, 0, true); entry.setUint16(36, 0, true); entry.setUint32(38, 0, true); entry.setUint32(42, offset, true);
      central.push(new Uint8Array(entry.buffer), name);
      offset += 30 + name.length + data.length;
    });
    var centralSize = central.reduce(function (sum, x) { return sum + x.length; }, 0);
    var end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true); end.setUint16(8, files.length, true); end.setUint16(10, files.length, true);
    end.setUint32(12, centralSize, true); end.setUint32(16, offset, true);
    var all = parts.concat(central, [new Uint8Array(end.buffer)]);
    var out = new Uint8Array(offset + centralSize + 22), at = 0;
    all.forEach(function (x) { out.set(x, at); at += x.length; });
    return out;
  }

  return { build: build, zip: zip, parseVersion: parseVersion, compareVersion: compareVersion, phaseCounts: phaseCounts,
    parsePercentages: parsePercentages, stamp: stamp, fileSafe: fileSafe, DETAIL_COLUMNS: DETAIL_COLUMNS };
})();
</script>
<script>
(function () {
  'use strict';
  var data = JSON.parse(document.getElementById('endpoint-data').textContent);
  var devices = data.devices || [];
  var apps = data.apps || [];
  var records = data.appRecords || [];
  var hasDeviceApps = !!(data.source && data.source.includeDeviceApps);
  var PAGE = 100;

  function esc(v) {
    if (v === null || v === undefined) { return ''; }
    return String(v).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function fmtDate(v) {
    if (!v) { return ''; }
    var d = new Date(v);
    if (isNaN(d.getTime())) { return String(v); }
    return d.toISOString().replace('T', ' ').substring(0, 16) + ' UTC';
  }
  function num(n) { return Number(n || 0).toLocaleString(); }
  function countBy(list, fn) {
    var m = {};
    list.forEach(function (x) { var k = fn(x) || '(blank)'; m[k] = (m[k] || 0) + 1; });
    return m;
  }
  function pillFor(state) {
    var s = String(state || '').toLowerCase();
    var cls = s === 'compliant' ? 'good' : (s === 'noncompliant' || s === 'error' || s === 'conflict') ? 'bad' : s === 'ingraceperiod' ? 'warn' : '';
    return '<span class="pill ' + cls + '">' + esc(state || 'unknown') + '</span>';
  }

  // Index: app record -> device indexes (only when per-device data exists).
  var devicesByRecord = null;
  if (hasDeviceApps) {
    devicesByRecord = {};
    devices.forEach(function (d, di) {
      (d.appRecordIndexes || []).forEach(function (ri) { (devicesByRecord[ri] = devicesByRecord[ri] || []).push(di); });
    });
  }

  // Header
  var gen = new Date(data.generatedAt);
  var ageH = (Date.now() - gen.getTime()) / 36e5;
  var age = ageH < 1 ? Math.round(ageH * 60) + ' min' : ageH < 48 ? ageH.toFixed(1) + ' h' : (ageH / 24).toFixed(1) + ' days';
  document.getElementById('meta').innerHTML =
    '<span>Generated ' + esc(fmtDate(data.generatedAt)) + ' (' + esc(age) + ' ago)</span>' +
    '<span>Scope: ' + (data.source.windowsOnly ? 'Windows devices' : 'all platforms') + '</span>' +
    '<span>Per-device apps: ' + (hasDeviceApps ? 'included' : 'not collected') + '</span>' +
    '<span>Active window: ' + esc(data.thresholds.activeWithinDays) + ' days</span>' +
    '<span>Graph calls: ' + esc(data.source.graphCalls) + '</span>';
  if (data.warnings && data.warnings.length) {
    document.getElementById('warnings').innerHTML = data.warnings.map(function (w) { return 'Warning: ' + esc(w); }).join('<br>');
  }

  // Cards
  var mgmt = countBy(devices, function (d) { return d.managementType; });
  var act = countBy(devices, function (d) { return d.activityState; });
  var comp = countBy(devices, function (d) { return d.complianceState; });
  var top = apps.length ? apps[0] : null;
  var cards = [
    ['Devices', num(devices.length), data.source.windowsOnly ? 'Windows' : 'All platforms'],
    ['Active', num(act.Active), 'checked in within ' + data.thresholds.activeWithinDays + ' days'],
    ['Stale', num(act.Stale), 'no check-in beyond threshold'],
    ['Never checked in', num(act.Never), ''],
    ['Co-managed', num(mgmt['Co-managed']), 'ConfigMgr + Intune'],
    ['Intune MDM', num(mgmt['Intune MDM']), 'Intune only'],
    ['ConfigMgr only', num(mgmt['ConfigMgr only']), ''],
    ['Compliant', num(comp.compliant), num(comp.noncompliant) + ' noncompliant'],
    ['Distinct apps', num(apps.length), num(records.length) + ' name/version records'],
    ['Top app', top ? num(top.deviceCount) : '0', top ? top.name : '']
  ];
  document.getElementById('cards').innerHTML = cards.map(function (c) {
    return '<div class="card"><div class="label">' + esc(c[0]) + '</div><div class="value">' + esc(c[1]) +
      '</div><div class="sub" title="' + esc(c[2]) + '">' + esc(c[2]) + '</div></div>';
  }).join('');

  // Charts: single-series horizontal bars, direct-labeled; clicking a bar filters the device table.
  function barChart(title, counts, order, filterId, limit) {
    var keys = order ? order.filter(function (k) { return counts[k]; }) : Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; });
    var other = 0;
    if (limit && keys.length > limit) {
      keys.slice(limit).forEach(function (k) { other += counts[k]; });
      keys = keys.slice(0, limit);
    }
    var rows = keys.map(function (k) { return [k, counts[k], true]; });
    if (other) { rows.push(['Other', other, false]); }
    var max = Math.max.apply(null, rows.map(function (r) { return r[1]; }).concat([1]));
    var total = devices.length || 1;
    var html = '<div class="chart"><h3>' + esc(title) + '</h3>';
    if (!rows.length) { html += '<div class="empty">No data</div>'; }
    rows.forEach(function (r) {
      var pct = (100 * r[1] / total).toFixed(1);
      var click = filterId && r[2];
      html += '<div class="bar-row' + (click ? ' clickable' : '') + '"' +
        (click ? ' data-filter="' + esc(filterId) + '" data-value="' + esc(r[0]) + '"' : '') +
        ' title="' + esc(r[0]) + ': ' + num(r[1]) + ' devices (' + pct + '%)' + (click ? ' - click to filter' : '') + '">' +
        '<div class="bar-label">' + esc(r[0]) + '</div>' +
        '<div class="bar-track"><div class="bar" style="width:' + (100 * r[1] / max).toFixed(2) + '%"></div></div>' +
        '<div class="bar-value">' + num(r[1]) + '</div></div>';
    });
    return html + '</div>';
  }
  var buckets = countBy(devices, function (d) { return d.activityBucket; });
  var osv = countBy(devices, function (d) { return d.osVersion; });
  var chartsEl = document.getElementById('charts');
  chartsEl.innerHTML =
    barChart('Management type', mgmt, null, 'device-mgmt') +
    barChart('Last check-in', buckets, ['Recent', 'Aging', 'Stale', 'Never'], 'activity-bucket') +
    barChart('Compliance', comp, null, 'device-compliance') +
    barChart('OS version (top 10)', osv, null, 'os-version', 10);

  // Device table
  var deviceState = { q: '', mgmt: '', activity: '', compliance: '', bucket: '', os: '', sort: 'deviceName', dir: 1, page: 0 };
  var deviceCols = [
    ['deviceName', 'Device'], ['userPrincipalName', 'Primary user'], ['lastCheckIn', 'Last check-in'],
    ['activityBucket', 'Activity'], ['managementType', 'Management'], ['osVersion', 'OS version'],
    ['model', 'Model'], ['serialNumber', 'Serial'], ['complianceState', 'Compliance']
  ];
  if (hasDeviceApps) { deviceCols.push(['appCount', 'Apps', true]); }
  devices.forEach(function (d) { d.appCount = (d.appRecordIndexes || []).length; });

  function fillSelect(id, counts) {
    var el = document.getElementById(id);
    Object.keys(counts).sort().forEach(function (k) {
      var o = document.createElement('option'); o.value = k; o.textContent = k + ' (' + counts[k] + ')'; el.appendChild(o);
    });
  }
  fillSelect('device-mgmt', mgmt);
  fillSelect('device-activity', act);
  fillSelect('device-compliance', comp);

  function cmp(a, b, key, dir) {
    var x = a[key], y = b[key];
    if (typeof x === 'number' || typeof y === 'number') { return ((x || 0) - (y || 0)) * dir; }
    x = (x === null || x === undefined) ? '' : String(x).toLowerCase();
    y = (y === null || y === undefined) ? '' : String(y).toLowerCase();
    if (x === y) { return 0; }
    if (x === '') { return 1; }
    if (y === '') { return -1; }
    return (x < y ? -1 : 1) * dir;
  }
  function header(tableId, cols, state, render) {
    var thead = document.querySelector('#' + tableId + ' thead');
    thead.innerHTML = '<tr>' + cols.map(function (c) {
      var cls = (c[2] ? 'num ' : '') + (state.sort === c[0] ? (state.dir === 1 ? 'sorted-asc' : 'sorted-desc') : '');
      return '<th data-key="' + c[0] + '" class="' + cls + '">' + esc(c[1]) + '</th>';
    }).join('') + '</tr>';
    thead.onclick = function (e) {
      var th = e.target.closest('th'); if (!th) { return; }
      var key = th.getAttribute('data-key');
      if (state.sort === key) { state.dir = -state.dir; } else { state.sort = key; state.dir = 1; }
      state.page = 0; render();
    };
  }
  function pager(id, state, total, render) {
    var pages = Math.max(1, Math.ceil(total / PAGE));
    if (state.page >= pages) { state.page = pages - 1; }
    var el = document.getElementById(id);
    el.innerHTML = '<button data-p="prev"' + (state.page === 0 ? ' disabled' : '') + '>Previous</button>' +
      '<span class="count">Page ' + (state.page + 1) + ' of ' + pages + '</span>' +
      '<button data-p="next"' + (state.page >= pages - 1 ? ' disabled' : '') + '>Next</button>';
    el.onclick = function (e) {
      var b = e.target.closest('button'); if (!b || b.disabled) { return; }
      state.page += b.getAttribute('data-p') === 'next' ? 1 : -1; render();
    };
  }
  function filteredDevices() {
    var q = deviceState.q.toLowerCase();
    return devices.filter(function (d) {
      if (deviceState.mgmt && d.managementType !== deviceState.mgmt) { return false; }
      if (deviceState.activity && d.activityState !== deviceState.activity) { return false; }
      if (deviceState.compliance && (d.complianceState || '(blank)') !== deviceState.compliance) { return false; }
      if (deviceState.bucket && d.activityBucket !== deviceState.bucket) { return false; }
      if (deviceState.os && (d.osVersion || '(blank)') !== deviceState.os) { return false; }
      if (!q) { return true; }
      return [d.deviceName, d.userPrincipalName, d.serialNumber, d.model, d.manufacturer, d.osVersion].some(function (v) {
        return v && String(v).toLowerCase().indexOf(q) !== -1;
      });
    });
  }
  var currentDevices = [];
  function renderDevices() {
    header('device-table', deviceCols, deviceState, renderDevices);
    var list = filteredDevices().sort(function (a, b) { return cmp(a, b, deviceState.sort, deviceState.dir); });
    currentDevices = list;
    var extra = [];
    if (deviceState.bucket) { extra.push('check-in: ' + deviceState.bucket); }
    if (deviceState.os) { extra.push('OS: ' + deviceState.os); }
    document.getElementById('device-count').innerHTML = num(list.length) + ' of ' + num(devices.length) + ' devices' +
      (extra.length ? ' (' + esc(extra.join(', ')) + ') <button id="clear-chart-filter">Clear</button>' : '');
    var clear = document.getElementById('clear-chart-filter');
    if (clear) { clear.onclick = function () { deviceState.bucket = ''; deviceState.os = ''; deviceState.page = 0; renderDevices(); }; }
    pager('device-pager', deviceState, list.length, renderDevices);
    var start = deviceState.page * PAGE;
    var rows = list.slice(start, start + PAGE).map(function (d, i) {
      return '<tr data-i="' + (start + i) + '">' + deviceCols.map(function (c) {
        var v = d[c[0]];
        if (c[0] === 'lastCheckIn') { v = fmtDate(v); }
        if (c[0] === 'complianceState') { return '<td>' + pillFor(v) + '</td>'; }
        return '<td' + (c[2] ? ' class="num"' : '') + '>' + esc(v) + '</td>';
      }).join('') + '</tr>';
    });
    document.querySelector('#device-table tbody').innerHTML = rows.length ? rows.join('') :
      '<tr><td colspan="' + deviceCols.length + '" class="empty">No devices match.</td></tr>';
  }
  document.querySelector('#device-table tbody').onclick = function (e) {
    var tr = e.target.closest('tr[data-i]'); if (tr) { openDevice(currentDevices[+tr.getAttribute('data-i')]); }
  };
  document.getElementById('device-search').oninput = function (e) { deviceState.q = e.target.value; deviceState.page = 0; renderDevices(); };
  document.getElementById('device-mgmt').onchange = function (e) { deviceState.mgmt = e.target.value; deviceState.page = 0; renderDevices(); };
  document.getElementById('device-activity').onchange = function (e) { deviceState.activity = e.target.value; deviceState.page = 0; renderDevices(); };
  document.getElementById('device-compliance').onchange = function (e) { deviceState.compliance = e.target.value; deviceState.page = 0; renderDevices(); };
  chartsEl.onclick = function (e) {
    var row = e.target.closest('.bar-row.clickable'); if (!row) { return; }
    var f = row.getAttribute('data-filter'), v = row.getAttribute('data-value');
    if (f === 'activity-bucket') { deviceState.bucket = v; }
    else if (f === 'os-version') { deviceState.os = v; }
    else { document.getElementById(f).value = v; deviceState[f === 'device-mgmt' ? 'mgmt' : 'compliance'] = v; }
    deviceState.page = 0; renderDevices();
    document.getElementById('devices-section').scrollIntoView({ behavior: 'smooth' });
  };

  // App table
  var appState = { q: '', sort: 'deviceCount', dir: -1, page: 0 };
  var appCols = [['name', 'App'], ['publisher', 'Publisher'], ['versionText', 'Versions'], ['platform', 'Platform'], ['deviceCount', 'Devices', true]];
  apps.forEach(function (a, i) {
    a._i = i;
    var v = a.versions || [];
    a.versionText = v.length > 3 ? v.slice(0, 3).join(', ') + ' +' + (v.length - 3) + ' more' : v.join(', ');
  });
  var currentApps = [];
  function renderApps() {
    header('app-table', appCols, appState, renderApps);
    var q = appState.q.toLowerCase();
    var list = apps.filter(function (a) {
      return !q || (a.name && a.name.toLowerCase().indexOf(q) !== -1) || (a.publisher && a.publisher.toLowerCase().indexOf(q) !== -1);
    }).sort(function (a, b) { return cmp(a, b, appState.sort, appState.dir); });
    currentApps = list;
    var approx = apps.some(function (a) { return a.isInstalledVersionApprox; });
    document.getElementById('app-count').textContent = num(list.length) + ' of ' + num(apps.length) + ' apps' +
      (approx ? ' - device counts sum each version\'s count, so a device with two versions counts twice' : '');
    pager('app-pager', appState, list.length, renderApps);
    var start = appState.page * PAGE;
    var rows = list.slice(start, start + PAGE).map(function (a, i) {
      return '<tr data-i="' + (start + i) + '">' + appCols.map(function (c) {
        return '<td' + (c[2] ? ' class="num"' : '') + '>' + esc(c[2] ? num(a[c[0]]) : a[c[0]]) + '</td>';
      }).join('') + '</tr>';
    });
    document.querySelector('#app-table tbody').innerHTML = rows.length ? rows.join('') :
      '<tr><td colspan="' + appCols.length + '" class="empty">No apps match.</td></tr>';
  }
  document.querySelector('#app-table tbody').onclick = function (e) {
    var tr = e.target.closest('tr[data-i]'); if (tr) { openApp(currentApps[+tr.getAttribute('data-i')]); }
  };
  document.getElementById('app-search').oninput = function (e) { appState.q = e.target.value; appState.page = 0; renderApps(); };

  // Drawer
  var drawer = document.getElementById('drawer');
  function openDrawer(html) {
    drawer.innerHTML = html; drawer.classList.add('open'); drawer.setAttribute('aria-hidden', 'false');
    var close = drawer.querySelector('.close'); if (close) { close.focus(); }
  }
  function closeDrawer() { drawer.classList.remove('open'); drawer.setAttribute('aria-hidden', 'true'); }
  drawer.onclick = function (e) {
    if (e.target.closest('.close')) { closeDrawer(); return; }
    var action = e.target.closest('[data-act]');
    if (action) { rolloutAction(action.getAttribute('data-act')); return; }
    var link = e.target.closest('[data-device]');
    if (link) { openDevice(devices[+link.getAttribute('data-device')]); return; }
    var appLink = e.target.closest('[data-app]');
    if (appLink) { openApp(apps[+appLink.getAttribute('data-app')]); }
  };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { closeDrawer(); } });
  // A click anywhere outside the drawer closes it, except a click on another
  // table row, which swaps the drawer content instead of closing it.
  document.addEventListener('click', function (e) {
    // composedPath() is fixed at dispatch, so a click on drawer content that
    // re-rendered the drawer (a device or app link) still counts as inside.
    if (!drawer.classList.contains('open') || e.composedPath().indexOf(drawer) !== -1) { return; }
    if (e.target.closest('#device-table tbody tr[data-i], #app-table tbody tr[data-i]')) { return; }
    closeDrawer();
  });
  function dl(pairs) {
    return '<dl>' + pairs.map(function (p) { return '<dt>' + esc(p[0]) + '</dt><dd>' + esc(p[1]) + '</dd>'; }).join('') + '</dl>';
  }
  var appOfRecord = {};
  apps.forEach(function (a, i) { (a.recordIndexes || []).forEach(function (ri) { appOfRecord[ri] = i; }); });
  function openDevice(d) {
    if (!d) { return; }
    var html = '<div class="drawer-head"><h2>' + esc(d.deviceName || '(no name)') + '</h2><button class="close">Close</button></div>' +
      dl([
        ['Primary user', d.userPrincipalName], ['Last check-in', fmtDate(d.lastCheckIn)], ['Activity', d.activityState + ' (' + d.activityBucket + ')'],
        ['Management type', d.managementType], ['Management agent', d.managementAgent], ['Enrollment type', d.enrollmentType],
        ['Operating system', d.operatingSystem], ['OS version', d.osVersion], ['Compliance', d.complianceState],
        ['Manufacturer', d.manufacturer], ['Model', d.model], ['Serial number', d.serialNumber],
        ['Ownership', d.ownerType], ['Category', d.category], ['Encrypted', d.isEncrypted === null ? '' : (d.isEncrypted ? 'Yes' : 'No')],
        ['Enrolled', fmtDate(d.enrolledDateTime)], ['Intune device ID', d.intuneDeviceId], ['Entra device ID', d.azureADDeviceId],
        ['Entra object ID', d.entraObjectId], ['Entra last sign-in (approx.)', fmtDate(d.entraApproxLastSignIn)]
      ]);
    if (!hasDeviceApps) {
      html += '<div class="empty">Per-device apps were not collected. Rerun with -IncludeDeviceApps.</div>';
    } else {
      var list = (d.appRecordIndexes || []).filter(function (ri) { return records[ri]; })
        .sort(function (x, y) { return cmp(records[x], records[y], 'name', 1); });
      html += '<h2>Installed apps (' + list.length + ')</h2>';
      html += list.length ? '<div class="table-wrap"><table><thead><tr><th>App</th><th>Version</th><th>Publisher</th></tr></thead><tbody>' +
        list.map(function (ri) {
          var r = records[ri], ai = appOfRecord[ri];
          return '<tr' + (ai !== undefined ? ' data-app="' + ai + '"' : '') + '><td>' + esc(r.name) + '</td><td>' + esc(r.version) + '</td><td>' + esc(r.publisher) + '</td></tr>';
        }).join('') + '</tbody></table></div>' : '<div class="empty">No detected apps for this device.</div>';
    }
    openDrawer(html);
  }
  // App drawer with version selection and the phased rollout export.
  var rollout = { app: null, selected: {}, result: null };
  function openApp(a) {
    if (!a) { return; }
    rollout = { app: a, selected: {}, result: null };
    var html = '<div class="drawer-head"><h2>' + esc(a.name || '(no name)') + '</h2><button class="close">Close</button></div>' +
      dl([['Publisher', a.publisher], ['Platform', a.platform], ['Devices', num(a.deviceCount) + (a.isInstalledVersionApprox ? ' (approximate)' : '')]]);
    html += '<h2>Versions</h2>';
    if (hasDeviceApps) {
      html += '<div class="toolbar">' +
        '<button data-act="sel-all">Select all</button><button data-act="sel-none">Clear</button>' +
        '<label class="inline">Below version <input type="text" id="below-version" size="12" placeholder="e.g. 3.0.21"></label>' +
        '<button data-act="sel-below">Select</button><span class="count" id="sel-summary"></span>' +
        '<button class="primary" data-act="rollout-open" id="rollout-open" disabled>Create rollout export</button></div>';
    }
    html += '<div class="table-wrap"><table><thead><tr>' + (hasDeviceApps ? '<th class="check"></th>' : '') +
      '<th>Version</th><th class="num">Devices (Intune)</th>' + (hasDeviceApps ? '<th class="num">Devices (snapshot)</th>' : '') + '</tr></thead><tbody>' +
      (a.recordIndexes || []).map(function (ri) {
        var r = records[ri]; if (!r) { return ''; }
        return '<tr>' + (hasDeviceApps ? '<td class="check"><input type="checkbox" data-ri="' + ri + '" aria-label="Select version ' + esc(r.version) + '"></td>' : '') +
          '<td>' + esc(r.version) + '</td><td class="num">' + num(r.deviceCount) + '</td>' +
          (hasDeviceApps ? '<td class="num">' + num((devicesByRecord[ri] || []).length) + '</td>' : '') + '</tr>';
      }).join('') + '</tbody></table></div><div id="rollout-panel"></div>';
    if (!hasDeviceApps) {
      html += '<div class="empty">Device list and rollout export need per-device apps. Rerun with -IncludeDeviceApps.</div>';
    } else {
      var seen = {}, list = [];
      (a.recordIndexes || []).forEach(function (ri) {
        (devicesByRecord[ri] || []).forEach(function (di) { if (!seen[di]) { seen[di] = records[ri].version; list.push(di); } });
      });
      list.sort(function (x, y) { return cmp(devices[x], devices[y], 'deviceName', 1); });
      html += '<h2>Devices (' + list.length + ')</h2>';
      html += list.length ? '<div class="table-wrap"><table><thead><tr><th>Device</th><th>Primary user</th><th>Version</th></tr></thead><tbody>' +
        list.map(function (di) {
          var d = devices[di];
          return '<tr data-device="' + di + '"><td>' + esc(d.deviceName) + '</td><td>' + esc(d.userPrincipalName) + '</td><td>' + esc(seen[di]) + '</td></tr>';
        }).join('') + '</tbody></table></div>' : '<div class="empty">No devices in this snapshot have this app.</div>';
    }
    openDrawer(html);
    if (hasDeviceApps) { updateSelection(); }
  }
  function selectedIndexes() { return Object.keys(rollout.selected).map(Number).sort(function (x, y) { return x - y; }); }
  function updateSelection(message) {
    var idx = selectedIndexes(), seen = {}, count = 0;
    idx.forEach(function (ri) { (devicesByRecord[ri] || []).forEach(function (di) { if (!seen[di]) { seen[di] = true; count++; } }); });
    Array.prototype.forEach.call(drawer.querySelectorAll('input[data-ri]'), function (box) { box.checked = !!rollout.selected[box.getAttribute('data-ri')]; });
    document.getElementById('sel-summary').innerHTML = message ? '<span class="error">' + esc(message) + '</span>' :
      num(idx.length) + ' version(s), ' + num(count) + ' device(s) selected';
    document.getElementById('rollout-open').disabled = count === 0;
    if (!count) { document.getElementById('rollout-panel').innerHTML = ''; }
    else if (document.getElementById('rollout-pct')) { renderRolloutPreview(); }
  }
  function rolloutAction(act) {
    var a = rollout.app; if (!a) { return; }
    if (act === 'sel-all') { (a.recordIndexes || []).forEach(function (ri) { rollout.selected[ri] = true; }); updateSelection(); }
    else if (act === 'sel-none') { rollout.selected = {}; updateSelection(); }
    else if (act === 'sel-below') {
      var bound = EndpointRollout.parseVersion(document.getElementById('below-version').value);
      if (!bound) { updateSelection('Enter a version such as 12, 3.0 or 3.0.21.'); return; }
      // Exclusive bound, like -MaxVersion; unparseable versions are left out.
      rollout.selected = {};
      (a.recordIndexes || []).forEach(function (ri) {
        var v = EndpointRollout.parseVersion(records[ri].version);
        if (v && EndpointRollout.compareVersion(v, bound) < 0) { rollout.selected[ri] = true; }
      });
      updateSelection();
    }
    else if (act === 'rollout-open') { renderRolloutPanel(); }
    else if (act === 'rollout-cancel') { document.getElementById('rollout-panel').innerHTML = ''; }
    else if (act === 'rollout-download') { downloadRollout(); }
  }
  drawer.addEventListener('change', function (e) {
    var box = e.target.closest('input[data-ri]');
    if (box) { if (box.checked) { rollout.selected[box.getAttribute('data-ri')] = true; } else { delete rollout.selected[box.getAttribute('data-ri')]; } updateSelection(); return; }
    if (e.target.id === 'rollout-require') { renderRolloutPreview(); }
  });
  drawer.addEventListener('input', function (e) { if (e.target.id === 'rollout-pct' || e.target.id === 'rollout-days') { renderRolloutPreview(); } });
  drawer.addEventListener('keydown', function (e) { if (e.key === 'Enter' && e.target.id === 'below-version') { rolloutAction('sel-below'); } });
  function renderRolloutPanel() {
    document.getElementById('rollout-panel').innerHTML = '<div class="rollout-panel"><h2>Phased rollout export</h2>' +
      '<div class="rollout-form">' +
      '<label>Phase percentages<input type="text" id="rollout-pct" value="10,30,60" size="14"></label>' +
      '<label>Active within days<input type="number" id="rollout-days" value="90" min="0" max="3650" style="width:90px"></label>' +
      '<label class="check"><input type="checkbox" id="rollout-require"> Require primary user</label></div>' +
      '<div id="rollout-preview"></div>' +
      '<div class="toolbar"><button class="primary" data-act="rollout-download" id="rollout-download">Download .zip</button>' +
      '<button data-act="rollout-cancel">Cancel</button><span class="count" id="rollout-status"></span></div>' +
      '<div class="note">Same files and columns as PhasedRollout/phased-rollout-creator.ps1. Built from this snapshot (' + esc(fmtDate(data.generatedAt)) +
      '): primary users, check-ins, and app versions are as of then. No Graph calls are made.</div></div>';
    renderRolloutPreview();
  }
  function rolloutOptions() {
    var pct = EndpointRollout.parsePercentages(document.getElementById('rollout-pct').value);
    var daysText = document.getElementById('rollout-days').value, days = Number(daysText);
    var error = pct.error || (!/^\d+$/.test(daysText) || days > 3650 ? 'Active within days must be a whole number from 0 to 3650.' : '');
    return { error: error, percentages: pct.values, activeWithinDays: days, requirePrimaryUser: document.getElementById('rollout-require').checked };
  }
  function renderRolloutPreview() {
    var opts = rolloutOptions(), preview = document.getElementById('rollout-preview');
    var button = document.getElementById('rollout-download');
    rollout.result = null;
    if (opts.error) { preview.innerHTML = '<div class="error">' + esc(opts.error) + '</div>'; button.disabled = true; return; }
    var r = EndpointRollout.build(data, selectedIndexes(), { percentages: opts.percentages, activeWithinDays: opts.activeWithinDays, requirePrimaryUser: opts.requirePrimaryUser, stamp: 'preview' });
    rollout.result = r;
    var rows = opts.percentages.map(function (p, i) { return ['Phase ' + (i + 1) + ' (' + p + '%)', r.phaseCounts[i]]; });
    rows.push(['Inactive (no check-in for ' + opts.activeWithinDays + '+ days)', r.inactive]);
    var reasons = {};
    r.skipped.forEach(function (x) { reasons[x.reason] = (reasons[x.reason] || 0) + 1; });
    var html = '<table><thead><tr><th>Group</th><th class="num">Devices</th></tr></thead><tbody>' +
      rows.map(function (x) { return '<tr><td>' + esc(x[0]) + '</td><td class="num">' + num(x[1]) + '</td></tr>'; }).join('') +
      '</tbody></table><div class="count">' + num(r.matched) + ' Intune device(s) matched; ' + num(r.rows.length) + ' Entra device(s) exported' +
      (opts.activeWithinDays > 0 ? '; active means checked in on or after ' + esc(fmtDate(new Date(r.cutoff).toISOString())) : '') + '.</div>';
    Object.keys(reasons).forEach(function (k) { html += '<div class="count warn">Skipped (' + esc(k) + '): ' + num(reasons[k]) + '</div>'; });
    if (r.noPrimaryUser) { html += '<div class="count warn">' + num(r.noPrimaryUser) + ' device(s) have no primary user; their UPN is blank. Tick Require primary user to skip them.</div>'; }
    preview.innerHTML = html;
    button.disabled = r.rows.length === 0;
  }
  function downloadRollout() {
    var opts = rolloutOptions(); if (opts.error) { return; }
    var now = new Date(), tag = EndpointRollout.stamp(now);
    var r = EndpointRollout.build(data, selectedIndexes(), { percentages: opts.percentages, activeWithinDays: opts.activeWithinDays, requirePrimaryUser: opts.requirePrimaryUser, stamp: tag });
    var name = 'PhasedRollout-' + EndpointRollout.fileSafe(rollout.app.name) + '-' + tag + '.zip';
    var url = URL.createObjectURL(new Blob([EndpointRollout.zip(r.files, now)], { type: 'application/zip' }));
    var link = document.createElement('a');
    link.href = url; link.download = name; document.body.appendChild(link); link.click(); link.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
    document.getElementById('rollout-status').innerHTML = '<span class="ok">Downloaded ' + esc(name) + ' (' + r.files.length + ' files).</span>';
  }

  renderDevices();
  renderApps();
})();
</script>
</body>
</html>
'@
}

#endregion

#region Orchestrator

function Invoke-EndpointInventory {
    <#
    .SYNOPSIS
    Implements Export-EndpointInventory.ps1. See that script for full help.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $OutputDirectory = 'exports/EndpointExplorer',
        [string] $TenantId,
        [switch] $UseDeviceCode,
        [switch] $AllPlatforms,
        [switch] $IncludeDeviceApps,
        [ValidateRange(0, 8760)] [int] $MaxAgeHours = 24,
        [switch] $Refresh,
        [switch] $FromCache,
        [ValidateRange(0, 3650)] [int] $ActiveWithinDays = 30,
        [switch] $ExportCsv,
        [switch] $PassThru
    )
    if ($FromCache -and $Refresh) { throw '-FromCache and -Refresh cannot be used together.' }
    Initialize-EndpointGraphState
    $windowsOnly = -not $AllPlatforms
    $directory = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $paths = [pscustomobject]@{
        Json = Join-Path $directory 'EndpointInventory.json'
        Html = Join-Path $directory 'EndpointInventory.html'
        DevicesCsv = Join-Path $directory 'EndpointDevices.csv'
        AppsCsv = Join-Path $directory 'EndpointApps.csv'
        DeviceAppsCsv = Join-Path $directory 'EndpointDeviceApps.csv'
    }

    $snapshot = $null
    $origin = ''
    if ($FromCache) {
        if (-not (Test-Path -LiteralPath $paths.Json -PathType Leaf)) { throw "-FromCache: no snapshot at '$($paths.Json)'. Run without -FromCache first." }
        $snapshot = Import-EndpointSnapshot -Path $paths.Json -ActiveWithinDays $ActiveWithinDays
        $mismatch = Get-EndpointCacheMismatch -Snapshot $snapshot -WindowsOnly:$windowsOnly -IncludeDeviceApps:$IncludeDeviceApps
        if ($mismatch) { Write-Warning "-FromCache renders the snapshot as stored: $mismatch." }
        $origin = 'cache (-FromCache)'
    }
    else {
        if (-not $Refresh -and $MaxAgeHours -gt 0 -and (Test-Path -LiteralPath $paths.Json -PathType Leaf)) {
            $cached = $null
            try { $cached = Import-EndpointSnapshot -Path $paths.Json -ActiveWithinDays $ActiveWithinDays }
            catch { Write-Warning "Ignoring cached snapshot: $($_.Exception.Message)" }
            if ($null -ne $cached) {
                $age = [DateTimeOffset]::UtcNow - (ConvertTo-EndpointTimestamp $cached.generatedAt)
                $mismatch = Get-EndpointCacheMismatch -Snapshot $cached -WindowsOnly:$windowsOnly -IncludeDeviceApps:$IncludeDeviceApps
                if ($mismatch) { Write-Information "Cached snapshot not reused: $mismatch." -InformationAction Continue }
                elseif ($age -lt [TimeSpan]::Zero) { Write-Warning 'Cached snapshot is dated in the future; pulling a fresh one.' }
                elseif ($age.TotalHours -ge $MaxAgeHours) { Write-Information ('Cached snapshot is {0:N1} h old (limit {1} h); pulling a fresh one.' -f $age.TotalHours, $MaxAgeHours) -InformationAction Continue }
                else {
                    $snapshot = $cached
                    $origin = 'cache ({0:N1} h old)' -f $age.TotalHours
                }
            }
        }
        if ($null -eq $snapshot) {
            $script:EndpointGraphState.Session = Connect-EndpointGraph -TenantId $TenantId -Scopes $script:EndpointRequiredScopes -DeviceCode:$UseDeviceCode
            Write-Information ('Connected to Microsoft Graph as {0} ({1}).' -f $script:EndpointGraphState.Session.Account, $script:EndpointGraphState.Session.Mode) -InformationAction Continue
            $snapshot = Get-EndpointInventorySnapshot -WindowsOnly:$windowsOnly -IncludeDeviceApps:$IncludeDeviceApps -ActiveWithinDays $ActiveWithinDays
            $origin = 'Microsoft Graph'
        }
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $written = New-Object 'System.Collections.Generic.List[string]'
    $ensureDirectory = {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
    }
    if ($origin -eq 'Microsoft Graph' -and $PSCmdlet.ShouldProcess($paths.Json, 'Write inventory snapshot')) {
        & $ensureDirectory
        [System.IO.File]::WriteAllText($paths.Json, (ConvertTo-Json -InputObject $snapshot -Depth 10 -Compress), $utf8)
        $written.Add($paths.Json)
    }
    if ($PSCmdlet.ShouldProcess($paths.Html, 'Write HTML report')) {
        & $ensureDirectory
        [System.IO.File]::WriteAllText($paths.Html, (ConvertTo-EndpointHtml -Snapshot $snapshot), $utf8)
        $written.Add($paths.Html)
    }
    if ($ExportCsv) {
        if ($PSCmdlet.ShouldProcess($paths.DevicesCsv, 'Write device CSV')) {
            & $ensureDirectory
            Get-EndpointDeviceCsvRow -Snapshot $snapshot | Export-Csv -LiteralPath $paths.DevicesCsv -NoTypeInformation -Encoding UTF8
            $written.Add($paths.DevicesCsv)
        }
        if ($PSCmdlet.ShouldProcess($paths.AppsCsv, 'Write fleet app CSV')) {
            & $ensureDirectory
            Get-EndpointAppCsvRow -Snapshot $snapshot | Export-Csv -LiteralPath $paths.AppsCsv -NoTypeInformation -Encoding UTF8
            $written.Add($paths.AppsCsv)
        }
        if ($snapshot.source.includeDeviceApps) {
            if ($PSCmdlet.ShouldProcess($paths.DeviceAppsCsv, 'Write per-device app CSV')) {
                & $ensureDirectory
                Get-EndpointDeviceAppCsvRow -Snapshot $snapshot | Export-Csv -LiteralPath $paths.DeviceAppsCsv -NoTypeInformation -Encoding UTF8
                $written.Add($paths.DeviceAppsCsv)
            }
        }
        # A per-device CSV from an earlier snapshot would no longer match the others.
        elseif ((Test-Path -LiteralPath $paths.DeviceAppsCsv -PathType Leaf) -and
            $PSCmdlet.ShouldProcess($paths.DeviceAppsCsv, 'Remove stale per-device app CSV (this snapshot has no per-device apps)')) {
            Remove-Item -LiteralPath $paths.DeviceAppsCsv
            Write-Information "Removed stale: $($paths.DeviceAppsCsv)" -InformationAction Continue
        }
    }

    $devices = @($snapshot.devices)
    Write-Information "Source: $origin; snapshot generated $($snapshot.generatedAt)." -InformationAction Continue
    Write-Information ('Devices: {0} (Active {1}, Stale {2}, Never {3}); Co-managed {4}, Intune MDM {5}, ConfigMgr only {6}.' -f $devices.Count,
        @($devices | Where-Object { $_.activityState -eq 'Active' }).Count, @($devices | Where-Object { $_.activityState -eq 'Stale' }).Count,
        @($devices | Where-Object { $_.activityState -eq 'Never' }).Count, @($devices | Where-Object { $_.managementType -eq 'Co-managed' }).Count,
        @($devices | Where-Object { $_.managementType -eq 'Intune MDM' }).Count, @($devices | Where-Object { $_.managementType -eq 'ConfigMgr only' }).Count) -InformationAction Continue
    Write-Information ('Apps: {0} distinct ({1} name/version records); per-device apps: {2}.' -f @($snapshot.apps).Count, @($snapshot.appRecords).Count, [bool]$snapshot.source.includeDeviceApps) -InformationAction Continue
    Write-Information ('Graph HTTP calls this run: {0} (batch subrequests: {1}).' -f $script:EndpointGraphState.CallCount, $script:EndpointGraphState.BatchSubrequestCount) -InformationAction Continue
    if ($written.Count -gt 0) { foreach ($file in $written) { Write-Information "Wrote: $file" -InformationAction Continue } }
    else { Write-Information "No files written. Output directory: $directory" -InformationAction Continue }
    if ($PassThru) { return $snapshot }
}

#endregion
