#requires -Version 5.1
<#
.SYNOPSIS
Writes a demo Endpoint Explorer report from generated mock data.

.DESCRIPTION
Builds a deterministic, obviously fake fleet (example.test users, placeholder
GUIDs) and pushes it through the same code paths as a real export:
ConvertTo-EndpointDevice (classification and activity),
ConvertTo-EndpointAppSummary (fleet app aggregation), and ConvertTo-EndpointHtml.
Never connects to Microsoft Graph.

The data deliberately includes edge cases: every management type and
compliance state, never-checked-in and stale devices, devices without a
primary user or encryption state, non-ASCII and very long device names, a
device name containing a script tag (to show HTML escaping), apps with many
versions, apps without a publisher, a long tail of rare apps, and for rollout
exports: several Intune records for one Entra device, devices without an Entra
device id, and devices without an Entra object.

Writes EndpointInventory.json and EndpointInventory.html. Because the snapshot
is valid, Export-EndpointInventory.ps1 -FromCache can also render it.

.PARAMETER OutputDirectory
Folder for the demo files. Defaults to exports/EndpointExplorer/Demo
(git-ignored).

.PARAMETER DeviceCount
Number of mock devices. Defaults to 3000, the target fleet size.

.PARAMETER Seed
Random seed. The same seed and device count produce the same fleet.

.PARAMETER WithoutDeviceApps
Renders the report as if -IncludeDeviceApps had not been used: no per-device
drill-down, and app device counts are the approximate per-version sums.

.PARAMETER PassThru
Returns the snapshot object.

.EXAMPLE
.\New-EndpointDemoReport.ps1
Writes a 3,000-device demo report with per-device apps.

.EXAMPLE
.\New-EndpointDemoReport.ps1 -DeviceCount 200 -WithoutDeviceApps -WhatIf
Shows which files would be written, without writing them.

.EXAMPLE
.\New-EndpointDemoReport.ps1; ..\EndpointExplorer\Export-EndpointInventory.ps1 -FromCache -OutputDirectory exports/EndpointExplorer/Demo -ActiveWithinDays 14
Generates the demo, then re-renders it through the real cache path.

.NOTES
Demo data only. The report header carries a DEMO DATA warning.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory = 'exports/EndpointExplorer/Demo',
    [ValidateRange(1, 20000)] [int] $DeviceCount = 3000,
    [int] $Seed = 20261013,
    [switch] $WithoutDeviceApps,
    [switch] $PassThru
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EndpointExplorer.Common.ps1')

function Get-DemoWeightedItem {
    # Picks one item from @(@(value, weight), ...) using the shared generator.
    param([Parameter(Mandatory)] [System.Random] $Random, [Parameter(Mandatory)] [object[]] $Choices)
    $total = 0.0
    foreach ($choice in $Choices) { $total += $choice[1] }
    $roll = $Random.NextDouble() * $total
    foreach ($choice in $Choices) {
        $roll -= $choice[1]
        if ($roll -lt 0) { return $choice[0] }
    }
    return $Choices[-1][0]
}

function Get-DemoGuid {
    # Placeholder GUIDs: a fixed prefix per kind plus the index, never random.
    param([Parameter(Mandatory)] [string] $Prefix, [Parameter(Mandatory)] [int] $Index)
    return '{0}-0000-4000-8000-{1:d12}' -f $Prefix, $Index
}

