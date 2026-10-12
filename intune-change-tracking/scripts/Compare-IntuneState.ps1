[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$CurrentPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$AuditPath,
    [string]$ChangeRecordsPath,
    [string]$EnvironmentName,
    [switch]$FailOnUndocumentedChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileIndex {
    param([Parameter(Mandatory)][string]$Root)
    $index = @{}
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $index }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($file in Get-ChildItem -LiteralPath $rootPath -File -Recurse) {
        $relative = $file.FullName.Substring($rootPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $relative = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
        $index[$relative] = [ordered]@{ path = $file.FullName; hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    return $index
}

function Get-ObjectLabel {
    param([string]$Path, [string]$Fallback)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or $Path -notlike '*.json') { return $Fallback }
    try {
        $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($value.PSObject.Properties['displayName'] -and $value.displayName) { return [string]$value.displayName }
        if ($value.PSObject.Properties['name'] -and $value.name) { return [string]$value.name }
    }
    catch { }
    return $Fallback
}

function Get-ChangeRecords {
    param([string]$Root)
    $records = [System.Collections.Generic.List[object]]::new()
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return ,$records.ToArray() }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)

    foreach ($file in Get-ChildItem -LiteralPath $rootPath -Filter '*.md' -File -Recurse) {
        $lines = @(Get-Content -LiteralPath $file.FullName)
        if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { continue }
        $metadata = @{}
        for ($index = 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index].Trim() -eq '---') { break }
            if ($lines[$index] -match '^([a-zA-Z0-9_]+):\s*(.*)$') {
                $key = $Matches[1].ToLowerInvariant()
                $rawValue = $Matches[2].Trim()
                try { $metadata[$key] = $rawValue | ConvertFrom-Json } catch { $metadata[$key] = $rawValue.Trim('''', '"') }
            }
        }

        $validUntil = [DateTimeOffset]::MinValue
        if ($metadata.ContainsKey('valid_until_utc')) {
            [void][DateTimeOffset]::TryParse([string]$metadata.valid_until_utc, [ref]$validUntil)
        }
        $relative = $file.FullName.Substring($rootPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $records.Add([ordered]@{
            path = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
            policy = if ($metadata.ContainsKey('policy')) { [string]$metadata.policy } else { '' }
            environment = if ($metadata.ContainsKey('environment')) { [string]$metadata.environment } else { '' }
            objectId = if ($metadata.ContainsKey('object_id')) { [string]$metadata.object_id } else { '' }
            ticket = if ($metadata.ContainsKey('ticket')) { [string]$metadata.ticket } else { '' }
            validUntilUtc = $validUntil
        })
    }
    return ,$records.ToArray()
}

function ConvertTo-MarkdownCell {
    param([AllowNull()][object]$Value)
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

if (-not (Test-Path -LiteralPath $CurrentPath -PathType Container)) { throw "Current snapshot does not exist: $CurrentPath" }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$baseline = Get-FileIndex -Root $BaselinePath
$current = Get-FileIndex -Root $CurrentPath
$allPaths = @($baseline.Keys + $current.Keys | Sort-Object -Unique)
$changes = [System.Collections.Generic.List[object]]::new()

foreach ($relativePath in $allPaths) {
    $kind = $null
    if (-not $baseline.ContainsKey($relativePath)) { $kind = 'added' }
    elseif (-not $current.ContainsKey($relativePath)) { $kind = 'deleted' }
    elseif ($baseline[$relativePath].hash -ne $current[$relativePath].hash) { $kind = 'modified' }
    if (-not $kind) { continue }

    $preferredPath = if ($current.ContainsKey($relativePath)) { $current[$relativePath].path } else { $baseline[$relativePath].path }
    $idMatch = [regex]::Match($relativePath, '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    $changes.Add([ordered]@{
        change = $kind
        path = $relativePath
        objectId = if ($idMatch.Success) { $idMatch.Value } else { $null }
        displayName = Get-ObjectLabel -Path $preferredPath -Fallback ([IO.Path]::GetFileNameWithoutExtension($relativePath))
        recordStatus = 'not-evaluated'
        matchedRecord = $null
        ticket = $null
    })
}

$records = @(Get-ChangeRecords -Root $ChangeRecordsPath)
if ($ChangeRecordsPath) {
    foreach ($change in $changes) {
        if ($change.path -eq 'manifest.json') {
            $change.recordStatus = 'generated'
            continue
        }
        $matching = @($records | Where-Object {
            $_.validUntilUtc -ge [DateTimeOffset]::UtcNow -and
            ([string]::IsNullOrWhiteSpace($_.environment) -or $_.environment -eq $EnvironmentName) -and
            ((-not [string]::IsNullOrWhiteSpace($_.objectId) -and $_.objectId -eq $change.objectId) -or
             ([string]::IsNullOrWhiteSpace($_.objectId) -and $_.policy -eq $change.displayName))
        } | Sort-Object validUntilUtc -Descending)
        if ($matching.Count -gt 0) {
            $change.recordStatus = 'documented'
            $change.matchedRecord = $matching[0].path
            $change.ticket = $matching[0].ticket
        }
        else {
            $change.recordStatus = 'unrecorded'
        }
    }
}

$auditEvents = @()
if ($AuditPath -and (Test-Path -LiteralPath $AuditPath -PathType Leaf)) {
    $auditDocument = Get-Content -LiteralPath $AuditPath -Raw | ConvertFrom-Json
    $auditEvents = @($auditDocument.events)
}
$correlations = [System.Collections.Generic.List[object]]::new()
foreach ($change in $changes) {
    if (-not $change.objectId) { continue }
    foreach ($event in $auditEvents) {
        if (@($event.resources | Where-Object { $_.id -eq $change.objectId }).Count -gt 0) {
            $actor = if ($event.actor.userPrincipalName) { $event.actor.userPrincipalName }
                elseif ($event.actor.servicePrincipalName) { $event.actor.servicePrincipalName }
                else { $event.actor.applicationDisplayName }
            $correlations.Add([ordered]@{
                path = $change.path; objectId = $change.objectId; activityDateTime = $event.activityDateTime
                activity = $event.activity; actor = $actor; result = $event.result
            })
        }
    }
}

$counts = [ordered]@{
    added = @($changes | Where-Object change -eq 'added').Count
    modified = @($changes | Where-Object change -eq 'modified').Count
    deleted = @($changes | Where-Object change -eq 'deleted').Count
    documented = @($changes | Where-Object recordStatus -eq 'documented').Count
    unrecorded = @($changes | Where-Object recordStatus -eq 'unrecorded').Count
}
$report = [ordered]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    environment = $EnvironmentName
    baselineExists = Test-Path -LiteralPath $BaselinePath -PathType Container
    counts = $counts
    changes = @($changes)
    auditCorrelations = @($correlations)
}
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputPath 'changes.json') -Encoding utf8NoBOM

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# Intune state diff')
$markdown.Add('')
$markdown.Add("Environment: $EnvironmentName  ")
$markdown.Add("Generated: $([DateTime]::UtcNow.ToString('u'))")
$markdown.Add('')
$markdown.Add('| Added | Modified | Deleted | Documented | Unrecorded |')
$markdown.Add('| ---: | ---: | ---: | ---: | ---: |')
$markdown.Add("| $($counts.added) | $($counts.modified) | $($counts.deleted) | $($counts.documented) | **$($counts.unrecorded)** |")
$markdown.Add('')

if ($changes.Count -eq 0) { $markdown.Add('No configuration changes were detected.') }
else {
    $markdown.Add('## Changed objects')
    $markdown.Add('')
    $markdown.Add('| Record status | Change | Object | Record/ticket | Path |')
    $markdown.Add('| --- | --- | --- | --- | --- |')
    foreach ($change in $changes) {
        $recordText = @($change.matchedRecord, $change.ticket | Where-Object { $_ }) -join ' / '
        $markdown.Add("| **$(ConvertTo-MarkdownCell $change.recordStatus)** | $(ConvertTo-MarkdownCell $change.change) | $(ConvertTo-MarkdownCell $change.displayName) | $(ConvertTo-MarkdownCell $recordText) | ``$(ConvertTo-MarkdownCell $change.path)`` |")
    }
}

if ($counts.unrecorded -gt 0) {
    $markdown.Add('')
    $markdown.Add('> [!WARNING]')
    $markdown.Add("> $($counts.unrecorded) changed Intune object(s) have no active matching change record.")
}

if ($correlations.Count -gt 0) {
    $markdown.Add('')
    $markdown.Add('## Matching Intune audit events')
    $markdown.Add('')
    $markdown.Add('These are correlations by Intune object ID, not proof that one event produced every line in the diff.')
    $markdown.Add('')
    $markdown.Add('| Time (UTC) | Actor | Activity | Object path | Result |')
    $markdown.Add('| --- | --- | --- | --- | --- |')
    foreach ($item in $correlations | Sort-Object activityDateTime -Descending) {
        $markdown.Add("| $(ConvertTo-MarkdownCell $item.activityDateTime) | $(ConvertTo-MarkdownCell $item.actor) | $(ConvertTo-MarkdownCell $item.activity) | ``$(ConvertTo-MarkdownCell $item.path)`` | $(ConvertTo-MarkdownCell $item.result) |")
    }
}
elseif ($changes.Count -gt 0) {
    $markdown.Add('')
    $markdown.Add('No recent audit event matched the changed object IDs. Check the audit time window and Graph permissions.')
}
$markdown | Set-Content -LiteralPath (Join-Path $OutputPath 'summary.md') -Encoding utf8NoBOM

$patchPath = Join-Path $OutputPath 'state.patch'
if (Test-Path -LiteralPath $BaselinePath -PathType Container) {
    $patchOutput = @(& git diff --no-index --no-color -- $BaselinePath $CurrentPath 2>&1)
    $gitExit = $LASTEXITCODE
    if ($gitExit -gt 1) { throw "git diff failed with exit code $gitExit." }
    $patchOutput | Set-Content -LiteralPath $patchPath -Encoding utf8NoBOM
}
else {
    'No baseline existed. All current objects are reported as added; the next run will include a raw patch.' | Set-Content -LiteralPath $patchPath -Encoding utf8NoBOM
}

foreach ($change in @($changes | Where-Object recordStatus -eq 'unrecorded')) {
    $message = "Unrecorded Intune change: $($change.change) '$($change.displayName)' ($($change.path))"
    Write-Warning $message
    Write-Host "##vso[task.logissue type=warning]$message"
}
Write-Host "Diff complete: $($counts.added) added, $($counts.modified) modified, $($counts.deleted) deleted; $($counts.unrecorded) unrecorded."
if ($FailOnUndocumentedChanges -and $counts.unrecorded -gt 0) {
    throw "$($counts.unrecorded) Intune change(s) have no active matching change record."
}
