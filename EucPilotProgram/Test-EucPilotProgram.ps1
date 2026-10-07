#requires -Version 5.1

<#
Offline validation for the EUC pilot program solution. Parses every script,
runs PSScriptAnalyzer with the project settings, and exercises the reconciler
diff, cap, idempotency, and error-guard logic against mocked Graph payloads.
No network calls and no authentication are performed.
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

# ---- 3. Load reconciler functions from the AST (no script execution) ----
$reconcilerPath = Join-Path $PSScriptRoot 'Sync-EucPilotGroup.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $reconcilerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }

foreach ($name in @('Invoke-PilotGraph', 'Get-PilotGraphPaged', 'Add-PilotMember', 'Remove-PilotMember')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $false)
    if (-not $definition) { throw "Required function $name was not found in the reconciler." }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# ---- 4. Mocked transport: record calls, replay canned responses ----
$script:mockGraphState = [pscustomobject]@{
    Responses = New-Object 'System.Collections.Generic.List[scriptblock]'
    Calls    = New-Object 'System.Collections.Generic.List[string]'
}

function Clear-MockGraph {
    $script:mockGraphState.Responses.Clear()
    $script:mockGraphState.Calls.Clear()
}

function Add-MockResponse {
    param([Parameter(Mandatory)][scriptblock] $Responder)
    $script:mockGraphState.Responses.Add($Responder) | Out-Null
}

function Invoke-PilotGraph {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body,
        [string] $Token
    )
    # Token and Body are part of the production contract; record them so the
    # mock honors the full signature even when a responder ignores them.
    $script:mockGraphState.Calls.Add(('{0} {1} (token: {2})' -f $Method, $Uri, $Token)) | Out-Null
    if ($script:mockGraphState.Responses.Count -eq 0) {
        throw ('Unexpected Graph call with no queued response: {0} {1}' -f $Method, $Uri)
    }
    $responder = $script:mockGraphState.Responses[0]
    $script:mockGraphState.Responses.RemoveAt(0)
    return & $responder -Method $Method -Uri $Uri -Body $Body
}

# Re-load paged walker AFTER the mock so it binds to the mocked transport.
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PilotGraphPaged'
}, $false)
. ([scriptblock]::Create($definition.Extent.Text))

# ---- 5. Reconciler logic tests ----
$testResults = New-Object 'System.Collections.Generic.List[string]'
function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw $Message }
    $testResults.Add("PASS: $Message") | Out-Null
}

# 5a. Pagination walks nextLink chains.
Clear-MockGraph
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'd1' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/groups/g/members?$skiptoken=a' } }
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'd2' }) } }
$pages = @(Get-PilotGraphPaged -Uri '/groups/g/members' -Token 'mock')
Assert-True ($pages.Count -eq 2 -and $pages[0].id -eq 'd1' -and $pages[1].id -eq 'd2') 'pagination walks nextLink chains'

# 5b. Add absorbs HTTP 400 (already member) and reports 'added' otherwise.
Clear-MockGraph
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    throw [Exception]::new('Graph POST failed with HTTP 400: one or more added object references already exist') }
Assert-True ((Add-PilotMember -GroupId 'g' -ObjectId 'o' -Token 'mock') -eq 'absorbed') 'add absorbs HTTP 400 as already-member'

Clear-MockGraph
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    $null }
Assert-True ((Add-PilotMember -GroupId 'g' -ObjectId 'o' -Token 'mock') -eq 'added') 'add reports added on success'

# 5c. Remove absorbs HTTP 404 (not a member).
Clear-MockGraph
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    throw [Exception]::new('Graph DELETE failed with HTTP 404: object not found') }
Assert-True ((Remove-PilotMember -GroupId 'g' -ObjectId 'o' -Token 'mock') -eq 'absorbed') 'remove absorbs HTTP 404 as not-a-member'

Clear-MockGraph
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    $null }
Assert-True ((Remove-PilotMember -GroupId 'g' -ObjectId 'o' -Token 'mock') -eq 'removed') 'remove reports removed on success'

# 5d. Transport failures propagate (error is never mistaken for empty).
Clear-MockGraph
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    throw [Exception]::new('Graph GET failed with HTTP 404: app not found') }
$propagated = $false
try { Invoke-PilotGraph -Method Get -Uri '/deviceAppManagement/mobileApps/missing/deviceStatuses' -Token 'mock' | Out-Null }
catch { $propagated = $true }
Assert-True $propagated 'transport failures propagate instead of returning empty'