function Get-DemoAppCatalog {
    # Name, publisher, versions (newest first; earlier versions are more common),
    # share of devices, and an optional manufacturer the app is limited to.
    $catalog = New-Object 'System.Collections.Generic.List[object]'
    $add = {
        param($Name, $Publisher, [string[]] $Versions, [double] $Share, [string] $Manufacturer = '')
        $catalog.Add([pscustomobject]@{ Name = $Name; Publisher = $Publisher; Versions = $Versions; Share = $Share; Manufacturer = $Manufacturer })
    }
    & $add 'Microsoft Edge' 'Microsoft Corporation' @('130.0.2849.68', '129.0.2792.89', '128.0.2739.79') 0.99
    & $add 'Microsoft OneDrive' 'Microsoft Corporation' @('24.201.1006.0005', '24.186.0915.0002') 0.97
    & $add 'Microsoft Visual C++ 2015-2022 Redistributable (x64)' 'Microsoft Corporation' @('14.40.33816.0', '14.38.33135.0', '14.36.32532.0') 0.98
    & $add 'Microsoft 365 Apps for enterprise - en-us' 'Microsoft Corporation' @('16.0.18129.20116', '16.0.17928.20216') 0.95
    & $add 'Microsoft Teams' 'Microsoft Corporation' @('24277.3502.3161.3007', '24243.1309.3132.617') 0.9
    & $add 'Cisco Secure Client - AnyConnect VPN' 'Cisco Systems, Inc.' @('5.1.4.74', '5.1.2.42', '4.10.08025') 0.8
    & $add 'Google Chrome' 'Google LLC' @('130.0.6723.92', '129.0.6668.101', '128.0.6613.138', '127.0.6533.120') 0.7
    & $add 'Adobe Acrobat (64-bit)' 'Adobe' @('24.003.20180', '24.002.20991', '23.008.20470') 0.6
    & $add '7-Zip 23.01 (x64)' 'Igor Pavlov' @('23.01') 0.4
    & $add '7-Zip 19.00 (x64)' 'Igor Pavlov' @('19.00') 0.12
    & $add 'Zoom Workplace (64-bit)' 'Zoom Video Communications, Inc.' @('6.2.6', '6.1.11', '5.17.11') 0.35
    & $add 'Dell Command | Update' 'Dell Inc.' @('5.4.0', '5.3.0') 0.9 'Dell Inc.'
    & $add 'HP Support Assistant' 'HP Inc.' @('9.38.20.0', '9.36.28.0') 0.85 'HP'
    & $add 'Lenovo Vantage Service' 'Lenovo Group Ltd.' @('4.1.33.0', '3.13.43.0') 0.85 'LENOVO'
    & $add 'Notepad++ (64-bit x64)' 'Notepad++ Team' @('8.7', '8.6.9', '8.5.8') 0.25
    & $add 'VLC media player' 'VideoLAN' @('3.0.21', '3.0.20') 0.2
    & $add 'Mozilla Firefox (x64 en-US)' 'Mozilla' @('131.0.3', '128.3.1') 0.15
    & $add 'Microsoft Visual Studio Code (User)' 'Microsoft Corporation' @('1.95.1', '1.94.2', '1.93.1') 0.12
    & $add 'Java 8 Update 431 (64-bit)' 'Oracle Corporation' @('8.0.4310.11', '8.0.4210.9') 0.1
    & $add 'Git' 'The Git Development Community' @('2.47.0', '2.46.2') 0.08
    & $add 'Python 3.12.7 (64-bit)' 'Python Software Foundation' @('3.12.7150.0') 0.06
    & $add 'Webex' 'Cisco Systems, Inc' @('44.10.0.30906', '44.9.1.30809', '44.8.0.30404', '44.7.0.30285', '44.6.2.30086', '44.5.0.29672', '44.4.0.29432', '44.3.0.28993', '44.2.0.28744', '43.12.0.27870', '43.10.0.27605', '43.8.0.26955') 0.18
    & $add 'Legacy Expense Tool' '' @('1.0') 0.03
    for ($i = 1; $i -le 160; $i++) {
        $versionCount = 1 + ($i % 3)
        $versions = @(for ($v = $versionCount; $v -ge 1; $v--) { '{0}.{1}.0' -f (1 + ($i % 4)), $v })
        & $add ('Line of Business App {0:d3}' -f $i) 'Example Corp' $versions (0.002 + (($i * 37) % 50) / 1000.0)
    }
    return $catalog.ToArray()
}

