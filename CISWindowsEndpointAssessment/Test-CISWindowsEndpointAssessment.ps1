#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]
$engineVersion = '0.9.4'
$expectedManifestHash = '6EC3F28E8FC111C5DEC510B62F465BD5B2F0F8290EC8DFA294EC423137D0C848'
$engineRoot = Join-Path $PSScriptRoot "Vendor\HardeningKitty\$engineVersion"
$packageManifestPath = Join-Path $engineRoot 'PackageManifest.psd1'

function Add-Failure {
    param([Parameter(Mandatory)] [string]$Message)
    $failures.Add($Message)
}

try {
    & (Join-Path $PSScriptRoot 'Build-IntunePackage.ps1') | Out-Null
}
catch {
    Add-Failure "Package build failed: $($_.Exception.Message)"
}

foreach ($path in @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Where-Object Extension -in @('.ps1', '.psm1', '.psd1'))) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) {
        Add-Failure "PowerShell parse error in $($path.FullName) at line $($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
}

try {
    if ((Get-FileHash -LiteralPath $packageManifestPath -Algorithm SHA256).Hash -ne $expectedManifestHash) {
        Add-Failure 'The vendored PackageManifest.psd1 hash does not match the adapter pin.'
    }
    $manifest = Import-PowerShellDataFile -LiteralPath $packageManifestPath
    if ($manifest.EngineVersion -ne $engineVersion) { Add-Failure 'Unexpected HardeningKitty engine version.' }
    if ($manifest.SourceCommit -ne 'da0976073caad006c48b2478588c2f7fa572ab46') { Add-Failure 'Unexpected HardeningKitty source commit.' }
    foreach ($entry in $manifest.Files.GetEnumerator()) {
        $path = Join-Path $engineRoot ([string]$entry.Key)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Failure "Vendored engine file is missing: $($entry.Key)."
            continue
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string]$entry.Value) {
            Add-Failure "Vendored engine file hash mismatch: $($entry.Key)."
        }
    }

    $moduleContent = [System.IO.File]::ReadAllText((Join-Path $engineRoot 'HardeningKitty.psm1'))
    if ($moduleContent -notmatch '\$HardeningKittyVersion\s*=\s*"0\.9\.4"') { Add-Failure 'HardeningKitty module does not identify itself as 0.9.4.' }
    if ($moduleContent -notmatch '# SIG # Begin signature block') { Add-Failure 'HardeningKitty Authenticode signature block is missing.' }
    if ($moduleContent -notmatch 'audit mode is not usable until further notice') { Add-Failure 'Expected upstream warning about incomplete Intune source-mode coverage is missing; re-review the engine.' }

    $signedManifestPath = Join-Path $engineRoot 'lists\hardeningkitty_lists_manifest.psd1'
    $signaturePath = "$signedManifestPath.p7s"
    if (-not ([System.Management.Automation.PSTypeName]'System.Security.Cryptography.Pkcs.SignedCms').Type) {
        Add-Type -AssemblyName System.Security
    }
    $manifestBytes = [System.IO.File]::ReadAllBytes($signedManifestPath)
    $signatureBytes = [System.IO.File]::ReadAllBytes($signaturePath)
    $contentInfo = New-Object System.Security.Cryptography.Pkcs.ContentInfo(, $manifestBytes)
    $signedCms = New-Object System.Security.Cryptography.Pkcs.SignedCms($contentInfo, $true)
    $signedCms.Decode($signatureBytes)
    $signedCms.CheckSignature($true)
    if ($signedCms.SignerInfos[0].Certificate.Thumbprint -ne 'E962C15FED3A489616A6A048B492983679D6F643') {
        Add-Failure 'The HardeningKitty list manifest signer does not match the engine pin.'
    }
}
catch {
    Add-Failure "Engine integrity validation failed: $($_.Exception.Message)"
}

$expectedCategories = [ordered]@{
    'Account Policies' = 'AccountPoliciesCompliant'
    'Administrative Templates: Control Panel' = 'AdminTemplatesControlPanelCompliant'
    'Administrative Templates: Network' = 'AdminTemplatesNetworkCompliant'
    'Administrative Templates: Printers' = 'AdminTemplatesPrintersCompliant'
    'Administrative Templates: Start Menu and Taskbar' = 'AdminTemplatesStartMenuAndTaskbarCompliant'
    'Administrative Templates: System' = 'AdminTemplatesSystemCompliant'
    'Administrative Templates: Windows Components' = 'AdminTemplatesWindowsComponentsCompliant'
    'Advanced Audit Policy Configuration' = 'AdvancedAuditPolicyCompliant'
    'Microsoft Defender Application Guard' = 'DefenderApplicationGuardCompliant'
    'MSS (Legacy)' = 'MSSLegacyCompliant'
    'MS Security Guide' = 'MSSecurityGuideCompliant'
    'Security Options' = 'SecurityOptionsCompliant'
    'System Services' = 'SystemServicesCompliant'
    'User Rights Assignment' = 'UserRightsAssignmentCompliant'
    'Windows Firewall' = 'WindowsFirewallCompliant'
}

