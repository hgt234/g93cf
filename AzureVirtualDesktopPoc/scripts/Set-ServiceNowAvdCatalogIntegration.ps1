#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$InstanceUrl,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [Parameter(Mandatory)][string]$AzureDevOpsPat,
    [string]$ReportPath = (Join-Path $PWD 'servicenow-avd-configuration.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$instance = $InstanceUrl.AbsoluteUri.TrimEnd('/')
$token = Invoke-RestMethod -Method Post -Uri "$instance/oauth_token.do" -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type = 'client_credentials'
    client_id = $ClientId
    client_secret = $ClientSecret
}
if ([string]::IsNullOrWhiteSpace([string]$token.access_token)) { throw 'ServiceNow did not return an OAuth access token.' }
$headers = @{ Authorization = "Bearer $($token.access_token)"; Accept = 'application/json' }

function Invoke-SnTable {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Table,
        [string]$SysId,
        [hashtable]$Body
    )
    $uri = "$instance/api/now/table/$Table"
    if ($SysId) { $uri += "/$SysId" }
    $parameters = @{ Method = $Method; Uri = $uri; Headers = $headers }
    if ($Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    return (Invoke-RestMethod @parameters).result
}

function Get-SnRecords {
    param([Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][string]$Query, [string]$Fields = 'sys_id')
    $encodedQuery = [Uri]::EscapeDataString($Query)
    $encodedFields = [Uri]::EscapeDataString($Fields)
    $uri = "$instance/api/now/table/$Table`?sysparm_query=$encodedQuery&sysparm_fields=$encodedFields&sysparm_limit=20"
    return @((Invoke-RestMethod -Method Get -Uri $uri -Headers $headers).result)
}

function Set-SnExactRecord {
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][hashtable]$Body,
        [string]$Fields = 'sys_id'
    )
    $records = @(Get-SnRecords -Table $Table -Query $Query -Fields $Fields)
    if ($records.Count -gt 1) { throw "ServiceNow query for $Table is ambiguous: $Query" }
    if ($records.Count -eq 1) {
        $sysId = [string]$records[0].sys_id
        [void](Invoke-SnTable -Method PATCH -Table $Table -SysId $sysId -Body $Body)
        return $sysId
    }
    $created = Invoke-SnTable -Method POST -Table $Table -Body $Body
    if ([string]::IsNullOrWhiteSpace([string]$created.sys_id)) { throw "ServiceNow did not return a sys_id for new $Table record." }
    return [string]$created.sys_id
}

$ritmSysId = 'aeed229047801200e0ef563dbb9a71c2'
$sessionPipelineUrl = 'https://dev.azure.com/ThomasWillmus0350/KITSLAB/_apis/pipelines/6/runs?api-version=7.1'

$catalogItemId = Set-SnExactRecord -Table 'sc_cat_item' -Query 'name=Order AVD Build' -Fields 'sys_id,name,active' -Body @{
    name = 'Order AVD Build'
    short_description = 'Request a personal Azure Virtual Desktop session host.'
    description = 'Creates a private personal Windows 11 Azure Virtual Desktop for the requested-for user.'
    active = $true
    no_quantity = $true
    no_cart = $false
    no_order = $false
}

$requestedForVariableId = Set-SnExactRecord -Table 'item_option_new' -Query "cat_item=$catalogItemId^name=requested_for" -Fields 'sys_id,name,question_text,type,reference,mandatory,active,cat_item' -Body @{
    cat_item = $catalogItemId
    name = 'requested_for'
    question_text = 'Requested for'
    type = '8'
    reference = 'sys_user'
    reference_qual = 'active=true'
    mandatory = $true
    active = $true
    order = 100
    read_only = $false
}

$userId = Set-SnExactRecord -Table 'sys_user' -Query 'user_name=AVDtest01@keepitsimple.business' -Fields 'sys_id,user_name,email,active' -Body @{
    user_name = 'AVDtest01@keepitsimple.business'
    email = 'AVDtest01@keepitsimple.business'
    first_name = 'AVD'
    last_name = 'Test01'
    active = $true
    web_service_access_only = $false
}

