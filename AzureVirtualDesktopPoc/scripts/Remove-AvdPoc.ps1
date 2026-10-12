#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]{3,32}$')]
    [string]$PocId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateCount(1, 10)]
    [string[]]$ResourceGroupName,

    [string]$HostPoolResourceGroupName,

    [string]$HostPoolName,

    [switch]$RemoveDirectoryRecords,

    [switch]$Execute,

    [string]$ConfirmationText,

    [ValidateRange(5, 120)]
    [int]$WaitMinutes = 30,

    [string]$ReportPath = (Join-Path -Path $PWD -ChildPath 'avd-poc-decommission-report.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $raw = & az @ArgumentList --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($ArgumentList -join ' ')`n$($raw -join [Environment]::NewLine)"
    }

    $text = $raw -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return $text | ConvertFrom-Json -Depth 100
}

function Invoke-AzCli {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $raw = & az @ArgumentList --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($ArgumentList -join ' ')`n$($raw -join [Environment]::NewLine)"
    }
}

function Invoke-GraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept = 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ErrorAction Stop
}

function Get-GraphCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $records = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    while ($nextUri) {
        $response = Invoke-GraphRequest -Method GET -Uri $nextUri -AccessToken $AccessToken
        foreach ($record in @($response.value)) { $records.Add($record) }
        $nextLink = $response.PSObject.Properties['@odata.nextLink']
        $nextUri = if ($nextLink -and $nextLink.Value) { [uri]$nextLink.Value } else { $null }
    }
    return @($records)
}

function New-ArmGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Value)

    $namespaceBytes = ([guid]'11fb06fb-712d-4ddd-98c7-e71bbd588830').ToByteArray()
    [Array]::Reverse($namespaceBytes, 0, 4)
    [Array]::Reverse($namespaceBytes, 4, 2)
    [Array]::Reverse($namespaceBytes, 6, 2)
    $nameBytes = [Text.Encoding]::UTF8.GetBytes(($Value -join '-'))
    $inputBytes = [byte[]]::new($namespaceBytes.Length + $nameBytes.Length)
    [Array]::Copy($namespaceBytes, 0, $inputBytes, 0, $namespaceBytes.Length)
    [Array]::Copy($nameBytes, 0, $inputBytes, $namespaceBytes.Length, $nameBytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($inputBytes) } finally { $sha1.Dispose() }
    $guidBytes = [byte[]]::new(16)
    [Array]::Copy($hash, $guidBytes, 16)
    $guidBytes[6] = ($guidBytes[6] -band 0x0f) -bor 0x50
    $guidBytes[8] = ($guidBytes[8] -band 0x3f) -bor 0x80
    [Array]::Reverse($guidBytes, 0, 4)
    [Array]::Reverse($guidBytes, 4, 2)
    [Array]::Reverse($guidBytes, 6, 2)
    return ([guid]::new($guidBytes)).Guid
}

function Get-SessionInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SessionHost)

    $sessions = [System.Collections.Generic.List[object]]::new()
    $nextUri = "https://management.azure.com$($SessionHost.id)/userSessions?api-version=2024-04-03"
    while ($nextUri) {
        $response = Invoke-AzCliJson -ArgumentList @('rest', '--method', 'GET', '--url', $nextUri)
        foreach ($session in @($response.value)) { $sessions.Add($session) }
        $nextLink = $response.PSObject.Properties['nextLink']
        $nextUri = if ($nextLink -and $nextLink.Value) { [string]$nextLink.Value } else { $null }
    }
    return [ordered]@{
        sessionCount = $sessions.Count
        activeSessionCount = @($sessions | Where-Object { [string]$_.properties.sessionState -ieq 'Active' }).Count
        sessions = @($sessions | ForEach-Object {
            [ordered]@{
                id = $_.id
                name = $_.name
                userPrincipalName = $_.properties.userPrincipalName
                state = $_.properties.sessionState
            }
        })
    }
}

function Get-TagValue {
    param([object]$Tags, [string]$Name)
    if ($null -eq $Tags) { return $null }
    $property = $Tags.PSObject.Properties | Where-Object Name -IEQ $Name | Select-Object -First 1
    if ($null -eq $property) { return $null }
    return [string]$property.Value
}

function Save-Report {
    param([System.Collections.IDictionary]$Value)
    $parent = Split-Path -Parent $ReportPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ReportPath -Encoding utf8
}

$expectedConfirmation = "DELETE $PocId"
if ($Execute -and $ConfirmationText -cne $expectedConfirmation) {
    throw "Execution requires exact confirmation text: $expectedConfirmation"
}
if (($HostPoolName -and -not $HostPoolResourceGroupName) -or
    ($HostPoolResourceGroupName -and -not $HostPoolName)) {
    throw 'HostPoolName and HostPoolResourceGroupName must be supplied together.'
}

$resourceGroups = @($ResourceGroupName | Sort-Object -Unique)
$expectedStagingGroupName = "rg-avd-$($PocId.ToLowerInvariant())-aib-stage"
$expectedPlatformGroupName = "rg-avd-$($PocId.ToLowerInvariant())"
foreach ($name in $resourceGroups) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOfAny([char[]]'*?[]') -ge 0) {
        throw "Unsafe resource-group name: '$name'. Wildcards and empty names are not allowed."
    }
}

$report = [ordered]@{
    schemaVersion = 1
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    mode = if ($Execute) { 'execute' } else { 'plan' }
    pocId = $PocId
    subscriptionId = $SubscriptionId
    directoryRecordRemovalRequested = [bool]$RemoveDirectoryRecords
    resourceGroups = @()
    virtualMachines = @()
    sessionHosts = @()
    sessionSummary = [ordered]@{ sessionHostCount = 0; sessionCount = 0; activeSessionCount = 0 }
    directoryRecords = @()
    subscriptionResources = @()
    result = 'Validating'
    notes = @(
        'MDE inventory records are retained according to Defender retention policy.',
        'Azure DevOps service connections and ServiceNow records are outside Azure resource-group scope and are not deleted.'
    )
}

try {
    $account = Invoke-AzCliJson -ArgumentList @('account', 'show')
    if (-not $account) { throw 'Azure CLI is not authenticated.' }
    Invoke-AzCli -ArgumentList @('account', 'set', '--subscription', $SubscriptionId)
    $account = Invoke-AzCliJson -ArgumentList @('account', 'show')
    if ([string]$account.id -ine $SubscriptionId) {
        throw "Active subscription '$($account.id)' does not match '$SubscriptionId'."
    }
    if ($TenantId -and [string]$account.tenantId -ine $TenantId) {
        throw "Active tenant '$($account.tenantId)' does not match '$TenantId'."
    }

    $vmNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $resourceGroups) {
        $groupExists = Invoke-AzCliJson -ArgumentList @('group', 'exists', '--name', $name, '--subscription', $SubscriptionId)
        if (-not $groupExists) {
            if ($name -cne $expectedStagingGroupName) {
                throw "Required resource group '$name' does not exist; only the exact Image Builder staging group '$expectedStagingGroupName' may already be absent."
            }
            $report.resourceGroups += [ordered]@{
                id = "/subscriptions/$SubscriptionId/resourceGroups/$name"
                name = $name
                exists = $false
                resourceCount = 0
                resources = @()
                validatedTags = $false
                deletionState = 'AlreadyAbsent'
            }
            continue
        }
        $group = Invoke-AzCliJson -ArgumentList @('group', 'show', '--name', $name, '--subscription', $SubscriptionId)
        $managedBy = Get-TagValue -Tags $group.tags -Name 'ManagedBy'
        $tagPocId = Get-TagValue -Tags $group.tags -Name 'PocId'
        if ($managedBy -cne 'AzureVirtualDesktopPoc' -or $tagPocId -cne $PocId) {
            throw "Resource group '$name' failed safety-tag validation. Required: ManagedBy=AzureVirtualDesktopPoc and PocId=$PocId."
        }

        $resources = @(Invoke-AzCliJson -ArgumentList @('resource', 'list', '--resource-group', $name, '--subscription', $SubscriptionId))
        $vms = @(Invoke-AzCliJson -ArgumentList @('vm', 'list', '--resource-group', $name, '--subscription', $SubscriptionId))
        foreach ($vm in $vms) { [void]$vmNames.Add([string]$vm.name) }

        $report.resourceGroups += [ordered]@{
            id = $group.id
            name = $name
            exists = $true
            location = $group.location
            resourceCount = $resources.Count
            resources = @($resources | Select-Object id, name, type, location)
            validatedTags = $true
            deletionState = if ($Execute) { 'Pending' } else { 'Planned' }
        }
    }
    $report.virtualMachines = @($vmNames | Sort-Object)

    if (-not $HostPoolName) {
        $hostPools = @($report.resourceGroups | Where-Object exists | ForEach-Object {
            $groupName = $_.name
            @($_.resources | Where-Object { [string]$_.type -ieq 'Microsoft.DesktopVirtualization/hostPools' } | ForEach-Object {
                [ordered]@{ name = $_.name; resourceGroupName = $groupName }
            })
        })
        if ($hostPools.Count -gt 1) {
            throw 'Multiple host pools were found in the validated groups; specify HostPoolName and HostPoolResourceGroupName explicitly.'
        }
        if ($hostPools.Count -eq 1) {
            $HostPoolName = [string]$hostPools[0].name
            $HostPoolResourceGroupName = [string]$hostPools[0].resourceGroupName
        }
    }
    if ($HostPoolName -and (@($report.resourceGroups | Where-Object exists | ForEach-Object { [string]$_.name }) -inotcontains $HostPoolResourceGroupName)) {
        throw "Host pool '$HostPoolName' is outside the validated resource groups."
    }

    $roleResourceGroup = @($report.resourceGroups | Where-Object {
        $_.exists -and [string]$_.name -ceq $expectedPlatformGroupName
    } | Select-Object -First 1)
    if ($roleResourceGroup.Count -eq 0) {
        $roleResourceGroup = @($report.resourceGroups | Where-Object {
            $_.exists -and @($_.resources | Where-Object { [string]$_.type -ieq 'Microsoft.DesktopVirtualization/hostPools' }).Count -gt 0
        } | Select-Object -First 1)
    }
    if ($roleResourceGroup.Count -eq 0) {
        throw 'Unable to identify the validated platform resource group needed to derive custom-role definition IDs.'
    }
    $subscriptionScope = "/subscriptions/$($SubscriptionId.ToLowerInvariant())"
    $roleSpecifications = @(
        [ordered]@{ name = "AVD POC Image Builder $PocId"; id = New-ArmGuid -Value @($subscriptionScope, $roleResourceGroup[0].name, 'avd-poc-image-builder', $PocId) },
        [ordered]@{ name = "AVD POC Deployment $PocId"; id = New-ArmGuid -Value @($subscriptionScope, $roleResourceGroup[0].name, $PocId, 'avd-deployment') },
        [ordered]@{ name = "AVD POC Readiness $PocId"; id = New-ArmGuid -Value @($subscriptionScope, $roleResourceGroup[0].name, $PocId, 'avd-readiness') },
        [ordered]@{ name = "AVD POC Assignment $PocId"; id = New-ArmGuid -Value @($subscriptionScope, $roleResourceGroup[0].name, $PocId, 'avd-assignment') }
    )
    foreach ($roleSpecification in $roleSpecifications) {
        $roleName = [string]$roleSpecification.name
        $roleDefinitions = @(Invoke-AzCliJson -ArgumentList @(
            'role', 'definition', 'list', '--name', [string]$roleSpecification.id,
            '--custom-role-only', 'true', '--subscription', $SubscriptionId
        ))
        foreach ($role in $roleDefinitions) {
            if ([string]$role.name -ine [string]$roleSpecification.id -or
                [string]$role.roleName -cne $roleName -or [string]$role.roleType -ine 'CustomRole') {
                throw "Role-definition lookup returned an unexpected role for '$roleName'."
            }
            $allowedScopes = @($report.resourceGroups | ForEach-Object { [string]$_.id })
            $outsideScope = @($role.assignableScopes | Where-Object { $allowedScopes -inotcontains [string]$_ })
            if ($outsideScope.Count -gt 0) {
                throw "Refusing to delete role '$roleName' because it is assignable outside the validated POC groups: $($outsideScope -join ', ')"
            }
            $report.subscriptionResources += [ordered]@{
                id = $role.id
                definitionName = $role.name
                expectedDefinitionName = $roleSpecification.id
                name = $role.roleName
                type = 'Microsoft.Authorization/roleDefinitions'
                deletionState = if ($Execute) { 'Pending' } else { 'Planned' }
            }
        }
    }

    if ($HostPoolName) {
        $hostPoolId = "/subscriptions/$SubscriptionId/resourceGroups/$HostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
        $sessionHostResponse = Invoke-AzCliJson -ArgumentList @(
            'rest', '--method', 'GET',
            '--url', "https://management.azure.com$hostPoolId/sessionHosts?api-version=2024-04-03"
        )
        $sessionHosts = @($sessionHostResponse.value)
        $matchedSessionHosts = @($sessionHosts | Where-Object {
            $leafName = ([string]$_.name -split '/')[-1]
            $computerName = ($leafName -split '\.')[0]
            $vmNames.Contains($computerName)
        })
        $report.sessionHosts = @($matchedSessionHosts | ForEach-Object {
            $inventory = Get-SessionInventory -SessionHost $_
            [ordered]@{
                name = $_.name
                id = $_.id
                resourceId = $_.properties.resourceId
                status = $_.properties.status
                allowNewSession = $_.properties.allowNewSession
                intendedAllowNewSession = $false
                drainState = if ($_.properties.allowNewSession) { 'Planned' } else { 'AlreadyDraining' }
                sessionCount = $inventory.sessionCount
                activeSessionCount = $inventory.activeSessionCount
                sessions = $inventory.sessions
            }
        })
        $report.sessionSummary = [ordered]@{
            sessionHostCount = $report.sessionHosts.Count
            sessionCount = @($report.sessionHosts | ForEach-Object { [int]$_.sessionCount } | Measure-Object -Sum).Sum
            activeSessionCount = @($report.sessionHosts | ForEach-Object { [int]$_.activeSessionCount } | Measure-Object -Sum).Sum
        }
    }

    if ($RemoveDirectoryRecords) {
        $token = Invoke-AzCliJson -ArgumentList @('account', 'get-access-token', '--resource', 'https://graph.microsoft.com', '--tenant', [string]$account.tenantId)
        if (-not $token.accessToken) { throw 'Azure CLI did not return a Microsoft Graph access token.' }
        foreach ($vmName in $vmNames) {
            $escapedName = $vmName.Replace("'", "''")
            $deviceFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
            $entraUri = [uri]"https://graph.microsoft.com/v1.0/devices?`$filter=$deviceFilter&`$select=id%2CdisplayName"
            foreach ($record in @(Get-GraphCollection -Uri $entraUri -AccessToken $token.accessToken | Where-Object displayName -CEQ $vmName)) {
                $report.directoryRecords += [ordered]@{
                    service = 'Entra'; id = $record.id; objectId = $record.id; name = $record.displayName
                    action = if ($Execute) { 'Pending' } else { 'Planned' }
                }
            }

            $intuneFilter = [Uri]::EscapeDataString("deviceName eq '$escapedName'")
            $intuneUri = [uri]"https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$intuneFilter&`$select=id%2CdeviceName"
            foreach ($record in @(Get-GraphCollection -Uri $intuneUri -AccessToken $token.accessToken | Where-Object deviceName -CEQ $vmName)) {
                $report.directoryRecords += [ordered]@{
                    service = 'Intune'; id = $record.id; objectId = $record.id; name = $record.deviceName
                    action = if ($Execute) { 'Pending' } else { 'Planned' }
                }
            }
        }
    }

    if (-not $Execute) {
        $report.result = 'PlanComplete'
        Save-Report -Value $report
        Write-Host "Validated decommission plan. No changes were made. Report: $ReportPath"
        return
    }

    foreach ($sessionHost in $report.sessionHosts) {
        $leafName = ([string]$sessionHost.name -split '/')[-1]
        if ($sessionHost.allowNewSession -and $PSCmdlet.ShouldProcess($leafName, "Set drain mode in $HostPoolName")) {
            $body = @{ properties = @{ allowNewSession = $false } } | ConvertTo-Json -Compress
            $bodyPath = Join-Path ([IO.Path]::GetTempPath()) "avd-drain-$([Guid]::NewGuid().ToString('N')).json"
            try {
                $body | Set-Content -LiteralPath $bodyPath -Encoding utf8
                Invoke-AzCli -ArgumentList @(
                    'rest', '--method', 'PATCH', '--url', "https://management.azure.com$($sessionHost.id)?api-version=2024-04-03",
                    '--headers', 'Content-Type=application/json', '--body', "@$bodyPath"
                )
            }
            finally {
                Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
            }
        }
        $sessionHost.drainState = 'Draining'
        $inventory = Get-SessionInventory -SessionHost $sessionHost
        $sessionHost.sessionCount = $inventory.sessionCount
        $sessionHost.activeSessionCount = $inventory.activeSessionCount
        $sessionHost.sessions = $inventory.sessions
    }
    $activeSessionCount = @($report.sessionHosts | ForEach-Object { [int]$_.activeSessionCount } | Measure-Object -Sum).Sum
    $report.sessionSummary = [ordered]@{
        sessionHostCount = $report.sessionHosts.Count
        sessionCount = @($report.sessionHosts | ForEach-Object { [int]$_.sessionCount } | Measure-Object -Sum).Sum
        activeSessionCount = $activeSessionCount
    }
    if ($activeSessionCount -gt 0) {
        Save-Report -Value $report
        throw "Refusing decommission while $activeSessionCount active AVD user session(s) exist on matched session hosts."
    }

    foreach ($vmName in $vmNames) {
        $vmResourceGroup = ($report.resourceGroups | Where-Object {
            @($_.resources | Where-Object {
                [string]$_.name -ieq $vmName -and [string]$_.type -ieq 'Microsoft.Compute/virtualMachines'
            }).Count -eq 1
        } | Select-Object -First 1).name
        if ($vmResourceGroup -and $PSCmdlet.ShouldProcess("$vmResourceGroup/$vmName", 'Deallocate virtual machine')) {
            Invoke-AzCli -ArgumentList @('vm', 'deallocate', '--resource-group', $vmResourceGroup, '--name', $vmName, '--subscription', $SubscriptionId, '--no-wait')
        }
    }

    foreach ($sessionHost in $report.sessionHosts) {
        $leafName = ([string]$sessionHost.name -split '/')[-1]
        if ($PSCmdlet.ShouldProcess($leafName, "Remove session-host record from $HostPoolName")) {
            Invoke-AzCli -ArgumentList @(
                'rest', '--method', 'DELETE',
                '--url', "https://management.azure.com$($sessionHost.id)?api-version=2024-04-03"
            )
        }
    }

    if ($RemoveDirectoryRecords) {
        foreach ($record in $report.directoryRecords) {
            $path = if ($record.service -ceq 'Entra') { 'devices' } else { 'deviceManagement/managedDevices' }
            $objectId = ([guid][string]$record.id).Guid
            if ($PSCmdlet.ShouldProcess("$($record.service) record $($record.id)", 'Delete exact VM directory record')) {
                Invoke-GraphRequest -Method DELETE -Uri ([uri]"https://graph.microsoft.com/v1.0/$path/$objectId") -AccessToken $token.accessToken | Out-Null
                $record.action = 'Deleted'
            }
        }
    }

    foreach ($name in $resourceGroups) {
        $groupReport = $report.resourceGroups | Where-Object { [string]$_.name -ceq $name } | Select-Object -First 1
        if (-not $groupReport.exists) { continue }
        $locks = @(Invoke-AzCliJson -ArgumentList @('lock', 'list', '--resource-group', $name, '--subscription', $SubscriptionId))
        $group = Invoke-AzCliJson -ArgumentList @('group', 'show', '--name', $name, '--subscription', $SubscriptionId)
        $groupId = ([string]$group.id).TrimEnd('/')
        foreach ($lock in $locks) {
            if (-not ([string]$lock.id).StartsWith("$groupId/", [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to remove lock outside validated resource group '$name': $($lock.id)"
            }
            if ($PSCmdlet.ShouldProcess([string]$lock.id, 'Remove resource lock required for POC teardown')) {
                Invoke-AzCli -ArgumentList @('lock', 'delete', '--ids', [string]$lock.id, '--subscription', $SubscriptionId)
            }
        }
        if ($PSCmdlet.ShouldProcess($name, 'Delete validated POC resource group and all contained resources')) {
            Invoke-AzCli -ArgumentList @('group', 'delete', '--name', $name, '--subscription', $SubscriptionId, '--yes', '--no-wait')
        }
    }

    $timeoutSeconds = $WaitMinutes * 60
    foreach ($entry in $report.resourceGroups) {
        if (-not $entry.exists) { continue }
        try {
            Invoke-AzCli -ArgumentList @('group', 'wait', '--name', [string]$entry.name, '--subscription', $SubscriptionId, '--deleted', '--interval', '15', '--timeout', [string]$timeoutSeconds)
            $entry.deletionState = 'Deleted'
        }
        catch {
            $entry.deletionState = 'TimedOutOrFailed'
            throw
        }
    }

    foreach ($entry in $report.subscriptionResources) {
        if ($PSCmdlet.ShouldProcess([string]$entry.id, 'Delete validated POC custom role definition')) {
            $deleted = $false
            foreach ($attempt in 1..12) {
                try {
                    Invoke-AzCli -ArgumentList @(
                        'role', 'definition', 'delete', '--name', [string]$entry.definitionName,
                        '--custom-role-only', 'true', '--subscription', $SubscriptionId
                    )
                    $deleted = $true
                    break
                }
                catch {
                    if ($attempt -eq 12) { throw }
                    Start-Sleep -Seconds 15
                }
            }
            if (-not $deleted) { throw "Unable to remove role definition '$($entry.name)'." }
            $entry.deletionState = 'Deleted'
        }
    }

    $report.result = 'Complete'
}
catch {
    $report.result = 'Failed'
    $report['error'] = $_.Exception.Message
    throw
}
finally {
    $report.completedUtc = [DateTime]::UtcNow.ToString('o')
    Save-Report -Value $report
}

Write-Host "POC decommission complete. Report: $ReportPath"
