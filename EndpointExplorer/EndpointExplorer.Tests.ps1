#requires -Version 5.1
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
Offline Pester tests for EndpointExplorer.

Only the HTTP transport (Send-EndpointGraphRequest), sign-in
(Connect-EndpointGraph), and Start-Sleep are mocked. Requests are served from
an in-memory fake tenant; paging, batching, retry, the read-only boundary,
classification, caching, ShouldProcess, and rendering are the real code.
No network, no credentials, no tenant.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'EndpointExplorer.Common.ps1')
    $script:wrapperPath = Join-Path $PSScriptRoot 'Export-EndpointInventory.ps1'
    $script:fake = $null

    function Initialize-FakeTenant {
        $now = [DateTimeOffset]::UtcNow
        $tenant = @{
            Calls = New-Object 'System.Collections.Generic.List[object]'
            StatusQueue = New-Object 'System.Collections.Generic.Queue[int]'
            Connects = 0
            FilterMode = 'ok'
            PageSize = 2
            Devices = @(
                @{ id = 'dev-1'; deviceName = 'WIN-001'; userPrincipalName = 'user1@example.test'; lastSyncDateTime = $now.AddDays(-1).ToString('o'); managementAgent = 'configurationManagerClientMdm'; deviceEnrollmentType = 'windowsAzureADJoin'; operatingSystem = 'Windows'; osVersion = '10.0.26100.2033'; complianceState = 'compliant'; model = 'Model A'; manufacturer = 'Contoso'; serialNumber = 'SN001'; azureADDeviceId = '11111111-1111-1111-1111-111111111111'; enrolledDateTime = '2025-01-01T00:00:00Z'; managedDeviceOwnerType = 'company'; deviceCategoryDisplayName = 'Laptop'; isEncrypted = $true }
                @{ id = 'dev-2'; deviceName = 'WIN-002'; userPrincipalName = 'user2@example.test'; lastSyncDateTime = $now.AddDays(-10).ToString('o'); managementAgent = 'mdm'; deviceEnrollmentType = 'windowsAzureADJoin'; operatingSystem = 'Windows'; osVersion = '10.0.22631.4317'; complianceState = 'noncompliant'; model = 'Model B'; manufacturer = 'Contoso'; serialNumber = 'SN002'; azureADDeviceId = '22222222-2222-2222-2222-222222222222'; enrolledDateTime = '2025-01-02T00:00:00Z'; managedDeviceOwnerType = 'company'; deviceCategoryDisplayName = ''; isEncrypted = $false }
                @{ id = 'dev-3'; deviceName = 'WIN-003'; userPrincipalName = ''; lastSyncDateTime = $now.AddDays(-45).ToString('o'); managementAgent = 'configurationManagerClient'; deviceEnrollmentType = 'unknown'; operatingSystem = 'Windows'; osVersion = '10.0.26100.2033'; complianceState = 'unknown'; model = 'Model A'; manufacturer = 'Contoso'; serialNumber = 'SN003'; azureADDeviceId = '33333333-3333-3333-3333-333333333333'; enrolledDateTime = '2025-01-03T00:00:00Z'; managedDeviceOwnerType = 'company'; deviceCategoryDisplayName = ''; isEncrypted = $null }
                @{ id = 'dev-4'; deviceName = '</script><script>alert(1)</script>'; userPrincipalName = 'user4@example.test'; lastSyncDateTime = '0001-01-01T00:00:00Z'; managementAgent = 'mdm'; deviceEnrollmentType = 'windowsCoManagement'; operatingSystem = 'Windows'; osVersion = '10.0.26100.2033'; complianceState = 'compliant'; model = 'Model C'; manufacturer = 'Fabrikam'; serialNumber = 'SN004'; azureADDeviceId = '44444444-4444-4444-4444-444444444444'; enrolledDateTime = '2025-01-04T00:00:00Z'; managedDeviceOwnerType = 'personal'; deviceCategoryDisplayName = ''; isEncrypted = $true }
                @{ id = 'dev-5'; deviceName = 'MAC-001'; userPrincipalName = 'user5@example.test'; lastSyncDateTime = $now.AddDays(-2).ToString('o'); managementAgent = 'mdm'; deviceEnrollmentType = 'userEnrollment'; operatingSystem = 'macOS'; osVersion = '15.1'; complianceState = 'compliant'; model = 'MacBook'; manufacturer = 'Apple'; serialNumber = 'SN005'; azureADDeviceId = '55555555-5555-5555-5555-555555555555'; enrolledDateTime = '2025-01-05T00:00:00Z'; managedDeviceOwnerType = 'company'; deviceCategoryDisplayName = ''; isEncrypted = $true }
            )
            Apps = @(
                @{ id = 'app-7z-23'; displayName = '7-Zip'; version = '23.01'; publisher = 'Igor Pavlov'; platform = 'windows'; deviceCount = 2; sizeInByte = 100 }
                @{ id = 'app-7z-19'; displayName = '7-Zip'; version = '19.00'; publisher = 'Igor Pavlov'; platform = 'windows'; deviceCount = 1; sizeInByte = 100 }
                @{ id = 'app-chrome'; displayName = 'Google Chrome'; version = '130.0'; publisher = 'Google'; platform = 'windows'; deviceCount = 3; sizeInByte = 0 }
                @{ id = 'app-gone'; displayName = 'Gone App'; version = '1.0'; publisher = 'Nobody'; platform = 'windows'; deviceCount = 1; sizeInByte = 0 }
                @{ id = 'app-mac'; displayName = 'Safari'; version = '18.0'; publisher = 'Apple'; platform = 'macOS'; deviceCount = 1; sizeInByte = 0 }
                @{ id = 'app-ghost'; displayName = 'Ghost Tool'; version = '2.0'; publisher = 'Ghost'; platform = 'windows'; deviceCount = 1; sizeInByte = 0 }
            )
            EntraDevices = @(
                @{ id = 'obj-1'; deviceId = '11111111-1111-1111-1111-111111111111'; operatingSystem = 'Windows'; approximateLastSignInDateTime = $now.AddDays(-3).ToString('o') }
                @{ id = 'obj-2'; deviceId = '22222222-2222-2222-2222-222222222222'.ToUpperInvariant(); operatingSystem = 'Windows'; approximateLastSignInDateTime = $null }
                @{ id = 'obj-4'; deviceId = '44444444-4444-4444-4444-444444444444'; operatingSystem = 'Windows'; approximateLastSignInDateTime = $now.AddDays(-1).ToString('o') }
                @{ id = 'obj-5'; deviceId = '55555555-5555-5555-5555-555555555555'; operatingSystem = 'MacMDM'; approximateLastSignInDateTime = $now.AddDays(-1).ToString('o') }
                @{ id = 'obj-other'; deviceId = '99999999-9999-9999-9999-999999999999'; operatingSystem = 'iOS'; approximateLastSignInDateTime = $null }
            )
            EntraFilterMode = 'ok'
            BatchFirstStatus = 0
            ThrottledApps = @()
            ExportStatuses = New-Object 'System.Collections.Generic.Queue[string]'
            AppDevices = @{
                'app-7z-23' = @('dev-1', 'dev-2'); 'app-7z-19' = @('dev-2'); 'app-chrome' = @('dev-1', 'dev-2', 'dev-3')
                'app-mac' = @('dev-5'); 'app-ghost' = @('dev-unknown')
            }
        }
        return $tenant
    }

    function Get-FakePage {
        param([string] $Uri, [object[]] $Items, [int] $PageSize)
        $skip = 0
        if ($Uri -match '&skip=(\d+)') { $skip = [int]$Matches[1] }
        $page = @{ value = @($Items | Select-Object -Skip $skip -First $PageSize) }
        if ($skip + $PageSize -lt $Items.Count) { $page['@odata.nextLink'] = ($Uri -replace '&skip=\d+', '') + "&skip=$($skip + $PageSize)" }
        return $page
    }

    function Invoke-FakeGraph {
        param([string] $Method, [string] $Uri, [string] $BodyJson)
        $tenant = $script:fake
        $body = if ($BodyJson) { $BodyJson | ConvertFrom-Json } else { $null }
        $tenant.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $body })
        if ($tenant.StatusQueue.Count -gt 0) {
            $queued = $tenant.StatusQueue.Dequeue()
            if ($queued -ne 200) { return [pscustomobject]@{ StatusCode = $queued; RetryAfter = 7; Content = '{"error":{"code":"Injected"}}' } }
        }
        $content = $null
        if ($Method -eq 'Get' -and $Uri -match '/v1\.0/deviceManagement/detectedApps/([^/?]+)/managedDevices\?') {
            $ids = @($tenant.AppDevices[[uri]::UnescapeDataString($Matches[1])])
            $content = Get-FakePage -Uri $Uri -Items @($ids | ForEach-Object { @{ id = $_ } }) -PageSize $tenant.PageSize
        }
        elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/deviceManagement/detectedApps\?') {
            if ($Uri -notmatch '\$select=') { throw "detectedApps read without `$select: $Uri" }
            $content = Get-FakePage -Uri $Uri -Items $tenant.Apps -PageSize $tenant.PageSize
        }
        elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/deviceManagement/managedDevices\?') {
            if ($Uri -notmatch '\$select=' -or $Uri -notmatch '\$top=1000') { throw "managedDevices read without `$select/`$top: $Uri" }
            $items = $tenant.Devices
            if ($Uri -match '\$filter=') {
                if ($tenant.FilterMode -eq '400') { return [pscustomobject]@{ StatusCode = 400; RetryAfter = 0; Content = '{"error":{"code":"BadRequest"}}' } }
                $items = @(if ($tenant.FilterMode -ne 'empty') { $items | Where-Object { $_.operatingSystem -eq 'Windows' } })
            }
            $content = Get-FakePage -Uri $Uri -Items $items -PageSize $tenant.PageSize
        }
        elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/devices\?') {
            if ($Uri -notmatch '\$select=id,deviceId,approximateLastSignInDateTime' -or $Uri -notmatch '\$top=999') { throw "devices read without `$select/`$top: $Uri" }
            $items = $tenant.EntraDevices
            if ($Uri -match '\$filter=') {
                if ($tenant.EntraFilterMode -eq '400') { return [pscustomobject]@{ StatusCode = 400; RetryAfter = 0; Content = '{"error":{"code":"BadRequest"}}' } }
                $items = @($items | Where-Object { $_.operatingSystem -eq 'Windows' })
            }
            $content = Get-FakePage -Uri $Uri -Items $items -PageSize $tenant.PageSize
        }
        elseif ($Method -eq 'Post' -and $Uri.EndsWith('/$batch')) {
            $firstStatus = $tenant.BatchFirstStatus
            $tenant.BatchFirstStatus = 0
            $first = $true
            $responses = @(foreach ($request in $body.requests) {
                    if ($firstStatus -and $first) {
                        $first = $false
                        @{ id = $request.id; status = $firstStatus; headers = @{ 'Retry-After' = '3' }; body = @{} }
                        continue
                    }
                    if ([string]$request.url -notmatch '^/deviceManagement/detectedApps/([^/?]+)/managedDevices\?\$select=id$') { throw "Unexpected batch url $($request.url)" }
                    $appId = [uri]::UnescapeDataString($Matches[1])
                    if ($tenant.ThrottledApps -contains $appId) { @{ id = $request.id; status = 429; headers = @{ 'Retry-After' = '2' }; body = @{} }; continue }
                    if (-not $tenant.AppDevices.ContainsKey($appId)) { @{ id = $request.id; status = 404; body = @{ error = @{ code = 'NotFound' } } }; continue }
                    $pageUri = "https://graph.microsoft.com/v1.0/deviceManagement/detectedApps/$appId/managedDevices?`$select=id"
                    $page = Get-FakePage -Uri $pageUri -Items @($tenant.AppDevices[$appId] | ForEach-Object { @{ id = $_ } }) -PageSize $tenant.PageSize
                    @{ id = $request.id; status = 200; body = $page }
                })
            $content = @{ responses = $responses }
        }
        elseif ($Method -eq 'Post' -and $Uri -match '/v1\.0/deviceManagement/reports/exportJobs$') {
            return [pscustomobject]@{ StatusCode = 201; RetryAfter = 0; Content = (@{ id = 'AppInvRawData_0a1b-2c3d'; reportName = $body.reportName; status = 'notStarted' } | ConvertTo-Json -Compress) }
        }
        elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/deviceManagement/reports/exportJobs/(AppInvRawData_[^/?]+)$') {
            $status = if ($tenant.ExportStatuses.Count -gt 0) { $tenant.ExportStatuses.Dequeue() } else { 'completed' }
            $content = @{ id = $Matches[1]; status = $status; url = $(if ($status -eq 'completed') { 'https://fakeacct.blob.core.windows.net/c/AppInvRawData.zip?sig=redacted' } else { $null }) }
        }
        else { throw "Unexpected Graph request $Method $Uri" }
        return [pscustomobject]@{ StatusCode = 200; RetryAfter = 0; Content = ($content | ConvertTo-Json -Depth 20 -Compress) }
    }

    Mock Send-EndpointGraphRequest { Invoke-FakeGraph -Method $Method -Uri $Uri -BodyJson $BodyJson }
    Mock Connect-EndpointGraph { $script:fake.Connects++; [pscustomobject]@{ Mode = 'MgGraph'; Token = $null; Account = 'offline@example.test' } }
    Mock Start-Sleep { }

    function Get-GraphCallCount { return $script:fake.Calls.Count }
}

