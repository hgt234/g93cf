#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$productName = 'ManagedDriveMapper'
$taskName = 'Managed Drive Mapper'
$installPath = Join-Path $env:ProgramData $productName
$payloadPath = Join-Path $PSScriptRoot 'Payload'
$requiredFiles = @(
    'Invoke-DriveMapper.ps1',
    'Mappings.json',
    'Register-DriveMapperTask.ps1',
    'Test-DriveMapperTask.ps1',
    'Version.json'
)

foreach ($file in $requiredFiles) {
    $source = Join-Path $payloadPath $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Package payload is incomplete. Missing: $source"
    }
}

& (Join-Path $payloadPath 'Invoke-DriveMapper.ps1') `
    -ConfigurationPath (Join-Path $payloadPath 'Mappings.json') -ValidateOnly | Out-Null

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask -and $existingTask.State -eq 'Running') {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $installPath) {
    $installDirectory = Get-Item -LiteralPath $installPath -Force
    if (-not $installDirectory.PSIsContainer) {
        throw "Install path exists but is not a directory: $installPath"
    }
    if (($installDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to install through a reparse point: $installPath"
    }
    $nestedReparsePoint = Get-ChildItem -LiteralPath $installPath -Force -Recurse |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($null -ne $nestedReparsePoint) {
        throw "Refusing to replace an install directory containing a reparse point: $($nestedReparsePoint.FullName)"
    }
    Remove-Item -LiteralPath $installPath -Recurse -Force
}

New-Item -Path $installPath -ItemType Directory | Out-Null

$inheritanceFlags = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier($sid)),
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritanceFlags,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
}
$usersRule = New-Object Security.AccessControl.FileSystemAccessRule(
    (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),
    [Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize',
    $inheritanceFlags,
    [Security.AccessControl.PropagationFlags]::None,
    [Security.AccessControl.AccessControlType]::Allow
)
[void]$acl.AddAccessRule($usersRule)
Set-Acl -LiteralPath $installPath -AclObject $acl

foreach ($file in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $payloadPath $file) -Destination (Join-Path $installPath $file) -Force
}

& (Join-Path $payloadPath 'Register-DriveMapperTask.ps1') -InstallPath $installPath

$version = Get-Content -LiteralPath (Join-Path $installPath 'Version.json') -Raw | ConvertFrom-Json
$registryPath = 'HKLM:\SOFTWARE\ManagedDriveMapper'
if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}
New-ItemProperty -Path $registryPath -Name Version -Value ([string]$version.Version) -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name InstallPath -Value $installPath -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name InstalledUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force | Out-Null

Write-Output "Installed $productName version $($version.Version) to $installPath."
