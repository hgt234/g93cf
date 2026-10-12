#requires -Version 5.1

[CmdletBinding()]
param(
    [string] $InstallPath = (Join-Path $env:ProgramData 'ManagedDriveMapper'),
    [string] $TaskName = 'Managed Drive Mapper'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function ConvertTo-SidValue {
    param([Parameter(Mandatory)] [string] $Identity)

    if ($Identity -match '^S-1-(\d+-)+\d+$') { return $Identity }
    $account = New-Object Security.Principal.NTAccount($Identity)
    return $account.Translate([Security.Principal.SecurityIdentifier]).Value
}

function Get-TaskXmlText {
    param(
        [Parameter(Mandatory)] [xml] $XmlDocument,
        [Parameter(Mandatory)] [Xml.XmlNamespaceManager] $NamespaceManager,
        [Parameter(Mandatory)] [string] $XPath
    )

    $node = $XmlDocument.SelectSingleNode($XPath, $NamespaceManager)
    if ($null -eq $node) { throw "Scheduled task XML is missing required node '$XPath'." }
    if ($node -is [Xml.XmlAttribute]) { return $node.Value }
    return $node.InnerText
}

function Test-TaskXmlChildSet {
    param(
        [Parameter(Mandatory)] [xml] $XmlDocument,
        [Parameter(Mandatory)] [Xml.XmlNamespaceManager] $NamespaceManager,
        [Parameter(Mandatory)] [string] $XPath,
        [Parameter(Mandatory)] [string[]] $ExpectedNames
    )

    $parentNode = $XmlDocument.SelectSingleNode($XPath, $NamespaceManager)
    if ($null -eq $parentNode) { return $false }
    $actualNames = @($parentNode.ChildNodes |
        Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element } |
        ForEach-Object { $_.LocalName } |
        Sort-Object)
    return @(Compare-Object -ReferenceObject @($ExpectedNames | Sort-Object) -DifferenceObject $actualNames).Count -eq 0
}

$tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop)
if ($tasks.Count -ne 1 -or $tasks[0].TaskPath -ne '\') {
    throw "Scheduled task '$TaskName' must exist exactly once in the root task folder."
}

$task = $tasks[0]
if ($task.State -eq 'Disabled') { throw "Scheduled task '$TaskName' is disabled." }

$actions = @($task.Actions)
if ($actions.Count -ne 1) { throw "Scheduled task '$TaskName' must have exactly one action." }

$expectedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$expectedEngine = Join-Path $InstallPath 'Invoke-DriveMapper.ps1'
$expectedArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $expectedEngine
if ([string]$actions[0].Execute -ine $expectedPowerShell -or
    [string]$actions[0].Arguments -cne $expectedArguments) {
    throw "Scheduled task '$TaskName' has an unexpected executable or arguments."
}

if ((ConvertTo-SidValue ([string]$task.Principal.GroupId)) -ne 'S-1-5-32-545' -or
    [string]$task.Principal.RunLevel -ne 'Limited' -or
    [string]$task.Principal.LogonType -ne 'Group') {
    throw "Scheduled task '$TaskName' must run as BUILTIN\Users with least privilege."
}

[xml]$taskXml = Export-ScheduledTask -TaskName $TaskName -TaskPath '\'
$namespace = New-Object Xml.XmlNamespaceManager($taskXml.NameTable)
$namespace.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
if ((Get-TaskXmlText $taskXml $namespace '/t:Task/t:Actions/@Context') -ne 'Author' -or
    (Get-TaskXmlText $taskXml $namespace '/t:Task/t:Principals/t:Principal/@id') -ne 'Author') {
    throw "Scheduled task '$TaskName' has an unexpected action or principal context."
}
if (-not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Actions/t:Exec' @('Command', 'Arguments')) -or
    -not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Principals/t:Principal' @('GroupId', 'RunLevel'))) {
    throw "Scheduled task '$TaskName' has unexpected action or principal options."
}
$triggers = $taskXml.SelectNodes('/t:Task/t:Triggers/*', $namespace)
$logonTriggers = $taskXml.SelectNodes('/t:Task/t:Triggers/t:LogonTrigger', $namespace)
$calendarTriggers = $taskXml.SelectNodes('/t:Task/t:Triggers/t:CalendarTrigger', $namespace)
$eventTriggers = $taskXml.SelectNodes('/t:Task/t:Triggers/t:EventTrigger', $namespace)
if ($triggers.Count -ne 3 -or $logonTriggers.Count -ne 1 -or
    $calendarTriggers.Count -ne 1 -or $eventTriggers.Count -ne 1) {
    throw "Scheduled task '$TaskName' does not have the required three triggers."
}

