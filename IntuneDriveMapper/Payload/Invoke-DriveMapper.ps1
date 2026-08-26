#requires -Version 5.1

<#
.SYNOPSIS
Reconciles centrally managed SMB drive mappings for the interactive user.

.DESCRIPTION
Reads Mappings.json beside this script, resolves nested on-premises AD group membership
with the current user's Kerberos credentials, and adds/removes only mappings owned by this
engine. Group membership is cached to avoid repeated tokenGroups queries.

No credentials are collected or stored. When VPN, DNS, AD, or a file server is unavailable,
the affected mapping is left unchanged and the scheduled task retries later.
#>

[CmdletBinding()]
param(
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot 'Mappings.json'),
    [switch] $ForceGroupRefresh,
    [switch] $ValidateOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:ProductName = 'ManagedDriveMapper'
$script:UserDataPath = Join-Path $env:LOCALAPPDATA $script:ProductName
$script:LogPath = Join-Path $script:UserDataPath 'DriveMapper.log'
$script:StatePath = Join-Path $script:UserDataPath 'State.json'
$script:GroupCachePath = Join-Path $script:UserDataPath 'GroupCache.json'

function Get-PropertyValue {
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Write-MapperLog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )

    if (-not (Test-Path -LiteralPath $script:UserDataPath -PathType Container)) {
        New-Item -Path $script:UserDataPath -ItemType Directory -Force | Out-Null
    }

    if ((Test-Path -LiteralPath $script:LogPath) -and
        (Get-Item -LiteralPath $script:LogPath).Length -gt 2097152) {
        $oldLog = "$($script:LogPath).old"
        Move-Item -LiteralPath $script:LogPath -Destination $oldLog -Force
    }

    $line = '{0} [{1}] {2}' -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    if ($ValidateOnly -or $VerbosePreference -eq 'Continue') { Write-Verbose $line }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )

    $temporaryPath = "$Path.tmp"
    $InputObject | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function ConvertTo-StringArray {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return @() }
    return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertTo-LdapFilterValue {
    param([Parameter(Mandatory)] [string] $Value)

    $builder = New-Object Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        switch ([int][char]$character) {
            0      { [void]$builder.Append('\00') }
            40     { [void]$builder.Append('\28') }
            41     { [void]$builder.Append('\29') }
            42     { [void]$builder.Append('\2a') }
            92     { [void]$builder.Append('\5c') }
            default { [void]$builder.Append($character) }
        }
    }
    return $builder.ToString()
}