Describe 'Read-only Graph boundary' {
    BeforeEach { $script:fake = Initialize-FakeTenant }

    It 'allows <Uri>' -ForEach @(
        @{ Uri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id&$top=1000' }
        @{ Uri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices' }
        @{ Uri = 'https://graph.microsoft.com/v1.0/deviceManagement/detectedApps?$select=id' }
        @{ Uri = 'https://graph.microsoft.com/v1.0/deviceManagement/detectedApps/abc123/managedDevices?$select=id&$skiptoken=x' }
        @{ Uri = 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,approximateLastSignInDateTime&$top=999' }
    ) {
        { Assert-EndpointReadRequest -Method Get -Uri $Uri -Body $null } | Should -Not -Throw
    }

    It 'rejects <Method> <Uri> before HTTP' -ForEach @(
        @{ Method = 'Patch'; Uri = '/deviceManagement/managedDevices/dev-1' }
        @{ Method = 'Put'; Uri = '/deviceManagement/managedDevices/dev-1' }
        @{ Method = 'Delete'; Uri = '/deviceManagement/managedDevices/dev-1' }
        @{ Method = 'Post'; Uri = '/deviceManagement/managedDevices' }
        @{ Method = 'Post'; Uri = '/deviceManagement/managedDevices/dev-1/wipe' }
        @{ Method = 'Post'; Uri = '/deviceManagement/managedDevices/dev-1/syncDevice' }
        @{ Method = 'Post'; Uri = '/deviceManagement/reports/exportJobs' }
        @{ Method = 'Get'; Uri = '/deviceManagement/reports/exportJobs' }
        @{ Method = 'Get'; Uri = '/deviceManagement/managedDevices/dev-1' }
        @{ Method = 'Get'; Uri = '/deviceManagement/detectedApps/../managedDevices' }
        @{ Method = 'Get'; Uri = '/groups/abc/members' }
        @{ Method = 'Patch'; Uri = '/devices/obj-1' }
        @{ Method = 'Delete'; Uri = '/devices/obj-1' }
        @{ Method = 'Get'; Uri = '/devices/obj-1/registeredOwners' }
        @{ Method = 'Post'; Uri = '/groups/abc/members/$ref' }
        @{ Method = 'Get'; Uri = 'https://graph.microsoft.com/beta/deviceManagement/detectedApps' }
        @{ Method = 'Get'; Uri = 'https://evil.example.test/v1.0/deviceManagement/managedDevices' }
    ) {
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'MgGraph' }
        { Invoke-EndpointGraph -Method $Method -Uri $Uri } | Should -Throw '*Read-only Graph boundary rejected*'
        Should -Invoke Send-EndpointGraphRequest -Times 0 -Exactly
    }

    It 'rejects a batch subrequest that is <Case>' -ForEach @(
        @{ Case = 'a POST'; Requests = @(@{ id = '0'; method = 'POST'; url = '/deviceManagement/detectedApps/a/managedDevices?$select=id' }) }
        @{ Case = 'a DELETE'; Requests = @(@{ id = '0'; method = 'DELETE'; url = '/deviceManagement/detectedApps/a/managedDevices?$select=id' }) }
        @{ Case = 'a GET with a body'; Requests = @(@{ id = '0'; method = 'GET'; url = '/deviceManagement/detectedApps/a/managedDevices?$select=id'; body = @{} }) }
        @{ Case = 'another resource'; Requests = @(@{ id = '0'; method = 'GET'; url = '/deviceManagement/managedDevices/dev-1' }) }
        @{ Case = 'an export job'; Requests = @(@{ id = '0'; method = 'GET'; url = '/deviceManagement/reports/exportJobs' }) }
    ) {
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'MgGraph' }
        { Invoke-EndpointGraph -Method Post -Uri '/$batch' -Body @{ requests = $Requests } } | Should -Throw '*rejected batch request*'
        Should -Invoke Send-EndpointGraphRequest -Times 0 -Exactly
    }

    It 'rejects empty and oversized batches' {
        $one = @{ id = '0'; method = 'GET'; url = '/deviceManagement/detectedApps/a/managedDevices?$select=id' }
        { Assert-EndpointReadRequest -Method Post -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body @{ requests = @() } } | Should -Throw '*1 to 20*'
        $many = @(for ($i = 0; $i -lt 21; $i++) { $one })
        { Assert-EndpointReadRequest -Method Post -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body @{ requests = $many } } | Should -Throw '*1 to 20*'
    }
}

Describe 'Classification' {
    It 'maps agent <Agent> / enrollment <Enrollment> to <Expected>' -ForEach @(
        @{ Agent = 'configurationManagerClientMdm'; Enrollment = 'windowsAzureADJoin'; Expected = 'Co-managed' }
        @{ Agent = 'configurationManagerClientMdmEas'; Enrollment = ''; Expected = 'Co-managed' }
        @{ Agent = 'mdm'; Enrollment = 'windowsCoManagement'; Expected = 'Co-managed' }
        @{ Agent = 'configurationManagerClient'; Enrollment = 'windowsCoManagement'; Expected = 'Co-managed' }
        @{ Agent = 'mdm'; Enrollment = 'windowsAzureADJoin'; Expected = 'Intune MDM' }
        @{ Agent = 'configurationManagerClient'; Enrollment = 'unknown'; Expected = 'ConfigMgr only' }
        @{ Agent = 'eas'; Enrollment = ''; Expected = 'EAS / legacy client' }
        @{ Agent = 'easMdm'; Enrollment = ''; Expected = 'EAS / legacy client' }
        @{ Agent = 'intuneClient'; Enrollment = ''; Expected = 'EAS / legacy client' }
        @{ Agent = 'easIntuneClient'; Enrollment = ''; Expected = 'EAS / legacy client' }
        @{ Agent = 'unknown'; Enrollment = ''; Expected = 'Other / Unknown' }
        @{ Agent = 'msSense'; Enrollment = ''; Expected = 'Other / Unknown' }
        @{ Agent = ''; Enrollment = ''; Expected = 'Other / Unknown' }
    ) {
        Get-EndpointManagementType -ManagementAgent $Agent -EnrollmentType $Enrollment | Should -Be $Expected
    }

    It 'buckets a check-in <AgeDays> days old (threshold <Threshold>) as <State>/<Bucket>' -ForEach @(
        @{ AgeDays = 0; Threshold = 30; State = 'Active'; Bucket = 'Recent' }
        @{ AgeDays = 7; Threshold = 30; State = 'Active'; Bucket = 'Recent' }
        @{ AgeDays = 8; Threshold = 30; State = 'Active'; Bucket = 'Aging' }
        @{ AgeDays = 30; Threshold = 30; State = 'Active'; Bucket = 'Aging' }
        @{ AgeDays = 31; Threshold = 30; State = 'Stale'; Bucket = 'Stale' }
        @{ AgeDays = 5; Threshold = 3; State = 'Stale'; Bucket = 'Stale' }
        @{ AgeDays = 400; Threshold = 0; State = 'Active'; Bucket = 'Aging' }
        @{ AgeDays = -1; Threshold = 30; State = 'Never'; Bucket = 'Never' }
    ) {
        $reference = [DateTimeOffset]'2026-10-13T12:00:00Z'
        $lastCheckIn = if ($AgeDays -lt 0) { [DateTimeOffset]::MinValue } else { $reference.AddDays(-$AgeDays) }
        $result = Get-EndpointActivity -LastCheckIn $lastCheckIn -ReferenceTime $reference -ActiveWithinDays $Threshold
        $result.State | Should -Be $State
        $result.Bucket | Should -Be $Bucket
    }

    It 'treats a year-1 timestamp as never' {
        ConvertTo-EndpointTimestamp '0001-01-01T00:00:00Z' | Should -Be ([DateTimeOffset]::MinValue)
        ConvertTo-EndpointTimestamp $null | Should -Be ([DateTimeOffset]::MinValue)
    }
}

Describe 'Fleet app aggregation' {
    BeforeAll {
        $script:records = @(
            [pscustomobject]@{ id = 'a'; name = '7-Zip'; version = '19.00'; publisher = 'Igor Pavlov'; platform = 'windows'; deviceCount = 1; sizeInByte = 0 }
            [pscustomobject]@{ id = 'b'; name = '7-Zip'; version = '23.01'; publisher = 'Igor Pavlov'; platform = 'windows'; deviceCount = 2; sizeInByte = 0 }
            [pscustomobject]@{ id = 'c'; name = 'Chrome'; version = '130.0'; publisher = 'Google'; platform = 'windows'; deviceCount = 5; sizeInByte = 0 }
        )
    }

    It 'groups versions newest first and sums Intune counts when no device map exists' {
        $apps = @(ConvertTo-EndpointAppSummary -AppRecords $script:records)
        $apps.Count | Should -Be 2
        $apps[0].name | Should -Be 'Chrome'
        $zip = $apps | Where-Object name -EQ '7-Zip'
        $zip.versions | Should -Be @('23.01', '19.00')
        $zip.deviceCount | Should -Be 3
        $zip.isInstalledVersionApprox | Should -BeTrue
        $zip.recordIndexes | Should -Be @(1, 0)
    }

    It 'counts distinct devices when a device map exists' {
        $list1 = New-Object 'System.Collections.Generic.List[int]'; $list1.Add(0); $list1.Add(1)
        $list2 = New-Object 'System.Collections.Generic.List[int]'; $list2.Add(1)
        $apps = @(ConvertTo-EndpointAppSummary -AppRecords $script:records -DeviceAppMap @{ 'dev-1' = $list1; 'dev-2' = $list2 })
        $zip = $apps | Where-Object name -EQ '7-Zip'
        $zip.deviceCount | Should -Be 2
        $zip.isInstalledVersionApprox | Should -BeFalse
        ($apps | Where-Object name -EQ 'Chrome').deviceCount | Should -Be 0
    }

    It 'filters app records to Windows unless all platforms are requested' {
        $script:fake = Initialize-FakeTenant
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'MgGraph' }
        @(Get-EndpointDetectedApp -WindowsOnly).platform | Should -Not -Contain 'macOS'
        @(Get-EndpointDetectedApp).platform | Should -Contain 'macOS'
    }
}