$fieldSpecifications = @(
    @{ element = 'u_avd_build_status'; label = 'AVD Build Status'; maxLength = 20 },
    @{ element = 'u_avd_hostname'; label = 'AVD Hostname'; maxLength = 15 },
    @{ element = 'u_ado_run_id'; label = 'Azure DevOps Run ID'; maxLength = 40 },
    @{ element = 'u_ado_run_url'; label = 'Azure DevOps Run URL'; maxLength = 1000 },
    @{ element = 'u_ado_queue_state'; label = 'Azure DevOps Queue State'; maxLength = 40 },
    @{ element = 'u_ado_queue_token'; label = 'Azure DevOps Queue Token'; maxLength = 36 }
)
foreach ($field in $fieldSpecifications) {
    [void](Set-SnExactRecord -Table 'sys_dictionary' -Query "name=sc_req_item^element=$($field.element)" -Body @{
        name = 'sc_req_item'
        element = $field.element
        column_label = $field.label
        internal_type = 'string'
        max_length = $field.maxLength
        active = $true
    })
}
foreach ($attempt in 1..12) {
    $fieldNames = @(Get-SnRecords -Table 'sys_dictionary' -Query 'name=sc_req_item^elementINu_avd_build_status,u_avd_hostname,u_ado_run_id,u_ado_run_url,u_ado_queue_state,u_ado_queue_token' -Fields 'element' | ForEach-Object { [string]$_.element })
    if ($fieldNames.Count -eq 6) { break }
    if ($attempt -eq 12) { throw "ServiceNow did not expose all required RITM fields after schema updates: $($fieldNames -join ', ')" }
    Start-Sleep -Seconds 5
}

$authProfileId = Set-SnExactRecord -Table 'sys_auth_profile_basic' -Query 'name=Azure DevOps AVD PAT' -Fields 'sys_id,name,username' -Body @{
    name = 'Azure DevOps AVD PAT'
    username = 'avd-poc'
    password = $AzureDevOpsPat
}

$restMessageId = Set-SnExactRecord -Table 'sys_rest_message' -Query 'name=Azure DevOps AVD' -Fields 'sys_id,name' -Body @{
    name = 'Azure DevOps AVD'
    rest_endpoint = $sessionPipelineUrl
    authentication_type = 'basic'
    use_basic_auth = $true
    basic_auth_profile = $authProfileId
}

$existingRestMethods = @(Get-SnRecords -Table 'sys_rest_message_fn' -Query "rest_message=$restMessageId" -Fields 'sys_id,function_name,rest_message')
if ($existingRestMethods.Count -gt 1) { throw 'Multiple REST methods exist for the Azure DevOps AVD REST Message.' }
$restMethodQuery = if ($existingRestMethods.Count -eq 1) { "sys_id=$($existingRestMethods[0].sys_id)" } else { "rest_message=$restMessageId^function_name=Queue pipeline" }
$restMethodId = Set-SnExactRecord -Table 'sys_rest_message_fn' -Query $restMethodQuery -Fields 'sys_id,function_name,rest_message' -Body @{
    rest_message = $restMessageId
    function_name = 'Queue pipeline'
    http_method = 'post'
    rest_endpoint = $sessionPipelineUrl
    authentication_type = 'inherit_from_parent'
    content = '{}'
}

$beforeScript = @'
(function executeRule(current, previous) {
    var match = /^RITM([0-9]{1,12})$/i.exec(String(current.number));
    if (!match) {
        gs.error('AVD catalog request has an invalid RITM number: ' + current.number);
        return;
    }
    var hostname = 'AVD' + match[1];
    if (hostname.length > 15) {
        gs.error('AVD catalog request derives a hostname longer than 15 characters: ' + hostname);
        return;
    }
    current.setValue('u_avd_hostname', hostname);
    current.setValue('u_avd_build_status', 'Queued');
})(current, previous);
'@

