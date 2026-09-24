---
source: Microsoft Learn and Context7 API
library: Azure DevOps REST API and Microsoft Graph
package: azure-devops-wif
topic: ARM service connections with workload identity federation
tech_stack: Azure DevOps Services, Microsoft Entra ID, Azure public cloud
fetched: 2026-09-16T00:00:00Z
official_docs: https://learn.microsoft.com/en-us/azure/devops/pipelines/release/automate-service-connections?view=azure-devops
---

# Azure DevOps ARM workload-identity service connections (2026)

## Current model

- A manually created **single-tenant Entra app registration plus its service principal** is supported. A **user-assigned managed identity** is an alternative, not a requirement. A system-assigned managed identity isn't the manual identity option documented for this workflow.
- For an app registration, Azure DevOps `authorization.parameters.serviceprincipalid` is the application's **Application (client) ID (`appId`)**, not the application object ID or service-principal object ID. Azure RBAC role assignment uses the service principal's **object ID (`principalId`)**.
- Use `creationMode: Manual`, `authorization.scheme: WorkloadIdentityFederation`, `type: AzureRM`, `isShared: false`, and `isReady: true`.
- Current Azure-public-cloud connections use the **Microsoft Entra issuer**. The old `https://vstoken.dev.azure.com/<organization-id>` issuer is deprecated and retires July 1, 2027.
- One app registration can technically hold up to 20 federated identity credentials, so one app can back all five connections. Separate apps/service principals are usually preferable when the five connections need distinct RBAC and lifecycle boundaries.

## Required order

1. Create each single-tenant application (`signInAudience: AzureADMyOrg`) with Microsoft Graph.
2. Create its service principal. Retain application `id`, application `appId`, and service-principal `id`.
3. POST the Azure DevOps service endpoint, supplying the `appId`.
4. Read the returned `authorization.parameters.workloadIdentityFederationIssuer` and `workloadIdentityFederationSubject` exactly as returned.
5. POST the federated identity credential to the **application object** (Graph `/applications/{id}`), using those exact values and audience `api://AzureADTokenExchange`.
6. Assign Azure RBAC to the service-principal object ID at the minimum required scope.
7. Allow propagation, then exercise the connection with a supported Azure pipeline task. A successful endpoint-create response alone is not an end-to-end authentication test.
8. Explicitly assert that `allPipelines.authorized` is false, then authorize only named pipeline IDs if required.

The service endpoint must precede the federated credential because Azure DevOps generates the subject from Azure DevOps object IDs. Do not precompute the new subject from display names.

## Microsoft Graph identity requests

Create an application (repeat with a suitable app display name for each service connection):

```http
POST https://graph.microsoft.com/v1.0/applications
Authorization: Bearer <GRAPH_TOKEN>
Content-Type: application/json

{
  "displayName": "app-sc-avd-poc-bootstrap",
  "signInAudience": "AzureADMyOrg"
}
```

Create its service principal using the returned `appId`:

```http
POST https://graph.microsoft.com/v1.0/servicePrincipals
Authorization: Bearer <GRAPH_TOKEN>
Content-Type: application/json

{ "appId": "<APPLICATION_CLIENT_ID>" }
```

No client secret is needed or recommended.

## Azure DevOps service endpoint request

```http
POST https://dev.azure.com/ThomasWillmus0350/_apis/serviceendpoint/endpoints?api-version=7.1
Authorization: Bearer <AZDO_TOKEN>
Content-Type: application/json

{
  "data": {
    "subscriptionId": "57383abf-70be-4ada-aad8-c939d04bd112",
    "subscriptionName": "<ACTUAL_SUBSCRIPTION_DISPLAY_NAME>",
    "environment": "AzureCloud",
    "scopeLevel": "Subscription",
    "creationMode": "Manual"
  },
  "name": "sc-avd-poc-bootstrap",
  "type": "AzureRM",
  "url": "https://management.azure.com/",
  "authorization": {
    "parameters": {
      "tenantid": "ce5eca28-c365-424f-b2cf-9e5633886631",
      "serviceprincipalid": "<APPLICATION_CLIENT_ID>"
    },
    "scheme": "WorkloadIdentityFederation"
  },
  "isShared": false,
  "isReady": true,
  "serviceEndpointProjectReferences": [
    {
      "projectReference": {
        "id": "cbab5132-6471-4fe8-9102-f5f132182ce2",
        "name": "KITSLAB"
      },
      "name": "sc-avd-poc-bootstrap"
    }
  ]
}
```

