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
$script:ForceGroupRefresh = $ForceGroupRefresh
$script:UserDataPath = $null
$script:LogPath = $null
$script:StatePath = $null
$script:GroupCachePath = $null
$script:HealthPath = $null
if (-not $ValidateOnly) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. The mapper must run in an interactive user context.'
    }
    $script:UserDataPath = Join-Path $env:LOCALAPPDATA $script:ProductName
    $script:LogPath = Join-Path $script:UserDataPath 'DriveMapper.log'
    $script:StatePath = Join-Path $script:UserDataPath 'State.json'
    $script:GroupCachePath = Join-Path $script:UserDataPath 'GroupCache.json'
    $script:HealthPath = Join-Path $script:UserDataPath 'Health.json'
}

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

function Test-JsonInteger {
    param([AllowNull()] $Value)

    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Test-JsonNumber {
    param([AllowNull()] $Value)

    return (Test-JsonInteger $Value) -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]
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

function ConvertTo-NormalizedUncPath {
    param([Parameter(Mandatory)] [string] $Path)
    return ([Environment]::ExpandEnvironmentVariables($Path)).Trim().TrimEnd('\')
}

function Test-DnsFqdn {
    param([Parameter(Mandatory)] [string] $Name)

    if ($Name.Length -gt 253 -or $Name -notmatch '\.' -or $Name.StartsWith('.') -or $Name.EndsWith('.')) {
        return $false
    }
    $parsedAddress = $null
    if ([Net.IPAddress]::TryParse($Name, [ref]$parsedAddress)) { return $false }
    foreach ($label in $Name.Split('.')) {
        if ($label.Length -lt 1 -or $label.Length -gt 63 -or
            $label -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$') {
            return $false
        }
    }
    return $true
}

function ConvertFrom-AdDistinguishedName {
    param([Parameter(Mandatory)] [string] $DistinguishedName)

    $domainComponents = @([regex]::Matches($DistinguishedName, '(?i)(?:^|,)DC=([^,]+)') |
        ForEach-Object { $_.Groups[1].Value })
    if ($domainComponents.Count -eq 0) { return $null }
    return $domainComponents -join '.'
}

function Get-CurrentUserContext {
    $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $upn = $null
    try {
        $upnClaim = @($windowsIdentity.UserClaims |
            Where-Object { $_.Type -match '(?i)(/upn$|nameidentifier$)' -and $_.Value -match '@' } |
            Select-Object -First 1)
        if ($upnClaim.Count -eq 1) { $upn = [string]$upnClaim[0].Value }
    }
    catch { Write-Verbose "Could not read UPN claims: $($_.Exception.Message)" }

    if ([string]::IsNullOrWhiteSpace($upn)) {
        $whoAmIPath = Join-Path $env:SystemRoot 'System32\whoami.exe'
        if (Test-Path -LiteralPath $whoAmIPath -PathType Leaf) {
            $candidate = @(& $whoAmIPath /upn 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $candidate.Count -eq 1 -and [string]$candidate[0] -match '@') {
                $upn = ([string]$candidate[0]).Trim()
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($upn) -and -not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN) -and
        (Test-DnsFqdn $env:USERDNSDOMAIN)) {
        $upn = '{0}@{1}' -f $env:USERNAME, $env:USERDNSDOMAIN
    }

    return [pscustomobject]@{
        Sid = if ($null -ne $windowsIdentity.User) { $windowsIdentity.User.Value } else { $null }
        SamAccountName = [string]$env:USERNAME
        UserPrincipalName = if ([string]::IsNullOrWhiteSpace($upn)) { $null } else { $upn.Trim() }
    }
}

function Test-UserEligibility {
    param(
        [Parameter(Mandatory)] $Configuration,
        [Parameter(Mandatory)] $CurrentUser
    )

    if ([string]::IsNullOrWhiteSpace([string]$CurrentUser.UserPrincipalName)) {
        Write-MapperLog 'The current user UPN could not be determined; no mappings will be changed.' 'WARN'
        return $false
    }
    $separatorIndex = $CurrentUser.UserPrincipalName.LastIndexOf('@')
    $suffix = $CurrentUser.UserPrincipalName.Substring($separatorIndex + 1)
    $allowedSuffixes = @(ConvertTo-StringArray (Get-PropertyValue $Configuration 'AllowedUserUpnSuffixes' @()))
    if (@($allowedSuffixes | Where-Object { $_ -ieq $suffix }).Count -eq 0) {
        Write-MapperLog "User '$($CurrentUser.UserPrincipalName)' is outside the configured UPN scope; no mappings will be changed."
        return $false
    }
    return $true
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

    if ($configuration -isnot [pscustomobject]) { throw 'Mappings.json must contain one JSON object.' }
    $requiredConfigurationProperties = @(
        'SchemaVersion',
        'ConfigurationVersion',
        'AllowedUserUpnSuffixes',
        'AdDomainFqdn',
        'DirectoryServer',
        'DirectorySearchMode',
        'GroupCacheHours',
        'TcpConnectTimeoutMilliseconds',
        'RequireFqdnForFileServers',
        'AdoptExistingMappings',
        'Mappings'
    )
    foreach ($propertyName in $requiredConfigurationProperties) {
        if ($null -eq $configuration.PSObject.Properties[$propertyName]) {
            throw "Mappings.json is missing required property '$propertyName'."
        }
    }

    $schemaVersion = Get-PropertyValue $configuration 'SchemaVersion'
    if (-not (Test-JsonInteger $schemaVersion) -or [int64]$schemaVersion -ne 1) {
        throw 'Mappings.json SchemaVersion must be 1.'
    }
    if ((Get-PropertyValue $configuration 'ConfigurationVersion') -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $configuration 'ConfigurationVersion'))) {
        throw 'ConfigurationVersion must be a nonempty string.'
    }
    if ((Get-PropertyValue $configuration 'RequireFqdnForFileServers') -isnot [bool]) {
        throw 'RequireFqdnForFileServers must be a JSON Boolean.'
    }
    if ((Get-PropertyValue $configuration 'AdoptExistingMappings') -isnot [bool]) {
        throw 'AdoptExistingMappings must be a JSON Boolean.'
    }
    if ($configuration.PSObject.Properties['Mappings'].Value -isnot [array]) {
        throw 'Mappings must be a JSON array.'
    }

    $seenLetters = @{}
    foreach ($mapping in @(Get-PropertyValue $configuration 'Mappings' @())) {
        if ($mapping -isnot [pscustomobject]) { throw 'Every Mappings entry must be a JSON object.' }
        $requiredMappingProperties = @(
            'Enabled',
            'DriveLetter',
            'Path',
            'Label',
            'RequiredGroupSidsAny',
            'RequiredGroupSidsAll',
            'ExcludedGroupSids'
        )
        foreach ($propertyName in $requiredMappingProperties) {
            if ($null -eq $mapping.PSObject.Properties[$propertyName]) {
                throw "A mapping is missing required property '$propertyName'."
            }
        }
        if ((Get-PropertyValue $mapping 'Enabled') -isnot [bool]) {
            throw 'Each mapping Enabled value must be a JSON Boolean.'
        }
        foreach ($propertyName in @('DriveLetter', 'Path', 'Label')) {
            if ((Get-PropertyValue $mapping $propertyName) -isnot [string]) {
                throw "Each mapping $propertyName value must be a JSON string."
            }
        }
        foreach ($propertyName in @('RequiredGroupSidsAny', 'RequiredGroupSidsAll', 'ExcludedGroupSids')) {
            $groupSids = $mapping.PSObject.Properties[$propertyName].Value
            if ($groupSids -isnot [array]) { throw "Each mapping $propertyName value must be a JSON array." }
            foreach ($groupSid in $groupSids) {
                if ($groupSid -isnot [string]) { throw "Each $propertyName entry must be a JSON string." }
                if ($groupSid -notmatch '^S-1-(\d+-)+\d+$') { throw "Mapping contains an invalid group SID: $groupSid" }
            }
        }

        $letter = ([string](Get-PropertyValue $mapping 'DriveLetter' '')).TrimEnd(':').ToUpperInvariant()
        if ($letter -notmatch '^[A-Z]$') { throw "Invalid DriveLetter '$letter'. Use one letter from A through Z." }
        if ([bool](Get-PropertyValue $mapping 'Enabled')) {
            if ($seenLetters.ContainsKey($letter)) { throw "DriveLetter '$letter' appears more than once among enabled mappings." }
            $seenLetters[$letter] = $true
        }

        $path = ConvertTo-NormalizedUncPath ([string](Get-PropertyValue $mapping 'Path' ''))
        $server = Get-UncServer $path
        if ([string]::IsNullOrWhiteSpace($server)) { throw "Mapping $letter has an invalid UNC path: $path" }

        if ([bool](Get-PropertyValue $configuration 'RequireFqdnForFileServers' $true) -and -not (Test-DnsFqdn $server)) {
            throw "Mapping $letter uses invalid or non-FQDN server name '$server'. Use a DNS FQDN or disable RequireFqdnForFileServers."
        }

    }

    $timeoutValue = Get-PropertyValue $configuration 'TcpConnectTimeoutMilliseconds'
    if (-not (Test-JsonInteger $timeoutValue)) {
        throw 'TcpConnectTimeoutMilliseconds must be a JSON integer.'
    }
    $timeout = [int]$timeoutValue
    if ($timeout -lt 250 -or $timeout -gt 30000) {
        throw 'TcpConnectTimeoutMilliseconds must be between 250 and 30000.'
    }

    $cacheHoursValue = Get-PropertyValue $configuration 'GroupCacheHours'
    if (-not (Test-JsonNumber $cacheHoursValue)) { throw 'GroupCacheHours must be a JSON number.' }
    $cacheHours = [double]$cacheHoursValue
    if ($cacheHours -lt 0.25 -or $cacheHours -gt 168) {
        throw 'GroupCacheHours must be between 0.25 and 168.'
    }

    if ((Get-PropertyValue $configuration 'DirectoryServer') -isnot [string] -or
        (Get-PropertyValue $configuration 'AdDomainFqdn') -isnot [string] -or
        (Get-PropertyValue $configuration 'DirectorySearchMode') -isnot [string]) {
        throw 'DirectoryServer, AdDomainFqdn, and DirectorySearchMode must be JSON strings.'
    }
    $directoryServer = ([string](Get-PropertyValue $configuration 'DirectoryServer' '')).Trim()
    if (-not [string]::IsNullOrWhiteSpace($directoryServer) -and -not (Test-DnsFqdn $directoryServer)) {
        throw 'DirectoryServer must be blank or an FQDN.'
    }
    $directorySearchMode = [string](Get-PropertyValue $configuration 'DirectorySearchMode')
    if ($directorySearchMode -notin @('Domain', 'GlobalCatalog')) {
        throw "DirectorySearchMode must be 'Domain' or 'GlobalCatalog'."
    }
    if ($directorySearchMode -eq 'GlobalCatalog' -and [string]::IsNullOrWhiteSpace($directoryServer)) {
        throw 'DirectoryServer must specify a global catalog FQDN when DirectorySearchMode is GlobalCatalog.'
    }

    if ($configuration.PSObject.Properties['AllowedUserUpnSuffixes'].Value -isnot [array]) {
        throw 'AllowedUserUpnSuffixes must be a JSON array.'
    }
    foreach ($suffix in $configuration.PSObject.Properties['AllowedUserUpnSuffixes'].Value) {
        if ($suffix -isnot [string]) { throw 'Every AllowedUserUpnSuffixes entry must be a JSON string.' }
    }
    $allowedUpnSuffixes = @(ConvertTo-StringArray (Get-PropertyValue $configuration 'AllowedUserUpnSuffixes' @()))
    if ($allowedUpnSuffixes.Count -eq 0) {
        throw 'AllowedUserUpnSuffixes must contain at least one permitted user UPN suffix.'
    }
    foreach ($suffix in $allowedUpnSuffixes) {
        if (-not (Test-DnsFqdn $suffix)) { throw "Allowed user UPN suffix '$suffix' is not a DNS FQDN." }
    }

    if (Test-ConfigurationNeedsGroupLookup $configuration) {
        $adDomain = ([string](Get-PropertyValue $configuration 'AdDomainFqdn' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($adDomain) -or -not (Test-DnsFqdn $adDomain)) {
            throw 'AdDomainFqdn must be an AD DNS FQDN when an enabled mapping has group rules.'
        }
    }

    return $configuration
}

function Test-ConfigurationNeedsGroupLookup {
    param([Parameter(Mandatory)] $Configuration)

    foreach ($mapping in @(Get-PropertyValue $Configuration 'Mappings' @())) {
        if (-not [bool](Get-PropertyValue $mapping 'Enabled' $true)) { continue }
        if (@(ConvertTo-StringArray (Get-PropertyValue $mapping 'RequiredGroupSidsAny' @())).Count -gt 0 -or
            @(ConvertTo-StringArray (Get-PropertyValue $mapping 'RequiredGroupSidsAll' @())).Count -gt 0 -or
            @(ConvertTo-StringArray (Get-PropertyValue $mapping 'ExcludedGroupSids' @())).Count -gt 0) {
            return $true
        }
    }
    return $false
}

function Read-GroupCache {
    param(
        [Parameter(Mandatory)] [string] $Domain,
        [Parameter(Mandatory)] [string] $Identity
    )

    if ($script:ForceGroupRefresh -or -not (Test-Path -LiteralPath $script:GroupCachePath -PathType Leaf)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $script:GroupCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string](Get-PropertyValue $cache 'Domain' '') -ine $Domain -or
            [string](Get-PropertyValue $cache 'Identity' '') -ine $Identity) { return $null }
        if ([DateTime](Get-PropertyValue $cache 'ExpiresUtc' ([DateTime]::MinValue)) -le [DateTime]::UtcNow) { return $null }
        return $cache
    }
    catch {
        Write-MapperLog "Ignoring unreadable group cache: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-AdTokenGroupSidSet {
    param(
        [Parameter(Mandatory)] [string] $Domain,
        [string] $DirectoryServer,
        [Parameter(Mandatory)] [ValidateSet('Domain', 'GlobalCatalog')] [string] $DirectorySearchMode,
        [string] $UserPrincipalName,
        [Parameter(Mandatory)] [string] $SamAccountName
    )

    Add-Type -AssemblyName System.DirectoryServices
    $ldapServer = if ([string]::IsNullOrWhiteSpace($DirectoryServer)) { $Domain } else { $DirectoryServer }
    $rootDse = $null
    $searchRoot = $null
    $searcher = $null
    $fallbackRootDse = $null
    $fallbackSearchRoot = $null
    $fallbackSearcher = $null
    $fallbackResults = $null
    $userEntry = $null

    try {
        $rootDse = New-Object DirectoryServices.DirectoryEntry("LDAP://$ldapServer/RootDSE")
        $defaultNamingContext = [string]$rootDse.Properties['defaultNamingContext'][0]
        if ([string]::IsNullOrWhiteSpace($defaultNamingContext)) {
            throw "LDAP server '$ldapServer' did not return defaultNamingContext."
        }
        $defaultDnsDomain = ConvertFrom-AdDistinguishedName $defaultNamingContext
        if ($DirectorySearchMode -eq 'Domain' -and $defaultDnsDomain -ine $Domain) {
            throw "Directory server '$ldapServer' belongs to '$defaultDnsDomain', not configured domain '$Domain'."
        }

        $isGlobalCatalog = [string]$rootDse.Properties['isGlobalCatalogReady'][0] -ieq 'TRUE'
        $rootDomainNamingContext = [string]$rootDse.Properties['rootDomainNamingContext'][0]
        $useGlobalCatalog = $DirectorySearchMode -eq 'GlobalCatalog'
        if ($useGlobalCatalog) {
            if (-not $isGlobalCatalog -or [string]::IsNullOrWhiteSpace($rootDomainNamingContext)) {
                throw "Directory server '$ldapServer' is not a ready global catalog."
            }
            $searchRoot = New-Object DirectoryServices.DirectoryEntry("GC://$ldapServer/$rootDomainNamingContext")
        }
        else {
            $searchRoot = New-Object DirectoryServices.DirectoryEntry("LDAP://$ldapServer/$defaultNamingContext")
        }
        $searcher = New-Object DirectoryServices.DirectorySearcher($searchRoot)
        if (-not [string]::IsNullOrWhiteSpace($UserPrincipalName)) {
            $escapedIdentity = ConvertTo-LdapFilterValue $UserPrincipalName
            $searcher.Filter = "(&(objectCategory=person)(objectClass=user)(userPrincipalName=$escapedIdentity))"
        }
        else {
            $escapedIdentity = ConvertTo-LdapFilterValue $SamAccountName
            $searcher.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$escapedIdentity))"
        }
        $searcher.SearchScope = [DirectoryServices.SearchScope]::Subtree
        $searcher.PageSize = 1
        [void]$searcher.PropertiesToLoad.Add('distinguishedName')
        $result = $searcher.FindOne()
        if ($null -ne $result) {
            $distinguishedName = [string]$result.Properties['distinguishedname'][0]
        }
        elseif (-not [string]::IsNullOrWhiteSpace($UserPrincipalName)) {
            $fallbackRootDse = New-Object DirectoryServices.DirectoryEntry("LDAP://$Domain/RootDSE")
            $fallbackNamingContext = [string]$fallbackRootDse.Properties['defaultNamingContext'][0]
            if ([string]::IsNullOrWhiteSpace($fallbackNamingContext)) {
                throw "AD domain '$Domain' did not return defaultNamingContext."
            }
            if ((ConvertFrom-AdDistinguishedName $fallbackNamingContext) -ine $Domain) {
                throw "AD domain '$Domain' resolved to an unexpected naming context '$fallbackNamingContext'."
            }
            $fallbackSearchRoot = New-Object DirectoryServices.DirectoryEntry("LDAP://$Domain/$fallbackNamingContext")
            $fallbackSearcher = New-Object DirectoryServices.DirectorySearcher($fallbackSearchRoot)
            $escapedSamAccountName = ConvertTo-LdapFilterValue $SamAccountName
            $fallbackSearcher.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$escapedSamAccountName))"
            $fallbackSearcher.SearchScope = [DirectoryServices.SearchScope]::Subtree
            $fallbackSearcher.PageSize = 2
            $fallbackSearcher.SizeLimit = 2
            [void]$fallbackSearcher.PropertiesToLoad.Add('distinguishedName')
            $fallbackResults = $fallbackSearcher.FindAll()
            if ($fallbackResults.Count -ne 1) {
                throw "UPN '$UserPrincipalName' was not found and sAMAccountName '$SamAccountName' was not unique in '$Domain'."
            }
            $distinguishedName = [string]$fallbackResults[0].Properties['distinguishedname'][0]
        }
        else {
            throw "Could not find sAMAccountName '$SamAccountName' in AD domain '$Domain'."
        }

        $resolvedDomain = ConvertFrom-AdDistinguishedName $distinguishedName
        $owningDomain = if ([string]::IsNullOrWhiteSpace($resolvedDomain)) { $Domain } else { $resolvedDomain }
        $userEntry = New-Object DirectoryServices.DirectoryEntry("LDAP://$owningDomain/$distinguishedName")
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
        if ($null -ne $fallbackResults) { $fallbackResults.Dispose() }
        if ($null -ne $fallbackSearcher) { $fallbackSearcher.Dispose() }
        if ($null -ne $fallbackSearchRoot) { $fallbackSearchRoot.Dispose() }
        if ($null -ne $fallbackRootDse) { $fallbackRootDse.Dispose() }
        if ($null -ne $searcher) { $searcher.Dispose() }
        if ($null -ne $searchRoot) { $searchRoot.Dispose() }
        if ($null -ne $rootDse) { $rootDse.Dispose() }
    }
}

