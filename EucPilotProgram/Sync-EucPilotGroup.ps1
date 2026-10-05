#requires -Version 5.1
<#
.SYNOPSIS
Reconciles an Entra pilot device group from Intune app install status.

.DESCRIPTION
State-based reconciler for the EUC Early Adopter pilot program. Devices whose
Join-app install state is 'installed' are added to the pilot group; devices no
longer reporting 'installed' are removed. Any Graph API failure halts the run
so an error is never mistaken for an empty desired state.

Two authentication branches share one transport abstraction:

- Azure Automation (production): system-assigned managed identity via the
  IMDS endpoint, raw Invoke-RestMethod, no module or secret dependencies.
- Interactive POC (delegated): Connect-MgGraph interactive prompt with full
  MFA and Conditional Access support, Invoke-MgGraphRequest as transport.
  Requires the Microsoft.Graph.Authentication module on the workstation.

.EXAMPLE
Sync-EucPilotGroup.ps1 -JoinAppId <mobileApp-guid> -PilotGroupId <group-guid>

.EXAMPLE
Sync-EucPilotGroup.ps1 -JoinAppId <guid> -PilotGroupId <guid> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $JoinAppId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $PilotGroupId,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $CommsGroupId,

    [ValidateRange(0, 100000)]
    [int] $MemberCap = 50,

    [string] $TeamsWebhookUri,

    [string] $TenantId,

    [switch] $NoLogo
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$graphVersion = 'v1.0'
$graphBase = "https://graph.microsoft.com/$graphVersion"
$requiredScopes = @(
    'DeviceManagementApps.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'Directory.Read.All'
    'GroupMember.ReadWrite.All'
)

function Get-PilotToken {
    # Returns a bearer token for Graph. Managed identity when hosted in
    # Azure Automation; interactive Connect-MgGraph otherwise.
    param(
        [string] $TenantId
    )
    if ($env:IDENTITY_ENDPOINT) {
        $response = Invoke-RestMethod -Method Get -Uri (
            "$($env:IDENTITY_ENDPOINT)?api-version=2019-08-01&resource=https://graph.microsoft.com/"
        ) -Headers @{ Metadata = $true }
        if (-not $response.access_token) { throw 'Managed identity returned no access token.' }
        return $response.access_token
    }

    $module = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $module) {
        throw 'Microsoft.Graph.Authentication is required for interactive sign-in. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module $module.Path -Force

    $connectArgs = @{ Scopes = $requiredScopes }
    if ($TenantId) { $connectArgs.TenantId = $TenantId }
    Write-Verbose ('Connecting to Microsoft Graph interactively.')
    Connect-MgGraph @connectArgs | Out-Null

    $context = Get-MgContext
    if (-not $context -or -not $context.Account) {
        throw 'Connect-MgGraph did not produce an authenticated context.'
    }
    Write-Output ("Interactive session established for {0}." -f $context.Account)
    return 'MgGraphSession'
}

function Invoke-PilotGraph {
    # Unified transport. $Token is either a bearer string (managed identity)
    # or the sentinel 'MgGraphSession' (interactive SDK session).
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body,
        [string] $Token
    )
    $resolvedUri = if ($Uri.StartsWith('http')) { $Uri } else { "$graphBase$Uri" }

    if ($Token -eq 'MgGraphSession') {
        $pilotGraphStatusCode = 0
        $requestArgs = @{
            Method             = $Method
            Uri                = $resolvedUri
            SkipHttpErrorCheck = $true
            StatusCodeVariable = 'pilotGraphStatusCode'
            OutputType         = 'PSObject'
        }
        if ($Body) {
            $requestArgs.Body = $Body | ConvertTo-Json -Depth 5
            $requestArgs.ContentType = 'application/json'
        }
        $response = Invoke-MgGraphRequest @requestArgs
        if ([int]$pilotGraphStatusCode -ge 400) {
            throw ('Graph {0} {1} failed with HTTP {2}: {3}' -f
                $Method, $resolvedUri, $pilotGraphStatusCode, ($response | ConvertTo-Json -Depth 3))
        }
        return $response
    }

    $restArgs = @{
        Method      = $Method
        Uri         = $resolvedUri
        Headers     = @{ Authorization = "Bearer $Token" }
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $restArgs.Body = $Body | ConvertTo-Json -Depth 5
        $restArgs.ContentType = 'application/json'
    }
    return Invoke-RestMethod @restArgs
}

