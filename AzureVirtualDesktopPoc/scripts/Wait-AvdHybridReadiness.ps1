#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ArcResourceGroupName,
    [Parameter(Mandatory)] [string] $PlatformResourceGroupName,
    [Parameter(Mandatory)] [string] $HostPoolName,
    [Parameter(Mandatory)] [string] $VmName,
    [string] $ExpectedGpuVendor = 'Intel',
    [string[]] $RequiredApplications = @(),
    [bool] $RequireIntuneCompliance = $true,
    [bool] $RequireMde = $true,
    [int] $TimeoutMinutes = 60,
    [string] $ReportPath = (Join-Path $PWD 'hybrid-readiness.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')" }
    if ([string]::IsNullOrWhiteSpace(($result -join "`n"))) { return $null }
    return (($result -join "`n") | ConvertFrom-Json -Depth 100)
}

function Get-NestedValue {
    param([object] $InputObject, [string[]] $Paths)
    foreach ($path in $Paths) {
        $value = $InputObject
        foreach ($part in ($path -split '\.')) {
            if ($null -eq $value) { break }
            $property = $value.PSObject.Properties[$part]
            if ($null -eq $property) { $value = $null; break }
            $value = $property.Value
        }
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
    }
    return $null
}

function Get-GuestReadiness {
    $requiredAppsJson = $RequiredApplications | ConvertTo-Json -Compress
    $encodedApps = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($requiredAppsJson))
    $guestScript = @'
$ErrorActionPreference = 'Stop'
$expectedTenantId = '{{TENANT}}'
$expectedGpuVendor = '{{GPU}}'
$requiredApps = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{{APPS}}')) | ConvertFrom-Json

$dsreg = (& dsregcmd.exe /status) -join "`n"
$tenantMatch = [regex]::Match($dsreg, '(?im)^\s*TenantId\s*:\s*([0-9a-f-]+)\s*$')
$deviceMatch = [regex]::Match($dsreg, '(?im)^\s*DeviceId\s*:\s*([0-9a-f-]+)\s*$')
$joined = $dsreg -match '(?im)^\s*AzureAdJoined\s*:\s*YES\s*$'
$tenantId = if ($tenantMatch.Success) { $tenantMatch.Groups[1].Value } else { $null }

$displayAdapters = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    [ordered]@{
        name = $_.Name
        vendorMatch = ($_.Name -match [regex]::Escape($expectedGpuVendor))
        configManagerErrorCode = $_.ConfigManagerErrorCode
        driverVersion = $_.DriverVersion
        driverDate = $_.DriverDate
        adapterRamBytes = $_.AdapterRAM
    }
})
$gpu = @($displayAdapters | Where-Object { $_.vendorMatch -and $_.configManagerErrorCode -eq 0 })

$dxdiagPath = Join-Path $env:TEMP ("avd-hybrid-dxdiag-{0}.xml" -f [guid]::NewGuid())
try {
    $dxProcess = Start-Process -FilePath "$env:WINDIR\System32\dxdiag.exe" -ArgumentList '/dontskip', '/whql:off', '/x', $dxdiagPath -Wait -PassThru -WindowStyle Hidden
    $dxdiagText = if (Test-Path $dxdiagPath) { Get-Content -Raw $dxdiagPath } else { '' }
    $dxdiagGpuDetected = ($dxProcess.ExitCode -eq 0) -and ($dxdiagText -match [regex]::Escape($expectedGpuVendor))
}
finally {
    Remove-Item -LiteralPath $dxdiagPath -Force -ErrorAction SilentlyContinue
}

$terminalServicesKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$rdpHardware = $false
$rdpAvc = $false
if (Test-Path $terminalServicesKey) {
    $rdpPolicy = Get-ItemProperty -Path $terminalServicesKey
    $rdpHardware = $rdpPolicy.bEnumerateHWBeforeSW -eq 1
    $rdpAvc = $rdpPolicy.AVCHardwareEncodePreferred -eq 1
}

$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installedNames = @(
    $uninstallPaths |
        ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
        Where-Object DisplayName |
        Select-Object -ExpandProperty DisplayName -Unique
)
$missingApps = @($requiredApps | Where-Object {
    $required = [string]$_
    -not ($installedNames | Where-Object { $_ -like "*$required*" })
})