$logonUser = $logonTriggers[0].SelectSingleNode('t:UserId', $namespace)
if ($null -ne $logonUser -and -not [string]::IsNullOrWhiteSpace($logonUser.InnerText)) {
    throw "Scheduled task '$TaskName' has an unexpected user-specific logon trigger."
}
if (-not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Triggers/t:LogonTrigger' @('Enabled')) -or
    -not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger' @('Repetition', 'StartBoundary', 'Enabled', 'ScheduleByDay')) -or
    -not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger/t:Repetition' @('Interval', 'StopAtDurationEnd')) -or
    -not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger/t:ScheduleByDay' @('DaysInterval')) -or
    -not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Triggers/t:EventTrigger' @('Enabled', 'Subscription', 'Delay'))) {
    throw "Scheduled task '$TaskName' has unexpected trigger options."
}
if ((Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:LogonTrigger/t:Enabled') -ne 'true' -or
    (Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger/t:Enabled') -ne 'true' -or
    (Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:EventTrigger/t:Enabled') -ne 'true') {
    throw "Scheduled task '$TaskName' has a disabled trigger."
}
if ((Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger/t:Repetition/t:Interval') -ne 'PT5M' -or
    (Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger/t:Repetition/t:StopAtDurationEnd') -ne 'false' -or
    (Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger/t:ScheduleByDay/t:DaysInterval') -ne '1') {
    throw "Scheduled task '$TaskName' has an unexpected repetition schedule."
}
$calendarStartText = Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:CalendarTrigger/t:StartBoundary'
$calendarStart = [DateTime]::MinValue
if (-not [DateTime]::TryParse($calendarStartText, [ref]$calendarStart) -or
    $calendarStart -gt (Get-Date).AddMinutes(1)) {
    throw "Scheduled task '$TaskName' has an invalid or future start boundary."
}
$eventSubscription = Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:EventTrigger/t:Subscription'
$expectedEventSubscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
if (($eventSubscription -replace '\s', '') -cne ($expectedEventSubscription -replace '\s', '') -or
    (Get-TaskXmlText $taskXml $namespace '/t:Task/t:Triggers/t:EventTrigger/t:Delay') -ne 'PT10S') {
    throw "Scheduled task '$TaskName' has an unexpected network trigger."
}

$expectedSettings = [ordered]@{
    '/t:Task/t:Settings/t:MultipleInstancesPolicy' = 'IgnoreNew'
    '/t:Task/t:Settings/t:DisallowStartIfOnBatteries' = 'false'
    '/t:Task/t:Settings/t:StopIfGoingOnBatteries' = 'false'
    '/t:Task/t:Settings/t:AllowHardTerminate' = 'true'
    '/t:Task/t:Settings/t:StartWhenAvailable' = 'true'
    '/t:Task/t:Settings/t:RunOnlyIfNetworkAvailable' = 'false'
    '/t:Task/t:Settings/t:IdleSettings/t:StopOnIdleEnd' = 'false'
    '/t:Task/t:Settings/t:IdleSettings/t:RestartOnIdle' = 'false'
    '/t:Task/t:Settings/t:AllowStartOnDemand' = 'true'
    '/t:Task/t:Settings/t:Enabled' = 'true'
    '/t:Task/t:Settings/t:Hidden' = 'false'
    '/t:Task/t:Settings/t:RunOnlyIfIdle' = 'false'
    '/t:Task/t:Settings/t:WakeToRun' = 'false'
    '/t:Task/t:Settings/t:ExecutionTimeLimit' = 'PT0S'
    '/t:Task/t:Settings/t:Priority' = '7'
}
$expectedSettingNames = @(
    'MultipleInstancesPolicy',
    'DisallowStartIfOnBatteries',
    'StopIfGoingOnBatteries',
    'AllowHardTerminate',
    'StartWhenAvailable',
    'RunOnlyIfNetworkAvailable',
    'IdleSettings',
    'AllowStartOnDemand',
    'Enabled',
    'Hidden',
    'RunOnlyIfIdle',
    'WakeToRun',
    'ExecutionTimeLimit',
    'Priority'
)
if (-not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Settings' $expectedSettingNames) -or
    -not (Test-TaskXmlChildSet $taskXml $namespace '/t:Task/t:Settings/t:IdleSettings' @('StopOnIdleEnd', 'RestartOnIdle'))) {
    throw "Scheduled task '$TaskName' has unexpected settings."
}
foreach ($setting in $expectedSettings.GetEnumerator()) {
    if ((Get-TaskXmlText $taskXml $namespace $setting.Key) -cne $setting.Value) {
        throw "Scheduled task '$TaskName' has unexpected setting '$($setting.Key)'."
    }
}