function New-DemoManagedDevice {
    # Returns a managedDevice-shaped hashtable (Graph v1.0 property names).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no state.')]
    param([Parameter(Mandatory)] [System.Random] $Random, [Parameter(Mandatory)] [int] $Index, [Parameter(Mandatory)] [DateTimeOffset] $Now)
    $hardware = Get-DemoWeightedItem -Random $Random -Choices @(
        @(@('LT', 'Dell Inc.', 'Latitude 7450'), 22), @(@('LT', 'Dell Inc.', 'Latitude 5440'), 18), @(@('LT', 'HP', 'HP EliteBook 840 G10'), 15),
        @(@('LT', 'LENOVO', '21HD003AUS'), 12), @(@('LT', 'Microsoft Corporation', 'Surface Laptop 6'), 8),
        @(@('DT', 'Dell Inc.', 'OptiPlex 7010'), 14), @(@('DT', 'HP', 'HP Elite Mini 800 G9'), 6), @(@('VM', 'Microsoft Corporation', 'Virtual Machine'), 5))
    $agent = Get-DemoWeightedItem -Random $Random -Choices @(
        @('mdm', 55), @('configurationManagerClientMdm', 30), @('configurationManagerClient', 8), @('configurationManagerClientMdmEas', 1),
        @('easMdm', 1), @('eas', 0.5), @('intuneClient', 0.5), @('unknown', 2), @('msSense', 2))
    $enrollment = if ($agent -eq 'mdm' -and $Random.NextDouble() -lt 0.05) { 'windowsCoManagement' }
    elseif ($agent -like 'configurationManagerClientMdm*') { 'windowsCoManagement' }
    elseif ($agent -eq 'configurationManagerClient') { 'unknown' }
    else { Get-DemoWeightedItem -Random $Random -Choices @(@('windowsAzureADJoin', 70), @('windowsAutoEnrollment', 20), @('windowsBulkUserless', 5), @('unknown', 5)) }
    $os = Get-DemoWeightedItem -Random $Random -Choices @(
        @('10.0.26100.2033', 30), @('10.0.26100.1882', 12), @('10.0.22631.4317', 25), @('10.0.22631.4169', 10), @('10.0.22621.4317', 5),
        @('10.0.19045.5011', 14), @('10.0.19045.4894', 4))
    $ageBucket = Get-DemoWeightedItem -Random $Random -Choices @(@('recent', 58), @('aging', 22), @('stale', 15), @('never', 3), @('ancient', 2))
    $lastSync = switch ($ageBucket) {
        'recent' { $Now.AddMinutes(-$Random.Next(5, 7 * 24 * 60)) }
        'aging' { $Now.AddDays(-$Random.Next(8, 30)).AddHours(-$Random.Next(0, 24)) }
        'stale' { $Now.AddDays(-$Random.Next(31, 120)).AddHours(-$Random.Next(0, 24)) }
        'ancient' { $Now.AddDays(-$Random.Next(200, 700)) }
        default { $null }
    }
    $first = @('alex', 'sam', 'jordan', 'taylor', 'casey', 'morgan', 'riley', 'jamie', 'avery', 'quinn', 'drew', 'robin')[$Random.Next(0, 12)]
    $last = @('smith', 'garcia', 'chen', 'patel', 'novak', 'okafor', 'silva', 'kowalski', 'nguyen', 'murphy', 'haddad', 'berg')[$Random.Next(0, 12)]
    $upn = if ($hardware[0] -eq 'VM' -or $Random.NextDouble() -lt 0.04) { '' } else { '{0}.{1}{2}@example.test' -f $first, $last, $Index }
    $encrypted = Get-DemoWeightedItem -Random $Random -Choices @(@('true', 92), @('false', 6), @('null', 2))
    return @{
        id = Get-DemoGuid -Prefix 'aaaaaaaa' -Index $Index
        deviceName = 'ORG-{0}-{1:d4}' -f $hardware[0], $Index
        userPrincipalName = $upn
        lastSyncDateTime = if ($null -eq $lastSync) { '0001-01-01T00:00:00Z' } else { $lastSync.ToString('o') }
        managementAgent = $agent
        deviceEnrollmentType = $enrollment
        operatingSystem = 'Windows'
        osVersion = $os
        complianceState = Get-DemoWeightedItem -Random $Random -Choices @(
            @('compliant', 78), @('noncompliant', 9), @('inGracePeriod', 3), @('unknown', 5), @('error', 1), @('conflict', 1), @('configManager', 3))
        model = $hardware[2]
        manufacturer = $hardware[1]
        serialNumber = if ($hardware[0] -eq 'VM') { '' } else { 'DEMO{0:d6}' -f $Index }
        azureADDeviceId = Get-DemoGuid -Prefix 'bbbbbbbb' -Index $Index
        enrolledDateTime = $Now.AddDays(-$Random.Next(30, 900)).ToString('o')
        managedDeviceOwnerType = if ($Random.NextDouble() -lt 0.03) { 'personal' } else { 'company' }
        deviceCategoryDisplayName = switch ($hardware[0]) { 'LT' { 'Laptop' } 'DT' { 'Desktop' } default { '' } }
        isEncrypted = switch ($encrypted) { 'true' { $true } 'false' { $false } default { $null } }
    }
}

