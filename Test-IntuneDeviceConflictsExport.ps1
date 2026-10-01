#Requires -Version 7.0
# Offline regression tests: execute the production export helpers and export block.
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Get-IntuneDeviceConflicts.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
foreach ($name in @('ConvertTo-ExportValue', 'ConvertTo-ExportRow', 'Export-DataSet', 'Get-ConflictReview')) {
    $definition = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $false)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$exportBlock = $ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text -eq '$ExportPath'
} | Select-Object -Last 1
if (-not $exportBlock) { throw 'Export must be enabled by ExportPath alone.' }
$obsolete = $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $node.VariablePath.UserPath -eq 'Export'
}, $true)
if ($obsolete.Count) { throw 'Obsolete Export switch references remain.' }
$runExport = [scriptblock]::Create($exportBlock.Extent.Text)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Intune export tests ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
Push-Location $testRoot
try {
    $id = '11111111-2222-3333-4444-555555555555'
    $device = @{ deviceName = 'TestDevice'; id = $id; lastSyncDateTime = '2026-10-01T00:00:00Z' }
    $policies = @()
    $policyObservations = @()
    $policyConflicts = @()
    $unclassified = @()
    foreach ($scenario in @('populated', 'empty', 'disabled')) {
        $retrievedAtUtc = [datetime]::UtcNow
        $ExportPath = if ($scenario -eq 'disabled') { $null } else { "./reports with spaces/$scenario" }
        $settings = @()
        $conflicts = @()
        $issues = @()
        if ($scenario -eq 'populated') {
            $settings = @([pscustomobject]@{ PolicyName = '=Test'; SettingId = 'Firewall'; State = 'Conflict'; Classification = 'Conflict' })
            $conflicts = $settings
        }
        elseif ($scenario -eq 'empty') {
            $issues = @([pscustomobject]@{ Area = 'Policy report'; Message = 'Mock HTTP 400' })
        }
        $conflictReview = @(Get-ConflictReview -Settings $settings -PolicyObservations $policyObservations)
        $result = [pscustomobject]@{ ExportPath = $null }
        . $runExport
        if ($scenario -eq 'disabled') {
            if ($result.ExportPath) { throw 'Export ran without a path.' }
            continue
        }
        $expectedParent = Join-Path $testRoot "reports with spaces/$scenario"
        if ((Split-Path $result.ExportPath -Parent) -ne $expectedParent) {
            throw 'Relative path was not resolved from the PowerShell working location.'
        }
        foreach ($file in @('Summary.csv', 'Device.csv')) {
            if (-not (Test-Path (Join-Path $result.ExportPath $file))) { throw "Missing $file" }
        }
        if ($scenario -eq 'populated') {
            $rows = @(Import-Csv (Join-Path $result.ExportPath 'Conflicts.csv'))
            if ($rows.Count -ne 1 -or $rows[0].SettingId -ne 'Firewall' -or $rows[0].PolicyName -ne "'=Test") {
                throw 'Conflict CSV did not round-trip correctly.'
            }
            $reviewRows = @(Import-Csv (Join-Path $result.ExportPath 'ConflictReview.csv'))
            if ($reviewRows.Count -ne 1 -or $reviewRows[0].SettingId -ne 'Firewall') {
                throw 'Conflict review CSV did not preserve the underlying setting.'
            }
        }
        else {
            $rows = @(Import-Csv (Join-Path $result.ExportPath 'Issues.csv'))
            if ($rows[0].Message -ne 'Mock HTTP 400') { throw 'Empty report lost its diagnostic export.' }
            if (Test-Path (Join-Path $result.ExportPath 'Settings.csv')) { throw 'Unexpected settings export.' }
        }
    }
    Write-Host 'PASS: path-only export, relative paths with spaces, empty reports, and disabled export.'
    $setting = [pscustomobject]@{
        Classification = 'Conflict'; PolicyId = 'policy-1'; PolicyName = 'Firewall'
        UserId = 'user-1'; SettingId = 'firewall-enabled'; SettingName = 'Enable firewall'
        Source = 'getConfigurationSettingsReport'; CurrentValue = $false
    }
    $observations = @(
        [pscustomobject]@{ Classification = 'Conflict'; PolicyId = 'policy-1'; UserId = 'user-1' }
        [pscustomobject]@{ Classification = 'Conflict'; PolicyId = 'policy-1'; UserId = 'user-2' }
        [pscustomobject]@{ Classification = 'Conflict'; PolicyId = 'policy-2'; UserId = 'user-1' }
    )
    $review = @(Get-ConflictReview -Settings @($setting) -PolicyObservations $observations)
    if ($review.Count -ne 3 -or @($review | Where-Object Finding -eq 'Setting unresolved').Count -ne 2) {
        throw 'Review lost unresolved policies or merged distinct user contexts.'
    }
    if ($review[0].SettingId -ne 'firewall-enabled' -or $review[0].ReportedValue -ne $false) {
        throw 'Review lost setting identity or its false value.'
    }
    Write-Host 'PASS: conflict review preserves setting identity, values, and unresolved policy/user contexts.'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
