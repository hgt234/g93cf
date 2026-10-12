# ServiceNow request integration

ServiceNow supplies request identity only. Azure resource IDs, images, SKUs, policies, and service connections remain controlled by Azure DevOps variable groups.

For full configuration, see [../ServiceNowconfig.md](../ServiceNowconfig.md).

## Canonical request contract

Queue `pipelines/azure-pipelines-session-host.yml` with exactly these case-sensitive parameter names:

```http
POST https://dev.azure.com/{organization}/{project}/_apis/pipelines/{pipelineId}/runs?api-version=7.1
Content-Type: application/json
Authorization: configured on the REST Message credential
```

```json
{
  "templateParameters": {
    "ritmNumber": "RITM0000001",
    "ritmSysId": "0123456789abcdef0123456789abcdef",
    "requestedHostName": "AVD0000001",
    "requestedForUpn": "user@contoso.com"
  }
}
```

`requestedHostName` is not requester-selected. `Queue-AvdPipeline.js` derives it as `AVD` plus the digits from `ritmNumber`; Azure DevOps independently verifies the same rule. Leading zeros are preserved and the Windows name must be 15 characters or fewer.

## Fields and statuses

Create or map these `sc_req_item` fields:

| Field | Purpose |
|---|---|
| `u_avd_build_status` | `Queued`, `In Progress`, `Ready`, `Failed`, or `Timed Out` |
| `u_avd_hostname` | Derived hostname |
| `u_avd_platform` | Optional path label, including `Hybrid GPU` |
| `u_ado_run_id` | Azure DevOps run correlation |
| `u_ado_run_url` | Azure DevOps run link |
| `work_notes` | Pipeline progress and failure detail |

ServiceNow sets `Queued` after HTTP 200/201. Pipelines write `In Progress`, `Ready`, or `Failed`. A two-hour ServiceNow timer writes `Timed Out` only if no terminal callback arrives. Timeout never deletes a VM.

## Authentication

- **Outbound ServiceNow to Azure DevOps:** for the developer POC, store a short-lived PAT with only **Build: Read & execute** in a Basic Auth credential. Use a non-empty username. Never put the PAT in script or catalog variables.
- **Inbound Azure DevOps to ServiceNow:** OAuth client credentials with a Table API auth scope restricted to the required `sc_req_item` PATCH is the canonical configuration. Basic authentication remains an implementation-supported bootstrap fallback.
- Acquire an OAuth token for each callback invocation. Do not cache it across pipeline stages; respect the returned expiry and never log the token.

## Implemented Azure DevOps variables

Variable group `avd-poc-servicenow` uses:

```text
SN_INSTANCE_URL
SN_CLIENT_ID
SN_CLIENT_SECRET
SN_USERNAME
SN_PASSWORD
SN_STATUS_FIELD
SN_HOSTNAME_FIELD
SN_PLATFORM_FIELD
```

Mark `SN_CLIENT_SECRET` and `SN_PASSWORD` secret. Populate either the OAuth pair or the Basic pair, not both. The callback script treats unresolved `$(NAME)` macros as absent.

## Hybrid request

The hybrid catalog item queues `pipelines/azure-pipelines-hybrid-onboard.yml` through `Queue-AvdHybridPipeline.js`. It uses the same four-field contract and writes `u_avd_platform=Hybrid GPU`. Infrastructure and provisioning-package values remain in `avd-poc-hybrid`.

## Guardrail

**Conditional Access is out of scope; do not touch it.**