Repeat with matching top-level and project-reference names:

- `sc-avd-poc-bootstrap`
- `sc-avd-poc-deploy`
- `sc-avd-poc-readiness`
- `sc-avd-poc-assignment`
- `sc-avd-poc-decommission`

Use the actual subscription display name. The documented endpoint is organization-scoped; project association is in `serviceEndpointProjectReferences`.

Expected response parameters include:

```json
{
  "serviceprincipalid": "<APPLICATION_CLIENT_ID>",
  "tenantid": "ce5eca28-c365-424f-b2cf-9e5633886631",
  "workloadIdentityFederationIssuer": "https://login.microsoftonline.com/ce5eca28-c365-424f-b2cf-9e5633886631/v2.0",
  "workloadIdentityFederationIssuerType": "EntraID",
  "workloadIdentityFederationSubject": "<SERVER-GENERATED-SUBJECT>"
}
```

For 2026 Entra-issued connections, the documented subject shape is:

```text
<microsoft-entra-prefix>/sc/<azure-devops-organization-id>/<service-connection-id>
```

The prefix and IDs are generated values. **Use the returned subject verbatim.** The older subject `sc://ThomasWillmus0350/KITSLAB/<connection-name>` belongs to the deprecated Azure DevOps issuer model and should not be synthesized for a new connection.

## Federated identity credential

For each returned endpoint:

```http
POST https://graph.microsoft.com/v1.0/applications/<APPLICATION_OBJECT_ID>/federatedIdentityCredentials
Authorization: Bearer <GRAPH_TOKEN>
Content-Type: application/json

{
  "name": "fic-sc-avd-poc-bootstrap",
  "issuer": "https://login.microsoftonline.com/ce5eca28-c365-424f-b2cf-9e5633886631/v2.0",
  "subject": "<EXACT workloadIdentityFederationSubject FROM AZDO RESPONSE>",
  "audiences": ["api://AzureADTokenExchange"]
}
```

Graph accepts either `/applications/{application-object-id}/...` or `/applications(appId='{client-id}')/...`. The credential name is immutable, URL-friendly, and unique on the app. Issuer plus subject must be unique on the app.

## Readiness and verification behavior

- Endpoint creation intentionally occurs before the federated credential and RBAC assignment. Therefore HTTP 200 and `isReady: true` mean the endpoint object is configured/active, not that token exchange and ARM authorization have already succeeded.
- Inspect after creation with:

```http
GET https://dev.azure.com/ThomasWillmus0350/cbab5132-6471-4fe8-9102-f5f132182ce2/_apis/serviceendpoint/endpoints?type=AzureRM&authSchemes=WorkloadIdentityFederation&includeFailed=true&api-version=7.1
```

- Check `authorization.parameters`, `isReady`, and `operationStatus`, but perform the definitive test only after the FIC and RBAC assignment propagate: run a supported task such as `AzureCLI@2` and call `az account show` or a least-privilege ARM read.
- The documented UI's **Verify** step performs token/credential validation after the federated credential exists. The public endpoint-create REST contract does not document a separate supported “verify endpoint” operation for this automation sequence.

## Keep “Grant access permission to all pipelines” disabled

`isShared: false` prevents cross-project sharing; it is not the pipeline authorization flag. Do not send any open-access setting during creation. Then explicitly set and verify the protected-resource permission using resource type `endpoint` and the returned service-connection ID:

