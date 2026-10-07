#requires -Version 5.1

<#
.SYNOPSIS
Packages the EUC Early Adopter Join app as an Intune Win32 .intunewin file.

.DESCRIPTION
Runs the project validation suite first, then invokes Microsoft's
IntuneWinAppUtil to produce Install-EucPilotJoin.intunewin. The marker is
written under HKLM\SOFTWARE and WOW64 redirects it to WOW6432Node because
the Intune Management Extension runs the install as a 32-bit process; the
detection script reads that redirected node.

.EXAMPLE
Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $IntuneWinAppUtilPath,

    [string] $OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'EucPilotProgramOutput')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$setupFile = 'Install-EucPilotJoin.ps1'

& (Join-Path $PSScriptRoot 'Test-EucPilotProgram.ps1') | Out-Null

foreach ($requiredFile in @($setupFile, 'Uninstall-EucPilotJoin.ps1', 'Detect-EucPilotJoin.ps1')) {
    $path = Join-Path $PSScriptRoot $requiredFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Package payload is incomplete. Missing: $path"
    }
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Output ("Packaging {0} as the setup file..." -f $setupFile)
& $IntuneWinAppUtilPath -c $PSScriptRoot -s $setupFile -o $OutputPath -q
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }

$packagePath = Join-Path $OutputPath 'Install-EucPilotJoin.intunewin'
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw "Expected package was not produced: $packagePath"
}

Write-Output $packagePath