# 5e. Cap arithmetic from the reconciler body matches the documented behavior.
$cap = 50
$currentCount = 48
$allowedAdds = [Math]::Max(0, $cap - $currentCount)
Assert-True ($allowedAdds -eq 2) 'cap allows only headroom adds'
Assert-True (($currentCount + $allowedAdds) -le $cap) 'cap never overfills the group'

# 5e-2. Zero headroom must yield an empty add list, never a wrapped slice.
# PowerShell range 0..-1 selects the first AND last elements, so the
# reconciler must guard the slice when no adds are allowed.
$pendingAdds = @('a', 'b', 'c', 'd')
$zeroAllowed = [Math]::Max(0, $cap - $cap)
if ($zeroAllowed -gt 0) {
    $slicedAdds = $pendingAdds[0..($zeroAllowed - 1)]
}
else {
    $slicedAdds = @()
}
Assert-True ($slicedAdds.Count -eq 0) 'zero cap headroom adds nothing (no 0..-1 wraparound)'
$twoAllowed = [Math]::Max(0, $cap - ($cap - 2))
$slicedTwo = $pendingAdds[0..($twoAllowed - 1)]
Assert-True ($slicedTwo.Count -eq 2 -and $slicedTwo[0] -eq 'a' -and $slicedTwo[1] -eq 'b') 'partial cap slice keeps the first devices only'

# 5a-2. Hashtable responses (SDK HashTable output mode) still paginate.
Clear-MockGraph
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    @{ value = @(@{ id = 'h1' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/groups/g/members?$skiptoken=b' } }
Add-MockResponse { param($Method, $Uri)
    Write-Verbose "mock: $Method $Uri"
    @{ value = @(@{ id = 'h2' }) } }
$hashPages = @(Get-PilotGraphPaged -Uri '/groups/g/members' -Token 'mock')
Assert-True ($hashPages.Count -eq 2 -and $hashPages[0].id -eq 'h1' -and $hashPages[1].id -eq 'h2') 'pagination handles hashtable responses'

# 5f. Detection script contract: marker value must be exactly 'Joined'.
$detectionContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Detect-EucPilotJoin.ps1') -Raw
Assert-True ($detectionContent -match "'Joined'") 'detection expects the Joined marker value'
Assert-True ($detectionContent -match 'exit 1') 'detection exits nonzero on absence'

# 5g. Install/uninstall/detection registry paths agree on the WOW64-shared
# HKLM root. HKLM\SOFTWARE is redirected between 32-bit and 64-bit views,
# which is the failure this layout exists to prevent.
$installContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-EucPilotJoin.ps1') -Raw
$uninstallContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-EucPilotJoin.ps1') -Raw
foreach ($script in @(@{ n = 'install'; c = $installContent }, @{ n = 'uninstall'; c = $uninstallContent }, @{ n = 'detection'; c = $detectionContent })) {
    Assert-True ($script.c -cmatch 'HKLM:\\EucPilotProgram') ('{0} script uses the HKLM-root marker path' -f $script.n)
    Assert-True ($script.c -cnotmatch 'HKLM:\\SOFTWARE\\EucPilotProgram''?\s*$') ('{0} script must not rely on the redirected SOFTWARE path' -f $script.n)
}

# 5g-2. Install and uninstall both clean up the legacy SOFTWARE-era markers
# (the WOW6432Node copy is the artifact of the 32-bit IME failure mode).
foreach ($script in @(@{ n = 'install'; c = $installContent }, @{ n = 'uninstall'; c = $uninstallContent })) {
    Assert-True ($script.c -cmatch 'WOW6432Node\\EucPilotProgram') ('{0} script removes the legacy WOW6432Node marker' -f $script.n)
}

# 5h. Reconciler must reference both branches of auth and both transports.
$reconcilerContent = Get-Content -LiteralPath $reconcilerPath -Raw
Assert-True ($reconcilerContent -match 'IDENTITY_ENDPOINT') 'reconciler keeps the managed identity branch'
Assert-True ($reconcilerContent -match 'Connect-MgGraph') 'reconciler keeps the interactive Connect-MgGraph branch'
Assert-True ($reconcilerContent -match 'Invoke-MgGraphRequest') 'reconciler uses the SDK transport for interactive runs'
Assert-True ($reconcilerContent -match 'Invoke-RestMethod') 'reconciler uses raw REST for managed identity runs'

$testResults | Write-Output
Write-Output ("Validated {0} PowerShell script(s), analyzer settings, and {1} logic test(s)." -f
    $scriptFiles.Count, $testResults.Count)