Describe 'Per-device app resolution via $batch' {
    BeforeEach {
        $script:fake = Initialize-FakeTenant
        Initialize-EndpointGraphState
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'MgGraph' }
    }

    It 'maps devices, follows nextLink, tolerates 404, ignores out-of-scope devices, and honors batch Retry-After' {
        $script:fake.BatchFirstStatus = 429
        $records = @(Get-EndpointDetectedApp -WindowsOnly)
        $result = Get-EndpointDeviceAppMap -AppRecords $records -DeviceIds @('dev-1', 'dev-2', 'dev-3', 'dev-4')
        $chrome = [array]::IndexOf(@($records.id), 'app-chrome')
        @($result.Map['dev-3']) | Should -Be @($chrome)
        $result.Map['dev-2'].Count | Should -Be 3
        $result.Map.ContainsKey('dev-4') | Should -BeFalse
        $result.MissingApps | Should -Be 1
        $result.OutOfScopeDevices | Should -Be 1
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 3 }
        @($script:fake.Calls | Where-Object { $_.Method -eq 'Get' -and $_.Uri -match 'app-chrome/managedDevices.*skip=2' }).Count | Should -Be 1
        foreach ($call in @($script:fake.Calls | Where-Object { $_.Method -eq 'Post' })) {
            @($call.Body.requests).Count | Should -BeLessOrEqual 20
        }
    }

    It 'refreshes a managed-identity token on a batched 401 without sleeping' {
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'ManagedIdentity' }
        Mock Connect-EndpointGraph { $script:fake.Connects++; [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = 'new'; Account = 'mi' } }
        $script:fake.BatchFirstStatus = 401
        $records = @(Get-EndpointDetectedApp -WindowsOnly)
        $null = Get-EndpointDeviceAppMap -AppRecords $records -DeviceIds @('dev-1', 'dev-2')
        $script:fake.Connects | Should -Be 1
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'splits more than 20 app records into several batches' {
        $records = @(for ($i = 0; $i -lt 45; $i++) { [pscustomobject]@{ id = "app-7z-23"; name = "App $i" } })
        $null = Get-EndpointDeviceAppMap -AppRecords $records -DeviceIds @('dev-1')
        @($script:fake.Calls | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 3
        $script:EndpointGraphState.BatchSubrequestCount | Should -Be 45
    }
}

Describe 'Retry' {
    BeforeEach {
        $script:fake = Initialize-FakeTenant
        Initialize-EndpointGraphState
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'MgGraph' }
    }

    It 'waits exactly Retry-After and then succeeds' {
        $script:fake.StatusQueue.Enqueue(429)
        $null = Invoke-EndpointGraph -Method Get -Uri '/deviceManagement/detectedApps?$select=id'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
        $script:fake.Calls.Count | Should -Be 2
    }

    It 'never shortens a long Retry-After' {
        Get-EndpointRetryDelay -Attempt 1 -RetryAfter 120 | Should -Be 120
        Get-EndpointRetryDelay -Attempt 4 -RetryAfter 0 | Should -BeLessOrEqual 60
    }

    It 'gives up after a bounded number of attempts' {
        for ($i = 0; $i -lt 10; $i++) { $script:fake.StatusQueue.Enqueue(429) }
        { Invoke-EndpointGraph -Method Get -Uri '/deviceManagement/detectedApps?$select=id' } | Should -Throw '*HTTP 429*'
        $script:fake.Calls.Count | Should -Be $script:EndpointMaxGraphAttempts
        Should -Invoke Start-Sleep -Times ($script:EndpointMaxGraphAttempts - 1) -Exactly
    }

    It 'reports a missing Invoke-MgGraphRequest response clearly' {
        # The real transport (Send-EndpointGraphRequest is mocked elsewhere).
        $send = Get-Command -Name Send-EndpointGraphRequest -CommandType Function
        function Invoke-MgGraphRequest { }
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'MgGraph' }
        { & $send -Method Get -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/detectedApps' } | Should -Throw '*returned no response*'
    }

    It 'does not retry a 403' {
        $script:fake.StatusQueue.Enqueue(403)
        { Invoke-EndpointGraph -Method Get -Uri '/deviceManagement/detectedApps?$select=id' } | Should -Throw '*HTTP 403*'
        $script:fake.Calls.Count | Should -Be 1
    }
}

