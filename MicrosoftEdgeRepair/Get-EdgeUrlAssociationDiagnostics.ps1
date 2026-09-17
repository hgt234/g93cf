#requires -Version 5.1

[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path $env:TEMP (
            'MicrosoftEdgeUrlAssociationDiagnostics-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        )),

    [switch] $PassThru,

    [switch] $IncludeOtherUsers
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-RegistryKeySnapshot {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Win32.RegistryHive] $Hive,

        [Parameter(Mandatory)]
        [Microsoft.Win32.RegistryView] $View,

        [Parameter(Mandatory)]
        [string] $SubKey,

        [string[]] $ValueNames = @(),

        [switch] $AllValues,

        [switch] $IncludeSubKeys
    )

    $snapshot = [ordered]@{
        Hive    = $Hive.ToString()
        View    = $View.ToString()
        SubKey  = $SubKey
        Exists  = $false
        Values  = [ordered]@{}
        SubKeys = @()
        Error   = $null
    }
    $baseKey = $null
    $key = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
        $key = $baseKey.OpenSubKey($SubKey)
        if ($null -eq $key) {
            return [pscustomobject]$snapshot
        }

        $snapshot.Exists = $true
        $names = if ($AllValues) { @($key.GetValueNames()) } else { @($ValueNames) }
        foreach ($name in $names) {
            $displayName = if ([string]::IsNullOrEmpty($name)) { '(Default)' } else { $name }
            $snapshot.Values[$displayName] = $key.GetValue(
                $name,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        }
        if ($IncludeSubKeys) {
            $snapshot.SubKeys = @($key.GetSubKeyNames())
        }
    }
    catch {
        $snapshot.Error = $_.Exception.Message
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }

    return [pscustomobject]$snapshot
}

function Get-CommandTarget {
    param([AllowNull()] [object] $Command)

    $commandText = [string]$Command
    if ([string]::IsNullOrWhiteSpace($commandText)) {
        return [pscustomobject]@{ Path = $null; Exists = $false; ParsingStatus = 'Empty' }
    }

    $trimmedCommand = $commandText.Trim()
    $path = $null
    $parsingStatus = 'Unrecognized'
    if ($trimmedCommand.StartsWith('"')) {
        $match = [regex]::Match($trimmedCommand, '^"([^"]+)"')
        if ($match.Success) {
            $path = $match.Groups[1].Value
            $parsingStatus = 'QuotedPath'
        }
    }
    else {
        $match = [regex]::Match($trimmedCommand, '^(.*?\.exe)(?:\s|$)', 'IgnoreCase')
        if ($match.Success) {
            $path = $match.Groups[1].Value
            $parsingStatus = if ([IO.Path]::IsPathRooted($path)) { 'UnquotedPath' } else { 'BareExecutable' }
        }
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        return [pscustomobject]@{ Path = $null; Exists = $false; ParsingStatus = $parsingStatus }
    }

    $path = [Environment]::ExpandEnvironmentVariables($path)
    if (-not [IO.Path]::IsPathRooted($path)) {
        $resolvedCommand = Get-Command -Name $path -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $resolvedCommand) {
            $path = $resolvedCommand.Source
            $parsingStatus = 'ResolvedBareExecutable'
        }
    }
    return [pscustomobject]@{
        Path          = $path
        Exists        = Test-Path -LiteralPath $path -PathType Leaf
        ParsingStatus = $parsingStatus
    }
}