$lists = @(
    [pscustomobject]@{ Scope = 'Machine'; Path = Join-Path $engineRoot 'lists\finding_list_cis_microsoft_windows_11_enterprise_24h2_machine.csv'; Count = 647; Filters = @('L1', 'L2', 'BL') }
    [pscustomobject]@{ Scope = 'User'; Path = Join-Path $engineRoot 'lists\finding_list_cis_microsoft_windows_11_enterprise_24h2_user.csv'; Count = 13; Filters = @('L1', 'L2') }
)

foreach ($list in $lists) {
    try {
        $rows = @(Import-Csv -LiteralPath $list.Path)
        if ($rows.Count -ne $list.Count) { Add-Failure "$($list.Scope) list contains $($rows.Count) rows; expected $($list.Count)." }
        foreach ($property in @('ID', 'Category', 'Name', 'Method', 'Severity', 'Filter')) {
            if (@($rows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.$property) }).Count -gt 0) {
                Add-Failure "$($list.Scope) list contains blank $property values."
            }
        }
        $unexpectedFilters = @($rows.Filter | Where-Object { $_ -notin $list.Filters } | Select-Object -Unique)
        if ($unexpectedFilters.Count -gt 0) { Add-Failure "$($list.Scope) list has unexpected filters: $($unexpectedFilters -join ',')." }
        foreach ($category in @($rows.Category | Select-Object -Unique)) {
            if (-not $expectedCategories.Contains($category)) { Add-Failure "No compliance mapping exists for category '$category'." }
        }
    }
    catch {
        Add-Failure "Unable to validate $($list.Scope) list: $($_.Exception.Message)"
    }
}

$generatedTargets = @(
    [pscustomobject]@{ Relative = 'Deploy\Machine\Detect-CISWindows24H2MachineCompliance.ps1'; Scope = 'Machine'; Mode = 'IntuneRemediation' }
    [pscustomobject]@{ Relative = 'Deploy\Machine\Discover-CISWindows24H2MachineCompliance.ps1'; Scope = 'Machine'; Mode = 'CustomCompliance' }
    [pscustomobject]@{ Relative = 'Deploy\User\Detect-CISWindows24H2UserCompliance.ps1'; Scope = 'User'; Mode = 'IntuneRemediation' }
    [pscustomobject]@{ Relative = 'Deploy\User\Discover-CISWindows24H2UserCompliance.ps1'; Scope = 'User'; Mode = 'CustomCompliance' }
)
foreach ($target in $generatedTargets) {
    $path = Join-Path $PSScriptRoot $target.Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-Failure "Generated script missing: $($target.Relative)."; continue }
    $content = [System.IO.File]::ReadAllText($path)
    if ($content -notmatch [regex]::Escape("[string]`$Scope = '$($target.Scope)'")) { Add-Failure "$($target.Relative) has the wrong default scope." }
    if ($content -notmatch [regex]::Escape("[string]`$OutputMode = '$($target.Mode)'")) { Add-Failure "$($target.Relative) has the wrong output mode." }
    if ($content -notmatch 'Invoke-HardeningKitty\s+-Mode\s+Audit\s+-Source\s+GPO') { Add-Failure "$($target.Relative) does not force effective-state GPO audit mode." }
    if ($content -match '-Mode\s+HailMary') { Add-Failure "$($target.Relative) contains a HardeningKitty write-mode invocation." }
    if ((Get-Item -LiteralPath $path).Length -gt 1MB) { Add-Failure "$($target.Relative) exceeds the Intune 1 MB script limit." }
}

$ruleFiles = @(
    [pscustomobject]@{ Scope = 'Machine'; Path = Join-Path $PSScriptRoot 'MachineCustomComplianceRules.json'; Categories = @($expectedCategories.Values) }
    [pscustomobject]@{ Scope = 'User'; Path = Join-Path $PSScriptRoot 'UserCustomComplianceRules.json'; Categories = @('AdminTemplatesStartMenuAndTaskbarCompliant', 'AdminTemplatesSystemCompliant', 'AdminTemplatesWindowsComponentsCompliant') }
)
foreach ($rulesFile in $ruleFiles) {
    try {
        $rules = Get-Content -LiteralPath $rulesFile.Path -Raw | ConvertFrom-Json
        $names = @($rules.Rules.SettingName)
        $required = @('OverallCompliant', 'AssessmentHealthy', 'EngineIntegrity') + @($rulesFile.Categories)
        if ($names.Count -ne (@($names | Select-Object -Unique)).Count) { Add-Failure "$($rulesFile.Scope) compliance rule names are not unique." }
        if ($names.Count -gt 100) { Add-Failure "$($rulesFile.Scope) compliance rules exceed Intune's 100-rule limit." }
        if ((Get-Item -LiteralPath $rulesFile.Path).Length -gt 100KB) { Add-Failure "$($rulesFile.Scope) compliance rules exceed Intune's 100 KB limit." }
        foreach ($name in $required) {
            if ($names -notcontains $name) { Add-Failure "$($rulesFile.Scope) compliance rules are missing '$name'." }
        }
    }
    catch {
        Add-Failure "$($rulesFile.Scope) compliance rules are invalid: $($_.Exception.Message)"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output 'CIS Windows 11 24H2 HardeningKitty integration validation passed (647 machine + 13 user findings).'
exit 0