Describe 'Invoke-EndpointInventory' {
    BeforeEach {
        $script:fake = Initialize-FakeTenant
        $script:out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:jsonPath = Join-Path $script:out 'EndpointInventory.json'
        $script:htmlPath = Join-Path $script:out 'EndpointInventory.html'
    }

    Context 'WhatIf' {
        It 'reads Graph, reports counts, and writes zero files' {
            $output = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps -ExportCsv -WhatIf -PassThru 6>&1
            Test-Path -LiteralPath $script:out | Should -BeFalse
            Get-GraphCallCount | Should -BeGreaterThan 0
            @($script:fake.Calls | Where-Object { $_.Method -notin @('Get', 'Post') }).Count | Should -Be 0
            $snapshot = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
            @($snapshot.devices).Count | Should -Be 4
            $messages = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            ($messages -join "`n") | Should -Match 'Devices: 4 \(Active 2, Stale 1, Never 1\); Co-managed 2, Intune MDM 1, ConfigMgr only 1'
            ($messages -join "`n") | Should -Match 'No files written'
        }
    }

    Context 'Pull and render' {
        It 'writes the snapshot and HTML with Windows devices only and correct classification' {
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru 6>$null
            Test-Path -LiteralPath $script:jsonPath | Should -BeTrue
            Test-Path -LiteralPath $script:htmlPath | Should -BeTrue
            @($snapshot.devices).Count | Should -Be 4
            @($snapshot.devices).operatingSystem | Should -Not -Contain 'macOS'
            ($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-4').managementType | Should -Be 'Co-managed'
            ($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-4').activityState | Should -Be 'Never'
            ($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-3').activityState | Should -Be 'Stale'
            $snapshot.source.includeDeviceApps | Should -BeFalse
            @($snapshot.apps).name | Should -Not -Contain 'Safari'
            @($snapshot.devices | ForEach-Object { @($_.appRecordIndexes).Count } | Measure-Object -Sum).Sum | Should -Be 0
            @($script:fake.Calls | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 0
            $script:fake.Connects | Should -Be 1
        }

        It 'maps Entra object IDs by canonical deviceId and warns about devices without one' {
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru 6>$null
            $byId = @{}; foreach ($d in $snapshot.devices) { $byId[$d.intuneDeviceId] = $d }
            $byId['dev-1'].entraObjectId | Should -Be 'obj-1'
            $byId['dev-1'].entraApproxLastSignIn | Should -Not -BeNullOrEmpty
            $byId['dev-2'].entraObjectId | Should -Be 'obj-2'
            $byId['dev-2'].entraApproxLastSignIn | Should -Be ''
            $byId['dev-3'].entraObjectId | Should -Be ''
            @($snapshot.warnings) -join ' ' | Should -Match '1 device\(s\) have no matching Entra device object'
            # dev-3 is missing from the Windows-filtered list, so one full listing follows.
            @($script:fake.Calls | Where-Object { $_.Uri -match '/v1\.0/devices\?.*\$filter=' }).Count | Should -BeGreaterThan 0
            @($script:fake.Calls | Where-Object { $_.Uri -match '/v1\.0/devices\?' -and $_.Uri -notmatch '\$filter=' }).Count | Should -BeGreaterThan 0
        }

        It 'uses only the Windows-filtered Entra list when every device is in it' {
            $script:fake.EntraDevices += @{ id = 'obj-3'; deviceId = '33333333-3333-3333-3333-333333333333'; operatingSystem = 'Windows'; approximateLastSignInDateTime = $null }
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru 6>$null
            ($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-3').entraObjectId | Should -Be 'obj-3'
            @($script:fake.Calls | Where-Object { $_.Uri -match '/v1\.0/devices\?' -and $_.Uri -notmatch '\$filter=' }).Count | Should -Be 0
        }

        It 'falls back to the full Entra list when the Windows filter is rejected' {
            $script:fake.EntraFilterMode = '400'
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru 6>$null
            ($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-1').entraObjectId | Should -Be 'obj-1'
        }

        It 'treats a deviceId listed on two Entra objects as ambiguous' {
            $script:fake.EntraDevices += @{ id = 'obj-dup'; deviceId = '11111111-1111-1111-1111-111111111111'; operatingSystem = 'Windows'; approximateLastSignInDateTime = $null }
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru 6>$null
            ($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-1').entraObjectId | Should -Be ''
            @($snapshot.warnings) -join ' ' | Should -Match 'more than one Entra device object'
        }

        It 'round-trips the snapshot through the validator' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps 6>$null
            $loaded = Import-EndpointSnapshot -Path $script:jsonPath -ActiveWithinDays 30
            @(Test-EndpointSnapshot -Snapshot $loaded).Count | Should -Be 0
            @($loaded.devices).Count | Should -Be 4
            ($loaded.devices | Where-Object intuneDeviceId -EQ 'dev-2').appRecordIndexes.Count | Should -Be 3
        }

        It 'falls back to a full listing when the Windows filter is rejected' {
            $script:fake.FilterMode = '400'
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru -WarningVariable warned -WarningAction SilentlyContinue 6>$null
            @($snapshot.devices).Count | Should -Be 4
            @($snapshot.warnings | Where-Object { $_ -match 'Windows filter was rejected' }).Count | Should -Be 1
            $warned | Should -Not -BeNullOrEmpty
        }

        It 'confirms an empty Windows filter result and warns when it was wrong' {
            $script:fake.FilterMode = 'empty'
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru -WarningAction SilentlyContinue 6>$null
            @($snapshot.devices).Count | Should -Be 4
            @($snapshot.warnings | Where-Object { $_ -match 'filter returned no devices' }).Count | Should -Be 1
        }

        It 'does not warn when an empty Windows filter result is correct' {
            $script:fake.FilterMode = 'empty'
            foreach ($device in $script:fake.Devices) { $device.operatingSystem = 'iOS' }
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -PassThru -WarningAction SilentlyContinue 6>$null
            @($snapshot.devices).Count | Should -Be 0
            @($snapshot.warnings | Where-Object { $_ -match 'Windows filter' }).Count | Should -Be 0
        }

        It 'includes every platform with -AllPlatforms' {
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -AllPlatforms -PassThru 6>$null
            @($snapshot.devices).Count | Should -Be 5
            @($snapshot.apps).name | Should -Contain 'Safari'
            @($script:fake.Calls | Where-Object { $_.Uri -match '\$filter=' }).Count | Should -Be 0
        }

        It 'removes a stale per-device CSV when the new snapshot has no per-device apps' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps -ExportCsv 6>$null
            Test-Path -LiteralPath (Join-Path $script:out 'EndpointDeviceApps.csv') | Should -BeTrue
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -Refresh -ExportCsv -WhatIf 6>$null
            Test-Path -LiteralPath (Join-Path $script:out 'EndpointDeviceApps.csv') | Should -BeTrue
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -Refresh -ExportCsv 6>$null
            Test-Path -LiteralPath (Join-Path $script:out 'EndpointDeviceApps.csv') | Should -BeFalse
        }

        It 'guards CSV cells against spreadsheet formula injection' {
            $script:fake.Devices[1].deviceName = '=HYPERLINK("x")'
            $script:fake.Devices[2].userPrincipalName = '@SUM(1)'
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -ExportCsv 6>$null
            $rows = @(Import-Csv -LiteralPath (Join-Path $script:out 'EndpointDevices.csv'))
            $rows.DeviceName | Should -Contain "'=HYPERLINK(""x"")"
            $rows.UserPrincipalName | Should -Contain "'@SUM(1)"
            $rows.DeviceName | Should -Contain 'WIN-001'
        }

        It 'writes CSVs only with -ExportCsv, and per-device CSV only with device apps' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out 6>$null
            Test-Path -LiteralPath (Join-Path $script:out 'EndpointDevices.csv') | Should -BeFalse
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -ExportCsv -Refresh 6>$null
            Test-Path -LiteralPath (Join-Path $script:out 'EndpointDevices.csv') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:out 'EndpointApps.csv') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:out 'EndpointDeviceApps.csv') | Should -BeFalse
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -ExportCsv -IncludeDeviceApps -Refresh 6>$null
            $rows = @(Import-Csv -LiteralPath (Join-Path $script:out 'EndpointDeviceApps.csv'))
            $rows.Count | Should -Be 6
            @($rows | Where-Object DeviceName -EQ 'WIN-002').Count | Should -Be 3
        }
    }

    Context 'Cache' {
        BeforeEach {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out 6>$null
            $script:fake.Calls.Clear()
            $script:fake.Connects = 0
        }

        It 'reuses a fresh snapshot without contacting Graph' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out 6>$null
            Get-GraphCallCount | Should -Be 0
            $script:fake.Connects | Should -Be 0
        }

        It 'pulls again with -Refresh' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -Refresh 6>$null
            Get-GraphCallCount | Should -BeGreaterThan 0
        }

        It 'pulls again when the snapshot is older than -MaxAgeHours' {
            $json = Get-Content -LiteralPath $script:jsonPath -Raw | ConvertFrom-Json
            $json.generatedAt = [DateTimeOffset]::UtcNow.AddHours(-30).ToString('o')
            Set-Content -LiteralPath $script:jsonPath -Value ($json | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
            $null = Invoke-EndpointInventory -OutputDirectory $script:out 6>$null
            Get-GraphCallCount | Should -BeGreaterThan 0
        }

        It 'always pulls with -MaxAgeHours 0' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -MaxAgeHours 0 6>$null
            Get-GraphCallCount | Should -BeGreaterThan 0
        }

        It 'pulls again when the cached scope does not match' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -AllPlatforms 6>$null
            Get-GraphCallCount | Should -BeGreaterThan 0
        }

        It 'pulls again when per-device apps are requested but not cached' {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps 6>$null
            @($script:fake.Calls | Where-Object { $_.Method -eq 'Post' }).Count | Should -BeGreaterThan 0
        }

        It '-FromCache renders without any Graph call and applies -ActiveWithinDays' {
            Remove-Item -LiteralPath $script:htmlPath
            $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -FromCache -ActiveWithinDays 5 -PassThru 6>$null
            Get-GraphCallCount | Should -Be 0
            $script:fake.Connects | Should -Be 0
            Test-Path -LiteralPath $script:htmlPath | Should -BeTrue
            ($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-2').activityState | Should -Be 'Stale'
            $snapshot.thresholds.activeWithinDays | Should -Be 5
        }

        It '-FromCache rejects an invalid snapshot instead of rendering it empty' {
            $json = Get-Content -LiteralPath $script:jsonPath -Raw | ConvertFrom-Json
            $json.schemaVersion = 99
            Set-Content -LiteralPath $script:jsonPath -Value ($json | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
            Remove-Item -LiteralPath $script:htmlPath
            { Invoke-EndpointInventory -OutputDirectory $script:out -FromCache 6>$null } | Should -Throw '*Unsupported schemaVersion*'
            Test-Path -LiteralPath $script:htmlPath | Should -BeFalse
            Get-GraphCallCount | Should -Be 0
        }

        It 'rejects a schema version 1 snapshot (no Entra object IDs)' {
            $json = Get-Content -LiteralPath $script:jsonPath -Raw | ConvertFrom-Json
            $json.schemaVersion = 1
            Set-Content -LiteralPath $script:jsonPath -Value ($json | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
            { Invoke-EndpointInventory -OutputDirectory $script:out -FromCache 6>$null } | Should -Throw '*Unsupported schemaVersion*'
        }

        It '-FromCache rejects a snapshot without a devices collection' {
            Set-Content -LiteralPath $script:jsonPath -Value '{"schemaVersion":1,"generatedAt":"2026-10-13T00:00:00Z","source":{},"thresholds":{},"apps":[],"appRecords":[],"warnings":[]}' -Encoding UTF8
            { Invoke-EndpointInventory -OutputDirectory $script:out -FromCache 6>$null } | Should -Throw "*Missing 'devices'*"
        }

        It 'ignores an invalid cached snapshot and pulls when not -FromCache' {
            Set-Content -LiteralPath $script:jsonPath -Value 'not json' -Encoding UTF8
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -WarningAction SilentlyContinue 6>$null
            Get-GraphCallCount | Should -BeGreaterThan 0
            @(Test-EndpointSnapshot -Snapshot (Get-Content -LiteralPath $script:jsonPath -Raw | ConvertFrom-Json)).Count | Should -Be 0
        }

        It '-FromCache fails clearly when no snapshot exists' {
            { Invoke-EndpointInventory -OutputDirectory (Join-Path $TestDrive 'missing') -FromCache 6>$null } | Should -Throw '*no snapshot*'
        }

        It 'rejects -FromCache with -Refresh' {
            { Invoke-EndpointInventory -OutputDirectory $script:out -FromCache -Refresh 6>$null } | Should -Throw '*cannot be used together*'
        }
    }

    Context 'HTML' {
        BeforeEach {
            $null = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps 6>$null
            $script:html = Get-Content -LiteralPath $script:htmlPath -Raw -Encoding UTF8
        }

        It 'embeds the snapshot with the expected counts' {
            $match = [regex]::Match($script:html, '<script id="endpoint-data" type="application/json">(.*?)</script>', 'Singleline')
            $match.Success | Should -BeTrue
            $data = $match.Groups[1].Value | ConvertFrom-Json
            @($data.devices).Count | Should -Be 4
            @($data.apps).Count | Should -Be 4
            $data.source.includeDeviceApps | Should -BeTrue
        }

        It 'escapes a closing script tag in data' {
            $script:html | Should -Not -Match '</script><script>alert'
            $u = [string][char]92 + 'u'
            $script:html | Should -Match ([regex]::Escape("$($u)003c/script$($u)003e$($u)003cscript$($u)003ealert(1)"))
            ([regex]::Matches($script:html, '</script>')).Count | Should -Be ([regex]::Matches($script:html, '<script[ >]')).Count
            ([regex]::Matches($script:html, '</script>')).Count | Should -Be 3
        }

        It 'contains no external URLs' {
            $script:html | Should -Not -Match 'https?://'
            $script:html | Should -Not -Match '<(link|img|iframe)\b'
            $script:html | Should -Not -Match '<script[^>]+src='
        }

        It 'is ASCII apart from data' {
            (Get-EndpointHtmlTemplate) | Should -Not -Match '[^\x00-\x7F]'
        }
    }
}

Describe 'Export-EndpointInventory.ps1 wrapper' {
    It 'exposes the same parameters as Invoke-EndpointInventory' {
        $scriptParams = @((Get-Command $script:wrapperPath).Parameters.Keys)
        $functionParams = @((Get-Command Invoke-EndpointInventory).Parameters.Keys)
        Compare-Object $scriptParams $functionParams | Should -BeNullOrEmpty
        (Get-Command $script:wrapperPath).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'renders from cache end to end without Graph' {
        $script:fake = Initialize-FakeTenant
        $out = Join-Path $TestDrive 'wrapper'
        $null = Invoke-EndpointInventory -OutputDirectory $out 6>$null
        Remove-Item -LiteralPath (Join-Path $out 'EndpointInventory.html')
        $script:fake.Calls.Clear()
        & $script:wrapperPath -OutputDirectory $out -FromCache 6>$null
        Test-Path -LiteralPath (Join-Path $out 'EndpointInventory.html') | Should -BeTrue
        $script:fake.Calls.Count | Should -Be 0
    }

    It 'writes nothing with -WhatIf -FromCache' {
        $script:fake = Initialize-FakeTenant
        $out = Join-Path $TestDrive 'wrapper-whatif'
        $null = Invoke-EndpointInventory -OutputDirectory $out 6>$null
        Remove-Item -LiteralPath (Join-Path $out 'EndpointInventory.html')
        & $script:wrapperPath -OutputDirectory $out -FromCache -WhatIf 6>$null
        Test-Path -LiteralPath (Join-Path $out 'EndpointInventory.html') | Should -BeFalse
    }
}

Describe 'New-EndpointDemoReport.ps1' {
    BeforeAll { $script:demoPath = Join-Path $PSScriptRoot 'New-EndpointDemoReport.ps1' }

    It 'produces a valid snapshot that the cache path can render' {
        $out = Join-Path $TestDrive 'demo'
        $snapshot = & $script:demoPath -OutputDirectory $out -DeviceCount 150 -PassThru 6>$null
        @(Test-EndpointSnapshot -Snapshot $snapshot).Count | Should -Be 0
        @($snapshot.devices).Count | Should -Be 150
        @($snapshot.devices.managementType | Sort-Object -Unique) | Should -Contain 'ConfigMgr only'
        $loaded = Import-EndpointSnapshot -Path (Join-Path $out 'EndpointInventory.json') -ActiveWithinDays 30
        @($loaded.devices).Count | Should -Be 150
        (Get-Content -LiteralPath (Join-Path $out 'EndpointInventory.html') -Raw) | Should -Not -Match '</script><img'
    }

    It 'is deterministic for the same seed' {
        $a = & $script:demoPath -OutputDirectory (Join-Path $TestDrive 'a') -DeviceCount 50 -Seed 7 -PassThru 6>$null
        $b = & $script:demoPath -OutputDirectory (Join-Path $TestDrive 'b') -DeviceCount 50 -Seed 7 -PassThru 6>$null
        ($a.devices.managementType -join ',') | Should -Be ($b.devices.managementType -join ',')
        ($a.apps.name -join ',') | Should -Be ($b.apps.name -join ',')
    }

    It 'renders approximate app counts and no device apps with -WithoutDeviceApps' {
        $snapshot = & $script:demoPath -OutputDirectory (Join-Path $TestDrive 'nodev') -DeviceCount 50 -WithoutDeviceApps -PassThru 6>$null
        $snapshot.source.includeDeviceApps | Should -BeFalse
        @($snapshot.devices | Where-Object { @($_.appRecordIndexes).Count -gt 0 }).Count | Should -Be 0
        @($snapshot.apps | Where-Object { -not $_.isInstalledVersionApprox }).Count | Should -Be 0
    }

    It 'writes nothing with -WhatIf' {
        $out = Join-Path $TestDrive 'demo-whatif'
        & $script:demoPath -OutputDirectory $out -DeviceCount 20 -WhatIf 6>$null
        Test-Path -LiteralPath $out | Should -BeFalse
    }
}

Describe 'Rollout export parity with PhasedRollout/phased-rollout-creator.ps1' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
    # Runs the real phased-rollout-creator.ps1 (transport and sign-in faked)
    # and the report's JavaScript export under Node on the same demo data,
    # then compares every file byte for byte after normalizing the BOM and
    # line endings that differ between PowerShell 7 on Linux and 5.1.
    BeforeAll {
        $script:snapshot = & (Join-Path $PSScriptRoot 'New-EndpointDemoReport.ps1') -OutputDirectory (Join-Path $TestDrive 'parity-demo') -DeviceCount 400 -PassThru 6>$null
        $records = @($script:snapshot.appRecords)
        $managed = New-Object 'System.Collections.Generic.List[object]'
        $entra = @{}
        $appDevices = @{}
        foreach ($d in $script:snapshot.devices) {
            $managed.Add(@{ id = $d.intuneDeviceId; azureADDeviceId = $d.azureADDeviceId; deviceName = $d.deviceName; userPrincipalName = $d.userPrincipalName
                    lastSyncDateTime = $(if ($d.lastCheckIn) { $d.lastCheckIn } else { '0001-01-01T00:00:00Z' }) })
            if ($d.entraObjectId) {
                $entra[$d.azureADDeviceId] = @{ id = $d.entraObjectId; deviceId = $d.azureADDeviceId.ToUpperInvariant()
                    approximateLastSignInDateTime = $(if ($d.entraApproxLastSignIn) { $d.entraApproxLastSignIn } else { $null }) }
            }
            foreach ($ri in @($d.appRecordIndexes)) {
                $appId = $records[$ri].id
                if (-not $appDevices.ContainsKey($appId)) { $appDevices[$appId] = New-Object 'System.Collections.Generic.List[object]' }
                $appDevices[$appId].Add(@{ id = $d.intuneDeviceId; deviceName = $d.deviceName })
            }
        }
        $script:parity = @{
            Apps = @($records | ForEach-Object { @{ id = $_.id; displayName = $_.name; version = $_.version; platform = $_.platform; deviceCount = $_.deviceCount } })
            AppDevices = $appDevices; Managed = $managed.ToArray(); Entra = @($entra.Values)
        }
        $fakeSource = @'
function Connect-PilotGraph {
    param([string] $TenantId, [string[]] $Scopes, [switch] $DeviceCode)
    return [pscustomobject]@{ Mode = 'Mock'; Token = 'offline'; Account = 'offline' }
}
function Send-PilotGraphRequest {
    param([string] $Method, [string] $Uri, [string] $BodyJson)
    $p = $script:parity
    if ($Uri -match 'filter=') { return [pscustomobject]@{ StatusCode = 400; RetryAfter = 0; Content = '{"error":{"code":"BadRequest"}}' } }
    if ($Method -eq 'Get' -and $Uri -match '/beta/deviceManagement/detectedApps/([^/?]+)/managedDevices\?') {
        $id = [uri]::UnescapeDataString($Matches[1])
        $content = @{ value = @(if ($p.AppDevices.ContainsKey($id)) { $p.AppDevices[$id].ToArray() }) }
    }
    elseif ($Method -eq 'Get' -and $Uri -match '/beta/deviceManagement/detectedApps\?') { $content = @{ value = $p.Apps } }
    elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/deviceManagement/managedDevices\?') { $content = @{ value = $p.Managed } }
    elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/devices\?') { $content = @{ value = $p.Entra } }
    else { throw "Unexpected Graph request $Method $Uri" }
    return [pscustomobject]@{ StatusCode = 200; RetryAfter = 0; Content = ($content | ConvertTo-Json -Depth 6 -Compress) }
}
'@
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\PhasedRollout\phased-rollout-creator.ps1') -Raw
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $fakeAst = [Management.Automation.Language.Parser]::ParseInput($fakeSource, [ref]$null, [ref]$null)
        $replacements = @{}
        foreach ($fn in @($fakeAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))) { $replacements[$fn.Name] = $fn.Extent.Text }
        $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | Where-Object { $replacements.ContainsKey($_.Name) } | Sort-Object { $_.Extent.StartOffset } -Descending)
        $functions.Count | Should -Be 2
        foreach ($fn in $functions) {
            $source = $source.Remove($fn.Extent.StartOffset, $fn.Extent.EndOffset - $fn.Extent.StartOffset).Insert($fn.Extent.StartOffset, $replacements[$fn.Name])
        }
        $script:rolloutScript = [scriptblock]::Create($source)

        $template = Get-EndpointHtmlTemplate
        $lib = [regex]::Match($template, '<script id="rollout-lib">(.*?)</script>', 'Singleline').Groups[1].Value
        $script:libPath = Join-Path $TestDrive 'rollout-lib.js'
        $script:dataPath = Join-Path $TestDrive 'parity-data.json'
        $script:driverPath = Join-Path $TestDrive 'driver.js'
        [IO.File]::WriteAllText($script:libPath, $lib)
        [IO.File]::WriteAllText($script:dataPath, (ConvertTo-Json -InputObject $script:snapshot -Depth 10 -Compress))
        [IO.File]::WriteAllText($script:driverPath, @'
const fs = require('fs'), vm = require('vm');
const [libPath, dataPath, argsPath, outPath, zipPath] = process.argv.slice(2);
vm.runInThisContext(fs.readFileSync(libPath, 'utf8'));
const data = JSON.parse(fs.readFileSync(dataPath, 'utf8')), args = JSON.parse(fs.readFileSync(argsPath, 'utf8'));
args.options.referenceTime = Date.now();
const result = EndpointRollout.build(data, args.recordIndexes, args.options);
fs.writeFileSync(outPath, JSON.stringify({ files: result.files, skipped: result.skipped, rows: result.rows.length }));
fs.writeFileSync(zipPath, EndpointRollout.zip(result.files));
'@)

        function Invoke-ParityCase {
            param([string] $AppName, [string] $MaxVersion, [string] $Name, [switch] $RequirePrimaryUser)
            $records = @($script:snapshot.appRecords)
            $bound = if ($MaxVersion) { ConvertTo-EndpointVersion $MaxVersion } else { $null }
            $indexes = @(for ($i = 0; $i -lt $records.Count; $i++) {
                    if ($records[$i].name -notlike $AppName -or $records[$i].platform -ne 'windows') { continue }
                    $version = ConvertTo-EndpointVersion $records[$i].version
                    if ($bound -and ($null -eq $version -or $version -ge $bound)) { continue }
                    $i
                })
            $scriptDir = Join-Path $TestDrive "$Name-script"
            $null = New-Item -ItemType Directory -Path $scriptDir
            $scriptArgs = @{ AppName = $AppName; ExportDirectory = $scriptDir; DeviceLookup = 'Bulk'; ActiveWithinDays = 90; RequirePrimaryUser = $RequirePrimaryUser }
            if ($MaxVersion) { $scriptArgs.MaxVersion = $MaxVersion }
            & $script:rolloutScript @scriptArgs 6>$null 3>$null
            $argsPath = Join-Path $TestDrive "$Name-args.json"
            $outPath = Join-Path $TestDrive "$Name-js.json"
            $zipPath = Join-Path $TestDrive "$Name.zip"
            [IO.File]::WriteAllText($argsPath, (ConvertTo-Json -Depth 5 -InputObject @{
                        recordIndexes = $indexes
                        options = @{ percentages = @(10, 30, 60); activeWithinDays = 90; requirePrimaryUser = [bool]$RequirePrimaryUser; stamp = 'STAMP' }
                    }))
            & node $script:driverPath $script:libPath $script:dataPath $argsPath $outPath $zipPath
            if ($LASTEXITCODE -ne 0) { throw 'node driver failed' }
            $js = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json
            $scriptFiles = @{}
            foreach ($file in Get-ChildItem -LiteralPath $scriptDir -Filter '*.csv') {
                $key = $file.Name -replace '-\d{8}-\d{6}-\d{3}\.csv$', '-STAMP.csv'
                $scriptFiles[$key] = [IO.File]::ReadAllText($file.FullName).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
            }
            return [pscustomobject]@{ Js = $js; ScriptFiles = $scriptFiles; ZipPath = $zipPath; Indexes = $indexes }
        }
    }

    It 'matches the script for <Name>' -ForEach @(
        @{ Name = 'chrome-below-130'; AppName = 'Google Chrome'; MaxVersion = '130'; RequirePrimaryUser = $false }
        @{ Name = 'edge-all-versions'; AppName = 'Microsoft Edge'; MaxVersion = ''; RequirePrimaryUser = $false }
        @{ Name = 'teams-require-user'; AppName = 'Microsoft Teams'; MaxVersion = ''; RequirePrimaryUser = $true }
    ) {
        $case = Invoke-ParityCase -AppName $AppName -MaxVersion $MaxVersion -Name $Name -RequirePrimaryUser:$RequirePrimaryUser
        $case.Indexes.Count | Should -BeGreaterThan 0
        $case.Js.rows | Should -BeGreaterThan 20
        @($case.Js.files).Count | Should -Be $case.ScriptFiles.Count
        foreach ($file in $case.Js.files) {
            $case.ScriptFiles.ContainsKey($file.name) | Should -BeTrue -Because $file.name
            $file.text.Replace("`r`n", "`n") | Should -BeExactly $case.ScriptFiles[$file.name] -Because $file.name
        }
    }

    It 'exercises de-duplication and skips in the demo data' {
        $case = Invoke-ParityCase -AppName 'Microsoft Edge' -MaxVersion '' -Name 'edge-skips'
        @($case.Js.skipped | Where-Object reason -EQ 'no Entra device id').Count | Should -BeGreaterThan 0
        $detail = $case.ScriptFiles['PhasedRolloutDetail-STAMP.csv'] -split "`n" | Where-Object { $_ }
        $intuneMatched = @($script:snapshot.devices | Where-Object { $d = $_; @($d.appRecordIndexes | Where-Object { $case.Indexes -contains $_ }).Count -gt 0 }).Count
        ($detail.Count - 1) | Should -BeLessThan $intuneMatched
        # The demo's formula look-alike device names are exported guarded by both.
        $case.ScriptFiles['PhasedRolloutDetail-STAMP.csv'] | Should -Match ([regex]::Escape("""'=1+2-FORMULA"""))
        $case.ScriptFiles['PhasedRolloutDetail-STAMP.csv'] | Should -Not -Match '(^|,)"[=+@]'
    }

    It 'writes a valid zip with BOM-prefixed CRLF CSVs' {
        $case = Invoke-ParityCase -AppName 'Google Chrome' -MaxVersion '130' -Name 'zip'
        $extract = Join-Path $TestDrive 'zip-out'
        Expand-Archive -LiteralPath $case.ZipPath -DestinationPath $extract
        $names = @(Get-ChildItem -LiteralPath $extract | Select-Object -ExpandProperty Name | Sort-Object)
        $names | Should -Be @($case.Js.files.name | Sort-Object)
        foreach ($file in $case.Js.files) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $extract $file.name))
            @($bytes[0..2]) | Should -Be @(0xEF, 0xBB, 0xBF)
            [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) | Should -BeExactly $file.text
            $file.text | Should -Match "`r`n$"
        }
    }
}

