#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$Location = 'centralus',
    [string]$VmSize = 'Standard_E4bs_v5',
    [string]$ReportPath = (Join-Path $PWD 'avd-poc-prerequisites.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$requiredProviders = @(
    'Microsoft.Compute',
    'Microsoft.ContainerInstance',
    'Microsoft.DesktopVirtualization',
    'Microsoft.HybridCompute',
    'Microsoft.KeyVault',
    'Microsoft.ManagedIdentity',
    'Microsoft.Network',
    'Microsoft.Storage',
    'Microsoft.VirtualMachineImages'
)
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$entryPoints = @(
    'infra/main.bicep',
    'infra/access.bicep',
    'infra/hybrid-main.bicep',
    'infra/hybrid-access.bicep',
    'infra/image-main.bicep',
    'infra/session-host.bicep'
)
$checks = [ordered]@{}
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-AzText {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $result = & az @ArgumentList --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($ArgumentList -join ' ') failed:`n$($result -join [Environment]::NewLine)"
    }
    return ($result -join [Environment]::NewLine)
}

try {
    $account = (Invoke-AzText @('account', 'show', '--output', 'json')) | ConvertFrom-Json
    $checks.azureCliAuthenticated = $true
    $checks.subscriptionMatches = [string]$account.id -ieq $SubscriptionId
    $checks.tenantMatches = [string]$account.tenantId -ieq $TenantId
    if (-not $checks.subscriptionMatches) { $failures.Add("Azure CLI subscription is '$($account.id)', expected '$SubscriptionId'.") }
    if (-not $checks.tenantMatches) { $failures.Add("Azure CLI tenant is '$($account.tenantId)', expected '$TenantId'.") }
}
catch {
    $checks.azureCliAuthenticated = $false
    $failures.Add($_.Exception.Message)
}

$providerStates = [ordered]@{}
if ($checks.azureCliAuthenticated) {
    foreach ($namespace in $requiredProviders) {
        try {
            $state = Invoke-AzText @(
                'provider', 'show', '--namespace', $namespace,
                '--subscription', $SubscriptionId,
                '--query', 'registrationState', '--output', 'tsv'
            )
            $providerStates[$namespace] = $state.Trim()
            if ($state.Trim() -ine 'Registered') { $failures.Add("Provider '$namespace' is '$($state.Trim())'.") }
        }
        catch {
            $providerStates[$namespace] = 'ReadFailed'
            $failures.Add($_.Exception.Message)
        }
    }
}
$checks.providers = $providerStates

if ($checks.azureCliAuthenticated) {
    try {
        $skuJson = Invoke-AzText @(
            'vm', 'list-skus', '--location', $Location, '--size', $VmSize,
            '--subscription', $SubscriptionId, '--all', '--output', 'json'
        )
        $skus = @($skuJson | ConvertFrom-Json -Depth 50)
        $usableSku = $skus | Where-Object {
            [string]$_.name -ieq $VmSize -and
            @($_.restrictions | Where-Object reasonCode -EQ 'NotAvailableForSubscription').Count -eq 0
        } | Select-Object -First 1
        $checks.vmSizeAvailable = $null -ne $usableSku
        if (-not $checks.vmSizeAvailable) { $failures.Add("VM size '$VmSize' is unavailable for this subscription in '$Location'.") }
    }
    catch {
        $checks.vmSizeAvailable = $false
        $failures.Add($_.Exception.Message)
    }

    try {
        $imageId = Invoke-AzText @(
            'vm', 'image', 'show', '--location', $Location,
            '--urn', 'MicrosoftWindowsDesktop:windows-11:win11-24h2-ent:latest',
            '--subscription', $SubscriptionId, '--query', 'id', '--output', 'tsv'
        )
        $checks.windows11ImageAvailable = -not [string]::IsNullOrWhiteSpace($imageId)
        if (-not $checks.windows11ImageAvailable) { $failures.Add("Windows 11 24H2 Enterprise image was not found in '$Location'.") }
    }
    catch {
        $checks.windows11ImageAvailable = $false
        $failures.Add($_.Exception.Message)
    }
}

$bicepResults = [ordered]@{}
foreach ($relativePath in $entryPoints) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $bicepResults[$relativePath] = 'Missing'
        $failures.Add("Missing Bicep entry point '$relativePath'.")
        continue
    }
    $buildOutput = & az bicep build --file $path --stdout 2>&1
    if ($LASTEXITCODE -eq 0) {
        $bicepResults[$relativePath] = 'Compiled'
    }
    else {
        $bicepResults[$relativePath] = 'CompileFailed'
        $failures.Add("Bicep compile failed for '$relativePath': $($buildOutput -join [Environment]::NewLine)")
    }
}
$checks.bicep = $bicepResults

$report = [ordered]@{
    checkedUtc = [DateTime]::UtcNow.ToString('o')
    subscriptionId = $SubscriptionId
    tenantId = $TenantId
    location = $Location
    vmSize = $VmSize
    passed = $failures.Count -eq 0
    checks = $checks
    failures = @($failures)
}
$parent = Split-Path -Parent $ReportPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$report | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ReportPath -Encoding utf8

if ($failures.Count -gt 0) {
    throw "AVD POC prerequisite checks failed. Review '$ReportPath':`n- $($failures -join "`n- ")"
}
Write-Host "AVD POC prerequisites passed. Report: $ReportPath"
