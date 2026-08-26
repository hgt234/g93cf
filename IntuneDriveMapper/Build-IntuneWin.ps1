#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $IntuneWinAppUtilPath,

    [string] $OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'IntuneDriveMapperOutput')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Test-DriveMapperSolution.ps1') -SkipScriptAnalyzer | Out-Null

if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

& $IntuneWinAppUtilPath -c $PSScriptRoot -s 'Install-DriveMapper.cmd' -o $OutputPath -q
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }

Write-Output (Join-Path $OutputPath 'Install-DriveMapper.intunewin')
