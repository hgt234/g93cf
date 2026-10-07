#requires -Version 5.1

# Packages the Intune Win32 app. Point it at IntuneWinAppUtil.exe; the
# .intunewin lands beside the EucPilotProgram folder.
#
#   .\Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $IntuneWinAppUtilPath,

    [string] $OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'EucPilotProgramOutput')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

& $IntuneWinAppUtilPath -c $PSScriptRoot -s 'Install-EucPilotJoin.ps1' -o $OutputPath -q
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }

Write-Output (Join-Path $OutputPath 'Install-EucPilotJoin.intunewin')