function Get-PilotGraphPaged {
    # Walks @odata.nextLink pages and returns every 'value' entry.
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Token
    )
    $items = @()
    $nextUri = $Uri
    while ($nextUri) {
        $response = Invoke-PilotGraph -Method Get -Uri $nextUri -Token $Token
        if ($response.value) { $items += $response.value }
        $nextUri = $null
        $responseIsObject = $response -is [psobject]
        $hasNextLink = $responseIsObject -and $response.PSObject.Properties['@odata.nextLink']
        if (-not $responseIsObject -and $response -is [hashtable]) {
            $hasNextLink = $response.ContainsKey('@odata.nextLink')
        }
        if ($hasNextLink) {
            $nextUri = if ($responseIsObject) { $response.'@odata.nextLink' } else { $response['@odata.nextLink'] }
        }
    }
    return $items
}

function Add-PilotMember {
    param(
        [Parameter(Mandatory)] [string] $GroupId,
        [Parameter(Mandatory)] [string] $ObjectId,
        [string] $Token,
        [string] $GraphBase = 'https://graph.microsoft.com/v1.0'
    )
    $body = @{ '@odata.id' = "$GraphBase/directoryObjects/$ObjectId" }
    try {
        Invoke-PilotGraph -Method Post -Uri "/groups/$GroupId/members/`$ref" -Body $body -Token $Token | Out-Null
        return 'added'
    }
    catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties['Response']) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 400 -or $_.Exception.Message -match 'HTTP 400') { return 'absorbed' }
        throw
    }
}

function Remove-PilotMember {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $GroupId,
        [Parameter(Mandatory)] [string] $ObjectId,
        [string] $Token
    )
    if (-not $PSCmdlet.ShouldProcess("object $ObjectId", 'Remove from group')) { return 'skipped' }
    try {
        Invoke-PilotGraph -Method Delete -Uri "/groups/$GroupId/members/$ObjectId/`$ref" -Token $Token | Out-Null
        return 'removed'
    }
    catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties['Response']) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 404 -or $_.Exception.Message -match 'HTTP 404') { return 'absorbed' }
        throw
    }
}

if (-not $NoLogo) {
    Write-Output 'EUC Pilot Group Reconciler'
}

$token = Get-PilotToken -TenantId $TenantId

# ---- 1. Desired state: devices reporting the Join app as installed ----
Write-Output "Reading install status for app $JoinAppId..."
$installStatuses = Get-PilotGraphPaged -Uri "/deviceAppManagement/mobileApps/$JoinAppId/deviceStatuses" -Token $token
$installed = @($installStatuses | Where-Object { $_.installState -eq 'installed' })
Write-Output ("Devices reporting installed: {0}" -f $installed.Count)

$desired = @{}
foreach ($status in $installed) {
    $managedDevice = Invoke-PilotGraph -Method Get `
        -Uri "/deviceManagement/managedDevices/$($status.deviceId)?`$select=azureADDeviceId,deviceName,userPrincipalName" `
        -Token $token
    if ($managedDevice.azureADDeviceId) {
        $desired[$managedDevice.azureADDeviceId] = [pscustomobject] @{
            DeviceName = $managedDevice.deviceName
            UserPrincipalName = $managedDevice.userPrincipalName
        }
    }
    else {
        Write-Output ("SKIP (no Entra device id): managed device {0}" -f $status.deviceId)
    }
}

# ---- 2. Current state: device members of the pilot group ----
Write-Output "Reading pilot group $PilotGroupId membership..."
$current = @{}
foreach ($member in (Get-PilotGraphPaged -Uri "/groups/$PilotGroupId/members" -Token $token)) {
    if ($member.'@odata.type' -eq '#microsoft.graph.device') {
        $current[$member.deviceId] = $member.id
    }
}
Write-Output ("Devices currently in group: {0}" -f $current.Count)

# ---- 3/4. Diff, cap, and reconcile ----
$toAdd = @($desired.Keys | Where-Object { -not $current.ContainsKey($_) })
$toRemove = @($current.Keys | Where-Object { -not $desired.ContainsKey($_) })

$capReached = $false
if ($MemberCap -gt 0 -and ($current.Count + $toAdd.Count) -gt $MemberCap) {
    $allowedAdds = [Math]::Max(0, $MemberCap - $current.Count)
    if ($allowedAdds -gt 0) {
        $toAdd = $toAdd[0..($allowedAdds - 1)]
    }
    else {
        $toAdd = @()
    }
    $capReached = $true
}