$random = New-Object System.Random $Seed
$now = [DateTimeOffset]::UtcNow
$managed = @(for ($i = 1; $i -le $DeviceCount; $i++) { New-DemoManagedDevice -Random $random -Index $i -Now $now })

# Edge cases on fixed devices so they are easy to find in the report.
$managed[0].deviceName = '</script><img src=x onerror=alert(1)>'
if ($DeviceCount -ge 2) { $managed[1].deviceName = 'ORG-LT-' + [string][char]0x00C5 + 'S' + [string][char]0x00D8 + '-M' + [string][char]0x00DC + 'LLER' }
if ($DeviceCount -ge 3) { $managed[2].deviceName = 'ORG-LT-THIS-IS-A-VERY-LONG-DEVICE-NAME-THAT-SHOULD-TRUNCATE-OR-WRAP-0003' }
# Spreadsheet formula look-alikes, to exercise the CSV formula-injection guard.
if ($DeviceCount -ge 5) { $managed[3].deviceName = '=1+2-FORMULA'; $managed[4].deviceName = '@SUM(1,1)' }

# Duplicate Intune records for one Entra device (re-enrollment) and devices
# with no Entra device id, to exercise rollout de-duplication and skips.
for ($i = 10; $i -lt $DeviceCount; $i += 97) { $managed[$i].azureADDeviceId = $managed[$i - 1].azureADDeviceId }
for ($i = 25; $i -lt $DeviceCount; $i += 211) { $managed[$i].azureADDeviceId = '' }

$devices = @(foreach ($item in $managed) { ConvertTo-EndpointDevice -ManagedDevice $item -ReferenceTime $now -ActiveWithinDays 30 })
# Entra objects keyed by deviceId, as the real pull resolves them. About 1% of
# devices have no Entra object (deleted or never registered).
$entraByDeviceId = @{}
for ($d = 0; $d -lt $devices.Count; $d++) {
    $key = ConvertTo-EndpointEntraKey $devices[$d].azureADDeviceId
    if (-not $key) { continue }
    if (-not $entraByDeviceId.ContainsKey($key)) {
        $signIn = ConvertTo-EndpointTimestamp $devices[$d].lastCheckIn
        $entraByDeviceId[$key] = if ($random.NextDouble() -lt 0.01) { $null } else {
            [pscustomobject]@{
                Id = Get-DemoGuid -Prefix 'cccccccc' -Index ($d + 1)
                ApproxLastSignIn = if ($signIn -eq [DateTimeOffset]::MinValue) { '' } else { Format-EndpointTimestamp $signIn.AddDays(-$random.Next(0, 14)) }
            }
        }
    }
    if ($null -ne $entraByDeviceId[$key]) {
        $devices[$d].entraObjectId = $entraByDeviceId[$key].Id
        $devices[$d].entraApproxLastSignIn = $entraByDeviceId[$key].ApproxLastSignIn
    }
}

