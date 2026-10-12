[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = [IO.Path]::GetFullPath($SourcePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$destination = [IO.Path]::GetFullPath($DestinationPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Source does not exist: $source" }
if ($source -eq $destination) { throw 'Source and destination must be different.' }
if ((Split-Path -Leaf (Split-Path -Parent $destination)) -ne 'state') {
    throw "Destination must be an environment directory immediately below a 'state' directory: $destination"
}

New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($file in Get-ChildItem -LiteralPath $destination -File -Recurse) {
    Remove-Item -LiteralPath $file.FullName -Force
}
foreach ($directory in Get-ChildItem -LiteralPath $destination -Directory -Recurse | Sort-Object FullName -Descending) {
    if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
        Remove-Item -LiteralPath $directory.FullName -Force
    }
}

foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse) {
    $relative = $file.FullName.Substring($source.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $target = Join-Path $destination $relative
    $targetParent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
}
Write-Host "Synchronized snapshot to $destination"