function Normalize-UncPath {
    param([Parameter(Mandatory)] [string] $Path)
    return ([Environment]::ExpandEnvironmentVariables($Path)).Trim().TrimEnd('\')
}

function Get-UncServer {
    param([Parameter(Mandatory)] [string] $Path)
    if ($Path -match '^\\\\([^\\]+)\\[^\\]+') { return $Matches[1] }
    return $null
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [int] $TimeoutMilliseconds
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($result)
        return $true
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Read-Configuration {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    try { $configuration = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Configuration is not valid JSON: $($_.Exception.Message)" }

    if ([int](Get-PropertyValue $configuration 'SchemaVersion' 0) -ne 1) {
        throw 'Mappings.json SchemaVersion must be 1.'
    }

    $seenLetters = @{}
    foreach ($mapping in @(Get-PropertyValue $configuration 'Mappings' @())) {
        if (-not [bool](Get-PropertyValue $mapping 'Enabled' $true)) { continue }

        $letter = ([string](Get-PropertyValue $mapping 'DriveLetter' '')).TrimEnd(':').ToUpperInvariant()
        if ($letter -notmatch '^[A-Z]$') { throw "Invalid DriveLetter '$letter'. Use one letter from A through Z." }
        if ($seenLetters.ContainsKey($letter)) { throw "DriveLetter '$letter' appears more than once among enabled mappings." }
        $seenLetters[$letter] = $true

        $path = Normalize-UncPath ([string](Get-PropertyValue $mapping 'Path' ''))
        $server = Get-UncServer $path
        if ([string]::IsNullOrWhiteSpace($server)) { throw "Mapping $letter has an invalid UNC path: $path" }

        if ([bool](Get-PropertyValue $configuration 'RequireFqdnForFileServers' $true) -and $server -notmatch '\.') {
            throw "Mapping $letter uses short server name '$server'. Use its FQDN or disable RequireFqdnForFileServers."
        }

        foreach ($sid in @(
            (ConvertTo-StringArray (Get-PropertyValue $mapping 'RequiredGroupSidsAny' @())) +
            (ConvertTo-StringArray (Get-PropertyValue $mapping 'RequiredGroupSidsAll' @())) +
            (ConvertTo-StringArray (Get-PropertyValue $mapping 'ExcludedGroupSids' @()))
        )) {
            if ($sid -notmatch '^S-1-(\d+-)+\d+$') { throw "Mapping $letter contains an invalid group SID: $sid" }
        }
    }

    $timeout = [int](Get-PropertyValue $configuration 'TcpConnectTimeoutMilliseconds' 3000)
    if ($timeout -lt 250 -or $timeout -gt 30000) {
        throw 'TcpConnectTimeoutMilliseconds must be between 250 and 30000.'
    }

    $cacheHours = [double](Get-PropertyValue $configuration 'GroupCacheHours' 4)
    if ($cacheHours -lt 0.25 -or $cacheHours -gt 168) {
        throw 'GroupCacheHours must be between 0.25 and 168.'
    }

    $directoryServer = ([string](Get-PropertyValue $configuration 'DirectoryServer' '')).Trim()
    if (-not [string]::IsNullOrWhiteSpace($directoryServer) -and $directoryServer -notmatch '\.') {
        throw 'DirectoryServer must be blank or an FQDN.'
    }

    if (Test-ConfigurationNeedsGroups $configuration) {
        $adDomain = ([string](Get-PropertyValue $configuration 'AdDomainFqdn' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($adDomain) -or $adDomain -notmatch '\.') {
            throw 'AdDomainFqdn must be an AD DNS FQDN when an enabled mapping has group rules.'
        }
    }

    return $configuration
}

function Test-ConfigurationNeedsGroups {
    param([Parameter(Mandatory)] $Configuration)

    foreach ($mapping in @(Get-PropertyValue $Configuration 'Mappings' @())) {
        if (-not [bool](Get-PropertyValue $mapping 'Enabled' $true)) { continue }
        if ((ConvertTo-StringArray (Get-PropertyValue $mapping 'RequiredGroupSidsAny' @())).Count -gt 0 -or
            (ConvertTo-StringArray (Get-PropertyValue $mapping 'RequiredGroupSidsAll' @())).Count -gt 0 -or
            (ConvertTo-StringArray (Get-PropertyValue $mapping 'ExcludedGroupSids' @())).Count -gt 0) {
            return $true
        }
    }
    return $false
}

function Read-GroupCache {
    param(
        [Parameter(Mandatory)] [string] $Domain,
        [Parameter(Mandatory)] [string] $UserName
    )

    if ($ForceGroupRefresh -or -not (Test-Path -LiteralPath $script:GroupCachePath -PathType Leaf)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $script:GroupCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-PropertyValue $cache 'Domain' '') -ine $Domain -or
            [string](Get-PropertyValue $cache 'UserName' '') -ine $UserName) { return $null }
        if ([DateTime](Get-PropertyValue $cache 'ExpiresUtc' ([DateTime]::MinValue)) -le [DateTime]::UtcNow) { return $null }
        return $cache
    }
    catch {
        Write-MapperLog "Ignoring unreadable group cache: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-AdTokenGroupSids {
    param(
        [Parameter(Mandatory)] [string] $Domain,
        [string] $DirectoryServer,
        [Parameter(Mandatory)] [string] $UserName
    )

    Add-Type -AssemblyName System.DirectoryServices
    $ldapServer = if ([string]::IsNullOrWhiteSpace($DirectoryServer)) { $Domain } else { $DirectoryServer }
    $rootDse = $null
    $searchRoot = $null
    $searcher = $null
    $userEntry = $null

    try {
        $rootDse = New-Object DirectoryServices.DirectoryEntry("LDAP://$ldapServer/RootDSE")
        $defaultNamingContext = [string]$rootDse.Properties['defaultNamingContext'][0]
        if ([string]::IsNullOrWhiteSpace($defaultNamingContext)) {
            throw "LDAP server '$ldapServer' did not return defaultNamingContext."
        }

        $searchRoot = New-Object DirectoryServices.DirectoryEntry("LDAP://$ldapServer/$defaultNamingContext")
        $searcher = New-Object DirectoryServices.DirectorySearcher($searchRoot)
        $escapedUserName = ConvertTo-LdapFilterValue $UserName
        $searcher.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$escapedUserName))"
        $searcher.SearchScope = [DirectoryServices.SearchScope]::Subtree
        $searcher.PageSize = 1
        [void]$searcher.PropertiesToLoad.Add('distinguishedName')
        $result = $searcher.FindOne()
        if ($null -eq $result) { throw "Could not find sAMAccountName '$UserName' in $Domain." }

        $userEntry = $result.GetDirectoryEntry()
        $userEntry.RefreshCache(@('objectSid', 'tokenGroups'))

        $sids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($sidBytes in @($userEntry.Properties['tokenGroups'])) {
            if ($null -eq $sidBytes) { continue }
            $sid = New-Object Security.Principal.SecurityIdentifier($sidBytes, 0)
            [void]$sids.Add($sid.Value)
        }
        foreach ($sidBytes in @($userEntry.Properties['objectSid'])) {
            if ($null -eq $sidBytes) { continue }
            $sid = New-Object Security.Principal.SecurityIdentifier($sidBytes, 0)
            [void]$sids.Add($sid.Value)
        }

        return @($sids)
    }
    finally {
        if ($null -ne $userEntry) { $userEntry.Dispose() }
        if ($null -ne $searcher) { $searcher.Dispose() }
        if ($null -ne $searchRoot) { $searchRoot.Dispose() }
        if ($null -ne $rootDse) { $rootDse.Dispose() }
    }
}

function Get-GroupContext {
    param([Parameter(Mandatory)] $Configuration)

    $domain = ([string](Get-PropertyValue $Configuration 'AdDomainFqdn' '')).Trim()
    if ([string]::IsNullOrWhiteSpace($domain)) {
        Write-MapperLog 'Group-based mappings exist but AdDomainFqdn is empty.' 'WARN'
        return [pscustomobject]@{ Available = $false; Sids = @(); Source = 'Unavailable' }
    }

    $cache = Read-GroupCache -Domain $domain -UserName $env:USERNAME
    if ($null -ne $cache) {
        $cachedSids = ConvertTo-StringArray (Get-PropertyValue $cache 'Sids' @())
        Write-MapperLog "Using cached group membership ($($cachedSids.Count) SIDs)."
        return [pscustomobject]@{ Available = $true; Sids = $cachedSids; Source = 'Cache' }
    }

    try {
        $directoryServer = [string](Get-PropertyValue $Configuration 'DirectoryServer' '')
        $sids = @(Get-AdTokenGroupSids -Domain $domain -DirectoryServer $directoryServer -UserName $env:USERNAME)
        $cacheHours = [double](Get-PropertyValue $Configuration 'GroupCacheHours' 4)
        $cacheData = [ordered]@{
            Domain = $domain
            UserName = $env:USERNAME
            RefreshedUtc = [DateTime]::UtcNow.ToString('o')
            ExpiresUtc = [DateTime]::UtcNow.AddHours($cacheHours).ToString('o')
            Sids = @($sids | Sort-Object -Unique)
        }
        Write-JsonFile -InputObject $cacheData -Path $script:GroupCachePath
        Write-MapperLog "Refreshed AD group membership ($($sids.Count) SIDs)."
        return [pscustomobject]@{ Available = $true; Sids = $sids; Source = 'AD' }
    }
    catch {
        Write-MapperLog "AD group lookup unavailable; group-dependent mappings will remain unchanged. $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{ Available = $false; Sids = @(); Source = 'Unavailable' }
    }
}

function Test-MappingEntitlement {
    param(
        [Parameter(Mandatory)] $Mapping,
        [Parameter(Mandatory)] $GroupContext
    )

    $requiredAny = ConvertTo-StringArray (Get-PropertyValue $Mapping 'RequiredGroupSidsAny' @())
    $requiredAll = ConvertTo-StringArray (Get-PropertyValue $Mapping 'RequiredGroupSidsAll' @())
    $excluded = ConvertTo-StringArray (Get-PropertyValue $Mapping 'ExcludedGroupSids' @())
    $hasGroupRules = $requiredAny.Count -gt 0 -or $requiredAll.Count -gt 0 -or $excluded.Count -gt 0

    if ($hasGroupRules -and -not $GroupContext.Available) { return $null }

    $membership = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @($GroupContext.Sids)) { [void]$membership.Add([string]$sid) }

    if ($requiredAny.Count -gt 0) {
        $anyMatch = $false
        foreach ($sid in $requiredAny) { if ($membership.Contains($sid)) { $anyMatch = $true; break } }
        if (-not $anyMatch) { return $false }
    }
    foreach ($sid in $requiredAll) { if (-not $membership.Contains($sid)) { return $false } }
    foreach ($sid in $excluded) { if ($membership.Contains($sid)) { return $false } }
    return $true
}

