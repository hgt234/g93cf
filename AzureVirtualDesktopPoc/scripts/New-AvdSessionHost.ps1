#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$PlatformResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$SubnetId,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$RitmNumber,
    [Parameter(Mandatory)][string]$RequestedForUpn,
    [Parameter(Mandatory)][string]$PocId,
    [Parameter(Mandatory)][string]$TemplateFile,
    [Parameter(Mandatory)][string]$AvdDscConfigurationUri,
    [ValidateSet('Gallery', 'Marketplace')][string]$ImageSourceType = 'Gallery',
    [string]$GalleryImageDefinitionId,
    [string]$GalleryImageVersionId,
    [string]$Location = 'centralus',
    [string]$VmSize = 'Standard_E4bs_v5',
    [string]$LocalAdminUsername = 'avdlocaladmin',
    [ValidateSet('StandardSSD_LRS', 'Premium_LRS')][string]$OsDiskSku = 'StandardSSD_LRS',
    [ValidateRange(30, 1440)][int]$RegistrationTokenLifetimeMinutes = 1440,
    [string]$WhatIfReportPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $raw = & az @ArgumentList --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($ArgumentList -join ' ')`n$($raw -join [Environment]::NewLine)"
    }
    $text = $raw -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 100
}

function New-RandomPassword {
    $random = [Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
    return ([Convert]::ToBase64String($random).TrimEnd('=') + '!aA7')
}

if ($VmName -notmatch '^AVD[0-9]{1,12}$' -or $VmName.Length -gt 15) {
    throw "VM name '$VmName' is not a valid RITM-derived AVD host name."
}
if ($ImageSourceType -eq 'Gallery' -and
    [string]::IsNullOrWhiteSpace($GalleryImageVersionId) -and
    [string]::IsNullOrWhiteSpace($GalleryImageDefinitionId)) {
    throw 'GalleryImageDefinitionId or GalleryImageVersionId is required when ImageSourceType is Gallery.'
}
if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
    throw "Session-host Bicep template was not found: $TemplateFile"
}

$account = Invoke-AzCliJson -ArgumentList @('account', 'show')
if ([string]$account.id -ine $SubscriptionId) {
    & az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to select subscription '$SubscriptionId'." }
    $account = Invoke-AzCliJson -ArgumentList @('account', 'show')
}
if ([string]$account.tenantId -ine $TenantId) {
    throw "Authenticated tenant '$($account.tenantId)' does not match requested tenant '$TenantId'."
}

$encodedUpn = [Uri]::EscapeDataString($RequestedForUpn)
$user = Invoke-AzCliJson -ArgumentList @(
    'rest', '--method', 'GET',
    '--url', "https://graph.microsoft.com/v1.0/users/${encodedUpn}?`$select=id,userPrincipalName,accountEnabled"
)
if (-not $user -or -not $user.id) { throw "Entra user '$RequestedForUpn' was not found." }
if ($user.accountEnabled -ne $true) { throw "Entra user '$RequestedForUpn' is disabled." }