# Assign apps per device, then derive Intune-style per-record device counts.
$records = New-Object 'System.Collections.Generic.List[object]'
$recordIndex = @{}
$catalog = Get-DemoAppCatalog
foreach ($app in $catalog) {
    foreach ($version in $app.Versions) {
        $recordIndex["$($app.Name)|$version"] = $records.Count
        $records.Add([pscustomobject][ordered]@{
                id = 'demo-app-{0:d4}' -f $records.Count
                name = $app.Name; version = $version; publisher = $app.Publisher; platform = 'windows'
                deviceCount = 0; sizeInByte = [long]$random.Next(0, 500) * 1048576
            })
    }
}
$map = @{}
for ($d = 0; $d -lt $devices.Count; $d++) {
    $indexes = New-Object 'System.Collections.Generic.List[int]'
    foreach ($app in $catalog) {
        if ($app.Manufacturer -and $managed[$d].manufacturer -ne $app.Manufacturer) { continue }
        if ($random.NextDouble() -ge $app.Share) { continue }
        # Earlier (newer) versions are progressively more common.
        $choices = @(for ($v = 0; $v -lt $app.Versions.Count; $v++) { , @($app.Versions[$v], [Math]::Pow(0.45, $v)) })
        $version = Get-DemoWeightedItem -Random $random -Choices $choices
        $index = $recordIndex["$($app.Name)|$version"]
        $indexes.Add($index)
        $records[$index].deviceCount++
    }
    $map[$devices[$d].intuneDeviceId] = $indexes
    if (-not $WithoutDeviceApps) { $devices[$d].appRecordIndexes = @($indexes.ToArray() | Sort-Object) }
}
# Drop unused records and re-index so device references stay valid.
$remap = @{}
$kept = New-Object 'System.Collections.Generic.List[object]'
for ($i = 0; $i -lt $records.Count; $i++) {
    if ($records[$i].deviceCount -gt 0) { $remap[$i] = $kept.Count; $kept.Add($records[$i]) }
}
$appRecords = $kept.ToArray()
if ($appRecords.Count -ne $records.Count) {
    foreach ($device in $devices) { $device.appRecordIndexes = @($device.appRecordIndexes | ForEach-Object { $remap[[int]$_] }) }
    foreach ($key in @($map.Keys)) {
        $list = New-Object 'System.Collections.Generic.List[int]'
        foreach ($old in $map[$key]) { $list.Add($remap[$old]) }
        $map[$key] = $list
    }
}
$summaryMap = if ($WithoutDeviceApps) { $null } else { $map }

$snapshot = [pscustomobject][ordered]@{
    schemaVersion = $script:EndpointSchemaVersion
    generatedAt = Format-EndpointTimestamp $now
    scopes = @($script:EndpointRequiredScopes)
    source = [pscustomobject][ordered]@{ windowsOnly = $true; includeDeviceApps = (-not $WithoutDeviceApps); graphCalls = 0; batchSubrequests = 0 }
    thresholds = [pscustomobject][ordered]@{ activeWithinDays = 30; recentDays = $script:EndpointRecentDays }
    devices = @($devices)
    apps = @(ConvertTo-EndpointAppSummary -AppRecords $appRecords -DeviceAppMap $summaryMap)
    appRecords = @($appRecords)
    warnings = @("DEMO DATA generated by New-EndpointDemoReport.ps1 (seed $Seed, $DeviceCount devices). Not from a tenant.")
}
$problems = @(Test-EndpointSnapshot -Snapshot $snapshot)
if ($problems.Count -gt 0) { throw "Generated demo snapshot is invalid: $($problems -join ' ')" }

$directory = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$jsonPath = Join-Path $directory 'EndpointInventory.json'
$htmlPath = Join-Path $directory 'EndpointInventory.html'
$utf8 = New-Object System.Text.UTF8Encoding $false
foreach ($target in @(@($jsonPath, 'Write demo snapshot'), @($htmlPath, 'Write demo HTML report'))) {
    if (-not $PSCmdlet.ShouldProcess($target[0], $target[1])) { continue }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
    $content = if ($target[0] -eq $jsonPath) { ConvertTo-Json -InputObject $snapshot -Depth 10 -Compress } else { ConvertTo-EndpointHtml -Snapshot $snapshot }
    [System.IO.File]::WriteAllText($target[0], $content, $utf8)
    Write-Information "Wrote: $($target[0])" -InformationAction Continue
}
Write-Information ('Demo: {0} devices, {1} distinct apps, {2} app records, per-device apps: {3}.' -f $devices.Count, @($snapshot.apps).Count, $appRecords.Count, (-not $WithoutDeviceApps)) -InformationAction Continue
if ($PassThru) { return $snapshot }
