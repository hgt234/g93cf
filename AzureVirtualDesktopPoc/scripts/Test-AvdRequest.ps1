#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RitmNumber,
    [Parameter(Mandatory)][string]$RequestedHostName,
    [Parameter(Mandatory)][string]$RequestedForUpn,
    [Parameter(Mandatory)][string]$RitmSysId
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$match = [regex]::Match($RitmNumber.Trim(), '^RITM(?<suffix>[0-9]{1,12})$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
if (-not $match.Success) {
    throw "RITM number '$RitmNumber' must match RITM followed by 1-12 digits."
}

$normalizedRitm = "RITM$($match.Groups['suffix'].Value)"
$expectedHostName = "AVD$($match.Groups['suffix'].Value)"
if ($expectedHostName.Length -gt 15) {
    throw "Derived host name '$expectedHostName' exceeds the Windows 15-character limit."
}
if ($RequestedHostName.Trim() -cne $expectedHostName) {
    throw "ServiceNow supplied '$RequestedHostName', but '$normalizedRitm' requires the exact host name '$expectedHostName'."
}
if ($RequestedForUpn -notmatch '^[^\s@]+@[^\s@]+$') {
    throw "Requested-for value '$RequestedForUpn' is not a valid UPN."
}
if ($RitmSysId -notmatch '^[0-9a-fA-F]{32}$') {
    throw 'RITM sys_id must contain exactly 32 hexadecimal characters.'
}

$result = [ordered]@{
    ritmNumber = $normalizedRitm
    hostName = $expectedHostName
    requestedForUpn = $RequestedForUpn.Trim().ToLowerInvariant()
    ritmSysId = $RitmSysId.ToLowerInvariant()
}

Write-Host "##vso[task.setvariable variable=ritmNumber;isOutput=true]$($result.ritmNumber)"
Write-Host "##vso[task.setvariable variable=hostName;isOutput=true]$($result.hostName)"
Write-Host "##vso[task.setvariable variable=requestedForUpn;isOutput=true]$($result.requestedForUpn)"
Write-Host "##vso[task.setvariable variable=ritmSysId;isOutput=true]$($result.ritmSysId)"
$result | ConvertTo-Json