$addedCount = 0
foreach ($azureAdDeviceId in $toAdd) {
    $info = $desired[$azureAdDeviceId]
    $entraDevice = Invoke-PilotGraph -Method Get `
        -Uri "/devices?`$filter=deviceId eq '$azureAdDeviceId'&`$select=id" -Token $token
    if (-not $entraDevice.value -or $entraDevice.value.Count -eq 0) {
        Write-Output ("SKIP (no Entra device object): {0} ({1})" -f $info.DeviceName, $azureAdDeviceId)
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($info.DeviceName, 'Add device to pilot group')) { continue }
    $result = Add-PilotMember -GroupId $PilotGroupId -ObjectId $entraDevice.value[0].id -Token $token
    Write-Output ("ADD ({0}): {1} [{2}]" -f $result, $info.DeviceName, $info.UserPrincipalName)
    if ($result -eq 'added') { $addedCount++ }
}

foreach ($azureAdDeviceId in $toRemove) {
    $objectId = $current[$azureAdDeviceId]
    if (-not $PSCmdlet.ShouldProcess($azureAdDeviceId, 'Remove device from pilot group')) { continue }
    $result = Remove-PilotMember -GroupId $PilotGroupId -ObjectId $objectId -Token $token
    Write-Output ("REMOVE ({0}): deviceId {1}" -f $result, $azureAdDeviceId)
}

if ($capReached) {
    Write-Output ("CAP REACHED ({0}) - additional adds deferred to a later run." -f $MemberCap)
}

# ---- 5. Optional: sync comms group from UPNs of joined devices ----
if ($CommsGroupId) {
    Write-Output "Syncing comms group $CommsGroupId..."
    $wantedUpns = @($desired.Values |
        Where-Object { $_.UserPrincipalName } |
        Select-Object -ExpandProperty UserPrincipalName -Unique)

    $wantedUsers = @{}
    foreach ($upn in $wantedUpns) {
        try {
            $user = Invoke-PilotGraph -Method Get `
                -Uri "/users/$([uri]::EscapeDataString($upn))?`$select=id,userPrincipalName" -Token $token
            $wantedUsers[$user.id] = $user.userPrincipalName
        }
        catch {
            Write-Output ("SKIP (user not resolvable): {0}" -f $upn)
        }
    }

    $commsMembers = @{}
    foreach ($member in (Get-PilotGraphPaged -Uri "/groups/$CommsGroupId/members" -Token $token)) {
        if ($member.'@odata.type' -eq '#microsoft.graph.user') {
            $commsMembers[$member.id] = $member.userPrincipalName
        }
    }

    foreach ($userId in @($wantedUsers.Keys | Where-Object { -not $commsMembers.ContainsKey($_) })) {
        if (-not $PSCmdlet.ShouldProcess($wantedUsers[$userId], 'Add user to comms group')) { continue }
        $result = Add-PilotMember -GroupId $CommsGroupId -ObjectId $userId -Token $token
        Write-Output ("COMMS ADD ({0}): {1}" -f $result, $wantedUsers[$userId])
    }
    foreach ($userId in @($commsMembers.Keys | Where-Object { -not $wantedUsers.ContainsKey($_) })) {
        if (-not $PSCmdlet.ShouldProcess($commsMembers[$userId], 'Remove user from comms group')) { continue }
        $result = Remove-PilotMember -GroupId $CommsGroupId -ObjectId $userId -Token $token
        Write-Output ("COMMS REMOVE ({0}): {1}" -f $result, $commsMembers[$userId])
    }
}

# ---- 6. Audit summary and optional Teams notification ----
$summary = ('EUC pilot sync {0}: +{1} added, {2} removed, {3} total devices.' -f
    (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $addedCount, $toRemove.Count, ($current.Count + $addedCount))
Write-Output $summary

if ($TeamsWebhookUri -and ($addedCount -gt 0 -or $toRemove.Count -gt 0)) {
    $webhookBody = @{
        summary  = 'EUC pilot group sync'
        sections = @(
            @{
                activityTitle    = 'EUC pilot group sync'
                activitySubtitle = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
                text            = $summary
            }
        )
    }
    Invoke-RestMethod -Method Post -Uri $TeamsWebhookUri `
        -ContentType 'application/json' `
        -Body ($webhookBody | ConvertTo-Json -Depth 5) | Out-Null
}