#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstanceUrl,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{32}$')][string]$RitmSysId,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$Message,
    [string]$HostName,
    [string]$Platform,
    [string]$StatusField = 'u_avd_build_status',
    [string]$HostNameField = 'u_avd_hostname',
    [string]$PlatformField = 'u_avd_platform',
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$UserName,
    [string]$Password
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$baseUrl = $InstanceUrl.TrimEnd('/')
$headers = @{ Accept = 'application/json' }

# Azure DevOps leaves an undefined $(VARIABLE_NAME) macro unchanged. Treat those
# literal values as absent so a POC can use Basic authentication without also
# defining dummy OAuth values (and vice versa).
$ClientId = if ($ClientId -match '^\$\([A-Za-z0-9_.-]+\)$') { '' } else { $ClientId }
$ClientSecret = if ($ClientSecret -match '^\$\([A-Za-z0-9_.-]+\)$') { '' } else { $ClientSecret }
$UserName = if ($UserName -match '^\$\([A-Za-z0-9_.-]+\)$') { '' } else { $UserName }
$Password = if ($Password -match '^\$\([A-Za-z0-9_.-]+\)$') { '' } else { $Password }

if ($ClientId -and $ClientSecret) {
    $token = Invoke-RestMethod -Method Post -Uri "$baseUrl/oauth_token.do" -ContentType 'application/x-www-form-urlencoded' -Body @{
        grant_type = 'client_credentials'
        client_id = $ClientId
        client_secret = $ClientSecret
    }
    $headers.Authorization = "Bearer $($token.access_token)"
}
elseif ($UserName -and $Password) {
    $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${UserName}:$Password")
    $headers.Authorization = "Basic $([Convert]::ToBase64String($credentialBytes))"
}
else {
    throw 'Provide either ServiceNow OAuth client credentials or a basic-auth integration account.'
}

$body = [ordered]@{
    work_notes = $Message
}
$body[$StatusField] = $Status
if ($HostName) { $body[$HostNameField] = $HostName }
if ($Platform) { $body[$PlatformField] = $Platform }

$response = Invoke-RestMethod -Method Patch `
    -Uri "$baseUrl/api/now/table/sc_req_item/$RitmSysId" `
    -Headers $headers `
    -ContentType 'application/json' `
    -Body ($body | ConvertTo-Json -Compress)
if (-not $response.result.sys_id) {
    throw "ServiceNow did not confirm the update for RITM sys_id '$RitmSysId'."
}
Write-Host "Updated ServiceNow RITM status to '$Status'."
