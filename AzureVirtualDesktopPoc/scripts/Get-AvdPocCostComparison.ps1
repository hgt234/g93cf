#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][decimal]$AzureStandardCompute30Day,
    [Parameter(Mandatory)][decimal]$AzureStandardStorage30Day,
    [Parameter(Mandatory)][decimal]$AzureSharedNetworkAllocation30Day,
    [Parameter(Mandatory)][decimal]$HybridAvdServiceFeePerUser,
    [decimal]$SharedUserLicensing30Day = 0,
    [decimal]$HybridMonitorIngestion30Day = 0,
    [decimal]$ProxmoxHostWattsIdle = 0,
    [decimal]$ProxmoxHostWattsLoad = 0,
    [ValidateRange(0, 100)][decimal]$ProxmoxLoadPercent = 0,
    [decimal]$ElectricityPricePerKwh = 0,
    [decimal]$ProxmoxHardwareCost = 0,
    [ValidateRange(1, 240)][int]$HardwareAmortizationMonths = 36,
    [ValidateRange(0, 100)][decimal]$HybridVmHostAllocationPercent = 100,
    [decimal]$AzureGpuAlternative30Day = 0,
    [string]$ReportPath = (Join-Path $PWD 'avd-30-day-cost-comparison.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$hours = [decimal]720
$averageWatts = $ProxmoxHostWattsIdle + (($ProxmoxHostWattsLoad - $ProxmoxHostWattsIdle) * ($ProxmoxLoadPercent / 100))
$hostElectricity = (($averageWatts / 1000) * $hours * $ElectricityPricePerKwh)
$allocation = $HybridVmHostAllocationPercent / 100
$hybridElectricity = $hostElectricity * $allocation
$hybridDepreciation = ($ProxmoxHardwareCost / $HardwareAmortizationMonths) * $allocation

$azureStandard = $AzureStandardCompute30Day + $AzureStandardStorage30Day + $AzureSharedNetworkAllocation30Day + $SharedUserLicensing30Day
$hybrid = $HybridAvdServiceFeePerUser + $SharedUserLicensing30Day + $HybridMonitorIngestion30Day + $hybridElectricity + $hybridDepreciation

$report = [ordered]@{
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    periodDays = 30
    currency = 'Use one consistent currency for every input'
    procurementGate = if ($HybridAvdServiceFeePerUser -le 0) { 'AVD Hybrid service quote required from Microsoft account team' } else { 'Hybrid fee supplied' }
    options = @(
        [ordered]@{
            name = 'Azure standard personal desktop'
            total = [math]::Round($azureStandard, 2)
            components = @{ compute = $AzureStandardCompute30Day; storage = $AzureStandardStorage30Day; sharedNetworkAllocation = $AzureSharedNetworkAllocation30Day; userLicensing = $SharedUserLicensing30Day }
        },
        [ordered]@{
            name = 'Proxmox Hybrid GPU personal desktop'
            total = [math]::Round($hybrid, 2)
            components = @{ avdHybridService = $HybridAvdServiceFeePerUser; userLicensing = $SharedUserLicensing30Day; monitorIngestion = $HybridMonitorIngestion30Day; electricity = [math]::Round($hybridElectricity, 2); hardwareDepreciation = [math]::Round($hybridDepreciation, 2) }
            excludedAzureServices = @('Azure VM', 'Managed disk', 'NAT Gateway', 'Bastion', 'Public IP', 'VPN Gateway')
        },
        [ordered]@{
            name = 'Estimated Azure GPU AVD alternative'
            total = if ($AzureGpuAlternative30Day -gt 0) { [math]::Round($AzureGpuAlternative30Day + $SharedUserLicensing30Day, 2) } else { $null }
            note = if ($AzureGpuAlternative30Day -gt 0) { 'Estimate supplied' } else { 'Not estimated; supply AzureGpuAlternative30Day when needed' }
        }
    )
}
$parent = Split-Path -Parent $ReportPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding utf8
$report | ConvertTo-Json -Depth 20