function Get-CurrentDrive {
    param([Parameter(Mandatory)] [string] $DriveLetter)

    $localPath = "$DriveLetter`:"
    try {
        $mapping = Get-SmbMapping -LocalPath $localPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $mapping) {
            return [pscustomobject]@{ Kind = 'Network'; Path = [string]$mapping.RemotePath; Status = [string]$mapping.Status }
        }
    }
    catch { }

    $drive = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($null -eq $drive) { return $null }
    $root = [string]$drive.Root
    if ($root.StartsWith('\\')) {
        return [pscustomobject]@{ Kind = 'Network'; Path = $root; Status = 'Unknown' }
    }
    return [pscustomobject]@{ Kind = 'Local'; Path = $root; Status = 'Available' }
}

function Remove-NetworkDrive {
    param([Parameter(Mandatory)] [string] $DriveLetter)

    $localPath = "$DriveLetter`:"
    try {
        Remove-SmbMapping -LocalPath $localPath -UpdateProfile -Force -ErrorAction Stop
        return
    }
    catch {
        & net.exe use $localPath '/delete' '/y' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not remove mapping $localPath." }
    }
}

function Add-NetworkDrive {
    param(
        [Parameter(Mandatory)] [string] $DriveLetter,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Label
    )

    New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $Path -Scope Global -Persist -ErrorAction Stop | Out-Null
    Set-NetworkDriveLabel -DriveLetter $DriveLetter -Label $Label
}