function Get-AssociationApiResult {
    param([Parameter(Mandatory)] [string] $Protocol)

    $queryTypes = [ordered]@{
        Command         = 1
        Executable      = 2
        FriendlyAppName = 4
        DelegateExecute = 18
        ProgId          = 20
    }
    $values = [ordered]@{}

    foreach ($entry in $queryTypes.GetEnumerator()) {
        # IS_PROTOCOL makes the shell resolve the affected user's URL default.
        [uint32] $flags = 0x00001020 # ASSOCF_IS_PROTOCOL | ASSOCF_NOTRUNCATE
        [uint32] $length = 0
        $sizeHresult = [EdgeUrlAssociation.NativeMethods]::AssocQueryString(
            $flags,
            [uint32]$entry.Value,
            $Protocol,
            'open',
            $null,
            [ref]$length
        )
        if ($length -eq 0) { $length = 4096 }
        $buffer = New-Object System.Text.StringBuilder ([int]$length)
        $hresult = [EdgeUrlAssociation.NativeMethods]::AssocQueryString(
            $flags,
            [uint32]$entry.Value,
            $Protocol,
            'open',
            $buffer,
            [ref]$length
        )
        $values[$entry.Key] = [pscustomobject]@{
            SizeQueryHResult = ('0x{0:X8}' -f $sizeHresult)
            HResult          = ('0x{0:X8}' -f $hresult)
            Value            = if ($hresult -eq 0) { $buffer.ToString() } else { $null }
        }
    }

    $commandTarget = Get-CommandTarget -Command $values.Command.Value
    $apiExecutableTarget = Get-CommandTarget -Command $values.Executable.Value
    return [pscustomobject]@{
        Protocol                = $Protocol
        Command                 = $values.Command
        Executable              = $values.Executable
        FriendlyAppName         = $values.FriendlyAppName
        DelegateExecute         = $values.DelegateExecute
        ProgId                  = $values.ProgId
        CommandExecutable       = $commandTarget.Path
        CommandExecutableExists = $commandTarget.Exists
        CommandParsingStatus    = $commandTarget.ParsingStatus
        ApiExecutableExists     = $apiExecutableTarget.Exists
    }
}

function Get-RegisteredApplicationCapabilities {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Win32.RegistryHive] $Hive,

        [Parameter(Mandatory)]
        [Microsoft.Win32.RegistryView] $View
    )

    $registered = Get-RegistryKeySnapshot -Hive $Hive -View $View `
        -SubKey 'SOFTWARE\RegisteredApplications' -AllValues
    if (-not $registered.Exists) { return @() }

    return @(
        foreach ($entry in $registered.Values.GetEnumerator()) {
            $capabilitiesPath = [string]$entry.Value
            if ([string]::IsNullOrWhiteSpace($capabilitiesPath)) { continue }
            $urlAssociations = Get-RegistryKeySnapshot -Hive $Hive -View $View `
                -SubKey "$capabilitiesPath\URLAssociations" -ValueNames @('http', 'https')
            if ($urlAssociations.Exists -and
                (-not [string]::IsNullOrWhiteSpace([string]$urlAssociations.Values.http) -or
                    -not [string]::IsNullOrWhiteSpace([string]$urlAssociations.Values.https))) {
                [pscustomobject]@{
                    Hive             = $Hive.ToString()
                    View             = $View.ToString()
                    Application      = [string]$entry.Key
                    CapabilitiesPath = $capabilitiesPath
                    UrlAssociations  = $urlAssociations
                }
            }
        }
    )
}

