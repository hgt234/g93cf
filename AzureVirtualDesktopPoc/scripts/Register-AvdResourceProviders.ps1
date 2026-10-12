#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string[]]$ProviderNamespace = @(
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
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$accountJson = & az account show --output json --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not authenticated.`n$($accountJson -join [Environment]::NewLine)"
}
$account = ($accountJson -join [Environment]::NewLine) | ConvertFrom-Json
if ([string]$account.id -ine $SubscriptionId) {
    & az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to select subscription '$SubscriptionId'." }
}

foreach ($namespace in ($ProviderNamespace | Sort-Object -Unique)) {
    $state = & az provider show `
        --namespace $namespace `
        --subscription $SubscriptionId `
        --query registrationState `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to read provider '$namespace'." }

    if ($state -ieq 'Registered') {
        Write-Host "$namespace is already registered."
        continue
    }

    if ($PSCmdlet.ShouldProcess("subscription $SubscriptionId", "Register $namespace")) {
        Write-Host "Registering $namespace (current state: $state)..."
        & az provider register `
            --namespace $namespace `
            --subscription $SubscriptionId `
            --wait `
            --output none `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Provider registration failed for '$namespace'." }
    }
}

Write-Host 'Required AVD POC providers are registered. No resources were deleted or unregistered.'