$senseService = Get-Service -Name Sense -ErrorAction SilentlyContinue
$senseStatus = if ($senseService) { [string]$senseService.Status } else { 'Missing' }

$result = [ordered]@{
    computerName = $env:COMPUTERNAME
    azureAdJoined = $joined
    tenantId = $tenantId
    deviceId = if ($deviceMatch.Success) { $deviceMatch.Groups[1].Value } else { $null }
    tenantMatches = $joined -and ($tenantId -ieq $expectedTenantId)
    displayAdapters = $displayAdapters
    gpuHealthy = $gpu.Count -gt 0
    gpuDriverVersion = if ($gpu.Count -gt 0) { $gpu[0].driverVersion } else { $null }
    dxdiagGpuDetected = $dxdiagGpuDetected
    rdpHardwareGraphicsPolicy = $rdpHardware
    rdpAvcHardwareEncodingPolicy = $rdpAvc
    missingApplications = $missingApps
    applicationsReady = $missingApps.Count -eq 0
    senseServiceStatus = $senseStatus
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
}
$json = $result | ConvertTo-Json -Depth 10 -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
Write-Output "AVD_HYBRID_CHECK:$encoded"
'@
    $guestScript = $guestScript.Replace('{{TENANT}}', $TenantId).Replace('{{GPU}}', $ExpectedGpuVendor).Replace('{{APPS}}', $encodedApps)

    $location = [string](Invoke-AzJson -Arguments @('connectedmachine', 'show', '--subscription', $SubscriptionId, '--resource-group', $ArcResourceGroupName, '--name', $VmName, '--query', 'location'))
    $null = Invoke-AzJson -Arguments @(
        'connectedmachine', 'run-command', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ArcResourceGroupName,
        '--machine-name', $VmName,
        '--location', $location.Trim('"'),
        '--run-command-name', 'avd-hybrid-readiness',
        '--script', $guestScript
    )
    $command = Invoke-AzJson -Arguments @(
        'connectedmachine', 'run-command', 'show',
        '--subscription', $SubscriptionId,
        '--resource-group', $ArcResourceGroupName,
        '--machine-name', $VmName,
        '--run-command-name', 'avd-hybrid-readiness'
    )
    $output = [string](Get-NestedValue -InputObject $command -Paths @('properties.instanceView.output', 'instanceView.output', 'properties.output'))
    $match = [regex]::Match($output, 'AVD_HYBRID_CHECK:([A-Za-z0-9+/=]+)')
    if (-not $match.Success) { throw 'Arc Run Command did not return a readable hybrid readiness result.' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value))
    return ($json | ConvertFrom-Json -Depth 20)
}

$null = Invoke-AzJson -Arguments @('account', 'set', '--subscription', $SubscriptionId)
$account = Invoke-AzJson -Arguments @('account', 'show')
if ($account.tenantId -ine $TenantId) { throw "Authenticated tenant '$($account.tenantId)' does not match expected tenant '$TenantId'." }

