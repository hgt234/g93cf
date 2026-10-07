#requires -Version 5.1

<#
.SYNOPSIS
Packages the EUC Early Adopter Join app as an Intune Win32 .intunewin file.

.DESCRIPTION
Runs the project validation suite when Test-EucPilotProgram.ps1 is present
beside this script, then invokes Microsoft's IntuneWinAppUtil to produce
Install-EucPilotJoin.intunewin. The marker is written under HKLM\SOFTWARE and
WOW64 redirects it to WOW6432Node because the Intune Management Extension runs
the install as a 32-bit process; the detection script reads that redirected
node.

.EXAMPLE
Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe

.EXAMPLE
# Package without running the optional validation suite.
Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe -SkipValidation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $IntuneWinAppUtilPath,

    [string] $OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'EucPilotProgramOutput'),

    [switch] $SkipValidation
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$setupFile = 'Install-EucPilotJoin.ps1'
$payloadFiles = @(
    $setupFile
    'Uninstall-EucPilotJoin.ps1'
    'Detect-EucPilotJoin.ps1'
)

foreach ($requiredFile in $payloadFiles) {
    $path = Join-Path $PSScriptRoot $requiredFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Package payload is incomplete. Missing: $path"
    }
}

if (-not $SkipValidation) {
    $validationScript = Join-Path $PSScriptRoot 'Test-EucPilotProgram.ps1'
    if (Test-Path -LiteralPath $validationScript -PathType Leaf) {
        # -SkipScriptAnalyzer keeps packaging hosts that do not have
        # PSScriptAnalyzer installed from failing the build.
        try {
            & $validationScript -SkipScriptAnalyzer | Out-Null
        }
        catch {
            $guidance = @(
                ('Validation failed: {0}' -f $_.Exception.Message)
                'The install, detection, and validation scripts may be from different revisions.'
                'Update the whole EucPilotProgram folder (git pull) so they match, or rerun this build with -SkipValidation to package the current payload anyway.'
            ) -join [Environment]::NewLine
            throw $guidance
        }
    }
    else {
        Write-Warning ("Validation script not found at {0}. Packaging without validation; run from the EucPilotProgram folder or pass -SkipValidation to silence this warning." -f $validationScript)
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