#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$SessionHostResourceGroupName,
    [Parameter(Mandatory)][string]$PlatformResourceGroupName,
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$VmName,
    [string[]]$RequiredAppName = @(),
    [switch]$RequireIntuneCompliant,
    [switch]$RequireMde,
    [ValidateRange(5, 120)][int]$TimeoutMinutes = 100,
    [ValidateRange(15, 300)][int]$PollSeconds = 60,
    [string]$MdeApiBaseUrl = 'https://api.securitycenter.microsoft.com',
    [string]$ReportPath = (Join-Path $PWD 'avd-readiness.json')
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

function Save-ReadinessReport {
    param([System.Collections.IDictionary]$Report)
    $parent = Split-Path -Parent $ReportPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ReportPath -Encoding utf8
}

$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$PlatformResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$graphToken = $null
$graphTokenRefreshUtc = [DateTime]::MinValue
$mdeToken = $null
$mdeTokenRefreshUtc = [DateTime]::MinValue
$appsVerified = $RequiredAppName.Count -eq 0
$appDetails = $null
$report = [ordered]@{
    schemaVersion = 1
    vmName = $VmName
    startedUtc = [DateTime]::UtcNow.ToString('o')
    deadlineUtc = $deadline.ToString('o')
    requiredApps = @($RequiredAppName)
    requireIntuneCompliant = [bool]$RequireIntuneCompliant
    requireMde = [bool]$RequireMde
    result = 'Waiting'
    checks = @{}
    errors = @()
}