function Set-NetworkDriveLabel {
    param(
        [Parameter(Mandatory)] [string] $DriveLetter,
        [string] $Label
    )

    $networkKey = "HKCU:\Network\$DriveLetter"
    if (Test-Path -LiteralPath $networkKey) {
        if (-not [string]::IsNullOrWhiteSpace($Label)) {
            New-ItemProperty -Path $networkKey -Name '_LabelFromReg' -Value $Label -PropertyType String -Force | Out-Null
        }
        else {
            Remove-ItemProperty -Path $networkKey -Name '_LabelFromReg' -ErrorAction SilentlyContinue
        }
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        return [pscustomobject]@{ ManagedMappings = @() }
    }
    try { return Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Write-MapperLog "Ignoring unreadable state file: $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{ ManagedMappings = @() }
    }
}

function Get-StateEntry {
    param($State, [string] $DriveLetter)
    return @(Get-PropertyValue $State 'ManagedMappings' @()) |
        Where-Object { [string](Get-PropertyValue $_ 'DriveLetter' '') -ieq $DriveLetter } |
        Select-Object -First 1
}

function Invoke-Reconciliation {
    param(
        [Parameter(Mandatory)] $Configuration,
        [Parameter(Mandatory)] $GroupContext
    )

    $state = Read-State
    $owned = New-Object Collections.Generic.List[object]
    foreach ($entry in @(Get-PropertyValue $state 'ManagedMappings' @())) { $owned.Add($entry) }
    $configuredLetters = @{}
    $timeout = [int](Get-PropertyValue $Configuration 'TcpConnectTimeoutMilliseconds' 3000)

    foreach ($mapping in @(Get-PropertyValue $Configuration 'Mappings' @())) {
        if (-not [bool](Get-PropertyValue $mapping 'Enabled' $true)) { continue }
        $letter = ([string](Get-PropertyValue $mapping 'DriveLetter' '')).TrimEnd(':').ToUpperInvariant()
        $configuredLetters[$letter] = $true
        $desiredPath = Normalize-UncPath ([string](Get-PropertyValue $mapping 'Path' ''))
        $stateEntry = Get-StateEntry $state $letter
        $entitled = Test-MappingEntitlement -Mapping $mapping -GroupContext $GroupContext

        if ($null -eq $entitled) {
            Write-MapperLog "$letter`: group entitlement is unknown; leaving the mapping unchanged." 'WARN'
            continue
        }

        $current = Get-CurrentDrive $letter
        if (-not $entitled) {
            if ($null -ne $stateEntry -and $null -ne $current -and $current.Kind -eq 'Network' -and
                (Normalize-UncPath $current.Path) -ieq (Normalize-UncPath ([string]$stateEntry.Path))) {
                try {
                    Remove-NetworkDrive $letter
                    Write-MapperLog "Removed $letter`: because the user is no longer entitled."
                }
                catch { Write-MapperLog "Failed to remove $letter`: $($_.Exception.Message)" 'ERROR'; continue }
            }
            foreach ($entry in @($owned.ToArray())) {
                if ([string]$entry.DriveLetter -ieq $letter) { [void]$owned.Remove($entry) }
            }
            continue
        }

        if ($null -ne $current -and $current.Kind -eq 'Network' -and
            (Normalize-UncPath $current.Path) -ieq $desiredPath) {
            if ($null -ne $stateEntry) {
                Set-NetworkDriveLabel -DriveLetter $letter -Label ([string](Get-PropertyValue $mapping 'Label' ''))
                if ((Normalize-UncPath ([string]$stateEntry.Path)) -ine $desiredPath) {
                    foreach ($entry in @($owned.ToArray())) {
                        if ([string]$entry.DriveLetter -ieq $letter) { [void]$owned.Remove($entry) }
                    }
                    $owned.Add([pscustomobject]@{ DriveLetter = $letter; Path = $desiredPath })
                }
                Write-MapperLog "$letter`: is already mapped correctly."
            }
            elseif ([bool](Get-PropertyValue $Configuration 'AdoptExistingMappings' $false)) {
                $newEntry = [pscustomobject]@{ DriveLetter = $letter; Path = $desiredPath }
                $owned.Add($newEntry)
                Write-MapperLog "$letter`: adopted an existing matching mapping."
            }
            else { Write-MapperLog "$letter`: already matches but is not owned; leaving it unmanaged." }
            continue
        }

        if ($null -ne $current) {
            $ownedPathMatches = $null -ne $stateEntry -and $current.Kind -eq 'Network' -and
                (Normalize-UncPath $current.Path) -ieq (Normalize-UncPath ([string]$stateEntry.Path))
            if (-not $ownedPathMatches) {
                Write-MapperLog "$letter`: is occupied by an unmanaged $($current.Kind.ToLowerInvariant()) drive '$($current.Path)'; no change made." 'ERROR'
                continue
            }
            try { Remove-NetworkDrive $letter }
            catch { Write-MapperLog "Failed to replace the old $letter`: mapping: $($_.Exception.Message)" 'ERROR'; continue }
        }

        $server = Get-UncServer $desiredPath
        if (-not (Test-TcpPort -ComputerName $server -Port 445 -TimeoutMilliseconds $timeout)) {
            Write-MapperLog "$letter`: $server`:445 is unavailable; retrying on a later task run." 'WARN'
            continue
        }

        try {
            Add-NetworkDrive -DriveLetter $letter -Path $desiredPath -Label ([string](Get-PropertyValue $mapping 'Label' ''))
            foreach ($entry in @($owned.ToArray())) {
                if ([string]$entry.DriveLetter -ieq $letter) { [void]$owned.Remove($entry) }
            }
            $owned.Add([pscustomobject]@{ DriveLetter = $letter; Path = $desiredPath })
            Write-MapperLog "Mapped $letter`: to $desiredPath."
        }
        catch {
            Write-MapperLog "Failed to map $letter`: to $desiredPath without stored credentials: $($_.Exception.Message)" 'ERROR'
        }
    }

    # A mapping removed from the configuration is retired only when it still matches the
    # path recorded in state. User-created or subsequently changed mappings are untouched.
    foreach ($entry in @($owned.ToArray())) {
        $letter = [string]$entry.DriveLetter
        if ($configuredLetters.ContainsKey($letter)) { continue }
        $current = Get-CurrentDrive $letter
        if ($null -ne $current -and $current.Kind -eq 'Network' -and
            (Normalize-UncPath $current.Path) -ieq (Normalize-UncPath ([string]$entry.Path))) {
            try {
                Remove-NetworkDrive $letter
                Write-MapperLog "Removed retired managed mapping $letter`: $($entry.Path)."
            }
            catch { Write-MapperLog "Failed to remove retired mapping $letter`: $($_.Exception.Message)" 'ERROR'; continue }
        }
        [void]$owned.Remove($entry)
    }

    $stateData = [ordered]@{
        ConfigurationVersion = [string](Get-PropertyValue $Configuration 'ConfigurationVersion' '')
        UserName = $env:USERNAME
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        ManagedMappings = @($owned.ToArray() | Sort-Object DriveLetter)
    }
    Write-JsonFile -InputObject $stateData -Path $script:StatePath
}