function Get-UserChoiceSnapshot {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Win32.RegistryHive] $Hive,

        [string] $Sid,

        [Parameter(Mandatory)]
        [string] $Protocol
    )

    $relativePath = "Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$Protocol\UserChoice"
    $subKey = if ($Hive -eq [Microsoft.Win32.RegistryHive]::Users) {
        "$Sid\$relativePath"
    }
    else {
        $relativePath
    }
    $snapshot = Get-RegistryKeySnapshot -Hive $Hive -View Registry64 -SubKey $subKey `
        -ValueNames @('ProgId', 'Hash')

    return [pscustomobject]@{
        Sid      = $Sid
        Protocol = $Protocol
        Exists   = $snapshot.Exists
        ProgId   = $snapshot.Values.ProgId
        Hash     = $snapshot.Values.Hash
        Error    = $snapshot.Error
    }
}

function Get-LoadedUserSids {
    $baseKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::Users,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        return @($baseKey.GetSubKeyNames() | Where-Object { $_ -match '^S-1-5-21-(?:\d+-){3}\d+$' })
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Get-EdgeFileSnapshots {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($basePath in @(
            [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
            [Environment]::GetEnvironmentVariable('ProgramW6432'),
            [Environment]::GetEnvironmentVariable('ProgramFiles'))) {
        if (-not [string]::IsNullOrWhiteSpace($basePath)) {
            $paths.Add((Join-Path $basePath 'Microsoft\Edge\Application\msedge.exe'))
        }
    }

    return @(
        foreach ($path in @($paths | Select-Object -Unique)) {
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            $version = $null
            $signatureStatus = $null
            if ($exists) {
                try { $version = (Get-Item -LiteralPath $path).VersionInfo.FileVersion } catch {}
                try { $signatureStatus = (Get-AuthenticodeSignature -LiteralPath $path).Status.ToString() } catch {}
            }
            [pscustomobject]@{
                Path            = $path
                Exists          = $exists
                Version         = $version
                SignatureStatus = $signatureStatus
            }
        }
    )
}

if (-not ('EdgeUrlAssociation.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace EdgeUrlAssociation
{
    public static class NativeMethods
    {
        [DllImport("Shlwapi.dll", CharSet = CharSet.Unicode)]
        public static extern int AssocQueryString(
            uint flags,
            uint associationString,
            string association,
            string extra,
            StringBuilder output,
            ref uint outputLength);
    }
}
'@
}

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $activeUser = $null
    $operatingSystem = $null
    $profiles = @()
    try { $activeUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName } catch {}
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $operatingSystem = [pscustomobject]@{
            Caption        = $os.Caption
            Version        = $os.Version
            BuildNumber    = $os.BuildNumber
            OSArchitecture = $os.OSArchitecture
        }
    }
    catch {}
    if ($IncludeOtherUsers) {
        try {
            $profiles = @(Get-CimInstance -ClassName Win32_UserProfile |
                    Select-Object SID, LocalPath, Loaded, Special)
        }
        catch {}
    }

    $protocols = @('http', 'https')
    $currentUserChoices = @(
        foreach ($protocol in $protocols) {
            Get-UserChoiceSnapshot -Hive CurrentUser -Sid $identity.User.Value -Protocol $protocol
        }
    )

    $loadedUserChoices = @()
    if ($IncludeOtherUsers) {
        $loadedUserChoices = @(
            foreach ($sid in @(Get-LoadedUserSids)) {
                foreach ($protocol in $protocols) {
                    Get-UserChoiceSnapshot -Hive Users -Sid $sid -Protocol $protocol
                }
            }
        )
    }

    $currentUserProtocolClasses = @(
        foreach ($protocol in $protocols) {
            $protocolKey = Get-RegistryKeySnapshot -Hive CurrentUser -View Registry64 `
                -SubKey "Software\Classes\$protocol" -ValueNames @('', 'URL Protocol')
            $commandKey = Get-RegistryKeySnapshot -Hive CurrentUser -View Registry64 `
                -SubKey "Software\Classes\$protocol\shell\open\command" `
                -ValueNames @('', 'DelegateExecute')
            $target = Get-CommandTarget -Command $commandKey.Values.'(Default)'
            [pscustomobject]@{
                Protocol                = $protocol
                ProtocolKey             = $protocolKey
                OpenCommandKey          = $commandKey
                CommandExecutable       = $target.Path
                CommandExecutableExists = $target.Exists
                CommandParsingStatus    = $target.ParsingStatus
            }
        }
    )

    $mergedProtocolClasses = @(
        foreach ($view in @('Registry64', 'Registry32')) {
            foreach ($protocol in $protocols) {
                $protocolKey = Get-RegistryKeySnapshot -Hive ClassesRoot -View $view `
                    -SubKey $protocol -ValueNames @('', 'URL Protocol')
                $commandKey = Get-RegistryKeySnapshot -Hive ClassesRoot -View $view `
                    -SubKey "$protocol\shell\open\command" -ValueNames @('', 'DelegateExecute')
                $target = Get-CommandTarget -Command $commandKey.Values.'(Default)'
                [pscustomobject]@{
                    View                    = $view
                    Protocol                = $protocol
                    ProtocolKey             = $protocolKey
                    OpenCommandKey          = $commandKey
                    CommandExecutable       = $target.Path
                    CommandExecutableExists = $target.Exists
                    CommandParsingStatus    = $target.ParsingStatus
                }
            }
        }
    )

    $machineProtocolClasses = @(
        foreach ($view in @('Registry64', 'Registry32')) {
            foreach ($protocol in $protocols) {
                $protocolKey = Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                    -SubKey "SOFTWARE\Classes\$protocol" -ValueNames @('', 'URL Protocol')
                $commandKey = Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                    -SubKey "SOFTWARE\Classes\$protocol\shell\open\command" `
                    -ValueNames @('', 'DelegateExecute')
                $target = Get-CommandTarget -Command $commandKey.Values.'(Default)'
                [pscustomobject]@{
                    View                    = $view
                    Protocol                = $protocol
                    ProtocolKey             = $protocolKey
                    OpenCommandKey          = $commandKey
                    CommandExecutable       = $target.Path
                    CommandExecutableExists = $target.Exists
                    CommandParsingStatus    = $target.ParsingStatus
                }
            }
        }
    )

    $progIds = @(
        'MSEdgeHTM'
        $currentUserChoices | ForEach-Object { $_.ProgId }
        $loadedUserChoices | ForEach-Object { $_.ProgId }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
    $progIdCommands = @(
        foreach ($view in @('Registry64', 'Registry32')) {
            foreach ($progId in $progIds) {
                $commandKey = Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                    -SubKey "SOFTWARE\Classes\$progId\shell\open\command" `
                    -ValueNames @('', 'DelegateExecute')
                $target = Get-CommandTarget -Command $commandKey.Values.'(Default)'
                [pscustomobject]@{
                    View                    = $view
                    ProgId                  = $progId
                    OpenCommandKey          = $commandKey
                    CommandExecutable       = $target.Path
                    CommandExecutableExists = $target.Exists
                    CommandParsingStatus    = $target.ParsingStatus
                }
            }
        }
    )

    $currentUserProgIdCommands = @(
        foreach ($progId in $progIds) {
            $commandKey = Get-RegistryKeySnapshot -Hive CurrentUser -View Registry64 `
                -SubKey "Software\Classes\$progId\shell\open\command" `
                -ValueNames @('', 'DelegateExecute')
            $target = Get-CommandTarget -Command $commandKey.Values.'(Default)'
            [pscustomobject]@{
                ProgId                  = $progId
                OpenCommandKey          = $commandKey
                CommandExecutable       = $target.Path
                CommandExecutableExists = $target.Exists
                CommandParsingStatus    = $target.ParsingStatus
            }
        }
    )

    $mergedProgIdCommands = @(
        foreach ($view in @('Registry64', 'Registry32')) {
            foreach ($progId in $progIds) {
                $commandKey = Get-RegistryKeySnapshot -Hive ClassesRoot -View $view `
                    -SubKey "$progId\shell\open\command" -ValueNames @('', 'DelegateExecute')
                $target = Get-CommandTarget -Command $commandKey.Values.'(Default)'
                [pscustomobject]@{
                    View                    = $view
                    ProgId                  = $progId
                    OpenCommandKey          = $commandKey
                    CommandExecutable       = $target.Path
                    CommandExecutableExists = $target.Exists
                    CommandParsingStatus    = $target.ParsingStatus
                }
            }
        }
    )

    $loadedUserProgIdCommands = @()
    if ($IncludeOtherUsers) {
        $loadedUserProgIdCommands = @(
            foreach ($choice in $loadedUserChoices) {
                if ([string]::IsNullOrWhiteSpace([string]$choice.ProgId)) { continue }
                $commandKey = Get-RegistryKeySnapshot -Hive Users -View Registry64 `
                    -SubKey "$($choice.Sid)\Software\Classes\$($choice.ProgId)\shell\open\command" `
                    -ValueNames @('', 'DelegateExecute')
                $target = Get-CommandTarget -Command $commandKey.Values.'(Default)'
                [pscustomobject]@{
                    Sid                     = $choice.Sid
                    ProgId                  = $choice.ProgId
                    OpenCommandKey          = $commandKey
                    CommandExecutable       = $target.Path
                    CommandExecutableExists = $target.Exists
                    CommandParsingStatus    = $target.ParsingStatus
                }
            }
        )
    }

    $registration = @(
        foreach ($view in @('Registry64', 'Registry32')) {
            Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                -SubKey 'SOFTWARE\RegisteredApplications' -AllValues
            Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                -SubKey 'SOFTWARE\Clients\StartMenuInternet' -ValueNames @('') -IncludeSubKeys
            Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                -SubKey 'SOFTWARE\Clients\StartMenuInternet\Microsoft Edge\Capabilities\URLAssociations' `
                -ValueNames @('http', 'https')
            Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' `
                -ValueNames @('', 'Path')
            Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                -SubKey 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' `
                -AllValues
        }
        Get-RegistryKeySnapshot -Hive CurrentUser -View Registry64 `
            -SubKey 'SOFTWARE\RegisteredApplications' -AllValues
        Get-RegistryKeySnapshot -Hive CurrentUser -View Registry64 `
            -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' `
            -ValueNames @('', 'Path')
    )

    $registeredCapabilities = @(
        foreach ($view in @('Registry64', 'Registry32')) {
            Get-RegisteredApplicationCapabilities -Hive LocalMachine -View $view
        }
        Get-RegisteredApplicationCapabilities -Hive CurrentUser -View Registry64
    )

    $policies = @(
        foreach ($view in @('Registry64', 'Registry32')) {
            Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                -SubKey 'SOFTWARE\Policies\Microsoft\Windows\System' `
                -ValueNames @('DefaultAssociationsConfiguration')
            Get-RegistryKeySnapshot -Hive LocalMachine -View $view `
                -SubKey 'SOFTWARE\Microsoft\PolicyManager\current\device\ApplicationDefaults' `
                -AllValues
        }
    )

    $associationApi = @(
        foreach ($protocol in $protocols) {
            Get-AssociationApiResult -Protocol $protocol
        }
    )

    $report = [pscustomobject][ordered]@{
        SchemaVersion         = 1
        CollectedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName          = $env:COMPUTERNAME
        ExecutionContext      = [pscustomobject]@{
            UserName       = $identity.Name
            Sid            = $identity.User.Value
            ActiveUser     = $activeUser
            Is64BitProcess = [Environment]::Is64BitProcess
            Is64BitOS      = [Environment]::Is64BitOperatingSystem
        }
        OperatingSystem       = $operatingSystem
        AssociationApi        = $associationApi
        CurrentUserChoices    = $currentUserChoices
        LoadedUserChoices     = $loadedUserChoices
        CurrentUserProtocolClasses = $currentUserProtocolClasses
        MergedProtocolClasses = $mergedProtocolClasses
        MachineProtocolClasses = $machineProtocolClasses
        CurrentUserProgIdCommands = $currentUserProgIdCommands
        MergedProgIdCommands  = $mergedProgIdCommands
        LoadedUserProgIdCommands = $loadedUserProgIdCommands
        ProgIdCommands        = $progIdCommands
        EdgeRegistration      = $registration
        RegisteredApplicationCapabilities = $registeredCapabilities
        AssociationPolicies   = $policies
        EdgeExecutables       = @(Get-EdgeFileSnapshots)
        UserProfiles          = if ($IncludeOtherUsers) { $profiles } else { @() }
    }

    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Path $fullOutputPath -Parent
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        $null = New-Item -Path $outputDirectory -ItemType Directory -Force
    }
    $json = $report | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($fullOutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    Write-Output ("Diagnostic report: {0}" -f $fullOutputPath)
    Write-Output ("Execution context: {0} ({1})" -f $identity.Name, $identity.User.Value)
    foreach ($result in $associationApi) {
        Write-Output ("{0}: ProgId={1}; Executable={2}; Exists={3}; CommandHRESULT={4}" -f
            $result.Protocol,
            $result.ProgId.Value,
            $result.Executable.Value,
            $result.ApiExecutableExists,
            $result.Command.HResult)
    }

    if ($PassThru) {
        Write-Output $report
    }
    exit 0
}
catch {
    Write-Output ("Unable to collect Edge URL association diagnostics: {0}" -f $_.Exception.Message)
    exit 1
}
