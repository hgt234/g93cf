#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IntuneWinAppUtilPath,

    [string]$OutputPath = (Join-Path $PSScriptRoot 'Output')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CISWindows24H2Engine-{0}' -f [guid]::NewGuid().ToString('N'))

try {
    $null = New-Item -Path $stagingRoot -ItemType Directory -Force
    foreach ($name in @('Install-HardeningKittyEngine.ps1', 'Uninstall-HardeningKittyEngine.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "EnginePackage\$name") -Destination (Join-Path $stagingRoot $name) -Force
    }
    $payloadRoot = Join-Path $stagingRoot 'Payload\HardeningKitty\0.9.4'
    $null = New-Item -Path (Split-Path -Parent $payloadRoot) -ItemType Directory -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Vendor\HardeningKitty\0.9.4') -Destination $payloadRoot -Recurse -Force

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
    }
    & $IntuneWinAppUtilPath -c $stagingRoot -s 'Install-HardeningKittyEngine.ps1' -o $OutputPath -q
    if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }
    Write-Output (Join-Path $OutputPath 'Install-HardeningKittyEngine.intunewin')
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