while ([DateTime]::UtcNow -lt $deadline) {
    $checks = [ordered]@{
        azureVm = $false
        entra = $false
        intune = -not $RequireIntuneCompliant
        intuneCompliance = -not $RequireIntuneCompliant
        requiredApps = $appsVerified
        mde = -not $RequireMde
        avd = $false
    }
    $details = [ordered]@{}
    $pollErrors = [System.Collections.Generic.List[string]]::new()

    try {
        $vm = Invoke-AzCliJson -ArgumentList @(
            'vm', 'get-instance-view', '--resource-group', $SessionHostResourceGroupName,
            '--name', $VmName, '--subscription', $SubscriptionId
        )
        $powerState = [string](@($vm.instanceView.statuses | Where-Object code -Like 'PowerState/*') | Select-Object -First 1).code
        $checks.azureVm = [string]$vm.provisioningState -ieq 'Succeeded' -and $powerState -ieq 'PowerState/running'
        $details.azureVm = @{ provisioningState = $vm.provisioningState; powerState = $powerState }
    }
    catch { $pollErrors.Add("Azure VM: $($_.Exception.Message)") }

    $entraDevice = $null
    try {
        if (-not $graphToken -or [DateTime]::UtcNow -ge $graphTokenRefreshUtc) {
            $tokenResult = Invoke-AzCliJson -ArgumentList @(
                'account', 'get-access-token', '--resource', 'https://graph.microsoft.com',
                '--subscription', $SubscriptionId
            )
            $graphToken = [string]$tokenResult.accessToken
            $graphTokenRefreshUtc = [DateTime]::UtcNow.AddMinutes(40)
        }
        $filter = [Uri]::EscapeDataString("displayName eq '$VmName'")
        $entra = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=$filter&`$select=id,deviceId,displayName,accountEnabled,trustType" `
            -Headers @{ Authorization = "Bearer $graphToken" }
        $entraDevice = @($entra.value | Where-Object displayName -CEQ $VmName) | Select-Object -First 1
        $checks.entra = $null -ne $entraDevice -and $entraDevice.accountEnabled -eq $true
        if ($entraDevice) {
            $details.entra = @{ id = $entraDevice.id; deviceId = $entraDevice.deviceId; trustType = $entraDevice.trustType; accountEnabled = $entraDevice.accountEnabled }
        }
    }
    catch { $pollErrors.Add("Entra: $($_.Exception.Message)") }

    $managedDevice = $null
    try {
        $filter = [Uri]::EscapeDataString("deviceName eq '$VmName'")
        $intune = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$filter&`$select=id,deviceName,complianceState,managementAgent,lastSyncDateTime,azureADDeviceId" `
            -Headers @{ Authorization = "Bearer $graphToken" }
        $managedDevice = @($intune.value | Where-Object deviceName -CEQ $VmName) | Sort-Object lastSyncDateTime -Descending | Select-Object -First 1
        $checks.intune = -not $RequireIntuneCompliant -or ($null -ne $managedDevice -and [string]$managedDevice.managementAgent -notin @('', 'unknown'))
        if ($managedDevice) {
            $checks.intuneCompliance = -not $RequireIntuneCompliant -or [string]$managedDevice.complianceState -ieq 'compliant'
            $details.intune = @{
                id = $managedDevice.id
                complianceState = $managedDevice.complianceState
                managementAgent = $managedDevice.managementAgent
                lastSyncDateTime = $managedDevice.lastSyncDateTime
            }
        }
    }
    catch { $pollErrors.Add("Intune: $($_.Exception.Message)") }

    if (-not $appsVerified -and $checks.azureVm) {
        try {
            $requiredJson = $RequiredAppName | ConvertTo-Json -Compress
            $requiredBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($requiredJson))
            $guestScript = @'
$requiredJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REQUIRED_APPS__'))
$required = @($requiredJson | ConvertFrom-Json)
$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$detected = @(Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    ForEach-Object { [string]$_.DisplayName } |
    Sort-Object -Unique)
$missing = @($required | Where-Object { $detected -inotcontains [string]$_ })
$payload = @{ detected = $detected; missing = $missing } | ConvertTo-Json -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
Write-Output "AVD_APP_CHECK:$encoded"
'@.Replace('__REQUIRED_APPS__', $requiredBase64)
            $guestScriptPath = Join-Path ([IO.Path]::GetTempPath()) "avd-app-check-$([Guid]::NewGuid().ToString('N')).ps1"
            try {
                $guestScript | Set-Content -LiteralPath $guestScriptPath -Encoding utf8
                $runCommand = Invoke-AzCliJson -ArgumentList @(
                    'vm', 'run-command', 'invoke',
                    '--resource-group', $SessionHostResourceGroupName,
                    '--name', $VmName,
                    '--subscription', $SubscriptionId,
                    '--command-id', 'RunPowerShellScript',
                    '--scripts', "@$guestScriptPath"
                )
            }
            finally {
                Remove-Item -LiteralPath $guestScriptPath -Force -ErrorAction SilentlyContinue
            }
            $message = @($runCommand.value | ForEach-Object { [string]$_.message }) -join [Environment]::NewLine
            $payloadMatch = [regex]::Match($message, 'AVD_APP_CHECK:(?<payload>[A-Za-z0-9+/=]+)')
            if (-not $payloadMatch.Success) { throw 'The guest application check returned no parseable result.' }
            $appJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadMatch.Groups['payload'].Value))
            $appDetails = $appJson | ConvertFrom-Json -Depth 20
            $appsVerified = @($appDetails.missing).Count -eq 0
            $checks.requiredApps = $appsVerified
        }
        catch { $pollErrors.Add("Required apps: $($_.Exception.Message)") }
    }
    if ($appDetails) { $details.requiredApps = $appDetails }

    if ($RequireMde -and $entraDevice) {
        try {
            if (-not $mdeToken -or [DateTime]::UtcNow -ge $mdeTokenRefreshUtc) {
                $tokenResult = Invoke-AzCliJson -ArgumentList @(
                    'account', 'get-access-token', '--resource', $MdeApiBaseUrl,
                    '--subscription', $SubscriptionId
                )
                $mdeToken = [string]$tokenResult.accessToken
                $mdeTokenRefreshUtc = [DateTime]::UtcNow.AddMinutes(40)
            }
            $mdeResponse = Invoke-RestMethod -Method Get `
                -Uri "$MdeApiBaseUrl/api/machines" `
                -Headers @{ Authorization = "Bearer $mdeToken" }
            $mdeMachine = @($mdeResponse.value | Where-Object aadDeviceId -IEQ $entraDevice.deviceId) |
                Sort-Object lastSeen -Descending | Select-Object -First 1
            $checks.mde = $null -ne $mdeMachine -and [string]$mdeMachine.onboardingStatus -ieq 'Onboarded' -and [string]$mdeMachine.healthStatus -ieq 'Active'
            if ($mdeMachine) {
                $details.mde = @{ id = $mdeMachine.id; onboardingStatus = $mdeMachine.onboardingStatus; healthStatus = $mdeMachine.healthStatus; lastSeen = $mdeMachine.lastSeen }
            }
        }
        catch { $pollErrors.Add("MDE: $($_.Exception.Message)") }
    }

    try {
        $sessionHostResponse = Invoke-AzCliJson -ArgumentList @(
            'rest', '--method', 'GET',
            '--url', "https://management.azure.com$hostPoolId/sessionHosts?api-version=2024-04-03"
        )
        $sessionHost = @($sessionHostResponse.value) | Where-Object {
            $leaf = (([string]$_.name -split '/')[-1] -split '\.')[0]
            $leaf -ieq $VmName
        } | Select-Object -First 1
        $checks.avd = $null -ne $sessionHost -and [string]$sessionHost.properties.status -ieq 'Available'
        if ($sessionHost) {
            $details.avd = @{ id = $sessionHost.id; status = $sessionHost.properties.status; allowNewSession = $sessionHost.properties.allowNewSession }
        }
    }
    catch { $pollErrors.Add("AVD: $($_.Exception.Message)") }

    $report.checks = $checks
    $report.details = $details
    $report.errors = @($pollErrors)
    $report.lastCheckedUtc = [DateTime]::UtcNow.ToString('o')
    Save-ReadinessReport -Report $report

    $pending = @($checks.Keys | Where-Object { -not $checks[$_] })
    if ($pending.Count -eq 0) {
        $report.result = 'Ready'
        $report.completedUtc = [DateTime]::UtcNow.ToString('o')
        Save-ReadinessReport -Report $report
        Write-Host "'$VmName' passed Azure, Entra, Intune, application, MDE, and AVD readiness gates."
        return
    }

    Write-Host "Waiting for '$VmName': $($pending -join ', '). Next check in $PollSeconds seconds."
    Start-Sleep -Seconds $PollSeconds
}

$report.result = 'TimedOut'
$report.completedUtc = [DateTime]::UtcNow.ToString('o')
Save-ReadinessReport -Report $report
throw "'$VmName' did not become ready within $TimeoutMinutes minutes. Pending checks: $((@($report.checks.Keys | Where-Object { -not $report.checks[$_] })) -join ', ')."
