#requires -Version 5.1
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
Offline Pester tests for GroupSync/Sync-EucPilotGroup.ps1.

The production script runs end to end against an in-memory fake tenant. Only
four functions are replaced in the script source: Connect-PilotGraph (no
sign-in), Send-PilotGraphRequest (no HTTP), Send-PilotTeamsNotification (no
webhook), plus a Start-Sleep stub. Everything else - report paging, batching,
retry, planning, guards, ShouldProcess - is the real code.
#>

BeforeAll {
    Set-StrictMode -Version 3.0
    $scriptPath = Join-Path $PSScriptRoot '..\GroupSync\Sync-EucPilotGroup.ps1'
    $source = Get-Content -LiteralPath $scriptPath -Raw
    $tokens = $null
    $parseErrors = $null
    $script:syncAst = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'Sync-EucPilotGroup.ps1 does not parse.' }
    $functions = @($script:syncAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))

    $fakeSource = @'
function Connect-PilotGraph {
    param([string] $TenantId, [string[]] $Scopes, [switch] $DeviceCode)
    $tenant = $script:fake.Tenant
    $tenant.AuthCount++
    if ($Scopes) { $tenant.Scopes = $Scopes }
    return [pscustomobject]@{ Mode = $tenant.AuthMode; Token = 'offline-token'; Account = 'offline' }
}
function Send-PilotTeamsNotification {
    param([string] $Uri, [string] $VariableName, [string[]] $Lines)
    $script:fake.Tenant.Teams.Add($Lines)
}
function Start-Sleep {
    param([int] $Seconds)
    $script:fake.Tenant.Sleeps.Add($Seconds)
}
function Get-FakePage {
    param([string] $Uri, [object[]] $Items, [int] $PageSize)
    $skip = 0
    if ($Uri -match '&skip=(\d+)') { $skip = [int]$Matches[1] }
    $page = @{ value = @($Items | Select-Object -Skip $skip -First $PageSize) }
    if ($skip + $PageSize -lt $Items.Count) {
        $page['@odata.nextLink'] = ($Uri -replace '&skip=\d+', '') + "&skip=$($skip + $PageSize)"
    }
    return $page
}
function Send-PilotGraphRequest {
    param([string] $Method, [string] $Uri, [string] $BodyJson)
    $tenant = $script:fake.Tenant
    $body = if ($BodyJson) { $BodyJson | ConvertFrom-Json } else { $null }
    $tenant.Calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $body })
    if ($tenant.StatusQueue.Count -gt 0) {
        $queued = $tenant.StatusQueue.Dequeue()
        if ($queued -ne 200) {
            return [pscustomobject]@{ StatusCode = $queued; RetryAfter = 7; Content = '{"error":{"code":"Injected","message":"injected failure"}}' }
        }
    }
    $status = 200
    $content = $null
    if ($Uri -match '/beta/deviceManagement/reports/') {
        if (($body.orderBy -join ',') -ne 'DeviceId asc,UserPrincipalName asc') { throw 'Report requested without a stable order.' }
        $rows = $tenant.ReportRows.ToArray()
        $values = @($rows | Select-Object -Skip $body.skip -First ([Math]::Min($body.top, $tenant.PageCap)))
        if ($tenant.ReportFault -eq 'repeat' -and $body.skip -gt 0) { $values = @(, $rows[0]) }
        $content = @{
            Schema        = @('DeviceId', 'DeviceName', 'UserPrincipalName', 'InstallState', 'LastModifiedDateTime' | ForEach-Object { @{ Column = $_ } })
            Values        = $values
            TotalRowCount = $rows.Count
        }
        if ($tenant.ReportFault -eq 'missing-total') { $content.Remove('TotalRowCount') }
        if ($tenant.ReportFault -eq 'changing-total' -and $body.skip -gt 0) { $content.TotalRowCount++ }
    }
    elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/groups/([^/?]+)/(members|owners)\?(.*)$') {
        $groupId = $Matches[1]
        $relationship = $Matches[2]
        $query = $Matches[3]
        if ($Uri -match 'microsoft\.graph\.') { throw "OData cast used (needs eventual consistency): $Uri" }
        if ($query -notmatch '\$select=' -or $query -notmatch '\$top=999') { throw "Group read without `$select/`$top: $Uri" }
        $tenant.MemberReads++
        $ids = if ($relationship -eq 'members') { $tenant.Groups[$groupId].Members } else { $tenant.Groups[$groupId].Owners }
        $items = @($ids | ForEach-Object {
                $object = $tenant.Objects[$_]
                $item = @{ '@odata.type' = $object.Type; id = $_ }
                if ($object.Type -eq '#microsoft.graph.device') { $item.deviceId = $object.DeviceId.ToUpperInvariant(); $item.displayName = $object.DisplayName }
                if ($object.Type -eq '#microsoft.graph.user') { $item.userPrincipalName = $object.UserPrincipalName }
                $item
            })
        $content = Get-FakePage -Uri $Uri -Items $items -PageSize $tenant.ListPageSize
    }
    elseif ($Method -eq 'Post' -and $Uri -match '/v1\.0/groups/([^/]+)/members/\$ref$') {
        $groupId = $Matches[1]
        $objectId = ([string]$body.'@odata.id').Split('/')[-1]
        if (-not $tenant.Objects.ContainsKey($objectId)) {
            $status = 404
            $content = '{"error":{"code":"Request_ResourceNotFound","message":"Resource does not exist."}}'
        }
        elseif ($tenant.Groups[$groupId].Members.Contains($objectId)) {
            $status = 400
            $content = '{"error":{"code":"Request_BadRequest","message":"One or more added object references already exist for the following modified properties: ''members''."}}'
        }
        else {
            $tenant.Groups[$groupId].Members.Add($objectId)
            $tenant.Writes.Add("ADD $groupId $objectId")
            $status = 204
        }
    }
    elseif ($Method -eq 'Delete' -and $Uri -match '/v1\.0/groups/([^/]+)/members/([^/]+)/\$ref$') {
        $groupId = $Matches[1]
        $objectId = $Matches[2]
        if ($tenant.Groups[$groupId].Members.Remove($objectId)) {
            $tenant.Writes.Add("REMOVE $groupId $objectId")
            $status = 204
        }
        else {
            $status = 404
            $content = '{"error":{"code":"Request_ResourceNotFound","message":"Resource does not exist."}}'
        }
    }
    elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/groups/([^/?]+)\?') {
        $group = $tenant.Groups[$Matches[1]]
        $content = @{ id = $Matches[1]; displayName = $group.DisplayName; groupTypes = $group.GroupTypes; securityEnabled = $group.SecurityEnabled; onPremisesSyncEnabled = $null }
    }
    elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/deviceManagement/managedDevices\?') {
        $items = @($tenant.ManagedDevices.Keys | Sort-Object | ForEach-Object { $tenant.ManagedDevices[$_] })
        $content = Get-FakePage -Uri $Uri -Items $items -PageSize $tenant.ListPageSize
    }
    elseif ($Method -eq 'Get' -and $Uri -match '/v1\.0/devices\?') {
        $items = @($tenant.EntraDevices.Keys | Sort-Object | ForEach-Object { @{ id = $tenant.EntraDevices[$_]; deviceId = $_ } })
        $content = Get-FakePage -Uri $Uri -Items $items -PageSize $tenant.ListPageSize
    }
    elseif ($Method -eq 'Post' -and $Uri.EndsWith('/$batch')) {
        $batchStatus = if ($tenant.BatchStatusQueue.Count -gt 0) { $tenant.BatchStatusQueue.Dequeue() } else { 200 }
        $responses = @(foreach ($request in $body.requests) {
                $url = [string]$request.url
                if ($batchStatus -ne 200) {
                    @{ id = $request.id; status = $batchStatus; headers = @{ 'Retry-After' = '3' }; body = @{} }
                    continue
                }
                if ($url -match '^/deviceManagement/managedDevices/([^?]+)\?\$select=(.+)$') {
                    $intuneId = $Matches[1]
                    $selected = @($Matches[2] -split ',')
                    if ($selected -notcontains 'userId' -or $selected -notcontains 'lastSyncDateTime') { throw "Managed device lookup missing userId/lastSyncDateTime: $url" }
                    $device = $tenant.ManagedDevices[$intuneId]
                    if ($null -eq $device) { @{ id = $request.id; status = 404; body = @{} } }
                    else { @{ id = $request.id; status = 200; body = $device } }
                }
                elseif ($url -match "^/devices\(deviceId='([^']+)'\)") {
                    $deviceId = $Matches[1]
                    if ($tenant.EntraDevices.ContainsKey($deviceId)) { @{ id = $request.id; status = 200; body = @{ id = $tenant.EntraDevices[$deviceId]; deviceId = $deviceId } } }
                    else { @{ id = $request.id; status = 404; body = @{} } }
                }
                else { throw "Unexpected batch request $url" }
            })
        if ($tenant.BatchFault -eq 'unexpected-id') { $responses[0].id = 'not-requested' }
        $content = @{ responses = $responses }
    }
    else {
        throw "Unexpected Graph request $Method $Uri"
    }
    $text = if ($null -eq $content) { '' } elseif ($content -is [string]) { $content } else { $content | ConvertTo-Json -Depth 20 -Compress }
    return [pscustomobject]@{ StatusCode = $status; RetryAfter = 0; Content = $text }
}
'@

    # Unit-test access to the real helpers, with the transport faked.
    foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
    . ([scriptblock]::Create($fakeSource))

    # Entry point: the production script with only the faked functions swapped.
    $fakeAst = [Management.Automation.Language.Parser]::ParseInput($fakeSource, [ref]$null, [ref]$null)
    $replacements = @{}
    foreach ($fn in @($fakeAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))) {
        $replacements[$fn.Name] = $fn.Extent.Text
    }
    $mockSource = $source
    foreach ($fn in @($functions | Where-Object { $replacements.ContainsKey($_.Name) } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $mockSource = $mockSource.Remove($fn.Extent.StartOffset, $fn.Extent.EndOffset - $fn.Extent.StartOffset).Insert($fn.Extent.StartOffset, $replacements[$fn.Name])
    }
    # Helpers that the production script does not define are inserted after param().
    $paramEnd = $script:syncAst.ParamBlock.Extent.EndOffset
    $extra = ($replacements.Keys | Where-Object { $_ -in @('Start-Sleep', 'Get-FakePage') } | ForEach-Object { $replacements[$_] }) -join "`n"
    $mockSource = $mockSource.Insert($paramEnd, "`n$extra`n")
    $script:entryPoint = [scriptblock]::Create($mockSource)

    $script:appId = '11111111-1111-1111-1111-111111111111'
    $script:pilotId = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:commsId = 'aaaaaaaa-0000-0000-0000-000000000002'
    $script:ownerId = 'bbbbbbbb-0000-0000-0000-000000000001'
    $script:fake = @{ Tenant = $null }

    function Initialize-FakeTenant {
        param([int] $DeviceCount = 3)
        $tenant = @{
            Calls = New-Object 'System.Collections.Generic.List[object]'
            Writes = New-Object 'System.Collections.Generic.List[string]'
            Sleeps = New-Object 'System.Collections.Generic.List[int]'
            Teams = New-Object 'System.Collections.Generic.List[object]'
            StatusQueue = New-Object 'System.Collections.Generic.Queue[int]'
            BatchStatusQueue = New-Object 'System.Collections.Generic.Queue[int]'
            ReportRows = New-Object 'System.Collections.Generic.List[object]'
            AuthCount = 0; AuthMode = 'MgGraph'; Scopes = @(); MemberReads = 0
            PageCap = 500; ReportFault = ''; BatchFault = ''; ListPageSize = 2
            ManagedDevices = @{}; EntraDevices = @{}; Objects = @{}
            Groups = @{}
        }
        $tenant.Groups[$script:pilotId] = @{ DisplayName = 'SEC-EUC-Pilot'; GroupTypes = @(); SecurityEnabled = $true
            Members = New-Object 'System.Collections.Generic.List[string]'; Owners = New-Object 'System.Collections.Generic.List[string]' }
        $tenant.Groups[$script:commsId] = @{ DisplayName = 'EUC-Pilot-Comms'; GroupTypes = @(); SecurityEnabled = $true
            Members = New-Object 'System.Collections.Generic.List[string]'; Owners = New-Object 'System.Collections.Generic.List[string]' }
        $tenant.Objects[$script:ownerId] = @{ Type = '#microsoft.graph.user'; UserPrincipalName = 'owner@example.test' }
        $tenant.Groups[$script:commsId].Owners.Add($script:ownerId)
        $tenant.Groups[$script:commsId].Members.Add($script:ownerId)
        $script:fake.Tenant = $tenant
        for ($i = 1; $i -le $DeviceCount; $i++) { Add-FakeDevice -Index $i }
        return $tenant
    }

    function Get-FakeId {
        param([int] $Index, [ValidateSet('Device', 'Object', 'User')] [string] $Kind)
        $suffix = @{ Device = '1111-1111-1111-111111111111'; Object = '2222-2222-2222-222222222222'; User = '3333-3333-3333-333333333333' }[$Kind]
        return ('{0:x8}-{1}' -f $Index, $suffix)
    }

    function Add-FakeDevice {
        param([int] $Index, [string] $State = 'Installed', [int] $DaysSinceSync = 1, [string] $LastModified)
        $tenant = $script:fake.Tenant
        $intuneId = 'intune-{0:D4}' -f $Index
        $deviceId = Get-FakeId $Index Device
        $objectId = Get-FakeId $Index Object
        $userId = Get-FakeId $Index User
        $upn = "user$Index@example.test"
        $tenant.ManagedDevices[$intuneId] = @{
            id = $intuneId; azureADDeviceId = $deviceId; deviceName = "PC$Index"
            userPrincipalName = $upn; userId = $userId
            lastSyncDateTime = [DateTimeOffset]::UtcNow.AddDays(-$DaysSinceSync).ToString('o')
        }
        $tenant.EntraDevices[$deviceId] = $objectId
        $tenant.Objects[$objectId] = @{ Type = '#microsoft.graph.device'; DeviceId = $deviceId; DisplayName = "PC$Index" }
        $tenant.Objects[$userId] = @{ Type = '#microsoft.graph.user'; UserPrincipalName = $upn }
        if (-not $LastModified) { $LastModified = '2026-01-{0:D2}T00:00:00Z' -f $Index }
        $tenant.ReportRows.Add(@($intuneId, "PC$Index", $upn, $State, $LastModified))
    }

    function Edit-FakeReportState {
        param([int] $Index, [string] $State)
        $intuneId = 'intune-{0:D4}' -f $Index
        foreach ($row in $script:fake.Tenant.ReportRows) { if ($row[0] -eq $intuneId) { $row[3] = $State } }
    }

    function Invoke-FakeSync {
        param([hashtable] $Parameters = @{})
        $arguments = @{ JoinAppId = $script:appId; PilotGroupId = $script:pilotId; CommsGroupId = $script:commsId; Force = $true; DeviceLookup = 'Batch' }
        foreach ($key in $Parameters.Keys) { $arguments[$key] = $Parameters[$key] }
        return @(& $script:entryPoint @arguments 3>$null)
    }

    function Get-PilotMemberIndex {
        $tenant = $script:fake.Tenant
        return @($tenant.Groups[$script:pilotId].Members | ForEach-Object { [int]('0x' + $_.Substring(0, 8)) } | Sort-Object)
    }

    function Get-CommsMemberIndex {
        $tenant = $script:fake.Tenant
        return @($tenant.Groups[$script:commsId].Members | Where-Object { $_ -ne $script:ownerId } |
                ForEach-Object { [int]('0x' + $_.Substring(0, 8)) } | Sort-Object)
    }
}

