#requires -Version 5.1

[CmdletBinding()]
param()

# The Intune agent runs the installer as a 32-bit process, so WOW64 stores the
# marker under WOW6432Node. Detection reads that node first and falls back to
# the native SOFTWARE key, so it succeeds whether Intune runs this script as a
# 32-bit or 64-bit process.
$markerKeyPaths = @(
    'HKLM:\SOFTWARE\WOW6432Node\EucPilotProgram',
    'HKLM:\SOFTWARE\EucPilotProgram'
)

foreach ($markerKeyPath in $markerKeyPaths) {
    if (-not (Test-Path -LiteralPath $markerKeyPath)) { continue }
    $status = [string](Get-ItemPropertyValue -Path $markerKeyPath -Name Status -ErrorAction SilentlyContinue)
    if ($status -eq 'Joined') {
        Write-Output "EUC Early Adopter opt-in marker present at $markerKeyPath."
        exit 0
    }
}

exit 1