#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ArcResourceGroupName,
    [Parameter(Mandatory)][string]$RitmNumber,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$RequestedForUpn,
    [Parameter(Mandatory)][datetime]$ProvisioningPackageCreatedUtc,
    [Parameter(Mandatory)][datetime]$ProvisioningPackageExpiresUtc,
    [ValidateRange(1, 90)][int]$MinimumPackageValidityDays = 30,
    [string]$ReportPath = (Join-Path $PWD 'avd-hybrid-preflight.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $raw = & az @ArgumentList --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($ArgumentList -join ' ')`n$($raw -join [Environment]::NewLine)" }
    $text = $raw -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 100
}

if ($RitmNumber -notmatch '^RITM(?<number>[0-9]+)$') { throw "RITM number '$RitmNumber' is invalid." }
$expectedVmName = "AVD$($Matches.number)".ToUpperInvariant()
if ($VmName.ToUpperInvariant() -ne $expectedVmName -or $VmName.Length -gt 15) {
    throw "'$VmName' violates the request naming contract; expected '$expectedVmName'."
}

$account = Invoke-AzJson @('account', 'show')
if ([string]$account.id -ine $SubscriptionId) {
    & az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to select subscription '$SubscriptionId'." }
    $account = Invoke-AzJson @('account', 'show')
}
if ([string]$account.tenantId -ine $TenantId) { throw "Authenticated tenant '$($account.tenantId)' does not match '$TenantId'." }

if ($ProvisioningPackageCreatedUtc.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5)) { throw 'Provisioning package creation time is in the future.' }
if ($ProvisioningPackageExpiresUtc.ToUniversalTime() -le $ProvisioningPackageCreatedUtc.ToUniversalTime()) { throw 'Provisioning package expiration must be after creation.' }
if (($ProvisioningPackageExpiresUtc.ToUniversalTime() - $ProvisioningPackageCreatedUtc.ToUniversalTime()).TotalDays -gt 181) { throw 'Provisioning package metadata exceeds the 180-day bulk-token lifetime.' }
$minimumExpiry = [DateTime]::UtcNow.AddDays($MinimumPackageValidityDays)
if ($ProvisioningPackageExpiresUtc.ToUniversalTime() -lt $minimumExpiry) {
    throw "The Entra/Intune provisioning package expires '$($ProvisioningPackageExpiresUtc.ToUniversalTime().ToString('o'))'; at least $MinimumPackageValidityDays days are required."
}

$machine = Invoke-AzJson @('connectedmachine', 'show', '--name', $VmName, '--resource-group', $ArcResourceGroupName, '--subscription', $SubscriptionId)
if (-not $machine.id) { throw "Arc machine '$VmName' was not found in '$ArcResourceGroupName'." }
if ([string]$machine.status -ine 'Connected') { throw "Arc machine '$VmName' is '$($machine.status)', not Connected." }
if ([string]$machine.name -ine $VmName) { throw "Arc resource name '$($machine.name)' does not match '$VmName'." }

$osName = [string]$machine.osName
$osVersion = [string]$machine.osVersion
$isWindows = ($osName -match 'Windows') -or ([string]$machine.osType -ieq 'windows')
if (-not $isWindows) { throw "Arc machine '$VmName' does not report Windows." }
$osBuild = 0
if ($osVersion -match '10\.0\.(?<build>[0-9]+)') { $osBuild = [int]$Matches.build }
if ($osBuild -lt 26100) { throw "Arc machine '$VmName' does not report Windows 11 24H2 build 26100 or later: '$osVersion'." }

$encodedUpn = [Uri]::EscapeDataString($RequestedForUpn)
$user = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/users/${encodedUpn}?`$select=id,userPrincipalName,accountEnabled")
if (-not $user.id -or $user.accountEnabled -ne $true) { throw "Entra user '$RequestedForUpn' was not found or is disabled." }

$report = [ordered]@{
    checkedUtc = [DateTime]::UtcNow.ToString('o')
    result = 'Passed'
    ritmNumber = $RitmNumber
    vmName = $VmName
    arcMachineId = $machine.id
    arcStatus = $machine.status
    osName = $osName
    osVersion = $osVersion
    requestedForUpn = $user.userPrincipalName
    requestedForObjectId = $user.id
    provisioningPackageCreatedUtc = $ProvisioningPackageCreatedUtc.ToUniversalTime().ToString('o')
    provisioningPackageExpiresUtc = $ProvisioningPackageExpiresUtc.ToUniversalTime().ToString('o')
}
$parent = Split-Path -Parent $ReportPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding utf8
Write-Host "Arc preflight passed for '$VmName'."