$mutex = $null
$hasMutex = $false
try {
    if (-not (Test-Path -LiteralPath $script:UserDataPath -PathType Container)) {
        New-Item -Path $script:UserDataPath -ItemType Directory -Force | Out-Null
    }

    if ($ValidateOnly) {
        $validationConfiguration = Read-Configuration -Path $ConfigurationPath
        $validationCount = @((Get-PropertyValue $validationConfiguration 'Mappings' @()) |
            Where-Object { [bool](Get-PropertyValue $_ 'Enabled' $true) }).Count
        Write-Output "Configuration is valid: $validationCount enabled mapping(s)."
        exit 0
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $identitySid = if ($null -ne $identity.User) { $identity.User.Value } else { $env:USERNAME }
    }
    catch {
        # The fallback also makes ValidateOnly useful from PowerShell on non-Windows build hosts.
        $identitySid = "$env:USERDOMAIN-$env:USERNAME"
    }
    $safeIdentity = $identitySid -replace '[^A-Za-z0-9-]', '_'
    $mutex = New-Object Threading.Mutex($false, "Local\ManagedDriveMapper-$safeIdentity")
    $hasMutex = $mutex.WaitOne(0, $false)
    if (-not $hasMutex) { exit 0 }

    Write-MapperLog "Starting mapping reconciliation for $env:USERNAME."
    $configuration = Read-Configuration -Path $ConfigurationPath
    $enabledCount = @((Get-PropertyValue $configuration 'Mappings' @()) | Where-Object { [bool](Get-PropertyValue $_ 'Enabled' $true) }).Count
    Write-MapperLog "Configuration $([string](Get-PropertyValue $configuration 'ConfigurationVersion' 'unversioned')) contains $enabledCount enabled mapping(s)."

    $groupContext = if (Test-ConfigurationNeedsGroups $configuration) {
        Get-GroupContext $configuration
    }
    else { [pscustomobject]@{ Available = $true; Sids = @(); Source = 'NotRequired' } }

    Invoke-Reconciliation -Configuration $configuration -GroupContext $groupContext
    Write-MapperLog 'Mapping reconciliation completed.'
    exit 0
}
catch {
    try { Write-MapperLog "Unhandled failure: $($_.Exception.Message)" 'ERROR' } catch { }
    Write-Error $_
    exit 1
}
finally {
    if ($hasMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