$queueScript = @'
(function executeRule(current, previous) {
    var operation = current.operation();
    if (operation === 'update' && !current.u_avd_build_status.changesTo('Queued'))
        return;
    if (operation === 'insert' && String(current.u_avd_build_status) !== 'Queued')
        return;
    if (String(current.u_ado_queue_state)) {
        gs.warn('AVD queue suppressed because a durable queue state already exists for ' + current.number + ': ' + current.u_ado_queue_state);
        return;
    }

    var match = /^RITM([0-9]{1,12})$/i.exec(String(current.number));
    if (!match)
        return;
    var hostname = 'AVD' + match[1];
    var requestedForId = String(current.variables.requested_for || current.getValue('requested_for') || '');
    var requestedFor = new GlideRecord('sys_user');
    if (!requestedForId || !requestedFor.get(requestedForId) || String(requestedFor.getValue('active')) !== '1') {
        gs.error('AVD catalog request has no active requested-for user: ' + current.number);
        return;
    }
    var upn = String(requestedFor.getValue('user_name') || requestedFor.getValue('email') || '').toLowerCase();
    if (!/^[^\s@]+@[^\s@]+$/.test(upn)) {
        gs.error('AVD catalog request has no usable requested-for UPN: ' + current.number);
        return;
    }

    var claimToken = gs.generateGUID();
    var update = new GlideRecord('sc_req_item');
    if (!update.get(current.getUniqueValue()))
        return;
    update.setWorkflow(false);
    update.setValue('requested_for', requestedFor.getUniqueValue());
    update.setValue('u_ado_queue_state', 'Claimed');
    update.setValue('u_ado_queue_token', claimToken);
    update.update();

    var claim = new GlideRecord('sc_req_item');
    if (!claim.get(current.getUniqueValue()) || String(claim.u_ado_queue_token) !== claimToken) {
        gs.warn('AVD queue claim lost before submission for ' + current.number + '.');
        return;
    }
    try {
        var request = new sn_ws.RESTMessageV2('Azure DevOps AVD', 'Queue pipeline');
        request.setRequestHeader('Content-Type', 'application/json');
        request.setRequestBody(JSON.stringify({ templateParameters: {
            ritmNumber: String(current.number),
            ritmSysId: String(current.getUniqueValue()),
            requestedHostName: hostname,
            requestedForUpn: upn
        }}));
        var response = request.execute();
        var status = response.getStatusCode();
        if (status !== 200 && status !== 201)
            throw new Error('Azure DevOps queue returned HTTP ' + status + ': ' + response.getErrorMessage());
        var result = JSON.parse(response.getBody());
        if (update.get(current.getUniqueValue()) && String(update.u_ado_queue_token) === claimToken) {
            update.setWorkflow(false);
            update.setValue('u_ado_run_id', String(result.id));
            update.setValue('u_ado_run_url', result._links && result._links.web ? String(result._links.web.href) : '');
            update.setValue('u_ado_queue_state', 'Queued');
            update.work_notes = 'Queued Azure DevOps run ' + result.id + ' for ' + hostname + '.';
            update.update();
        }
    } catch (error) {
        gs.error('AVD Azure DevOps queue failed for ' + current.number + ': ' + error.message);
        if (update.get(current.getUniqueValue()) && String(update.u_ado_queue_token) === claimToken) {
            update.setWorkflow(false);
            update.setValue('u_avd_build_status', 'Failed');
            update.setValue('u_ado_queue_state', 'Reconcile Required');
            update.work_notes = 'Azure DevOps queue outcome requires reconciliation; do not retry automatically: ' + error.message;
            update.update();
        }
    }
})(current, previous);
'@

$beforeRuleId = Set-SnExactRecord -Table 'sys_script' -Query 'name=AVD Derive Request Identity^collection=sc_req_item' -Fields 'sys_id,name,collection' -Body @{
    name = 'AVD Derive Request Identity'
    collection = 'sc_req_item'
    active = $false
    advanced = $true
    when = 'before'
    order = 100
    action_insert = $true
    action_update = $false
    filter_condition = "cat_item=$catalogItemId"
    script = $beforeScript
}

$queueRuleId = Set-SnExactRecord -Table 'sys_script' -Query 'name=AVD Queue Azure DevOps^collection=sc_req_item' -Fields 'sys_id,name,collection' -Body @{
    name = 'AVD Queue Azure DevOps'
    collection = 'sc_req_item'
    active = $false
    advanced = $true
    when = 'after'
    order = 200
    action_insert = $true
    action_update = $true
    filter_condition = "cat_item=$catalogItemId"
    script = $queueScript
}

$configuredMessage = @(Get-SnRecords -Table 'sys_rest_message' -Query "sys_id=$restMessageId" -Fields 'sys_id,name,authentication_type,basic_auth_profile')
$profileReference = if ($configuredMessage.Count -eq 1 -and $configuredMessage[0].basic_auth_profile -is [string]) {
    [string]$configuredMessage[0].basic_auth_profile
} elseif ($configuredMessage.Count -eq 1) {
    [string]$configuredMessage[0].basic_auth_profile.value
} else { '' }
if ($configuredMessage.Count -ne 1 -or [string]$configuredMessage[0].authentication_type -cne 'basic' -or $profileReference -cne $authProfileId) {
    throw 'The ServiceNow REST Message did not retain its exact Basic authentication profile; queue rules remain inactive.'
}
[void](Invoke-SnTable -Method PATCH -Table 'sys_script' -SysId $beforeRuleId -Body @{ active = $true })
[void](Invoke-SnTable -Method PATCH -Table 'sys_script' -SysId $queueRuleId -Body @{ active = $true })

[void](Invoke-SnTable -Method PATCH -Table 'sc_req_item' -SysId $ritmSysId -Body @{
    cat_item = $catalogItemId
    requested_for = $userId
    u_avd_hostname = 'AVD0000001'
})

$report = [ordered]@{
    catalogItemId = $catalogItemId
    requestedForVariableId = $requestedForVariableId
    testRequestSysId = $ritmSysId
    requestedForUserId = $userId
    authProfileId = $authProfileId
    restMessageId = $restMessageId
    restMethodId = $restMethodId
    beforeRuleId = $beforeRuleId
    queueRuleId = $queueRuleId
    pipelineId = 6
}
$parent = Split-Path -Parent $ReportPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8
Write-Host 'Configured ServiceNow AVD catalog integration without exposing credentials.'
