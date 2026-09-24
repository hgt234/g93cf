# ServiceNow configuration for AVD automation

This is the canonical ServiceNow setup for the implemented Azure DevOps pipelines. ServiceNow owns request state and sends request identity only; Azure DevOps owns infrastructure configuration.

```text
Catalog RITM -> guarded Business Rule -> Azure DevOps Runs API
             <- sc_req_item PATCH <- AVD pipeline
```

## 1. Create the RITM fields

Add these fields to `sc_req_item`:

| Field | Type | Values or purpose |
|---|---|---|
| `u_avd_build_status` | Choice/String | `Queued`, `In Progress`, `Ready`, `Failed`, `Timed Out` |
| `u_avd_hostname` | String(15) | RITM-derived Windows hostname |
| `u_avd_platform` | String | Optional; hybrid writes `Hybrid GPU` |
| `u_ado_run_id` | String | Queued Azure DevOps run ID |
| `u_ado_run_url` | URL/String | Azure DevOps run link |
| `u_ado_queue_state` | String(40) | Durable `Claimed`, `Queued`, or `Reconcile Required` submission state |
| `u_ado_queue_token` | String(36) | Per-submission claim token used to suppress duplicate queues |

Do not use alternate values such as `Submitted`, `Building`, `Complete`, or `Pipeline Started`.

## 2. Create the callback identity

Create a dedicated user, for example `avd.integration`:

- active and **Web service access only**;
- no interactive administrator role;
- custom role with read access to applicable `sc_req_item` records;
- write access only to the fields above and `work_notes`.

Test with elevated access only if required to isolate an ACL problem, then remove it immediately.

## 3. Configure OAuth client credentials

OAuth client credentials is the canonical Azure DevOps-to-ServiceNow authentication method.

1. Enable inbound client-credentials grants if the instance requires `glide.oauth.inbound.client.credential.grant_type.enabled=true`.
2. Under **System OAuth > Application Registry**, create an inbound client-credentials application.
3. Set its OAuth application user to the dedicated integration user.
4. Create an API auth scope such as `avd_ritm_patch`.
5. Map the scope to Table API `PATCH /api/now/table/sc_req_item/{sys_id}`.
6. Attach the scope to the OAuth application.
7. Store the client ID and secret only in the protected Azure DevOps variable group.

Token request:

```http
POST https://{instance}.service-now.com/oauth_token.do
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&client_id={client-id}&client_secret={client-secret}
```

The implementation requests a new token for every callback invocation. Never print tokens. Rotate any secret that has been exposed outside its secret store.

Basic authentication with a web-service-only account remains supported for developer-instance bootstrap. Populate either the OAuth pair or the Basic pair, never both.

## 4. Configure callback variables

Create variable group `avd-poc-servicenow` with the implemented names:

| Variable | Secret | Value or purpose |
|---|---:|---|
| `SN_INSTANCE_URL` | No | ServiceNow instance URL |
| `SN_CLIENT_ID` | No | OAuth client ID |
| `SN_CLIENT_SECRET` | Yes | OAuth client secret |
| `SN_USERNAME` | No | Empty for OAuth |
| `SN_PASSWORD` | Yes | Empty for OAuth |
| `SN_STATUS_FIELD` | No | `u_avd_build_status` |
| `SN_HOSTNAME_FIELD` | No | `u_avd_hostname` |
| `SN_PLATFORM_FIELD` | No | `u_avd_platform` |

Authorize this group only for the session-host and hybrid-onboard pipelines that need it. The repository contains no credential values.

## 5. Configure ServiceNow-to-Azure DevOps authentication

For this developer POC, create a short-lived Azure DevOps PAT with only **Build: Read & execute**, limited to organization `ThomasWillmus0350`. Store it in a ServiceNow Basic Auth credential with a non-empty username and the PAT as password.

Never store the PAT in a catalog variable, Flow Designer script, REST body, work note, or log. Replace it with an approved Entra-backed integration identity for production.

## 6. Create the outbound REST Message

Create REST Message `Azure DevOps AVD` and method `Queue pipeline`:

```http
POST https://dev.azure.com/ThomasWillmus0350/KITSLAB/_apis/pipelines/6/runs?api-version=7.1
Content-Type: application/json
```

Attach the credential from step 5. The body contains exactly the implemented contract:

```json
{
  "templateParameters": {
    "ritmNumber": "RITM0000001",
    "ritmSysId": "aeed229047801200e0ef563dbb9a71c2",
    "requestedHostName": "AVD0000001",
    "requestedForUpn": "AVDtest01@keepitsimple.business"
  }
}
```

Parameter names are case-sensitive. Do not send environment, image, subscription, VM size, or a requester-selected hostname.

## 7. Configure the catalog Business Rules

`Set-ServiceNowAvdCatalogIntegration.ps1` idempotently creates or reactivates the `Order AVD Build` catalog item by exact name, then creates two exact `sc_req_item` Business Rules for it:

- `AVD Derive Request Identity`, a before-insert rule that validates the RITM number and derives `AVD<digits>`;
- `AVD Queue Azure DevOps`, an after-insert/update rule that queues only when status enters `Queued` and no durable queue state exists.

The queue rule:

1. accepts `RITM` plus 1-12 digits;
2. derives `AVD<digits>` and preserves leading zeros;
3. validates the requested-for UPN;
4. atomically records a unique claim before outbound submission;
5. sends `ritmNumber`, `ritmSysId`, `requestedHostName`, and `requestedForUpn`;
6. accepts HTTP 200 or 201 and records the run correlation;
7. records `Reconcile Required` after an ambiguous or failed submission and never retries it automatically.

Never expose `requestedHostName` as editable requester input.

## 8. Configure the catalog item

The protected configuration pipeline creates or reactivates `Order AVD Build` and adds a mandatory `Requested for` reference variable backed by `sys_user`. The queue rule resolves that reference server-side, requires an active user with a UPN-shaped `user_name` or email, and writes the same user to the RITM's native `requested_for` field before queuing Azure DevOps. Confirm that the item is available to the intended test user through the appropriate ServiceNow catalog. Do not add environment, image, hostname, Azure ID, or service-connection choices.

Submission sequence:

1. Select an active user in the mandatory `Requested for` reference variable.
2. Validate server-side that the referenced user has a usable UPN and associate that user with the RITM.
3. Derive the hostname and transition the RITM to `Queued`.
4. Claim the request and call the outbound REST Message.
5. Write only the returned run ID and URL without overwriting a newer pipeline status.
6. If `u_ado_queue_state` is `Reconcile Required`, verify Azure DevOps before clearing the claim and retrying manually.

The callback script performs unconditional PATCH operations, so Azure DevOps remains authoritative for the final run result. A timeout or reconciliation action must never delete or rebuild the VM.

## 9. Validate the callback

Run commands from the repository parent directory. Use a disposable RITM when testing writes:

```powershell
pwsh ./AzureVirtualDesktopPoc/scripts/Update-ServiceNowRitm.ps1 `
  -InstanceUrl 'https://example.service-now.com' `
  -ClientId '<client-id>' `
  -ClientSecret '<secret-from-secure-store>' `
  -RitmSysId '0123456789abcdef0123456789abcdef' `
  -Status 'In Progress' `
  -HostName 'AVD0000001' `
  -Message 'Callback validation.'
```

Expected result: HTTP 200, matching `result.sys_id`, updated status/hostname, and a work note. Do not paste real secrets into saved shell history or documentation.

## 10. Validate queue and lifecycle

1. Test the REST Message; require HTTP 200/201 and a run ID.
2. Submit `RITM0000001` for `AVDtest01@keepitsimple.business`.
3. Confirm `Queued -> In Progress -> Ready` and run correlation.
4. Confirm routine `Ready` means Azure, Entra, applications, MDE, AVD, and assignment passed. Intune compliance is certified only by a separate run with `AVD_REQUIRE_INTUNE_COMPLIANT=true`.
5. Force a safe validation failure and confirm the pipeline attempts a `Failed` callback. If callback delivery fails, use Azure DevOps as the authoritative record.
6. Test the timer on a disposable request and confirm `Timed Out` without deletion.

## Hybrid catalog item

Create a separate **Hybrid GPU Desktop** catalog item and REST Message targeting its Azure DevOps pipeline. Use `servicenow/Queue-AvdHybridPipeline.js`; it sends the same four fields and writes `u_avd_platform=Hybrid GPU`.

## Security boundary

- ServiceNow cannot select infrastructure settings.
- Callback ACLs are field-limited.
- Secrets remain in credentials or secret variables.
- Ordinary Azure service connections have no delete actions.
- Conditional Access is out of scope; do not touch it.
