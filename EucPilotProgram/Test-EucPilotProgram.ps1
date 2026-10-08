#requires -Version 5.1

<#
Offline validation for the EUC pilot program solution. Parses every script,
runs PSScriptAnalyzer with the project settings, and checks the Join app
install/uninstall/detection registry contract. No network calls and no
authentication are performed.
#>

[CmdletBinding()]
param(
    [switch] $SkipScriptAnalyzer
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ---- 1. Parse every script in the project ----
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

# ---- 2. PSScriptAnalyzer with project settings ----
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

# ---- 3. Join app registry contract ----
$testResults = New-Object 'System.Collections.Generic.List[string]'
function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw $Message }
    $testResults.Add("PASS: $Message") | Out-Null
}

# 3a. Detection: marker value must be exactly 'Joined'.
$detectionContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Detect-EucPilotJoin.ps1') -Raw
Assert-True ($detectionContent -match "'Joined'") 'detection expects the Joined marker value'
Assert-True ($detectionContent -match 'exit 1') 'detection exits nonzero on absence'

# 3b. The marker is written under SOFTWARE with the readable registry
# cmdlets. The Intune agent runs 32-bit, so WOW64 stores it under
# WOW6432Node, and the detection script reads that node.
$installContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-EucPilotJoin.ps1') -Raw
$uninstallContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-EucPilotJoin.ps1') -Raw
Assert-True ($installContent -cmatch 'HKLM:\\SOFTWARE\\EucPilotProgram') 'install writes the marker under SOFTWARE'
Assert-True ($installContent -cmatch 'New-ItemProperty[\s\S]*-Name Status[\s\S]*-Value ''Joined''') 'install writes the Joined marker with New-ItemProperty'
Assert-True ($uninstallContent -cmatch 'HKLM:\\SOFTWARE\\EucPilotProgram') 'uninstall removes the native SOFTWARE marker'
Assert-True ($uninstallContent -cmatch 'HKLM:\\SOFTWARE\\WOW6432Node\\EucPilotProgram') 'uninstall removes the redirected WOW6432Node marker'
Assert-True ($detectionContent -cmatch 'HKLM:\\SOFTWARE\\WOW6432Node\\EucPilotProgram') 'detection reads the redirected WOW6432Node marker'
Assert-True ($detectionContent -cmatch 'Get-ItemPropertyValue') 'detection reads the marker with Get-ItemPropertyValue'
Assert-True ($detectionContent -cmatch '-Name Status') 'detection checks the Status value'
Assert-True ($detectionContent -cmatch 'HKLM:\\SOFTWARE\\EucPilotProgram') 'detection keeps a native SOFTWARE fallback for 32-bit detection'
foreach ($script in @(@{ n = 'install'; c = $installContent }, @{ n = 'uninstall'; c = $uninstallContent }, @{ n = 'detection'; c = $detectionContent })) {
    Assert-True ($script.c -cnotmatch 'HKLM:\\EucPilotProgram''') ('{0} script must not target the forbidden HKLM root' -f $script.n)
    Assert-True ($script.c -cnotmatch 'Microsoft\.Win32\.Registry') ('{0} script stays on readable PowerShell registry cmdlets' -f $script.n)
}

$testResults | Write-Output
Write-Output ("Validated {0} PowerShell script(s), analyzer settings, and {1} contract test(s)." -f
    $scriptFiles.Count, $testResults.Count)