Describe 'App inventory import (-AppInventoryPath)' {
    BeforeAll {
        function Write-FakeInventory {
            param([string] $Path, [string[]] $Header, [object[]] $Rows, [switch] $Zip)
            $lines = @(($Header | ForEach-Object { '"' + $_ + '"' }) -join ',')
            foreach ($row in $Rows) { $lines += (@($row | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ',') }
            $csvPath = if ($Zip) { [IO.Path]::ChangeExtension($Path, '.csv') } else { $Path }
            [IO.File]::WriteAllText($csvPath, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding $true))
            if ($Zip) { Compress-Archive -LiteralPath $csvPath -DestinationPath $Path; Remove-Item -LiteralPath $csvPath }
            return $Path
        }
        # Header exactly as the Intune admin center raw-data export writes it.
        $script:apiHeader = @('Application key', 'ApplicationID', 'ApplicationName', 'ApplicationPublisher', 'ApplicationShortVersion', 'ApplicationVersion',
            'DeviceID', 'DeviceName', 'OSDescription', 'OSVersion', 'Platform', 'UserID', 'EmailAddress', 'Username')
        function Get-FakeInventoryRow {
            param([string] $Name, [string] $Publisher, [string] $Short, [string] $Version, [string] $DeviceId, [string] $DeviceName, [string] $Os = 'Windows')
            return , @('key', '', $Name, $Publisher, $Short, $Version, $DeviceId, $DeviceName, $Os, '10.0', $Os, 'u', 'user@example.test', 'User')
        }
        # dev-1: 7-Zip 23.01 + an app Graph does not list; dev-2: 7-Zip 19.00 + Chrome;
        # dev-3: Chrome; dev-ghost is not in the snapshot.
        $script:apiRows = @(
            , (Get-FakeInventoryRow '7-Zip' 'Igor Pavlov' '23.01' '23.01' 'dev-1' 'WIN-001')
            , (Get-FakeInventoryRow 'Brand New Tool' 'Example Corp' '1.0' '1.0.0.0' 'dev-1' 'WIN-001')
            , (Get-FakeInventoryRow '7-Zip' 'Igor Pavlov' '19.00' '19.00' 'DEV-2' 'WIN-002')
            , (Get-FakeInventoryRow 'Google Chrome' 'Google' '130.0' '130.0' 'dev-2' 'WIN-002')
            , (Get-FakeInventoryRow 'Google Chrome' 'Google' '130.0' '130.0' 'dev-3' 'WIN-003')
            , (Get-FakeInventoryRow 'Google Chrome' 'Google' '130.0' '130.0' 'dev-ghost' 'GHOST')
            # Other platforms are in the same export and must be skipped.
            , (Get-FakeInventoryRow 'Safari' 'Apple' '18.0' '18.0' 'dev-5' 'MAC-001' 'macOS')
            , (Get-FakeInventoryRow 'Outlook' 'Microsoft' '4.2' '4.2' 'ios-1' 'IPHONE' 'iOS')
        )
    }
    BeforeEach {
        $script:fake = Initialize-FakeTenant
        $script:out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:out
    }

    It 'maps devices from a CSV with API column names and makes no per-app Graph calls' {
        $file = Write-FakeInventory -Path (Join-Path $script:out 'inv.csv') -Header $script:apiHeader -Rows $script:apiRows
        $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps -AppInventoryPath $file -PassThru 6>$null
        @($script:fake.Calls | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 0
        $snapshot.source.includeDeviceApps | Should -BeTrue
        $snapshot.source.appInventory.deviceIdType | Should -Be 'Intune device ID'
        $snapshot.source.appInventory.matchedRows | Should -Be 5
        $snapshot.source.appInventory.nonWindowsRows | Should -Be 2
        $snapshot.source.appInventory.addedRecords | Should -Be 1
        @($snapshot.appRecords).name | Should -Not -Contain 'Safari'
        @($snapshot.appRecords).name | Should -Not -Contain 'Outlook'
        $snapshot.source.appInventory.outOfScopeDevices | Should -Be 1
        $records = @($snapshot.appRecords)
        $names = { param($id) @(($snapshot.devices | Where-Object intuneDeviceId -EQ $id).appRecordIndexes | ForEach-Object { '{0} {1}' -f $records[$_].name, $records[$_].version } | Sort-Object) }
        & $names 'dev-1' | Should -Be @('7-Zip 23.01', 'Brand New Tool 1.0.0.0')
        & $names 'dev-2' | Should -Be @('7-Zip 19.00', 'Google Chrome 130.0')
        & $names 'dev-4' | Should -BeNullOrEmpty
        $zip = $snapshot.apps | Where-Object name -EQ '7-Zip'
        $zip.deviceCount | Should -Be 2
        $zip.isInstalledVersionApprox | Should -BeFalse
        ($snapshot.apps | Where-Object name -EQ 'Brand New Tool').deviceCount | Should -Be 1
        @($snapshot.warnings | Where-Object { $_ -like 'App inventory import:*' }).Count | Should -Be 3
    }

    It 'reads a zipped export with spaced headers and Entra device IDs' {
        $header = @('Device ID', 'Application Name', 'Application Version', 'Application Publisher', 'Platform')
        $rows = @(
            , @('11111111-1111-1111-1111-111111111111', '7-Zip', '23.01', 'Igor Pavlov', 'Windows')
            , @('22222222-2222-2222-2222-222222222222'.ToUpperInvariant(), 'Google Chrome', '130.0', 'Google', 'Windows')
        )
        $file = Write-FakeInventory -Path (Join-Path $script:out 'inv.zip') -Header $header -Rows $rows -Zip
        $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -AppInventoryPath $file -PassThru 6>$null
        $snapshot.source.appInventory.deviceIdType | Should -Be 'Entra device ID'
        $snapshot.source.appInventory.matchedRows | Should -Be 2
        $snapshot.source.appInventory.addedRecords | Should -Be 0
        $records = @($snapshot.appRecords)
        $records[@(($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-2').appRecordIndexes)[0]].name | Should -Be 'Google Chrome'
    }

    It 'falls back to ApplicationShortVersion to match a detected app record' {
        $rows = @(, (Get-FakeInventoryRow '7-Zip' 'Igor Pavlov' '23.01' '23.01.0000.0' 'dev-1' 'WIN-001'))
        $file = Write-FakeInventory -Path (Join-Path $script:out 'inv.csv') -Header $script:apiHeader -Rows $rows
        $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -AppInventoryPath $file -PassThru 6>$null
        $snapshot.source.appInventory.addedRecords | Should -Be 0
        $records = @($snapshot.appRecords)
        $records[@(($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-1').appRecordIndexes)[0]].version | Should -Be '23.01'
    }

    It 'keeps other platforms with -AllPlatforms' {
        $file = Write-FakeInventory -Path (Join-Path $script:out 'inv.csv') -Header $script:apiHeader -Rows $script:apiRows
        $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -AllPlatforms -AppInventoryPath $file -PassThru 6>$null
        $snapshot.source.appInventory.nonWindowsRows | Should -Be 0
        $records = @($snapshot.appRecords)
        @(($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-5').appRecordIndexes | ForEach-Object { $records[$_].name }) | Should -Contain 'Safari'
    }

    It 'fails clearly when the export has no Windows rows' {
        $rows = @(, (Get-FakeInventoryRow 'Safari' 'Apple' '18.0' '18.0' 'dev-5' 'MAC-001' 'macOS'))
        $file = Write-FakeInventory -Path (Join-Path $script:out 'mac.csv') -Header $script:apiHeader -Rows $rows
        { Invoke-EndpointInventory -OutputDirectory $script:out -AppInventoryPath $file 6>$null } | Should -Throw '*none with OSDescription = Windows*'
    }

    It 'rejects the aggregate export (no DeviceId column) with the columns it found' {
        $file = Write-FakeInventory -Path (Join-Path $script:out 'agg.csv') -Header @('ApplicationName', 'ApplicationVersion', 'DeviceCount') -Rows @(, @('7-Zip', '23.01', '5'))
        { Invoke-EndpointInventory -OutputDirectory $script:out -AppInventoryPath $file 6>$null } | Should -Throw "*no 'deviceid' column*raw-data export*Columns found: ApplicationName*"
    }

    It 'rejects an export whose device IDs match no snapshot device' {
        $file = Write-FakeInventory -Path (Join-Path $script:out 'other.csv') -Header $script:apiHeader -Rows @(, (Get-FakeInventoryRow 'X' 'P' '1' '1' 'other-tenant' 'N'))
        { Invoke-EndpointInventory -OutputDirectory $script:out -AppInventoryPath $file 6>$null } | Should -Throw '*match this snapshot*'
    }

    It 'applies to a fresh cached snapshot without Graph and saves the result' {
        $null = Invoke-EndpointInventory -OutputDirectory $script:out 6>$null
        $script:fake.Calls.Clear(); $script:fake.Connects = 0
        $file = Write-FakeInventory -Path (Join-Path $script:out 'inv.csv') -Header $script:apiHeader -Rows $script:apiRows
        $null = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps -AppInventoryPath $file 6>$null
        $script:fake.Calls.Count | Should -Be 0
        $script:fake.Connects | Should -Be 0
        $saved = Import-EndpointSnapshot -Path (Join-Path $script:out 'EndpointInventory.json') -ActiveWithinDays 30
        $saved.source.includeDeviceApps | Should -BeTrue
        $saved.source.appInventory.file | Should -Be 'inv.csv'
        # A later run that asks for device apps reuses the imported snapshot.
        $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -IncludeDeviceApps -PassThru 6>$null
        $script:fake.Calls.Count | Should -Be 0
        @(($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-2').appRecordIndexes).Count | Should -Be 2
    }

    It 'leaves the cached snapshot untouched with -WhatIf' {
        $null = Invoke-EndpointInventory -OutputDirectory $script:out 6>$null
        $jsonPath = Join-Path $script:out 'EndpointInventory.json'
        $before = Get-Content -LiteralPath $jsonPath -Raw
        $file = Write-FakeInventory -Path (Join-Path $script:out 'inv.csv') -Header $script:apiHeader -Rows $script:apiRows
        $null = Invoke-EndpointInventory -OutputDirectory $script:out -FromCache -AppInventoryPath $file -WhatIf 6>$null
        Get-Content -LiteralPath $jsonPath -Raw | Should -BeExactly $before
    }

    It 'replaces earlier per-device data and does not stack import warnings' {
        $file = Write-FakeInventory -Path (Join-Path $script:out 'inv.csv') -Header $script:apiHeader -Rows $script:apiRows
        $null = Invoke-EndpointInventory -OutputDirectory $script:out -AppInventoryPath $file 6>$null
        $small = Write-FakeInventory -Path (Join-Path $script:out 'small.csv') -Header $script:apiHeader -Rows @(, $script:apiRows[0])
        $snapshot = Invoke-EndpointInventory -OutputDirectory $script:out -FromCache -AppInventoryPath $small -PassThru 6>$null
        @(($snapshot.devices | Where-Object intuneDeviceId -EQ 'dev-2').appRecordIndexes).Count | Should -Be 0
        @($snapshot.warnings | Where-Object { $_ -like 'App inventory import:*mapped*' }).Count | Should -Be 1
    }
}

Describe 'Graph per-app lookups under throttling' {
    BeforeEach {
        $script:fake = Initialize-FakeTenant
        Initialize-EndpointGraphState
        $script:EndpointGraphState.Session = [pscustomobject]@{ Mode = 'MgGraph' }
    }

    It 'counts a record that stays throttled as unresolved instead of failing the run' {
        $script:fake.ThrottledApps = @('app-chrome')
        $records = @(Get-EndpointDetectedApp -WindowsOnly)
        $result = Get-EndpointDeviceAppMap -AppRecords $records -DeviceIds @('dev-1', 'dev-2', 'dev-3')
        $result.Unresolved | Should -Be 1
        $result.Map['dev-1'].Count | Should -Be 1
        $script:EndpointGraphState.BatchPauseMs | Should -BeGreaterThan 0
        Should -Invoke Start-Sleep -ParameterFilter { $Milliseconds -gt 0 }
    }

    It 'reports unresolved records in the snapshot warnings' {
        $script:fake.ThrottledApps = @('app-chrome')
        $snapshot = Invoke-EndpointInventory -OutputDirectory (Join-Path $TestDrive 'throttle') -IncludeDeviceApps -PassThru -WarningAction SilentlyContinue 6>$null
        @($snapshot.warnings | Where-Object { $_ -match 'still throttled' }).Count | Should -Be 1
    }
}

Describe 'Export-EndpointAppInventoryReport (AppInvRawData export job)' {
    BeforeEach {
        $script:fake = Initialize-FakeTenant
        $script:out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'zip-bytes' }
    }

    It 'allows only the AppInvRawData job, and only when the export script enables it' {
        Initialize-EndpointGraphState
        $post = { param($Body) Assert-EndpointReadRequest -Method Post -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/reports/exportJobs' -Body $Body }
        { & $post @{ reportName = 'AppInvRawData' } } | Should -Throw '*boundary rejected*'
        $script:EndpointGraphState.AllowAppInventoryExport = $true
        { & $post @{ reportName = 'AppInvRawData'; format = 'csv' } } | Should -Not -Throw
        { & $post @{ reportName = 'Devices' } } | Should -Throw '*boundary rejected*'
        { & $post @{ reportName = 'AppInvRawData'; filter = "(DeviceId eq 'x')" } } | Should -Throw '*boundary rejected*'
        { Assert-EndpointReadRequest -Method Get -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/reports/exportJobs/AppInvRawData_0a1b-2c3d' -Body $null } | Should -Not -Throw
        { Assert-EndpointReadRequest -Method Get -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/reports/exportJobs/Devices_0a1b' -Body $null } | Should -Throw '*boundary rejected*'
        { Assert-EndpointReadRequest -Method Delete -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/reports/exportJobs/AppInvRawData_0a1b-2c3d' -Body $null } | Should -Throw '*boundary rejected*'
        Initialize-EndpointGraphState
        $script:EndpointGraphState.AllowAppInventoryExport | Should -BeFalse
    }

    It 'creates the job, polls until complete, downloads, and turns the opt-in off again' {
        $script:fake.ExportStatuses.Enqueue('inProgress')
        $file = Invoke-EndpointAppInventoryExport -OutputDirectory $script:out -PassThru 6>$null
        $file.Name | Should -Match '^AppInvRawData-\d{8}-\d{6}\.zip$'
        Test-Path -LiteralPath $file.FullName | Should -BeTrue
        $create = @($script:fake.Calls | Where-Object { $_.Method -eq 'Post' })
        $create.Count | Should -Be 1
        $create[0].Body.reportName | Should -Be 'AppInvRawData'
        @($create[0].Body.select) | Should -Contain 'DeviceId'
        @($script:fake.Calls | Where-Object { $_.Method -eq 'Get' }).Count | Should -Be 2
        Should -Invoke Connect-EndpointGraph -Times 1 -Exactly -ParameterFilter { $Scopes -contains 'DeviceManagementConfiguration.ReadWrite.All' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like 'https://fakeacct.blob.core.windows.net/*' -and -not $Headers }
        $script:EndpointGraphState.AllowAppInventoryExport | Should -BeFalse
    }

    It 'signs in and calls nothing with -WhatIf' {
        Invoke-EndpointAppInventoryExport -OutputDirectory $script:out -WhatIf 6>$null
        $script:fake.Calls.Count | Should -Be 0
        $script:fake.Connects | Should -Be 0
        Test-Path -LiteralPath $script:out | Should -BeFalse
    }

    It 'fails clearly when the job fails' {
        $script:fake.ExportStatuses.Enqueue('failed')
        { Invoke-EndpointAppInventoryExport -OutputDirectory $script:out 6>$null } | Should -Throw '*failed*'
        $script:EndpointGraphState.AllowAppInventoryExport | Should -BeFalse
    }

    It 'refuses to download from anywhere but Azure Blob Storage' {
        { Save-EndpointExportDownload -Url 'https://evil.example.test/AppInvRawData.zip' -Path (Join-Path $TestDrive 'x.zip') } | Should -Throw '*Azure Blob Storage*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'exposes the same parameters in the script wrapper' {
        $scriptParams = @((Get-Command (Join-Path $PSScriptRoot 'Export-EndpointAppInventoryReport.ps1')).Parameters.Keys)
        Compare-Object $scriptParams @((Get-Command Invoke-EndpointAppInventoryExport).Parameters.Keys) | Should -BeNullOrEmpty
    }
}