Describe 'Sync-EucPilotGroup reconciliation' {
    Context 'first-come-first-served adds within the cap' {
        It 'adds the earliest installers up to MemberCap and mirrors their primary users to comms' {
            Initialize-FakeTenant -DeviceCount 3 | Out-Null
            $output = Invoke-FakeSync @{ MemberCap = 2 }
            Get-PilotMemberIndex | Should -Be @(1, 2)
            Get-CommsMemberIndex | Should -Be @(1, 2)
            ($output -join "`n") | Should -Match 'deferred by cap 1'
        }

        It 'is idempotent: a second run makes no writes' {
            $tenant = Initialize-FakeTenant -DeviceCount 3
            Invoke-FakeSync @{ MemberCap = 2 } | Out-Null
            $tenant.Writes.Clear()
            Invoke-FakeSync @{ MemberCap = 2 } | Out-Null
            $tenant.Writes.Count | Should -Be 0
        }

        It 'orders by install time independent of host culture' {
            Initialize-FakeTenant -DeviceCount 0 | Out-Null
            # Day-13+ dates fail a current-culture parse in en-US/de-DE ambiguity cases.
            Add-FakeDevice -Index 1 -LastModified '2026-10-13T09:00:00Z'
            Add-FakeDevice -Index 2 -LastModified '2026-03-10T09:00:00Z'
            $original = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
                Invoke-FakeSync @{ MemberCap = 1 } | Out-Null
            }
            finally { [Threading.Thread]::CurrentThread.CurrentCulture = $original }
            Get-PilotMemberIndex | Should -Be @(2)
        }
    }

    Context 'opt-out, hold, and inactivity' {
        It 'removes opted-out devices and their users, but never comms owners' {
            Initialize-FakeTenant -DeviceCount 2 | Out-Null
            Invoke-FakeSync | Out-Null
            Edit-FakeReportState -Index 1 -State 'Not Installed'
            Invoke-FakeSync | Out-Null
            Get-PilotMemberIndex | Should -Be @(2)
            Get-CommsMemberIndex | Should -Be @(2)
            $script:fake.Tenant.Groups[$script:commsId].Members | Should -Contain $script:ownerId
        }

        It 'holds a pending member in place and does not add a pending non-member' {
            Initialize-FakeTenant -DeviceCount 2 | Out-Null
            Invoke-FakeSync | Out-Null
            Edit-FakeReportState -Index 1 -State 'Pending Install'
            Add-FakeDevice -Index 3 -State 'Pending Install'
            Invoke-FakeSync | Out-Null
            Get-PilotMemberIndex | Should -Be @(1, 2)
        }

        It 'removes an inactive member so its slot goes to the next active installer' {
            $tenant = Initialize-FakeTenant -DeviceCount 3
            Invoke-FakeSync @{ MemberCap = 2 } | Out-Null
            $tenant.ManagedDevices['intune-0001'].lastSyncDateTime = [DateTimeOffset]::UtcNow.AddDays(-60).ToString('o')
            $output = Invoke-FakeSync @{ MemberCap = 2; ActiveWithinDays = 30 }
            Get-PilotMemberIndex | Should -Be @(2, 3)
            ($output -join "`n") | Should -Match 'INACTIVE'
        }

        It 'keeps inactive devices when ActiveWithinDays is 0' {
            $tenant = Initialize-FakeTenant -DeviceCount 1
            $tenant.ManagedDevices['intune-0001'].lastSyncDateTime = '0001-01-01T00:00:00Z'
            Invoke-FakeSync @{ ActiveWithinDays = 0 } | Out-Null
            Get-PilotMemberIndex | Should -Be @(1)
        }
    }

    Context 'comms group uses Intune primary user object IDs' {
        It 'makes no per-user lookups' {
            $tenant = Initialize-FakeTenant -DeviceCount 2
            Invoke-FakeSync | Out-Null
            @($tenant.Calls | Where-Object { $_.Uri -match '/users/' }).Count | Should -Be 0
            @($tenant.Calls | Where-Object { $_.Body -and $_.Body.PSObject.Properties['requests'] -and (@($_.Body.requests.url) -match '^/users/') }).Count | Should -Be 0
        }

        It 'skips a deleted primary user without failing or blocking removals' {
            $tenant = Initialize-FakeTenant -DeviceCount 2
            Invoke-FakeSync | Out-Null
            $tenant.Groups[$script:commsId].Members.Remove((Get-FakeId 2 User)) | Out-Null
            $tenant.Objects.Remove((Get-FakeId 2 User))
            Edit-FakeReportState -Index 1 -State 'Not Installed'
            $output = Invoke-FakeSync
            Get-CommsMemberIndex | Should -Be @()
            ($output -join "`n") | Should -Match 'COMMS ADD \(notFound\)'
            ($output -join "`n") | Should -Match 'COMMS REMOVE \(removed\)'
        }

        It 'reads members with $select and $top=999 and no OData cast' {
            $tenant = Initialize-FakeTenant -DeviceCount 1
            Invoke-FakeSync | Out-Null
            $tenant.MemberReads | Should -BeGreaterThan 0
        }
    }

    Context 'WhatIf and confirmation' {
        It 'performs discovery but no writes under -WhatIf' {
            $tenant = Initialize-FakeTenant -DeviceCount 3
            $output = Invoke-FakeSync @{ WhatIf = $true }
            $tenant.Writes.Count | Should -Be 0
            @($tenant.Calls | Where-Object { $_.Method -in @('Delete') -or $_.Uri -match '/\$ref$' }).Count | Should -Be 0
            ($output -join "`n") | Should -Match 'WhatIf run: no changes were made'
            ($output -join "`n") | Should -Match 'Plan: remove 0, add 3'
        }

        It 'declares ConfirmImpact High' {
            $attribute = $script:syncAst.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
            ($attribute.NamedArguments | Where-Object { $_.ArgumentName -eq 'ConfirmImpact' }).Argument.Value | Should -Be 'High'
        }

        It 'refuses an unattended managed-identity run without -Force before reading groups' {
            $tenant = Initialize-FakeTenant -DeviceCount 1
            $tenant.AuthMode = 'ManagedIdentity'
            { & $script:entryPoint -JoinAppId $script:appId -PilotGroupId $script:pilotId 3>$null } | Should -Throw '*must pass -Force*'
            $tenant.Calls.Count | Should -Be 0
        }
    }

    Context 'guards evaluated before any write' {
        It 'aborts when removals exceed MaxRemovals' {
            $tenant = Initialize-FakeTenant -DeviceCount 3
            Invoke-FakeSync | Out-Null
            $tenant.Writes.Clear()
            Edit-FakeReportState -Index 1 -State 'Not Installed'
            Edit-FakeReportState -Index 2 -State 'Not Installed'
            { Invoke-FakeSync @{ MaxRemovals = 1 } } | Should -Throw '*above -MaxRemovals*'
            $tenant.Writes.Count | Should -Be 0
        }

        It 'refuses to empty the group on a zero-row report' {
            $tenant = Initialize-FakeTenant -DeviceCount 1
            Invoke-FakeSync | Out-Null
            $tenant.Writes.Clear()
            $tenant.ReportRows.Clear()
            { Invoke-FakeSync } | Should -Throw '*returned no rows*'
            $tenant.Writes.Count | Should -Be 0
        }
    }

    Context 'install report paging fails closed' {
        It 'reads every page when the service caps top below 500' {
            $tenant = Initialize-FakeTenant -DeviceCount 5
            $tenant.PageCap = 2
            Invoke-FakeSync @{ MemberCap = 0 } | Out-Null
            Get-PilotMemberIndex | Should -Be @(1, 2, 3, 4, 5)
            $skips = @($tenant.Calls | Where-Object { $_.Uri -match '/reports/' } | ForEach-Object { $_.Body.skip })
            $skips | Should -Be @(0, 2, 4)
        }

        It 'stops before any write on <Fault>' -TestCases @(
            @{ Fault = 'missing-total'; Pattern = '*TotalRowCount*' }
            @{ Fault = 'changing-total'; Pattern = '*changed during pagination*' }
            @{ Fault = 'repeat'; Pattern = '*repeated rows*' }
        ) {
            param($Fault, $Pattern)
            $tenant = Initialize-FakeTenant -DeviceCount 3
            $tenant.PageCap = 1
            $tenant.ReportFault = $Fault
            { Invoke-FakeSync } | Should -Throw $Pattern
            $tenant.Writes.Count | Should -Be 0
        }
    }

    Context 'device lookup modes' {
        It 'Bulk lists both directories once and sends no batches' {
            $tenant = Initialize-FakeTenant -DeviceCount 3
            Invoke-FakeSync @{ DeviceLookup = 'Bulk' } | Out-Null
            Get-PilotMemberIndex | Should -Be @(1, 2, 3)
            @($tenant.Calls | Where-Object { $_.Uri.EndsWith('/$batch') }).Count | Should -Be 0
        }

        It 'ReadOnly exports active installed devices without group calls or writes' {
            $tenant = Initialize-FakeTenant -DeviceCount 2
            $tenant.ManagedDevices['intune-0002'].lastSyncDateTime = [DateTimeOffset]::UtcNow.AddDays(-90).ToString('o')
            $out = Join-Path ([IO.Path]::GetTempPath()) ('euc-sync-test-' + [guid]::NewGuid().ToString('N'))
            try {
                & $script:entryPoint -JoinAppId $script:appId -ReadOnly -ExportDirectory $out -Force -DeviceLookup Batch 3>$null | Out-Null
                $tenant.Scopes | Should -Not -Contain 'GroupMember.ReadWrite.All'
                @($tenant.Calls | Where-Object { $_.Uri -match '/groups/' }).Count | Should -Be 0
                $rows = @(Import-Csv -LiteralPath (Get-ChildItem -LiteralPath $out -Filter 'EucPilotCandidates-*.csv').FullName)
                $rows.Count | Should -Be 1
                $rows[0].DeviceName | Should -Be 'PC1'
            }
            finally {
                if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
            }
        }
    }
}

