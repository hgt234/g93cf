#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $PSADTTemplatePath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $IntuneWinAppUtilPath,

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [switch] $SkipAuthenticodeCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AppFactory.Common.ps1')

$appPathResolved = (Resolve-Path -LiteralPath $AppPath).Path
$manifestPath = Join-Path $appPathResolved 'app.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing manifest '$manifestPath'." }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$errors = @(Test-AppFactoryManifest -Manifest $manifest | Where-Object Severity -eq 'Error')
if ($errors.Count -gt 0) {
    $errors | Format-Table -AutoSize | Out-Host
    throw 'Application manifest validation failed.'
}
if ($manifest.lifecycle.strategy -ne 'psadtWin32') {
    throw "'$($manifest.displayName)' uses '$($manifest.lifecycle.strategy)' and must not be wrapped in PSADT."
}

foreach ($value in @($manifest.lifecycle.version, $manifest.payload.fileName, $manifest.payload.sha256)) {
    if (Test-AppFactoryPlaceholder $value) { throw 'Replace all version, file and hash placeholders before building.' }
}

$packageConfigPath = Join-Path $appPathResolved 'Package\PackageConfig.psd1'
if (-not (Test-Path -LiteralPath $packageConfigPath -PathType Leaf)) {
    throw "Missing PSADT package configuration '$packageConfigPath'."
}
$packageConfig = Import-PowerShellDataFile -LiteralPath $packageConfigPath
if ($packageConfig.AppVersion -ne $manifest.lifecycle.version) {
    throw "PackageConfig AppVersion '$($packageConfig.AppVersion)' does not match manifest version '$($manifest.lifecycle.version)'."
}
if ($packageConfig.Installer.FileName -ne $manifest.payload.fileName) {
    throw 'PackageConfig installer filename does not match the manifest payload filename.'
}

$payloadPath = Join-Path $appPathResolved (Join-Path 'Payload' $manifest.payload.fileName)
if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw "Missing payload '$payloadPath'." }
$actualHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash
if ($actualHash -ne $manifest.payload.sha256) {
    throw "Payload SHA256 mismatch. Expected $($manifest.payload.sha256), received $actualHash."
}

if (-not $SkipAuthenticodeCheck) {
    if (Test-AppFactoryPlaceholder $manifest.payload.expectedPublisher) {
        throw 'Replace expectedPublisher or use -SkipAuthenticodeCheck only for an approved unsigned internal installer.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $payloadPath
    if ($signature.Status -ne 'Valid') { throw "Payload Authenticode status is '$($signature.Status)'." }
    if ($signature.SignerCertificate.Subject -notlike "*$($manifest.payload.expectedPublisher)*") {
        throw "Signer '$($signature.SignerCertificate.Subject)' does not contain expected publisher '$($manifest.payload.expectedPublisher)'."
    }
}

$templateEntryPoint = Join-Path $PSADTTemplatePath 'Invoke-AppDeployToolkit.exe'
$templateModule = Join-Path $PSADTTemplatePath 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
if (-not (Test-Path -LiteralPath $templateEntryPoint -PathType Leaf) -or
    -not (Test-Path -LiteralPath $templateModule -PathType Leaf)) {
    throw 'PSADTTemplatePath must be an extracted PSADT 4.1.8 deployment template containing Invoke-AppDeployToolkit.exe and the module.'
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$buildRoot = Join-Path $outputRoot (Join-Path $manifest.id $manifest.lifecycle.version)
if (Test-Path -LiteralPath $buildRoot) {
    throw "Build directory '$buildRoot' already exists. Use a clean output directory or a new version."
}
New-Item -Path $buildRoot -ItemType Directory -Force | Out-Null
$stagingPath = Join-Path $buildRoot 'Source'
Copy-Item -LiteralPath $PSADTTemplatePath -Destination $stagingPath -Recurse

Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\PSADT\Invoke-AppDeployToolkit.ps1') `
    -Destination (Join-Path $stagingPath 'Invoke-AppDeployToolkit.ps1') -Force
Copy-Item -LiteralPath $packageConfigPath -Destination (Join-Path $stagingPath 'PackageConfig.psd1') -Force
Copy-Item -LiteralPath $payloadPath -Destination (Join-Path $stagingPath 'Files') -Force

$scriptsPath = Join-Path $appPathResolved 'Package\Scripts'
if (Test-Path -LiteralPath $scriptsPath -PathType Container) {
    Copy-Item -LiteralPath $scriptsPath -Destination (Join-Path $stagingPath 'Scripts') -Recurse
}

$intuneWinOutput = Join-Path $buildRoot 'IntuneWin'
New-Item -Path $intuneWinOutput -ItemType Directory -Force | Out-Null
& $IntuneWinAppUtilPath -c $stagingPath -s 'Invoke-AppDeployToolkit.exe' -o $intuneWinOutput -q
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }

$artifact = Get-ChildItem -LiteralPath $intuneWinOutput -Filter '*.intunewin' -File | Select-Object -First 1
if (-not $artifact) { throw 'IntuneWinAppUtil completed but no .intunewin artifact was found.' }
$artifact.FullName
