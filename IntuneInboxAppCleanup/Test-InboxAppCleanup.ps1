#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptPaths = @(
    (Join-Path $PSScriptRoot 'Detect-InboxAppCleanup.ps1')
    (Join-Path $PSScriptRoot 'Remediate-InboxAppCleanup.ps1')
)

foreach ($scriptPath in $scriptPaths) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -gt 0) {
        $messages = $errors | ForEach-Object { $_.Message }
        throw ('PowerShell parser errors in {0}: {1}' -f $scriptPath, ($messages -join '; '))
    }
}

$targetPattern = [regex]'(?ms)\$targetPackageNames\s*=\s*@\((.*?)\)'
$targetLists = New-Object 'System.Collections.Generic.List[object]'
foreach ($scriptPath in $scriptPaths) {
    $content = Get-Content -LiteralPath $scriptPath -Raw
    $match = $targetPattern.Match($content)
    if (-not $match.Success) {
        throw "Could not find targetPackageNames in $scriptPath."
    }

    $targets = @(
        [regex]::Matches($match.Groups[1].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value }
    )
    $targetLists.Add([string[]]$targets)
}

if (($targetLists[0] -join "`n") -cne ($targetLists[1] -join "`n")) {
    throw 'The detection and remediation target package lists do not match.'
}

Write-Output ('Validation passed for {0} scripts and {1} target packages.' -f
    $scriptPaths.Count, $targetLists[0].Count)
