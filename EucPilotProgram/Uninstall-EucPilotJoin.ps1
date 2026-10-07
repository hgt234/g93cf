#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The .NET Registry API is used because the Windows PowerShell 5.1 registry
# provider cannot operate on keys directly at the HKLM drive root, and the
# Intune Management Extension runs 5.1. The 64-bit view reaches the physical
# legacy keys from any process bitness; the HKLM root is shared between views.
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry64
)

foreach ($subKey in @(
    'EucPilotProgram',
    'SOFTWARE\EucPilotProgram',
    'SOFTWARE\WOW6432Node\EucPilotProgram'
)) {
    $registry.DeleteSubKeyTree($subKey, $false)
}

$registry.Dispose()

Write-Output 'EUC Early Adopter opt-in marker removed.'