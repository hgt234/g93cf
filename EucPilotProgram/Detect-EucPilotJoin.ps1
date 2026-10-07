#requires -Version 5.1

[CmdletBinding()]
param()

try {
    $marker = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('EucPilotProgram')
    if ($null -eq $marker) { exit 1 }
    $status = [string]$marker.GetValue('Status')
    $marker.Close()
    if ($status -ne 'Joined') { exit 1 }
    Write-Output 'EUC Early Adopter opt-in marker present.'
    exit 0
}
catch { exit 1 }