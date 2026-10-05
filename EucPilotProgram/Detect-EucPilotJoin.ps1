#requires -Version 5.1

[CmdletBinding()]
param()

try {
    $status = [string](Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\EucPilotProgram' -Name Status -ErrorAction Stop)
    if ($status -ne 'Joined') { exit 1 }
    Write-Output 'EUC Early Adopter opt-in marker present.'
    exit 0
}
catch { exit 1 }