$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$lastReport = $null
do {
    $arc = Invoke-AzJson -Arguments @('connectedmachine', 'show', '--subscription', $SubscriptionId, '--resource-group', $ArcResourceGroupName, '--name', $VmName)
    $extensions = @(Invoke-AzJson -Arguments @('connectedmachine', 'extension', 'list', '--subscription', $SubscriptionId, '--resource-group', $ArcResourceGroupName, '--machine-name', $VmName))
    $aadExtension = @($extensions | Where-Object { $_.properties.type -eq 'AADLoginForWindows' }) | Select-Object -First 1
    $avdExtension = @($extensions | Where-Object { $_.properties.type -eq 'CloudDeviceExtension' -or $_.name -match 'CloudDeviceExtension$' }) | Select-Object -First 1
    $aadExtensionState = if ($aadExtension) { [string]$aadExtension.properties.provisioningState } else { $null }
    $avdExtensionState = if ($avdExtension) { [string]$avdExtension.properties.provisioningState } else { $null }

    $guest = $null
    $guestError = $null
    if ($arc.status -eq 'Connected') {
        try { $guest = Get-GuestReadiness } catch { $guestError = $_.Exception.Message }
    }

    $entraDevice = $null
    if ($guest -and $guest.deviceId) {
        $entraDevices = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId%20eq%20'$($guest.deviceId)'&`$select=id,deviceId,displayName,accountEnabled")
        $entraDevice = @($entraDevices.value | Where-Object deviceId -ieq $guest.deviceId) | Select-Object -First 1
    }

    $intuneDevice = $null
    if ($entraDevice) {
        $managed = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=azureADDeviceId%20eq%20'$($entraDevice.deviceId)'&`$select=id,deviceName,azureADDeviceId,complianceState,lastSyncDateTime")
        $intuneDevice = @($managed.value) | Select-Object -First 1
    }

    $mdeMachine = $null
    $mdeError = $null
    if ($RequireMde -and $entraDevice) {
        try {
            $mdeToken = & az account get-access-token --resource 'https://api.securitycenter.microsoft.com' --query accessToken --output tsv --only-show-errors
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mdeToken)) { throw 'Unable to acquire a Defender for Endpoint API token.' }
            $filter = [Uri]::EscapeDataString("aadDeviceId eq '$($entraDevice.deviceId)'")
            $mde = Invoke-RestMethod -Method Get -Uri "https://api.security.microsoft.com/api/machines?`$filter=$filter" -Headers @{ Authorization = "Bearer $mdeToken" }
            $mdeMachine = @($mde.value) | Sort-Object lastSeen -Descending | Select-Object -First 1
            $mdeToken = $null
        }
        catch {
            $mdeToken = $null
            $mdeError = $_.Exception.Message
        }
    }

    $hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
    $sessionHostResponse = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://management.azure.com$hostPoolId/sessionHosts?api-version=2024-04-03")
    $sessionHost = @($sessionHostResponse.value | Where-Object { $_.name.Split('/')[-1].Split('.')[0] -ieq $VmName }) | Select-Object -First 1

    $intuneReady = (-not $RequireIntuneCompliance) -or ($intuneDevice -and $intuneDevice.complianceState -eq 'compliant')
    $mdeReady = (-not $RequireMde) -or ($mdeMachine -and $mdeMachine.onboardingStatus -eq 'Onboarded' -and $mdeMachine.healthStatus -eq 'Active')
    $ready =
        $arc.status -eq 'Connected' -and
        $aadExtensionState -eq 'Succeeded' -and
        $avdExtensionState -eq 'Succeeded' -and
        $guest -and $guest.computerName -ieq $VmName -and $guest.tenantMatches -and
        $guest.gpuHealthy -and $guest.dxdiagGpuDetected -and
        $guest.rdpHardwareGraphicsPolicy -and $guest.rdpAvcHardwareEncodingPolicy -and
        $guest.applicationsReady -and
        $entraDevice -and $entraDevice.accountEnabled -and $entraDevice.displayName -ieq $VmName -and
        $intuneReady -and $mdeReady -and
        $sessionHost -and $sessionHost.properties.status -eq 'Available'

    $lastReport = [ordered]@{
        ready = [bool]$ready
        vmName = $VmName
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        arc = @{ status = $arc.status; id = $arc.id }
        extensions = @{
            aadLogin = $aadExtensionState
            avdCloudDevice = $avdExtensionState
        }
        guest = $guest
        guestError = $guestError
        entra = $entraDevice
        intune = $intuneDevice
        mde = $mdeMachine
        mdeQueryError = $mdeError
        sessionHost = if ($sessionHost) { @{ name = $sessionHost.name; status = $sessionHost.properties.status; allowNewSession = $sessionHost.properties.allowNewSession } } else { $null }
    }
    $lastReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    if ($ready) { break }
    Start-Sleep -Seconds 30
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $lastReport.ready) {
    throw "Hybrid session host '$VmName' did not pass all readiness gates within $TimeoutMinutes minutes. See '$ReportPath'."
}

Write-Host "Hybrid session host '$VmName' passed readiness. GPU driver: $($lastReport.guest.gpuDriverVersion)"
