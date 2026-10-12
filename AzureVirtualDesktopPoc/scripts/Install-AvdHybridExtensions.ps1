#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ArcResourceGroupName,
    [Parameter(Mandatory)][string]$PlatformResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$VmName,
    [ValidateRange(30, 1440)][int]$RegistrationTokenLifetimeMinutes = 1440,
    [ValidateRange(1, 30)][int]$RegistrationTimeoutMinutes = 15
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

$machine = Invoke-AzJson @(
    'connectedmachine', 'show', '--name', $VmName,
    '--resource-group', $ArcResourceGroupName, '--subscription', $SubscriptionId
)
if ([string]$machine.status -ine 'Connected') { throw "Arc machine '$VmName' is not Connected." }

$machineId = [string]$machine.id
$aadExtensionId = "$machineId/extensions/AADLoginForWindows"
$aadBody = @{
    location = $Location
    properties = @{
        publisher = 'Microsoft.Azure.ActiveDirectory'
        type = 'AADLoginForWindows'
        typeHandlerVersion = '2.1.0.0'
        autoUpgradeMinorVersion = $true
        enableAutomaticUpgrade = $true
        settings = @{ mdmId = '' }
    }
} | ConvertTo-Json -Depth 20 -Compress
[void](Invoke-AzJson @(
    'rest', '--method', 'PUT',
    '--url', "https://management.azure.com${aadExtensionId}?api-version=2024-07-10",
    '--headers', 'Content-Type=application/json', '--body', $aadBody
))

$hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$expiration = [DateTime]::UtcNow.AddMinutes($RegistrationTokenLifetimeMinutes).ToString('o')
$registrationBody = @{
    properties = @{
        registrationInfo = @{
            expirationTime = $expiration
            registrationTokenOperation = 'Update'
        }
    }
} | ConvertTo-Json -Depth 10 -Compress
[void](Invoke-AzJson @(
    'rest', '--method', 'PATCH',
    '--url', "https://management.azure.com${hostPoolId}?api-version=2024-04-03",
    '--headers', 'Content-Type=application/json', '--body', $registrationBody
))
$tokenResult = Invoke-AzJson @(
    'rest', '--method', 'POST',
    '--url', "https://management.azure.com${hostPoolId}/retrieveRegistrationToken?api-version=2024-04-03"
)
$token = [string]$tokenResult.token
if ([string]::IsNullOrWhiteSpace($token)) { throw "AVD returned no registration token for '$HostPoolName'." }
Write-Host "##vso[task.setsecret]$token"

$avdExtensionId = "$machineId/extensions/Microsoft.AzureVirtualDesktop.CloudDeviceExtension"
$avdBody = @{
    location = $Location
    properties = @{
        publisher = 'Microsoft.AzureVirtualDesktop'
        type = 'CloudDeviceExtension'
        autoUpgradeMinorVersion = $true
        enableAutomaticUpgrade = $true
        settings = @{}
        protectedSettings = @{ registrationToken = $token }
    }
} | ConvertTo-Json -Depth 20 -Compress
[void](Invoke-AzJson @(
    'rest', '--method', 'PUT',
    '--url', "https://management.azure.com${avdExtensionId}?api-version=2024-07-10",
    '--headers', 'Content-Type=application/json', '--body', $avdBody
))
$token = $null

$deadline = [DateTime]::UtcNow.AddMinutes($RegistrationTimeoutMinutes)
do {
    $aadState = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://management.azure.com${aadExtensionId}?api-version=2024-07-10")
    $avdState = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://management.azure.com${avdExtensionId}?api-version=2024-07-10")
    $hosts = Invoke-AzJson @('rest', '--method', 'GET', '--url', "https://management.azure.com${hostPoolId}/sessionHosts?api-version=2024-04-03")
    $sessionHost = @($hosts.value | Where-Object { (([string]$_.name -split '/')[-1] -split '\.')[0] -ieq $VmName }) | Select-Object -First 1
    $hostAvailable = $null -ne $sessionHost -and [string]$sessionHost.properties.status -eq 'Available'
    if ($aadState.properties.provisioningState -eq 'Succeeded' -and $avdState.properties.provisioningState -eq 'Succeeded' -and $hostAvailable) {
        Write-Host "Installed the Entra login and AVD Hybrid extensions; '$VmName' is Available."
        return
    }
    Start-Sleep -Seconds 30
} while ([DateTime]::UtcNow -lt $deadline)

throw "Hybrid registration for '$VmName' did not report both extensions Succeeded and the AVD host Available within $RegistrationTimeoutMinutes minutes."