function Get-GroupContext {
    param(
        [Parameter(Mandatory)] $Configuration,
        [Parameter(Mandatory)] $CurrentUser
    )

    $domain = ([string](Get-PropertyValue $Configuration 'AdDomainFqdn' '')).Trim()
    if ([string]::IsNullOrWhiteSpace($domain)) {
        Write-MapperLog 'Group-based mappings exist but AdDomainFqdn is empty.' 'WARN'
        return [pscustomobject]@{ Available = $false; Sids = @(); Source = 'Unavailable' }
    }

    $identityKey = if (-not [string]::IsNullOrWhiteSpace([string]$CurrentUser.UserPrincipalName)) {
        [string]$CurrentUser.UserPrincipalName
    }
    else { "$domain\$($CurrentUser.SamAccountName)" }
    $cache = Read-GroupCache -Domain $domain -Identity $identityKey
    if ($null -ne $cache) {
        $cachedSids = @(ConvertTo-StringArray (Get-PropertyValue $cache 'Sids' @()))
        Write-MapperLog "Using cached group membership ($($cachedSids.Count) SIDs)."
        return [pscustomobject]@{ Available = $true; Sids = $cachedSids; Source = 'Cache' }
    }

    try {
        $directoryServer = [string](Get-PropertyValue $Configuration 'DirectoryServer' '')
        $directorySearchMode = [string](Get-PropertyValue $Configuration 'DirectorySearchMode' 'Domain')
        $sids = @(Get-AdTokenGroupSidSet -Domain $domain -DirectoryServer $directoryServer `
            -DirectorySearchMode $directorySearchMode `
            -UserPrincipalName ([string]$CurrentUser.UserPrincipalName) `
            -SamAccountName ([string]$CurrentUser.SamAccountName))
        $cacheHours = [double](Get-PropertyValue $Configuration 'GroupCacheHours' 4)
        $cacheData = [ordered]@{
            Domain = $domain
            Identity = $identityKey
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

    $requiredAny = @(ConvertTo-StringArray (Get-PropertyValue $Mapping 'RequiredGroupSidsAny' @()))
    $requiredAll = @(ConvertTo-StringArray (Get-PropertyValue $Mapping 'RequiredGroupSidsAll' @()))
    $excluded = @(ConvertTo-StringArray (Get-PropertyValue $Mapping 'ExcludedGroupSids' @()))
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
    catch { Write-Verbose "Get-SmbMapping failed for $localPath`: $($_.Exception.Message)" }

    $drive = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    if ($null -eq $drive) { return $null }
    $root = [string]$drive.Root
    if ($root.StartsWith('\\')) {
        return [pscustomobject]@{ Kind = 'Network'; Path = $root; Status = 'Unknown' }
    }
    return [pscustomobject]@{ Kind = 'Local'; Path = $root; Status = 'Available' }
}

function Invoke-NetworkDriveRemoval {
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
    try { Invoke-NetworkDriveLabelUpdate -DriveLetter $DriveLetter -Label $Label }
    catch { Write-MapperLog "Mapped $DriveLetter`: but could not set its label: $($_.Exception.Message)" 'WARN' }
}

function Invoke-NetworkDriveLabelUpdate {
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

function Get-NetworkDriveLabel {
    param([Parameter(Mandatory)] [string] $DriveLetter)

    $networkKey = "HKCU:\Network\$DriveLetter"
    if (-not (Test-Path -LiteralPath $networkKey)) { return $null }
    return Get-ItemPropertyValue -LiteralPath $networkKey -Name '_LabelFromReg' -ErrorAction SilentlyContinue
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

function Save-State {
    param(
        [Parameter(Mandatory)] $Configuration,
        [Parameter(Mandatory)] $OwnedMappings
    )

    $stateData = [ordered]@{
        ConfigurationVersion = [string](Get-PropertyValue $Configuration 'ConfigurationVersion' '')
        UserName = $env:USERNAME
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        ManagedMappings = @($OwnedMappings.ToArray() | Sort-Object DriveLetter)
    }
    Write-JsonFile -InputObject $stateData -Path $script:StatePath
}

function Write-ReconciliationHealth {
    param(
        [Parameter(Mandatory)] [string] $Status,
        [int] $ErrorCount = 0,
        [int] $TransientFailureCount = 0,
        [string] $Message = ''
    )

    $health = [ordered]@{
        Status = $Status
        CheckedUtc = [DateTime]::UtcNow.ToString('o')
        ErrorCount = $ErrorCount
        TransientFailureCount = $TransientFailureCount
        Message = $Message
    }
    Write-JsonFile -InputObject $health -Path $script:HealthPath
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
    $errorCount = 0
    $transientFailureCount = 0

    foreach ($mapping in @(Get-PropertyValue $Configuration 'Mappings' @())) {
        if (-not [bool](Get-PropertyValue $mapping 'Enabled' $true)) { continue }
        $letter = ([string](Get-PropertyValue $mapping 'DriveLetter' '')).TrimEnd(':').ToUpperInvariant()
        $configuredLetters[$letter] = $true
        $desiredPath = ConvertTo-NormalizedUncPath ([string](Get-PropertyValue $mapping 'Path' ''))
        $stateEntry = Get-StateEntry $state $letter
        $entitled = Test-MappingEntitlement -Mapping $mapping -GroupContext $GroupContext

        if ($null -eq $entitled) {
            Write-MapperLog "$letter`: group entitlement is unknown; leaving the mapping unchanged." 'WARN'
            $transientFailureCount++
            continue
        }

        $current = Get-CurrentDrive $letter
        if (-not $entitled) {
            if ($null -ne $stateEntry -and $null -ne $current -and $current.Kind -eq 'Network' -and
                (ConvertTo-NormalizedUncPath $current.Path) -ieq (ConvertTo-NormalizedUncPath ([string]$stateEntry.Path))) {
                try {
                    Invoke-NetworkDriveRemoval $letter
                    Write-MapperLog "Removed $letter`: because the user is no longer entitled."
                }
                catch {
                    Write-MapperLog "Failed to remove $letter`: $($_.Exception.Message)" 'ERROR'
                    $errorCount++
                    continue
                }
            }
            foreach ($entry in @($owned.ToArray())) {
                if ([string]$entry.DriveLetter -ieq $letter) { [void]$owned.Remove($entry) }
            }
            Save-State -Configuration $Configuration -OwnedMappings $owned
            continue
        }

        if ($null -ne $current -and $current.Kind -eq 'Network' -and
            (ConvertTo-NormalizedUncPath $current.Path) -ieq $desiredPath) {
            $stateMatchesCurrent = $null -ne $stateEntry -and
                (ConvertTo-NormalizedUncPath ([string]$stateEntry.Path)) -ieq (ConvertTo-NormalizedUncPath $current.Path)
            if ($stateMatchesCurrent) {
                try { Invoke-NetworkDriveLabelUpdate -DriveLetter $letter -Label ([string](Get-PropertyValue $mapping 'Label' '')) }
                catch { Write-MapperLog "Could not update the $letter`: label: $($_.Exception.Message)" 'WARN' }
                Write-MapperLog "$letter`: is already mapped correctly."
            }
            else {
                if ($null -ne $stateEntry) {
                    foreach ($entry in @($owned.ToArray())) {
                        if ([string]$entry.DriveLetter -ieq $letter) { [void]$owned.Remove($entry) }
                    }
                    Save-State -Configuration $Configuration -OwnedMappings $owned
                    Write-MapperLog "$letter`: discarded stale ownership state."
                }
                if ([bool](Get-PropertyValue $Configuration 'AdoptExistingMappings' $false)) {
                    $owned.Add([pscustomobject]@{ DriveLetter = $letter; Path = $desiredPath })
                    Save-State -Configuration $Configuration -OwnedMappings $owned
                    Write-MapperLog "$letter`: adopted an existing matching mapping."
                }
                else { Write-MapperLog "$letter`: already matches but is not owned; leaving it unmanaged." }
            }
            continue
        }

        $oldPath = $null
        $oldLabel = $null
        if ($null -ne $current) {
            $ownedPathMatches = $null -ne $stateEntry -and $current.Kind -eq 'Network' -and
                (ConvertTo-NormalizedUncPath $current.Path) -ieq (ConvertTo-NormalizedUncPath ([string]$stateEntry.Path))
            if (-not $ownedPathMatches) {
                Write-MapperLog "$letter`: is occupied by an unmanaged $($current.Kind.ToLowerInvariant()) drive '$($current.Path)'; no change made." 'ERROR'
                $errorCount++
                continue
            }
            $oldPath = ConvertTo-NormalizedUncPath $current.Path
            $oldLabel = Get-NetworkDriveLabel $letter
        }

        $server = Get-UncServer $desiredPath
        if (-not (Test-TcpPort -ComputerName $server -Port 445 -TimeoutMilliseconds $timeout)) {
            Write-MapperLog "$letter`: $server`:445 is unavailable; retrying on a later task run." 'WARN'
            $transientFailureCount++
            continue
        }

        if ($null -ne $oldPath) {
            try {
                if (-not (Test-Path -LiteralPath $desiredPath -PathType Container)) {
                    throw "The replacement path '$desiredPath' is not accessible."
                }
                Invoke-NetworkDriveRemoval $letter
            }
            catch {
                Write-MapperLog "Kept the old $letter`: mapping because its replacement is not ready: $($_.Exception.Message)" 'ERROR'
                $errorCount++
                continue
            }
        }

        try { Add-NetworkDrive -DriveLetter $letter -Path $desiredPath -Label ([string](Get-PropertyValue $mapping 'Label' '')) }
        catch {
            Write-MapperLog "Failed to map $letter`: to $desiredPath without stored credentials: $($_.Exception.Message)" 'ERROR'
            $errorCount++
            if ($null -ne $oldPath) {
                try {
                    Add-NetworkDrive -DriveLetter $letter -Path $oldPath -Label $oldLabel
                    Write-MapperLog "Restored the previous $letter`: mapping to $oldPath."
                }
                catch { Write-MapperLog "Failed to restore the previous $letter`: mapping: $($_.Exception.Message)" 'ERROR' }
            }
            continue
        }

        $previousOwnedMappings = @($owned.ToArray())
        foreach ($entry in @($owned.ToArray())) {
            if ([string]$entry.DriveLetter -ieq $letter) { [void]$owned.Remove($entry) }
        }
        $owned.Add([pscustomobject]@{ DriveLetter = $letter; Path = $desiredPath })
        try { Save-State -Configuration $Configuration -OwnedMappings $owned }
        catch {
            $stateFailureMessage = $_.Exception.Message
            $newMappingRemoved = $false
            try {
                Invoke-NetworkDriveRemoval $letter
                $newMappingRemoved = $true
            }
            catch { Write-MapperLog "Could not remove untracked $letter`: mapping after state failure: $($_.Exception.Message)" 'ERROR' }
            if ($newMappingRemoved) {
                $owned.Clear()
                foreach ($entry in $previousOwnedMappings) { $owned.Add($entry) }
                if ($null -ne $oldPath) {
                    try {
                        Add-NetworkDrive -DriveLetter $letter -Path $oldPath -Label $oldLabel
                        Write-MapperLog "Restored the previous $letter`: mapping to $oldPath after state persistence failed."
                    }
                    catch { Write-MapperLog "Failed to restore the previous $letter`: mapping: $($_.Exception.Message)" 'ERROR' }
                }
                Write-MapperLog "Rolled back $letter`: because ownership state could not be persisted: $stateFailureMessage" 'ERROR'
            }
            else {
                Write-MapperLog "Could not roll back $letter`; retaining the new ownership entry in memory: $stateFailureMessage" 'ERROR'
            }
            $errorCount++
            continue
        }
        Write-MapperLog "Mapped $letter`: to $desiredPath."
    }

    # A mapping removed from the configuration is retired only when it still matches the
    # path recorded in state. User-created or subsequently changed mappings are untouched.
    foreach ($entry in @($owned.ToArray())) {
        $letter = [string]$entry.DriveLetter
        if ($configuredLetters.ContainsKey($letter)) { continue }
        $current = Get-CurrentDrive $letter
        if ($null -ne $current -and $current.Kind -eq 'Network' -and
            (ConvertTo-NormalizedUncPath $current.Path) -ieq (ConvertTo-NormalizedUncPath ([string]$entry.Path))) {
            try {
                Invoke-NetworkDriveRemoval $letter
                Write-MapperLog "Removed retired managed mapping $letter`: $($entry.Path)."
            }
            catch {
                Write-MapperLog "Failed to remove retired mapping $letter`: $($_.Exception.Message)" 'ERROR'
                $errorCount++
                continue
            }
        }
        [void]$owned.Remove($entry)
        Save-State -Configuration $Configuration -OwnedMappings $owned
    }

    Save-State -Configuration $Configuration -OwnedMappings $owned
    return [pscustomobject]@{
        ErrorCount = $errorCount
        TransientFailureCount = $transientFailureCount
    }
}

$mutex = $null
$hasMutex = $false
try {
    if ($ValidateOnly) {
        $validationConfiguration = Read-Configuration -Path $ConfigurationPath
        $validationCount = @((Get-PropertyValue $validationConfiguration 'Mappings' @()) |
            Where-Object { [bool](Get-PropertyValue $_ 'Enabled' $true) }).Count
        Write-Output "Configuration is valid: $validationCount enabled mapping(s)."
        return
    }

    if (-not (Test-Path -LiteralPath $script:UserDataPath -PathType Container)) {
        New-Item -Path $script:UserDataPath -ItemType Directory -Force | Out-Null
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
    if (-not $hasMutex) { return }

    Write-MapperLog "Starting mapping reconciliation for $env:USERNAME."
    $configuration = Read-Configuration -Path $ConfigurationPath
    $enabledCount = @((Get-PropertyValue $configuration 'Mappings' @()) | Where-Object { [bool](Get-PropertyValue $_ 'Enabled' $true) }).Count
    Write-MapperLog "Configuration $([string](Get-PropertyValue $configuration 'ConfigurationVersion' 'unversioned')) contains $enabledCount enabled mapping(s)."

    $currentUser = Get-CurrentUserContext
    if (-not (Test-UserEligibility -Configuration $configuration -CurrentUser $currentUser)) {
        Write-ReconciliationHealth -Status 'NotApplicable' -Message 'The current user is outside the configured UPN scope.'
        return
    }

    $groupContext = if (Test-ConfigurationNeedsGroupLookup $configuration) {
        Get-GroupContext -Configuration $configuration -CurrentUser $currentUser
    }
    else { [pscustomobject]@{ Available = $true; Sids = @(); Source = 'NotRequired' } }

    $result = Invoke-Reconciliation -Configuration $configuration -GroupContext $groupContext
    if ($result.ErrorCount -gt 0) {
        $message = "Mapping reconciliation completed with $($result.ErrorCount) non-transient error(s)."
        Write-ReconciliationHealth -Status 'Degraded' -ErrorCount $result.ErrorCount `
            -TransientFailureCount $result.TransientFailureCount -Message $message
        Write-MapperLog $message 'ERROR'
        exit 1
    }
    if ($result.TransientFailureCount -gt 0) {
        $message = "Mapping reconciliation deferred $($result.TransientFailureCount) operation(s) because a dependency is unavailable."
        Write-ReconciliationHealth -Status 'TransientFailure' `
            -TransientFailureCount $result.TransientFailureCount -Message $message
        Write-MapperLog $message 'WARN'
        return
    }

    Write-ReconciliationHealth -Status 'Healthy' -Message 'Mapping reconciliation completed successfully.'
    Write-MapperLog 'Mapping reconciliation completed successfully.'
}
catch {
    if ($ValidateOnly) { throw }
    try { Write-MapperLog "Unhandled failure: $($_.Exception.Message)" 'ERROR' }
    catch { Write-Verbose "Could not write the failure log: $($_.Exception.Message)" }
    try { Write-ReconciliationHealth -Status 'Failed' -ErrorCount 1 -Message $_.Exception.Message }
    catch { Write-Verbose "Could not write health status: $($_.Exception.Message)" }
    Write-Error $_ -ErrorAction Continue
    exit 1
}
finally {
    if ($hasMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