Describe 'Graph layer hardening' {
    BeforeEach {
        $script:graphRoot = 'https://graph.microsoft.com'
        $script:graphBase = "$script:graphRoot/v1.0"
        $script:maxGraphAttempts = 5
        $script:retryableStatusCodes = @(429, 502, 503, 504, 509)
        $script:graphCallCount = 0
        $script:batchSubrequestCount = 0
        $script:graphSession = [pscustomobject]@{ Mode = 'MgGraph'; Token = $null; Account = 'offline' }
        Initialize-FakeTenant -DeviceCount 1 | Out-Null
    }

    It 'retries transient HTTP <Status> honoring Retry-After' -TestCases @(@{ Status = 502 }, @{ Status = 509 }, @{ Status = 429 }) {
        param($Status)
        $script:fake.Tenant.StatusQueue.Enqueue($Status)
        $result = Invoke-PilotGraph -Method Get -Uri "/groups/$($script:pilotId)?`$select=id"
        $result.id | Should -Be $script:pilotId
        $script:fake.Tenant.Sleeps | Should -Be @(7)
    }

    It 'refreshes the managed identity token once on HTTP 401' {
        $script:fake.Tenant.AuthMode = 'ManagedIdentity'
        $script:graphSession = [pscustomobject]@{ Mode = 'ManagedIdentity'; Token = 'expired'; Account = 'mi' }
        $script:fake.Tenant.StatusQueue.Enqueue(401)
        Invoke-PilotGraph -Method Get -Uri "/groups/$($script:pilotId)?`$select=id" | Out-Null
        $script:fake.Tenant.AuthCount | Should -Be 1
        $script:fake.Tenant.StatusQueue.Enqueue(401)
        $script:fake.Tenant.StatusQueue.Enqueue(401)
        { Invoke-PilotGraph -Method Get -Uri "/groups/$($script:pilotId)?`$select=id" } | Should -Throw '*HTTP 401*'
    }

    It 'throws on an unexpected batch response id instead of re-sending $null' {
        $script:fake.Tenant.BatchFault = 'unexpected-id'
        $requests = @(@{ id = '0'; method = 'GET'; url = "/devices(deviceId='$(Get-FakeId 1 Device)')?`$select=id,deviceId" })
        { Invoke-PilotGraphBatch -Requests $requests } | Should -Throw '*unexpected or duplicate response id*'
    }

    It 'retries throttled batch subrequests with the service delay' {
        $script:fake.Tenant.BatchStatusQueue.Enqueue(429)
        $requests = @(@{ id = '0'; method = 'GET'; url = "/devices(deviceId='$(Get-FakeId 1 Device)')?`$select=id,deviceId" })
        $results = Invoke-PilotGraphBatch -Requests $requests
        $results['0'].Status | Should -Be 200
        $script:fake.Tenant.Sleeps | Should -Be @(3)
    }

    It 'parses Retry-After as delta seconds or HTTP-date' {
        ConvertFrom-PilotRetryAfter '12' | Should -Be 12
        ConvertFrom-PilotRetryAfter '' | Should -Be 0
        ConvertFrom-PilotRetryAfter 'garbage' | Should -Be 0
        $httpDate = [DateTimeOffset]::UtcNow.AddSeconds(30).ToString('r', [Globalization.CultureInfo]::InvariantCulture)
        ConvertFrom-PilotRetryAfter $httpDate | Should -BeGreaterThan 25
        ConvertFrom-PilotRetryAfter ([DateTimeOffset]::UtcNow.AddSeconds(-30).ToString('r', [Globalization.CultureInfo]::InvariantCulture)) | Should -Be 0
    }

    It 'parses timestamps culture-invariantly from strings and DateTime' {
        $original = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-GB')
            (ConvertTo-PilotTimestamp '2026-10-03T14:00:00Z').Month | Should -Be 10
            (ConvertTo-PilotTimestamp ([DateTime]::new(2026, 10, 3, 14, 0, 0, [DateTimeKind]::Utc))).Month | Should -Be 10
            ConvertTo-PilotTimestamp '0001-01-01T00:00:00Z' | Should -Be ([DateTimeOffset]::MinValue)
            ConvertTo-PilotTimestamp $null | Should -Be ([DateTimeOffset]::MinValue)
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $original }
    }

    It 'maps membership change outcomes' {
        Invoke-PilotMembershipChange -Action Add -GroupId $script:pilotId -ObjectId (Get-FakeId 1 Object) | Should -Be 'added'
        Invoke-PilotMembershipChange -Action Add -GroupId $script:pilotId -ObjectId (Get-FakeId 1 Object) | Should -Be 'absorbed'
        Invoke-PilotMembershipChange -Action Add -GroupId $script:pilotId -ObjectId 'deleted-object' | Should -Be 'notFound'
        Invoke-PilotMembershipChange -Action Remove -GroupId $script:pilotId -ObjectId (Get-FakeId 1 Object) | Should -Be 'removed'
        Invoke-PilotMembershipChange -Action Remove -GroupId $script:pilotId -ObjectId (Get-FakeId 1 Object) | Should -Be 'absorbed'
    }
}

