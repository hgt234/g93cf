#requires -Version 5.1

# Packages the Join app Win32 package. Only the Package folder (install and
# uninstall wrappers) goes into the .intunewin; the detection script is
# uploaded separately in Intune and the sync runbook never ships to devices.
# The .intunewin lands in EucPilotProgramOutput at the repository root.
#
#   .\Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $IntuneWinAppUtilPath,

    [string] $OutputPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'EucPilotProgramOutput')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$packageSource = Join-Path $PSScriptRoot 'Package'

if ($PSCmdlet.ShouldProcess($OutputPath, "Package $packageSource with IntuneWinAppUtil")) {
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    & $IntuneWinAppUtilPath -c $packageSource -s 'Install-EucPilotJoin.ps1' -o $OutputPath -q
    if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }

    Write-Output (Join-Path $OutputPath 'Install-EucPilotJoin.intunewin')
}
