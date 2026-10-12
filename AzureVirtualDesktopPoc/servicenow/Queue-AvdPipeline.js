/*
 * Flow Designer custom Action script.
 * Inputs: ritm_number, ritm_sys_id, requested_for_upn
 * Outputs: hostname, ado_run_id, ado_run_url
 *
 * Configure a REST Message named "Azure DevOps AVD" with a POST method named
 * "Queue pipeline". Put its authentication in a credential/connection alias.
 */
(function execute(inputs, outputs) {
    var match = /^RITM([0-9]{1,12})$/i.exec(String(inputs.ritm_number || '').trim());
    if (!match) {
        throw new Error('RITM number must be RITM followed by 1-12 digits.');
    }

    var hostname = 'AVD' + match[1];
    if (hostname.length > 15) {
        throw new Error('Derived AVD hostname exceeds the Windows 15-character limit.');
    }
    if (!/^[0-9a-f]{32}$/i.test(String(inputs.ritm_sys_id || ''))) {
        throw new Error('RITM sys_id is invalid.');
    }
    if (!/^[^\s@]+@[^\s@]+$/.test(String(inputs.requested_for_upn || ''))) {
        throw new Error('Requested-for UPN is invalid.');
    }

    var request = new sn_ws.RESTMessageV2('Azure DevOps AVD', 'Queue pipeline');
    request.setRequestHeader('Content-Type', 'application/json');
    request.setRequestBody(JSON.stringify({
        templateParameters: {
            ritmNumber: 'RITM' + match[1],
            ritmSysId: String(inputs.ritm_sys_id).toLowerCase(),
            requestedHostName: hostname,
            requestedForUpn: String(inputs.requested_for_upn).toLowerCase()
        }
    }));

    var response = request.execute();
    var status = response.getStatusCode();
    if (status !== 200 && status !== 201) {
        throw new Error('Azure DevOps queue request failed with HTTP ' + status + ': ' + response.getErrorMessage());
    }

    var body = JSON.parse(response.getBody());
    outputs.hostname = hostname;
    outputs.ado_run_id = String(body.id);
    outputs.ado_run_url = body._links && body._links.web ? body._links.web.href : '';
})(inputs, outputs);