Describe 'Connect-PilotGraph output contract' {
    It 'returns exactly one session object with -DeviceCode' {
        function Import-PilotAuthModule { }
        function Connect-MgGraph { param([string[]] $Scopes, [switch] $NoWelcome, [string] $TenantId, [switch] $UseDeviceCode) $null = $Scopes, $NoWelcome, $TenantId, $UseDeviceCode }
        function Get-MgContext { [pscustomobject]@{ Account = 'admin@example.test'; Scopes = @('Device.Read.All') } }
        $saved = @($env:IDENTITY_ENDPOINT, $env:IDENTITY_HEADER)
        try {
            $env:IDENTITY_ENDPOINT = $null
            $env:IDENTITY_HEADER = $null
            # Re-define the real function in this scope; the suite-level fake would shadow it.
            . ([scriptblock]::Create(($script:syncAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Connect-PilotGraph' }, $false) | Select-Object -First 1).Extent.Text))
            $result = @(Connect-PilotGraph -Scopes @('Device.Read.All') -DeviceCode 4>$null)
            $result.Count | Should -Be 1
            $result[0].Mode | Should -Be 'MgGraph'
        }
        finally {
            $env:IDENTITY_ENDPOINT = $saved[0]
            $env:IDENTITY_HEADER = $saved[1]
        }
    }
}
