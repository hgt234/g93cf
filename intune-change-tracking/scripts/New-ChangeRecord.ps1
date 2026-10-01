[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Policy,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$')][string]$Environment,
    [Parameter(Mandatory)][string]$Summary,
    [Parameter(Mandatory)][string]$Reason,
    [Parameter(Mandatory)][string]$Target,
    [string]$ObjectId = '',
    [string]$Ticket = '',
    [ValidateSet('planned', 'emergency')][string]$ChangeType = 'planned',
    [ValidateRange(1, 90)][int]$ValidForDays = 14,
    [string]$ChangesRoot = (Join-Path $PSScriptRoot '../changes')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-YamlQuotedString([string]$Value) { return ($Value | ConvertTo-Json -Compress) }

if ($ObjectId -and $ObjectId -notmatch '^[0-9a-fA-F-]{36}$') {
    throw 'ObjectId must be an Intune/Microsoft Graph GUID when supplied.'
}
$slug = ($Summary.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).TrimEnd('-') }
if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'intune-change' }

$now = [DateTime]::UtcNow
$validUntil = $now.AddDays($ValidForDays).ToString('o')
$yearFolder = Join-Path $ChangesRoot $now.ToString('yyyy')
New-Item -ItemType Directory -Path $yearFolder -Force | Out-Null
$path = Join-Path $yearFolder "$($now.ToString('yyyy-MM-dd'))-$slug.md"
if (Test-Path -LiteralPath $path) { $path = Join-Path $yearFolder "$($now.ToString('yyyy-MM-dd'))-$slug-$($now.ToString('HHmmss')).md" }

@(
    '---'
    "policy: $(ConvertTo-YamlQuotedString $Policy)"
    "object_id: $(ConvertTo-YamlQuotedString $ObjectId)"
    "environment: $(ConvertTo-YamlQuotedString $Environment)"
    "target: $(ConvertTo-YamlQuotedString $Target)"
    "ticket: $(ConvertTo-YamlQuotedString $Ticket)"
    "change_type: $(ConvertTo-YamlQuotedString $ChangeType)"
    "valid_until_utc: $(ConvertTo-YamlQuotedString $validUntil)"
    '---'
    ''
    '# Summary'
    ''
    $Summary
    ''
    '## Why'
    ''
    $Reason
    ''
    '## Validation'
    ''
    '- [ ] Confirm the intended assignment in Intune.'
    '- [ ] Confirm the next snapshot diff matches this record.'
    ''
    '## Rollback'
    ''
    '<Describe the prior value or how to remove/reverse this change.>'
) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
Write-Output $path