```http
PATCH https://dev.azure.com/ThomasWillmus0350/cbab5132-6471-4fe8-9102-f5f132182ce2/_apis/pipelines/pipelinepermissions/endpoint/<SERVICE_CONNECTION_ID>?api-version=7.1-preview.1
Content-Type: application/json

{
  "allPipelines": { "authorized": false }
}
```

Verify:

```http
GET https://dev.azure.com/ThomasWillmus0350/cbab5132-6471-4fe8-9102-f5f132182ce2/_apis/pipelines/pipelinepermissions/endpoint/<SERVICE_CONNECTION_ID>?api-version=7.1-preview.1
```

Require `allPipelines.authorized == false`. To allow one pipeline without opening the connection, PATCH `{"pipelines":[{"id":123,"authorized":true}]}`.

## Environments and approval checks

The supported stable environment-create API is Distributed Task 7.1:

```http
POST https://dev.azure.com/ThomasWillmus0350/cbab5132-6471-4fe8-9102-f5f132182ce2/_apis/distributedtask/environments?api-version=7.1
Content-Type: application/json

{
  "name": "<ENVIRONMENT_NAME>",
  "description": "AVD PoC deployment environment"
}
```

Use the integer `id` returned by that request to attach an approval check through the documented preview API:

```http
POST https://dev.azure.com/ThomasWillmus0350/cbab5132-6471-4fe8-9102-f5f132182ce2/_apis/pipelines/checks/configurations?api-version=7.1-preview.1
Content-Type: application/json

{
  "settings": {
    "approvers": [
      { "id": "<AZURE_DEVOPS_IDENTITY_GUID>", "displayName": null }
    ],
    "executionOrder": "anyOrder",
    "minRequiredApprovers": 1,
    "instructions": "Approve deployment to this environment.",
    "blockedApprovers": []
  },
  "timeout": 1440,
  "type": {
    "id": "8c6f20a7-a545-4486-9777-f762fafe0d4d",
    "name": "Approval"
  },
  "resource": {
    "type": "environment",
    "id": "<ENVIRONMENT_ID>",
    "name": "<ENVIRONMENT_NAME>"
  }
}
```

Approver IDs are Azure DevOps identity GUIDs, not blindly assumed Entra object IDs. Resolve/confirm the identity in the organization first. Approval/check configuration remains `7.1-preview.1`; environment creation itself is stable `7.1`.

## Authoritative links

- Automation and ordering (updated April 2026): https://learn.microsoft.com/en-us/azure/devops/pipelines/release/automate-service-connections?view=azure-devops
- 2026 issuer/subject formats and troubleshooting: https://learn.microsoft.com/en-us/azure/devops/pipelines/release/troubleshoot-workload-identity?view=azure-devops
- Service endpoint create 7.1: https://learn.microsoft.com/en-us/rest/api/azure/devops/serviceendpoint/endpoints/create?view=azure-devops-rest-7.1
- Service endpoint list 7.1: https://learn.microsoft.com/en-us/rest/api/azure/devops/serviceendpoint/endpoints/get-service-endpoints?view=azure-devops-rest-7.1
- Graph application create: https://learn.microsoft.com/en-us/graph/api/application-post-applications?view=graph-rest-1.0
- Graph service principal create: https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-serviceprincipals?view=graph-rest-1.0
- Graph federated credential create: https://learn.microsoft.com/en-us/graph/api/federatedidentitycredential-post?view=graph-rest-1.0
- Environment create 7.1: https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/environments/add?view=azure-devops-rest-7.1
- Approval/check add 7.1 preview: https://learn.microsoft.com/en-us/rest/api/azure/devops/approvalsandchecks/check-configurations/add?view=azure-devops-rest-7.1
- Pipeline permission update 7.1 preview: https://learn.microsoft.com/en-us/rest/api/azure/devops/approvalsandchecks/pipeline-permissions/update-pipeline-permisions-for-resource?view=azure-devops-rest-7.1
- Pipeline permission read 7.1 preview: https://learn.microsoft.com/en-us/rest/api/azure/devops/approvalsandchecks/pipeline-permissions/get?view=azure-devops-rest-7.1
