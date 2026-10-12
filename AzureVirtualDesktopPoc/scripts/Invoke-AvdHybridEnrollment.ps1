#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ArcResourceGroupName,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][uri]$ProvisioningPackageUri,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ProvisioningPackageSha256,
    [Parameter(Mandatory)][datetime]$ProvisioningPackageExpiresUtc,
    [ValidateRange(1, 90)][int]$MinimumPackageValidityDays = 30,
    [ValidateRange(5, 60)][int]$ReconnectTimeoutMinutes = 25
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ($ProvisioningPackageUri.Scheme -ne 'https') { throw 'The provisioning package URI must use HTTPS.' }
if ($ProvisioningPackageExpiresUtc.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays($MinimumPackageValidityDays)) {
    throw "The provisioning package has fewer than $MinimumPackageValidityDays days of validity remaining."
}

$guestScript = @'
param([string]$packageUri, [string]$expectedSha256, [string]$expectedTenantId)
$ErrorActionPreference = 'Stop'
$status = dsregcmd.exe /status | Out-String
if ($status -match 'AzureAdJoined\s*:\s*YES') {
    $tenantMatch = [regex]::Match($status, '(?im)^\s*TenantId\s*:\s*([0-9a-f-]+)\s*$')
    if (-not $tenantMatch.Success -or $tenantMatch.Groups[1].Value -ine $expectedTenantId) {
        throw 'The guest is already Entra joined to a different or unknown tenant.'
    }
    Write-Output 'AVD_HYBRID_ENROLLMENT:ALREADY_JOINED'
    exit 0
}
$working = Join-Path $env:ProgramData 'AvdHybridEnrollment'
New-Item -ItemType Directory -Path $working -Force | Out-Null
$package = Join-Path $working 'entra-intune.ppkg'
try {
    Invoke-WebRequest -Uri $packageUri -OutFile $package -UseBasicParsing
    $actualSha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($actualSha256 -ine $expectedSha256) { throw 'Provisioning package SHA-256 mismatch.' }
    $signature = Get-AuthenticodeSignature -FilePath $package
    if ($signature.Status -notin @('Valid', 'NotSigned')) { throw "Provisioning package signature status is '$($signature.Status)'." }
    Install-ProvisioningPackage -PackagePath $package -QuietInstall -ForceInstall -LogsDirectoryPath $working | Out-Null
    Write-Output 'AVD_HYBRID_ENROLLMENT:INSTALLED'
}
finally {
    if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Force }
}
shutdown.exe /r /t 60 /c 'Restarting to complete Entra and Intune enrollment.' /f
'@

$protected = @(@{ name = 'packageUri'; value = $ProvisioningPackageUri.AbsoluteUri }) | ConvertTo-Json -Compress
$parameters = @(
    @{ name = 'expectedSha256'; value = $ProvisioningPackageSha256.ToUpperInvariant() }
    @{ name = 'expectedTenantId'; value = $TenantId }
) | ConvertTo-Json -Compress
Write-Host "##vso[task.setsecret]$($ProvisioningPackageUri.AbsoluteUri)"
& az connectedmachine run-command create `
    --name 'avd-hybrid-enroll' `
    --machine-name $VmName `
    --resource-group $ArcResourceGroupName `
    --subscription $SubscriptionId `
    --location $Location `
    --script $guestScript `
    --parameters $parameters `
    --protected-parameters $protected `
    --timeout-in-seconds 1800 `
    --output none `
    --only-show-errors
if ($LASTEXITCODE -ne 0) { Write-Warning 'The enrollment command ended while the guest may have been restarting. Arc reconnection will determine success.' }

$deadline = [DateTime]::UtcNow.AddMinutes($ReconnectTimeoutMinutes)
$connected = $false
Start-Sleep -Seconds 45
do {
    $status = & az connectedmachine show --name $VmName --resource-group $ArcResourceGroupName --subscription $SubscriptionId --query status --output tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and $status -ieq 'Connected') {
        $connected = $true
        break
    }
    Write-Host "Waiting for '$VmName' to reconnect to Azure Arc..."
    Start-Sleep -Seconds 30
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $connected) { throw "Arc machine '$VmName' did not reconnect within $ReconnectTimeoutMinutes minutes." }

$verifyScript = @"
param([string]`$expectedTenantId)
`$status = dsregcmd.exe /status | Out-String
if (`$status -notmatch '(?im)^\s*AzureAdJoined\s*:\s*YES\s*`$') { throw 'AzureAdJoined is not YES.' }
`$tenantMatch = [regex]::Match(`$status, '(?im)^\s*TenantId\s*:\s*([0-9a-f-]+)\s*`$')
if (-not `$tenantMatch.Success -or `$tenantMatch.Groups[1].Value -ine `$expectedTenantId) { throw 'Entra tenant does not match.' }
Write-Output 'AVD_HYBRID_ENROLLMENT:VERIFIED'
"@
$verifyParameters = @(@{ name = 'expectedTenantId'; value = $TenantId }) | ConvertTo-Json -Compress
& az connectedmachine run-command create `
    --name 'avd-hybrid-enroll-verify' --machine-name $VmName --resource-group $ArcResourceGroupName `
    --subscription $SubscriptionId --location $Location --script $verifyScript --parameters $verifyParameters `
    --timeout-in-seconds 600 --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to execute the post-reboot Entra enrollment verification.' }
$verifyJson = & az connectedmachine run-command show --name 'avd-hybrid-enroll-verify' --machine-name $VmName --resource-group $ArcResourceGroupName --subscription $SubscriptionId --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the post-reboot Entra enrollment verification.' }
$verify = ($verifyJson -join [Environment]::NewLine) | ConvertFrom-Json -Depth 30
$instanceView = if ($verify.PSObject.Properties['instanceView']) { $verify.instanceView } else { $verify.properties.instanceView }
if ($instanceView.exitCode -ne 0 -or [string]$instanceView.output -notmatch 'AVD_HYBRID_ENROLLMENT:VERIFIED') {
    throw "Post-reboot Entra enrollment verification failed: $($instanceView.error)"
}
Write-Host "Arc machine '$VmName' reconnected and Entra tenant membership was verified."