$existingVms = @(Invoke-AzCliJson -ArgumentList @('vm', 'list', '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId))
$existingVm = $existingVms | Where-Object name -CEQ $VmName | Select-Object -First 1
if ($existingVm) {
    $existingRitm = if ($existingVm.tags) { [string]($existingVm.tags.PSObject.Properties | Where-Object Name -IEQ 'RITM' | Select-Object -First 1).Value } else { '' }
    $existingUser = if ($existingVm.tags) { [string]($existingVm.tags.PSObject.Properties | Where-Object Name -IEQ 'RequestedFor' | Select-Object -First 1).Value } else { '' }
    if ($existingRitm -cne $RitmNumber -or $existingUser -ine $RequestedForUpn) {
        throw "VM '$VmName' already exists but is owned by RITM '$existingRitm' for '$existingUser'."
    }
}

if ($ImageSourceType -eq 'Gallery' -and [string]::IsNullOrWhiteSpace($GalleryImageVersionId)) {
    $versionResponse = Invoke-AzCliJson -ArgumentList @(
        'rest', '--method', 'GET',
        '--url', "https://management.azure.com${GalleryImageDefinitionId}/versions?api-version=2024-03-03"
    )
    $latestVersion = @($versionResponse.value) | Where-Object {
        $_.properties.publishingProfile.excludeFromLatest -ne $true -and
        [string]$_.properties.provisioningState -ieq 'Succeeded'
    } | Sort-Object { [DateTime]$_.properties.publishingProfile.publishedDate } -Descending | Select-Object -First 1
    if (-not $latestVersion) { throw "No usable image version exists under '$GalleryImageDefinitionId'." }
    $GalleryImageVersionId = [string]$latestVersion.id
}

$hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$tokenResponse = $null
try {
    $tokenResponse = Invoke-AzCliJson -ArgumentList @(
        'rest', '--method', 'POST',
        '--url', "https://management.azure.com$hostPoolId/retrieveRegistrationToken?api-version=2024-04-03"
    )
}
catch {
    Write-Host 'No reusable AVD registration token was available; a new token will be requested.'
}
$registrationToken = if ($tokenResponse -and $tokenResponse.PSObject.Properties.Name -contains 'token') { [string]$tokenResponse.token } else { '' }
$tokenExpiration = if ($tokenResponse -and $tokenResponse.PSObject.Properties.Name -contains 'expirationTime' -and $tokenResponse.expirationTime) {
    [DateTime]$tokenResponse.expirationTime
}
else {
    [DateTime]::MinValue
}
if ([string]::IsNullOrWhiteSpace($registrationToken) -or $tokenExpiration -lt [DateTime]::UtcNow.AddMinutes(30)) {
    $expiration = [DateTime]::UtcNow.AddMinutes($RegistrationTokenLifetimeMinutes).ToString('o')
    $registrationBody = @{
        properties = @{
            registrationInfo = @{
                expirationTime = $expiration
                registrationTokenOperation = 'Update'
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    [void](Invoke-AzCliJson -ArgumentList @(
        'rest', '--method', 'PATCH',
        '--url', "https://management.azure.com${hostPoolId}?api-version=2024-04-03",
        '--headers', 'Content-Type=application/json',
        '--body', $registrationBody
    ))
    $tokenResponse = Invoke-AzCliJson -ArgumentList @(
        'rest', '--method', 'POST',
        '--url', "https://management.azure.com$hostPoolId/retrieveRegistrationToken?api-version=2024-04-03"
    )
    $registrationToken = if ($tokenResponse -and $tokenResponse.PSObject.Properties.Name -contains 'token') { [string]$tokenResponse.token } else { '' }
}
if ([string]::IsNullOrWhiteSpace($registrationToken)) {
    throw "AVD did not return a registration token for host pool '$HostPoolName'."
}
Write-Host "##vso[task.setsecret]$registrationToken"

$parameterFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), "avd-$VmName-$([Guid]::NewGuid().ToString('N')).parameters.json")
try {
    $parameters = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            vmName = @{ value = $VmName }
            location = @{ value = $Location }
            vmSize = @{ value = $VmSize }
            subnetId = @{ value = $SubnetId }
            hostPoolName = @{ value = $HostPoolName }
            ritmNumber = @{ value = $RitmNumber }
            requestedForUpn = @{ value = $RequestedForUpn }
            imageSourceType = @{ value = $ImageSourceType }
            galleryImageVersionId = @{ value = [string]$GalleryImageVersionId }
            avdDscConfigurationUri = @{ value = $AvdDscConfigurationUri }
            registrationToken = @{ value = $registrationToken }
            localAdminUsername = @{ value = $LocalAdminUsername }
            localAdminPassword = @{ value = (New-RandomPassword) }
            osDiskSku = @{ value = $OsDiskSku }
            tags = @{ value = @{ ManagedBy = 'AzureVirtualDesktopPoc'; PocId = $PocId; Environment = 'POC' } }
        }
    }
    $parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parameterFile -Encoding utf8

    $whatIfRaw = & az deployment group what-if `
        --name "avd-$($VmName.ToLowerInvariant())-whatif" `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --template-file $TemplateFile `
        --parameters "@$parameterFile" `
        --result-format FullResourcePayloads `
        --no-pretty-print `
        --only-show-errors `
        --output json
    if ($LASTEXITCODE -ne 0) { throw 'Session-host what-if failed.' }
    $whatIfText = $whatIfRaw -join [Environment]::NewLine
    if ($WhatIfReportPath) {
        $reportParent = Split-Path -Parent $WhatIfReportPath
        if ($reportParent -and -not (Test-Path -LiteralPath $reportParent)) {
            New-Item -ItemType Directory -Path $reportParent -Force | Out-Null
        }
        $whatIfText | Set-Content -LiteralPath $WhatIfReportPath -Encoding utf8
    }
    $whatIfResult = $whatIfText | ConvertFrom-Json -Depth 100
    if (@($whatIfResult.changes | Where-Object changeType -In @('Delete', 'Recreate')).Count -gt 0) {
        throw 'Session-host what-if contains a delete or recreate operation. Deployment is blocked.'
    }

    $deploymentName = "avd-$($VmName.ToLowerInvariant())-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    $deployment = Invoke-AzCliJson -ArgumentList @(
        'deployment', 'group', 'create',
        '--name', $deploymentName,
        '--resource-group', $ResourceGroupName,
        '--subscription', $SubscriptionId,
        '--template-file', $TemplateFile,
        '--parameters', "@$parameterFile",
        '--mode', 'Incremental'
    )
}
finally {
    if (Test-Path -LiteralPath $parameterFile) {
        Remove-Item -LiteralPath $parameterFile -Force
    }
    $registrationToken = $null
}

$vmId = [string]$deployment.properties.outputs.vmId.value
Write-Host "##vso[task.setvariable variable=vmId;isOutput=true]$vmId"
Write-Host "##vso[task.setvariable variable=userObjectId;isOutput=true]$($user.id)"
Write-Host "##vso[task.setvariable variable=deploymentName;isOutput=true]$deploymentName"
Write-Host "##vso[task.setvariable variable=galleryImageVersionId;isOutput=true]$GalleryImageVersionId"
Write-Host "Deployed or converged '$VmName' for '$RequestedForUpn' without a public IP address."
