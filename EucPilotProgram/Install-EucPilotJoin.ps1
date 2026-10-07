#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$markerSubKey = 'EucPilotProgram'
$programVersion = '1.0.0'

# The Windows PowerShell 5.1 registry provider cannot create a key directly
# at the HKLM drive root (the provider call fails with "The parameter is
# incorrect"), and the Intune Management Extension runs 5.1, so the .NET
# Registry API is used instead. The 64-bit view is opened explicitly so the
# legacy cleanup reaches the physical keys regardless of process bitness;
# the HKLM root itself is shared between registry views.
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry64
)

# Remove markers written by the original SOFTWARE-based deployment, including
# the WOW6432Node copy produced when the 32-bit Intune Management Extension
# ran the installer before the path moved to the WOW64-shared HKLM root.
foreach ($legacySubKey in @(
    'SOFTWARE\EucPilotProgram',
    'SOFTWARE\WOW6432Node\EucPilotProgram'
)) {
    $registry.DeleteSubKeyTree($legacySubKey, $false)
}

$marker = $registry.CreateSubKey($markerSubKey)
$marker.SetValue('Status', 'Joined', [Microsoft.Win32.RegistryValueKind]::String)
$marker.SetValue('Version', $programVersion, [Microsoft.Win32.RegistryValueKind]::String)
$marker.SetValue('JoinedUtc', [DateTime]::UtcNow.ToString('o'), [Microsoft.Win32.RegistryValueKind]::String)
$marker.Close()
$registry.Dispose()

Write-Output ("EUC Early Adopter opt-in marker written to HKLM:\{0}." -f $markerSubKey)