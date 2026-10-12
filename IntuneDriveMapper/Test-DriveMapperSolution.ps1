#requires -Version 5.1

[CmdletBinding()]
param(
    [switch] $SkipScriptAnalyzer
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter '*.ps1' -File)
$parseFailures = New-Object Collections.Generic.List[string]
foreach ($scriptFile in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $scriptFile.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    foreach ($parseError in @($parseErrors)) {
        $parseFailures.Add(('{0}:{1}:{2}: {3}' -f
            $scriptFile.FullName,
            $parseError.Extent.StartLineNumber,
            $parseError.Extent.StartColumnNumber,
            $parseError.Message))
    }
}
if ($parseFailures.Count -gt 0) {
    $parseFailures | Write-Output
    throw "PowerShell parsing failed with $($parseFailures.Count) error(s)."
}

Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Payload\Mappings.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json | Out-Null
$versionData = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Payload\Version.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json
if ($versionData.Version -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$versionData.Version)) {
    throw 'Payload\Version.json must contain a nonempty string Version property.'
}
$detectionContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Detect-DriveMapper.ps1') -Raw -Encoding UTF8
$detectionVersionMatches = [regex]::Matches($detectionContent, '\$expectedVersion\s*=\s*''([^'']+)''')
if ($detectionVersionMatches.Count -ne 1 -or
    $detectionVersionMatches[0].Groups[1].Value -cne [string]$versionData.Version) {
    throw 'Detect-DriveMapper.ps1 expectedVersion must exactly match Payload\Version.json.'
}
& (Join-Path $PSScriptRoot 'Payload\Invoke-DriveMapper.ps1') `
    -ConfigurationPath (Join-Path $PSScriptRoot 'Payload\Mappings.json') -ValidateOnly | Out-Null

if (-not $SkipScriptAnalyzer) {
    $analyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $analyzerModule) {
        throw 'PSScriptAnalyzer is not installed. Run: Install-PSResource -Name PSScriptAnalyzer -Scope CurrentUser'
    }
    Import-Module $analyzerModule.Path -Force
    $settingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings $settingsPath)
    if ($findings.Count -gt 0) {
        $findings |
            Sort-Object ScriptName, Line, RuleName |
            Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize |
            Out-String |
            Write-Output
        throw "PSScriptAnalyzer reported $($findings.Count) finding(s)."
    }
}

Write-Output "Validated $($scriptFiles.Count) PowerShell script(s), version synchronization, JSON configuration, and mapping rules."
