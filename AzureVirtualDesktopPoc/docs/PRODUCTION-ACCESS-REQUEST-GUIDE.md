# Production access request guide

Use this guide to request identities and access for the implemented Azure Virtual Desktop (AVD) solution without giving engineers broad production access. It is based on the checked-in Bicep, pipelines, scripts, configuration examples, and runbooks.

> **Boundary:** Conditional Access is out of scope. Do not request, inspect, create, change, disable, or delete Conditional Access policies for this solution.

> **Current-state caution:** The Azure-hosted resource groups can be absent after teardown. Names and scopes below describe required setup, not proof that resources currently exist.

## 1. Scope and assumptions

### Azure-hosted path

The primary path creates a private Azure VM, Azure Image Builder resources, a Compute Gallery image, and AVD resources in a dedicated group such as `rg-avd-poc01`. It uses separate deployment, readiness, assignment, and decommission identities. See the [deployment runbook](../DEPLOYMENT-RUNBOOK.md) and [session-host pipeline](../pipelines/azure-pipelines-session-host.yml).

### Optional Hybrid/Proxmox path

The optional path onboards a manually built Proxmox Windows VM through Azure Arc and AVD Hybrid. It has separate Azure roles and service connections and does not create, start, stop, or delete the Proxmox VM. See the [Hybrid runbook](../HYBRID-DEPLOYMENT-RUNBOOK.md) and [Hybrid onboarding pipeline](../pipelines/azure-pipelines-hybrid-onboard.yml).

### Identity terms

- **Application (client) ID:** identifies an app registration. Azure DevOps ARM service-connection configuration and OAuth clients use this value.
- **Service-principal object ID:** identifies the app's enterprise application in this tenant. Azure RBAC assignments and the access pipelines require this value.
- **Application permission:** app-only API access used by a pipeline service principal; it requires tenant admin consent. It does not depend on a signed-in user.
- **Delegated permission:** acts for a signed-in user. It is not the runtime model implemented by these WIF-backed pipelines.
- **Azure RBAC:** authorizes Azure Resource Manager operations. It does not grant Microsoft Graph, Intune, MDE, ServiceNow, or Azure DevOps API access.

## 2. Access request matrix

`Permanent` means the identity remains, not that every privilege remains active. Temporary grants must have an expiry and removal owner.

| Identity / purpose | System | Authentication | Duration | Scope | Azure RBAC / custom role | API permission | Admin consent | Normal owner / approver |
|---|---|---|---|---|---|---|---|---|
| Human bootstrap/operator | Azure, Entra, Azure DevOps | Human + MFA/PIM | Temporary for setup; operator access thereafter least privilege | Target subscription, tenant app registrations, ADO project | PIM/JIT rights to create RGs, role definitions, and assignments; no routine Owner | None for pipeline runtime | N/A | Subscription, Identity, and ADO teams |
| `sc-avd-poc-bootstrap` | Azure/ADO | Entra app + WIF | Temporary privileged | Target subscription | **Owner** during platform/access/image bootstrap; revoke or disable afterward | None | No | Subscription team |
| `sc-avd-poc-deploy` | Azure/Entra | Entra app + WIF | Privileged/JIT or brokered in production | POC RG | `AVD POC Deployment <POC_ID>` includes VM extension write (guest SYSTEM execution) | Graph `User.Read.All` application | Yes | Subscription + Identity teams |
| `sc-avd-poc-readiness` | Azure/Entra/MDE | Entra app + WIF | Permanent in POC; privileged/JIT in production | POC RG plus subscription read-only inventory | `AVD POC Readiness <POC_ID>` includes VM Run Command (guest SYSTEM execution); `AVD POC Planning Inventory <POC_ID>` adds subscription read | Graph `Device.Read.All`, `DeviceManagementManagedDevices.Read.All`; WindowsDefenderATP `Machine.Read.All` | Yes | Subscription + Identity + Defender teams |
| `sc-avd-poc-assignment` | Azure/Entra | Entra app + WIF | Permanent in POC; privileged/JIT or brokered in production | POC RG and child resources | `AVD POC Assignment <POC_ID>`; `roleAssignments/write` can indirectly escalate privilege | Graph `User.Read.All` application | Yes | Subscription + Identity teams |
| `sc-avd-poc-decommission` | Azure/optional Graph | Entra app + WIF | Disabled/unprivileged except approved window | Subscription for implemented RG and custom-role deletion | Temporary **Owner**, preferably PIM/JIT; revoke after run | Only if approved: Graph `Device.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All` | Yes, temporary | Subscription + Identity teams |
| `id-aib-avd-<poc>` | Azure Image Builder | User-assigned managed identity | Resource lifetime | POC RG | `AVD POC Image Builder <POC_ID>` | None | No | Subscription/platform team |
| Session-host VM identity | Azure/Entra | System-assigned managed identity | VM lifetime | Identity only; no repo RBAC assignment | None assigned by repository | None | No | Platform team |
| ADO-to-ServiceNow callback OAuth client | ServiceNow | OAuth 2.0 client credentials | Permanent, rotated | One ServiceNow API scope | N/A | `PATCH /api/now/table/sc_req_item/{sys_id}` only | ServiceNow approval | ServiceNow team |
| ServiceNow integration user, e.g. `avd.integration` | ServiceNow | OAuth application user; Basic only as POC fallback | Permanent least privilege | Applicable AVD RITMs | N/A | Read applicable RITM; write mapped AVD fields and `work_notes` | N/A | ServiceNow team |
| ServiceNow-to-ADO queue identity | Azure DevOps | **Implemented POC:** short-lived PAT in ServiceNow Basic credential | Temporary | One ADO organization; pipeline restriction comes from the PAT owner's ADO ACLs | N/A | PAT scope **Build: Read & execute** plus `Queue builds` only on intended pipeline(s) | No | ADO team |
| ServiceNow configuration administrator | ServiceNow | Human/admin or temporary admin OAuth client | Temporary setup | Catalog, dictionary, user, REST/auth profile, Business Rule, and fixed test records | N/A | GET/POST/PATCH only for objects used by the configuration script | ServiceNow approval | ServiceNow team |
| ServiceNow diagnostic/trigger identity | ServiceNow | Separate temporary OAuth client or human-approved job | Temporary validation | Configuration inventory and disposable test RITM | N/A | Read diagnostic tables; test trigger may PATCH only the approved disposable RITM | ServiceNow approval | ServiceNow team |
| Intune policy administrators | Intune | Human privileged role | Setup/day-2 duty | AVD device groups and assigned policies/apps | N/A | Policy, compliance, application, enrollment, and EDR configuration; not pipeline runtime | N/A | Intune team |
| Defender administrators | Defender portal | Human privileged role | Setup/day-2 duty | Endpoint integration and onboarding policy | N/A | Enable/verify Intune connector and MDE onboarding; not pipeline runtime | N/A | Defender team |
| Licensed requested/test user | Entra/AVD/Intune/MDE | Human | User lifecycle | Assigned VM and app group | Pipeline grants `Virtual Machine User Login` and `Desktop Virtualization User` | None | No | Licensing/AVD team |
| `sc-avd-hybrid-deploy` (optional) | Azure/ADO | Entra app + WIF | Privileged/JIT or brokered in production | Hybrid RG | `AVD Hybrid POC Deployment <POC_ID>` includes Arc extension write (guest SYSTEM execution) | None | No | Subscription team |
| `sc-avd-hybrid-readiness` (optional) | Azure/Entra/MDE | Entra app + WIF | Privileged/JIT recommended | Hybrid RG | `AVD Hybrid POC Readiness <POC_ID>` includes Arc Run Command write (guest SYSTEM execution) | Graph `User.Read.All`, `Device.Read.All`, `DeviceManagementManagedDevices.Read.All`; WindowsDefenderATP `Machine.Read.All` | Yes | Subscription + Identity + Defender teams |
| `sc-avd-hybrid-assignment` (optional) | Azure/Entra | Entra app + WIF | Permanent in POC; privileged/JIT or brokered in production | Hybrid RG | `AVD Hybrid POC Assignment <POC_ID>`; `roleAssignments/write` can indirectly escalate privilege | Graph `User.Read.All` | Yes | Subscription + Identity teams |
| Hybrid decommission principal (optional) | Azure/ADO | Entra app + WIF | Temporary privileged | Subscription/hybrid RG | Temporary Owner or a reviewed equivalent covering RG, role-assignment, and custom-role deletion | None | No | Subscription team |
| Arc onboarding principal (optional) | Azure Arc | Short-lived service-principal credential | Temporary; delete/revoke after Arc connection | Hybrid RG | Built-in `Azure Connected Machine Onboarding` | None | No | Subscription/Hybrid team |
| Hybrid host-pool identity (optional) | Azure | System-assigned managed identity | Host-pool lifetime | Hybrid RG | Built-in `Reader` | None | No | Created by Bicep |
| Proxmox/Hybrid operator (optional) | Proxmox, storage, Intune | Human privileged role | Operational | Exact VM, protected `.ppkg`, and supporting storage | No Azure role unless separately required | Platform-specific | Platform-specific | Proxmox/Hybrid team |

## 3. Identity-by-identity requirements

### 3.1 Human bootstrap/operator access

The engineer needs enough temporary access to create or coordinate:

1. Entra app registrations, service principals, federated credentials, and API-consent requests.
2. Azure resource groups, provider registration, custom role definitions, and role assignments.
3. Azure DevOps service connections, pipelines, protected variable groups, environments, and checks.
4. ServiceNow, Intune, and Defender changes through their owning teams.

Prefer PIM/JIT assignments. A human does not need persistent subscription Owner after bootstrap. Tenant, ADO, ServiceNow, Intune, and Defender administration should remain with their platform teams.

### 3.2 `sc-avd-poc-bootstrap`

**Implemented use:** [platform](../pipelines/azure-pipelines-platform.yml), [access](../pipelines/azure-pipelines-access.yml), and, per the deployment runbook, the [image pipeline](../pipelines/azure-pipelines-image.yml). The optional Hybrid platform and access pipelines also accept a privileged service connection as a queue parameter.

- Request a dedicated single-tenant Entra app/service principal and WIF ARM connection.
- Grant temporary subscription **Owner** so it can create the resource group, custom role definitions, role assignments, and image foundation.
- Protect `avd-poc-platform` and `avd-poc-access-bootstrap` with approvals.
- Revoke Owner and disable pipeline use after bootstrap.

For Hybrid, either activate the same bootstrap principal only during the approved Hybrid platform/access window or request a distinct JIT Hybrid bootstrap principal. It needs enough access to create the Hybrid RG/resources, define and assign Hybrid custom roles, and update the existing AVD workspace reference outside the Hybrid RG. Record the chosen connection explicitly; the checked-in Hybrid YAML does not pin it.

**Production design gap:** `image-main.bicep` redeploys a custom role definition and role assignment on every image run. The current runbook reuses bootstrap for image builds. Before unattended monthly production builds, the subscription team must design a separate image service connection and exact least-privilege role, or retain a controlled JIT bootstrap elevation. No such image-pipeline principal role is defined in this repository. The checked-in monthly cron also cannot supply the required queue-time service connection, subscription, subnet IDs, and customization URI because they have no defaults. Resolve both privilege and scheduled-parameter delivery before enabling the production schedule.

### 3.3 `sc-avd-poc-deploy`

[access.bicep](../infra/access.bicep) assigns this principal `AVD POC Deployment <POC_ID>` at the POC RG. Important operations are:

- deployment read/write/validate/what-if;
- VM, extension, disk, and NIC writes;
- subnet/NIC join;
- Compute and Network reads;
- host-pool read/write and registration-token retrieval.

[New-AvdSessionHost.ps1](../scripts/New-AvdSessionHost.ps1) also resolves the requested user, so request Graph **application** permission `User.Read.All` with admin consent. The custom role contains no delete action.

VM extension write can deploy script-capable extensions and execute in the guest as SYSTEM. Absence of an ARM delete action does not make this identity non-destructive. Use JIT or a brokered deployment path, authorize its service connection only for intended deployment pipelines, monitor extension changes, and enforce an Azure Policy extension allowlist where available.

### 3.4 `sc-avd-poc-readiness`

The custom role permits VM/AVD reads and `Microsoft.Compute/virtualMachines/runCommand/action` at the POC RG. Azure VM Run Command executes arbitrary guest PowerShell as SYSTEM; RBAC does not constrain it to the checked-in inventory command. Classify this as privileged remote execution, not read-only access. Use JIT where practical, restrict the service connection and variable group to the readiness pipeline, and monitor every Run Command invocation. [Wait-AvdReadiness.ps1](../scripts/Wait-AvdReadiness.ps1) requires:

- Graph `Device.Read.All` to find the Entra device;
- Graph `DeviceManagementManagedDevices.Read.All` to query the Intune managed device;
- WindowsDefenderATP `Machine.Read.All` to query MDE machines.

All are application permissions and require admin consent. The Intune endpoint is queried by the implementation even when compliance is not a blocking gate.

The access deployment also assigns this principal `AVD POC Planning Inventory <POC_ID>` at subscription scope. That role contains only `*/read`, with no writes, deletes, actions, or data-plane permissions. It exists because Azure Resource Manager inventory is authorization-filtered and teardown planning must prove the complete fixed scope. Keep this role separate from the RG-scoped readiness role; never grant VM Run Command at subscription scope.

This is still a material confidentiality and blast-radius exception: compromise of the runtime readiness identity exposes inventory and configuration metadata for unrelated subscription resources. For production, prefer a separate planning principal authorized only for approved teardown planning and activated JIT. If the combined POC design is retained, obtain a documented risk acceptance and include the assignment in access reviews.

### 3.5 `sc-avd-poc-assignment`

The custom role permits role-assignment read/write, VM read, and AVD host/session-host read/write at the POC RG. [Set-AvdPersonalDesktopAssignment.ps1](../scripts/Set-AvdPersonalDesktopAssignment.ps1) uses it to:

- resolve the user with Graph `User.Read.All` application permission;
- grant built-in `Virtual Machine User Login` on the VM;
- grant built-in `Desktop Virtualization User` on the desktop app group;
- set the personal host's `assignedUser` and `allowNewSession=true`.

The current Bicep role does not constrain role-assignment writes to only those two role IDs. Although it has no explicit delete action, `Microsoft.Authorization/roleAssignments/write` at RG scope can assign Owner or another powerful role and thereby obtain destructive or data-plane access. Do not classify this principal as harmlessly non-destructive in production. Require Azure RBAC delegation conditions that restrict allowed role IDs and principal types where supported, a brokered assignment process, or JIT activation; pipeline authorization and code review alone are weaker compensating controls.

### 3.6 `sc-avd-poc-decommission`

[Remove-AvdPoc.ps1](../scripts/Remove-AvdPoc.ps1) can drain/unregister hosts, remove locks, delete whole resource groups, and delete the four workload custom roles. Request temporary subscription **Owner** only for an approved execution window, then revoke it.

Directory cleanup defaults off. If `removeDirectoryRecords=true` is separately approved, temporarily grant and admin-consent:

- Graph `Device.ReadWrite.All`;
- Graph `DeviceManagementManagedDevices.ReadWrite.All`.

Remove those app permissions/admin consent after cleanup. MDE inventory is not deleted.

**Checked-in behavior:** [azure-pipelines-decommission.yml](../pipelines/azure-pipelines-decommission.yml) fixes planning to `sc-avd-poc-readiness` and execution to `sc-avd-poc-decommission`; neither can be replaced through queue-time parameters. Configure an approval/check on the destructive service connection and a separate approval/check on environment `avd-poc-decommission`.

### 3.7 Azure Image Builder managed identity

[image-builder.bicep](../infra/modules/image-builder.bicep) creates `id-aib-avd-<poc>` and assigns the custom role from [image-main.bicep](../infra/image-main.bicep) at the POC RG. It can:

- read gallery/image/version resources;
- create or update gallery image versions;
- read the VNet/subnets and join the private build subnet.

It has no delete or Graph permission. Verify its principal object ID and exact RG assignment after image foundation deployment; do not pre-create a different identity with the same display name.

### 3.8 Azure DevOps-to-ServiceNow callback

[Update-ServiceNowRitm.ps1](../scripts/Update-ServiceNowRitm.ps1) supports either ServiceNow OAuth client credentials or Basic authentication. OAuth client credentials is the canonical production method; the committed developer-POC variable example initially uses Basic and documents a later switch to OAuth. The callback authenticates and PATCHes one RITM.

Request from the ServiceNow team:

- an inbound client-credentials OAuth application;
- an application user bound to `avd.integration`;
- API auth scope for `PATCH /api/now/table/sc_req_item/{sys_id}`;
- ACLs limited to applicable records, `u_avd_build_status`, `u_avd_hostname`, optional `u_avd_platform`, and `work_notes`.

The client ID is nonsecret. Deliver the client secret only through an approved vault/secret-variable process—never email or a ticket comment.

### 3.9 ServiceNow-to-Azure DevOps queue identity

**Implemented POC method:** a short-lived PAT stored as the password of a ServiceNow Basic Auth credential, with a non-empty username and only **Build: Read & execute**. [Queue-AvdPipeline.js](../servicenow/Queue-AvdPipeline.js) and its [Hybrid equivalent](../servicenow/Queue-AvdHybridPipeline.js) call the Azure DevOps Runs API.

**Recommended production design:** replace the PAT with an approved Entra-backed service-to-service identity. The repository does not implement or prove the exact Azure DevOps authentication flow for that replacement. The ADO platform team must design and validate token audience, project membership, Runs API support, and the minimum permission to queue only the intended pipeline. Do not describe the alternative as implemented until that test succeeds.

### 3.10 ServiceNow integration user and OAuth application

Create a web-service-only, noninteractive user such as `avd.integration`. Give it only the record and field ACLs in section 3.8. The runtime OAuth application impersonates this application user through client credentials.

The separate [configuration script](../scripts/Set-ServiceNowAvdCatalogIntegration.ps1) performs GET/POST/PATCH against catalog, user, dictionary, auth-profile, REST-message, REST-method, Business Rule, and RITM tables. Those are temporary configuration-administrator rights, not runtime callback rights. Run the script only after replacing its developer-instance constants or configure production manually.

The repository also contains environment-protected [ServiceNow configuration](../pipelines/azure-pipelines-servicenow-configure.yml) and [trigger test](../pipelines/azure-pipelines-servicenow-trigger-test.yml) pipelines, plus a read-oriented [admin test](../pipelines/azure-pipelines-servicenow-admin-test.yml) that has no YAML environment. These administrative pipelines need broader temporary ServiceNow configuration/read access than the runtime callback's PATCH-only API scope. Give them a separate temporary administration identity/scope, restrict the admin-test pipeline and variable-group permissions in the Azure DevOps UI, and remove authorization after use; do not broaden the production callback identity.

### 3.11 Intune and Defender responsibilities

These are human/platform-team setup duties, separate from pipeline read permissions:

- **Intune team:** automatic Windows MDM enrollment, device targeting, compliance/configuration profiles, required applications, update policy, and EDR policy.
- **Defender team:** enable and verify the Intune-MDE connection and device-targeted MDE onboarding.
- **Runtime readiness principal:** read-only Graph and MDE application permissions listed in section 4.

The repository does not prescribe tenant-specific human role names or administrative-unit scope. Each team must select its least-privilege built-in/custom administrative role and document the assignment. Do not grant these policy-administration roles to pipeline service principals.

### 3.12 Optional Hybrid identities

The [Hybrid access Bicep](../infra/hybrid-access.bicep) creates three RG-scoped custom roles. None includes an ARM delete action, but deploy and readiness still provide guest SYSTEM control:

- **Deploy:** Arc machine/extension read-write and AVD registration-token operations. Arc extension write can deploy guest SYSTEM code; use JIT/brokering, intended-pipeline authorization, extension-change monitoring, and extension allowlisting where available.
- **Readiness:** Arc/extension reads, Arc Run Command read-write, and AVD reads. Arc Run Command write is arbitrary guest SYSTEM execution even though the checked-in script uses fixed commands. Treat it as privileged/JIT and consider separating enrollment from steady-state readiness. Because preflight resolves the user, add Graph `User.Read.All` as well as device, managed-device, and MDE reads.
- **Assignment:** role-assignment writes, Arc/app-group/AVD reads, and session-host writes; Graph `User.Read.All`.

**Hybrid assignment discrepancy:** [Set-AvdHybridPersonalDesktopAssignment.ps1](../scripts/Set-AvdHybridPersonalDesktopAssignment.ps1) grants built-in role ID `1c0163c0-47e6-4577-8991-ea5c82e286e4` (`Virtual Machine Administrator Login`) at the Arc machine, while the Hybrid runbook says `Virtual Machine User Login`. This is broader than the documented intent. The platform team must confirm or correct it before production; do not request administrator login merely because the stale prose calls it user login.

Also request:

- a temporary Arc onboarding principal with `Azure Connected Machine Onboarding` at the Hybrid RG;
- temporary Hybrid decommission privilege sufficient to delete the Hybrid RG, assignments, and Hybrid custom roles, plus read/write on the exact existing AVD workspace so its Hybrid application-group reference can be removed;
- no Azure delete permission for ordinary Hybrid principals;
- Proxmox operator access and protected provisioning-package handling from the Hybrid team.

The checked-in Hybrid decommission pipeline accepts its Azure service connection, subscription, tenant, resource group, host pool, application group, existing workspace RG/name, RITM, and VM as queue-time parameters. Production must protect the exact destructive service connection with an approval/check, protect environment `avd-poc-hybrid-decommission`, restrict queue/parameter permissions, and preferably pin the production connection and target scope in reviewed YAML.

[hybrid-platform.bicep](../infra/modules/hybrid-platform.bicep) creates a system-assigned host-pool identity and grants it built-in `Reader` at the Hybrid RG.

## 4. Exact API application permissions

These permissions are independent of Azure RBAC.

| Principal | Resource API | Application permission | Implemented call |
|---|---|---|---|
| Azure deploy | Microsoft Graph | `User.Read.All` | `GET /v1.0/users/{upn}` |
| Azure readiness | Microsoft Graph | `Device.Read.All` | `GET /v1.0/devices` |
| Azure readiness | Microsoft Graph | `DeviceManagementManagedDevices.Read.All` | `GET /v1.0/deviceManagement/managedDevices` |
| Azure readiness | WindowsDefenderATP | `Machine.Read.All` | `GET /api/machines` |
| Azure assignment | Microsoft Graph | `User.Read.All` | `GET /v1.0/users/{upn}` |
| Azure decommission, only when cleanup is approved | Microsoft Graph | `Device.ReadWrite.All` | Inventory and `DELETE /v1.0/devices/{id}` |
| Azure decommission, only when cleanup is approved | Microsoft Graph | `DeviceManagementManagedDevices.ReadWrite.All` | Inventory and `DELETE /v1.0/deviceManagement/managedDevices/{id}` |
| Hybrid readiness | Microsoft Graph | `User.Read.All`, `Device.Read.All`, `DeviceManagementManagedDevices.Read.All` | User preflight, Entra device, and Intune device reads |
| Hybrid readiness | WindowsDefenderATP | `Machine.Read.All` | MDE machine read |
| Hybrid assignment | Microsoft Graph | `User.Read.All` | Requested-user resolution |

Use **Application permissions**, not Delegated permissions, because the pipelines authenticate as service principals without a signed-in user. Every listed Graph and MDE application permission requires tenant admin consent.

## 5. Azure custom-role summary

The [Azure access pipeline](../pipelines/azure-pipelines-access.yml) deploys [access.bicep](../infra/access.bicep), which creates and assigns three roles to service-principal **object IDs** at the POC RG:

| Role | Important allowed operations | Scope | Delete posture |
|---|---|---|---|
| `AVD POC Deployment <POC_ID>` | ARM deployments; VM/disk/NIC/extension writes; subnet join; AVD host-pool write/token retrieval | POC RG | No ARM delete; VM extension write permits guest SYSTEM execution |
| `AVD POC Readiness <POC_ID>` | Compute reads, VM Run Command, host/session-host reads | POC RG | No ARM delete; VM Run Command is arbitrary guest SYSTEM execution |
| `AVD POC Assignment <POC_ID>` | Role-assignment read/write; VM read; host/session-host read/write | POC RG | No explicit delete; role-assignment write permits indirect privilege escalation unless constrained |
| `AVD POC Image Builder <POC_ID>` | Gallery-version write; gallery/network reads; subnet join | POC RG | No delete action |

The optional [Hybrid access pipeline](../pipelines/azure-pipelines-hybrid-access.yml) similarly creates deployment, readiness, and assignment roles at the Hybrid RG. Deployment/readiness roles have no ARM delete action, but Hybrid deployment can install guest SYSTEM extensions and Hybrid readiness can execute guest SYSTEM commands through Arc Run Command. The Hybrid assignment role has the same indirect escalation risk because it can write RG role assignments.

### Persistent planning-inventory role

[access.bicep](../infra/access.bicep) defines `AVD POC Planning Inventory <POC_ID>` with subscription assignable scope and only `*/read`. It assigns the role to the readiness principal and emits both role-definition and assignment IDs. The role has no write, delete, action, or data-plane permission and is intentionally distinct from the RG-scoped readiness role.

Request this as persistent read-only access only if the checked-in combined readiness/planning design is accepted for production. Prefer a separate JIT planning principal. Verify the exact role JSON and assignment ID after access bootstrap, preserve it during normal POC resource-group teardown, and include it in periodic access reviews.

## 6. Temporary elevation model

1. **Bootstrap:** grant `sc-avd-poc-bootstrap` subscription Owner through PIM/JIT to create role definitions and assignments. Approve the access environment, run bootstrap, then remove the grant.
2. **Decommission:** grant `sc-avd-poc-decommission` temporary subscription Owner only for the approved run because the implementation deletes complete RGs, locks, role assignments, and workload custom roles. Revoke immediately afterward.
3. **Directory cleanup:** grant Graph write permissions only when exact Entra/Intune cleanup is approved. Remove the permissions/admin consent after the run.
4. **Ordinary operation:** deploy and readiness identities retain no ARM delete action but still have privileged guest SYSTEM execution through extension or Run Command writes; make them JIT/brokered and pipeline-restricted. Assignment identities require delegation conditions, brokering, or JIT because role-assignment write can indirectly escalate privilege.
5. **Planning:** use read-only access. Do not use a permanently destructive identity merely to generate a plan.

## 7. UI setup procedures

### 7.1 Microsoft Entra admin center

Repeat for each Azure DevOps ARM identity.

1. Open **Entra admin center > Identity > Applications > App registrations > New registration**.
2. Create a single-tenant app named for the service connection, for example `app-sc-avd-poc-readiness`.
3. Record **Application (client) ID**, **Directory (tenant) ID**, and the app registration's object ID.
4. Open **Enterprise applications**, find the app, and record its **service-principal object ID**. This is the ID passed to access Bicep and used by Azure RBAC.
5. Under **API permissions > Add a permission > Microsoft Graph > Application permissions**, add only the permissions in section 4.
6. For readiness, also add **APIs my organization uses > WindowsDefenderATP > Application permissions > `Machine.Read.All`**.
7. An authorized tenant administrator selects **Grant admin consent** and records the granted status. Do not add delegated permissions for runtime pipelines.
8. Do not create a client secret for Azure ARM service connections. Create a **Federated credential** using the issuer and subject supplied by Azure DevOps, with audience `api://AzureADTokenExchange`.
9. Verify application/client ID and service-principal object ID are not confused in tickets or pipeline parameters.

### 7.2 Azure portal

1. Confirm or create the dedicated POC RG and required tags. It may be absent after teardown.
2. Open **Subscriptions > target subscription > Access control (IAM)** and use **Add role assignment** or **Privileged Identity Management** for temporary bootstrap/decommission Owner.
3. Run the access pipeline only after the platform RG exists.
4. Open **Resource group > Access control (IAM) > Role assignments** and verify each custom role is assigned to the intended, distinct service-principal object ID.
5. Open **Subscription > Access control (IAM) > Roles** and inspect each custom role's assignable scope and permissions. Confirm expected roles contain no ARM delete action, and separately flag VM/Arc extension write and Run Command as privileged guest SYSTEM execution.
6. If PIM is available, make privileged assignments eligible, require approval/MFA/justification, set a short activation duration, and capture activation/removal evidence.
7. After image deployment, open **Resource group > Managed identities > `id-aib-avd-<poc>`**. Record its object/principal ID and verify the Image Builder custom role at the POC RG.
8. For Hybrid, verify the host pool's system-assigned identity has Reader only at the Hybrid RG.

### 7.3 Azure DevOps

#### ARM service connections with WIF

1. Open **Project settings > Service connections > New service connection > Azure Resource Manager**.
2. Choose workload identity federation with an existing app registration/manual configuration where supported by policy.
3. Bind the connection to the matching app's **Application (client) ID**, tenant, subscription, and intended scope.
4. Complete the Entra federated credential using the exact issuer/subject generated by Azure DevOps; do not synthesize it from display names.
5. Name the connection exactly as the variable examples require.
6. Leave **Grant access permission to all pipelines** off.
7. Under the service connection's **Security/Pipeline permissions**, authorize only the pipeline that needs it.
8. Use **Verify** and run a least-privilege `AzureCLI@2` test. A connection name does not prove a distinct principal—record and compare application IDs and service-principal object IDs.

#### Pipelines, environments, and protected variables

1. Create pipelines from the YAML under [`pipelines/`](../pipelines/).
2. Create all environments referenced by the enabled YAML: `avd-poc-platform`, `avd-poc-access-bootstrap`, `avd-poc-decommission`, and `avd-poc-servicenow-config`. If Hybrid is enabled, also create `avd-poc-hybrid-platform`, `avd-poc-hybrid-access-bootstrap`, and `avd-poc-hybrid-decommission`.
3. Open each environment's **Approvals and checks** and configure approvers, timeout, and branch/resource controls.
4. Remember: a YAML `environment:` reference does **not** create approval checks automatically.
5. Create `avd-poc-platform`, `avd-poc-servicenow`, and optional `avd-poc-hybrid` variable groups from the [`config`](../config/) examples.
6. Mark OAuth secrets, passwords, PATs, and provisioning-package SAS URIs secret. Prefer an approved vault integration and rotation process.
7. In each variable group's **Pipeline permissions**, disable open access and authorize only required pipelines.
8. Restrict repository and pipeline queue/edit permissions. Limit who can change YAML, queue bootstrap/decommission, override parameters, administer checks, or use protected resources.

### 7.4 ServiceNow

1. Under **User Administration**, create `avd.integration`; set it active and **Web service access only**. Add no interactive admin role.
2. Create a custom role/ACL boundary for applicable `sc_req_item` records. Permit read plus writes only to the mapped AVD fields and `work_notes`.
3. Under **System OAuth > Application Registry**, create an inbound OAuth client-credentials application and bind its application user to `avd.integration`.
4. Create an API auth scope such as `avd_ritm_patch`, map it only to `PATCH /api/now/table/sc_req_item/{sys_id}`, and attach it to the OAuth app.
5. Record the client ID. Transfer the generated client secret directly to the approved vault/ADO secret-variable owner; do not display it in evidence.
6. Under **System Web Services > Outbound > REST Message**, create `Azure DevOps AVD` with method `Queue pipeline`, HTTP `POST`, and the Runs API endpoint. Create a separate Hybrid message if used.
7. **Current POC:** attach a ServiceNow Basic Auth credential whose non-empty username is the dedicated ADO queue identity and whose password is a short-lived PAT with only Build: Read & execute. PAT scope alone is not pipeline-specific: remove project-wide queue rights from that identity and grant `Queue builds` only on the intended pipeline(s). Never place the PAT in a script, catalog variable, body, or work note.
8. Create the catalog item with mandatory `Requested for` reference to active `sys_user`. Never expose hostname, subscription, image, VM size, service connection, or package URI as requester input.
9. Configure the guarded Flow/Business Rules and exact fields in [ServiceNowconfig.md](../ServiceNowconfig.md). Preserve the request contract and derive hostname from RITM.
10. Test the REST method and callback using disposable records. Record HTTP status, REST method identity, OAuth scope, RITM field changes, and run ID—not credentials or token values.

### 7.5 Intune admin center and Defender portal

1. In **Intune admin center**, assign the responsible operations group only the tenant-approved roles needed for enrollment, compliance/configuration profiles, applications, updates, and EDR policy.
2. Configure Windows automatic MDM enrollment and device-targeted AVD policies/apps. Use narrowly scoped production device groups rather than a broad POC naming rule.
3. In **Microsoft Defender portal**, have the Defender team enable/verify the Intune connection and MDE onboarding configuration.
4. Assign MDE onboarding through the approved device policy and verify a canary reports `Onboarded` and `Active`.
5. Keep human policy-administration roles separate from the readiness service principal's read-only Graph/MDE application permissions.

## 8. Copy/paste access request templates

Never request a secret, PAT, password, OAuth secret, registration token, provisioning package, or SAS URI by email/ticket. Ask for IDs and nonsecret evidence; use the approved secret-transfer channel separately.

### Azure subscription team

```text
Request: AVD production Azure identity/RBAC setup
Subscription: <subscription-id>
Tenant: <tenant-id>
POC/environment ID: <poc-id>
Resource groups: <azure-rg>, <aib-staging-rg>, optional <hybrid-rg>

Please:
1. Grant <bootstrap-sp-object-id> eligible/JIT Owner at subscription for <window> to deploy platform, custom roles, and assignments; revoke after validation.
2. After access bootstrap, verify deploy and assignment have their intended RG-scoped roles; readiness has its RG role plus the explicitly accepted subscription read-only planning role.
3. Grant <decommission-sp-object-id> eligible/JIT Owner only for an approved teardown window; revoke afterward.
4. Confirm deploy/readiness/image roles contain no ARM delete actions; treat deploy extension writes and readiness Run Command as privileged guest SYSTEM execution and approve JIT/brokered, pipeline-restricted use.
5. For assignment, implement role-delegation conditions restricting allowed role IDs/principal types, provide a brokered assignment service, or make the identity JIT; do not approve unconstrained permanent roleAssignments/write without risk acceptance.
6. Return role-assignment IDs, scopes, conditions, expiry, and approver—not credentials.

Do not modify Conditional Access.
```

### Entra/identity team

```text
Request: AVD workload app registrations and app-only consent
Tenant: <tenant-id>

Create distinct single-tenant apps/service principals for:
- app-sc-avd-poc-bootstrap
- app-sc-avd-poc-deploy: Microsoft Graph User.Read.All (Application)
- app-sc-avd-poc-readiness: Graph Device.Read.All and DeviceManagementManagedDevices.Read.All (Application)
- app-sc-avd-poc-assignment: Graph User.Read.All (Application)
- app-sc-avd-poc-decommission: no persistent Graph write permission

Also request WindowsDefenderATP Machine.Read.All (Application) for readiness from the Defender/API owner.
For approved directory cleanup only, temporarily add/admin-consent Graph Device.ReadWrite.All and DeviceManagementManagedDevices.ReadWrite.All to decommission, then remove them.

Use federated credentials for Azure DevOps ARM connections; do not create client secrets.
Return tenant ID, application/client IDs, application object IDs, service-principal object IDs, and consent status. Send no secrets.
Do not modify Conditional Access.
```

### Azure DevOps team

```text
Request: AVD pipelines and protected resources
Organization/project: <organization>/<project>
Repository/branch: <repository>/<branch>

Create WIF ARM service connections:
sc-avd-poc-bootstrap, sc-avd-poc-deploy, sc-avd-poc-readiness,
sc-avd-poc-assignment, sc-avd-poc-decommission
(plus separate Hybrid connections if enabled; explicitly identify the JIT connection used for Hybrid platform/access bootstrap).

Bind each connection to its matching application/client ID. Disable access to all pipelines and authorize only the required pipeline IDs.
Create YAML pipelines from <repo>/pipelines.
Create referenced environments and configure approvals/checks in the UI:
avd-poc-platform, avd-poc-access-bootstrap, avd-poc-decommission,
avd-poc-servicenow-config, and the three named Hybrid environments if enabled.
Create protected variable groups from the config examples; authorize only required pipelines.
Restrict YAML edits, pipeline administration, queue permissions, and protected-resource administration.
For any PAT-based ServiceNow queue identity, remove project-wide queue rights and grant Queue builds only on the intended request pipeline(s); PAT scope is not a pipeline boundary.

Return service-connection IDs/names, bound application IDs, pipeline IDs, environment check evidence, and protected-resource authorization evidence. Send no secrets.
```

### ServiceNow team

```text
Request: Restricted AVD catalog integration
Instance: <instance-url>
ADO target: <organization>/<project>/<pipeline-id>

Create web-service-only user <integration-user> with read access to applicable AVD RITMs and write access only to approved AVD fields and work_notes.
Create an inbound OAuth client-credentials application bound to that user and an auth scope limited to PATCH /api/now/table/sc_req_item/{sys_id}.
Create outbound REST Message Azure DevOps AVD / Queue pipeline using POST to the Runs API.
For the POC only, store a short-lived PAT with Build: Read & execute in a ServiceNow credential. Require the PAT owner to have Queue builds only on the intended pipeline(s). For production, coordinate an Entra-backed design with the ADO platform team.
Configure the requested-for behavior and guarded queue rules from ServiceNowconfig.md.
Use separate temporary administration/diagnostic authorization for catalog configuration, configuration-table inventory, and the disposable trigger test; do not add those rights to the runtime callback user.

Return nonsecret sys_ids, client ID, scope/ACL summary, REST method identity, and test result. Transfer secrets only through the approved vault channel.
```

### Intune team

```text
Request: AVD Windows management policy setup
Tenant: <tenant-id>
Device scope/group: <group-id/name>

Configure automatic MDM enrollment, Windows compliance/configuration profiles,
required device-targeted applications, update policy, and Endpoint detection and response policy for AVD devices.
Grant the responsible operations group only the least-privilege Intune administrative roles needed for these duties.
Confirm the test user/device licensing and assignments.

Return policy/app/group IDs and assignment screenshots/status. No secrets.
Do not modify Conditional Access.
```

### Defender team

```text
Request: AVD Microsoft Defender for Endpoint setup and API consent
Tenant: <tenant-id>

Enable/verify the Intune-MDE connection and device-targeted MDE onboarding policy.
Grant WindowsDefenderATP Machine.Read.All (Application) with admin consent to readiness service principal <object-id/app-id>.
Grant human operations staff only the least-privilege Defender role needed to manage/verify endpoint onboarding.

Return consent status and nonsecret onboarding/health evidence. No secrets.
Do not modify Conditional Access.
```

### Optional Proxmox/Hybrid team

```text
Request: Optional Proxmox AVD Hybrid access
VM: <avd-hostname>
Hybrid RG: <hybrid-rg>

Provide operator access to build and maintain the exact persistent Windows VM, GPU/vTPM/Secure Boot configuration, outbound connectivity, and recovery process.
Coordinate a temporary Arc onboarding principal with Azure Connected Machine Onboarding at the Hybrid RG; revoke it after the machine is Connected.
Store the Entra/Intune provisioning package outside the repository and image. Supply its hash/expiry as nonsecret metadata and its short-lived read-only URI only through the approved secret store.
Create separate Hybrid deploy/readiness/assignment WIF connections and protected decommission approval. Identify a JIT bootstrap connection for Hybrid platform/access. Grant platform bootstrap and reviewed decommission access to update the exact existing AVD workspace outside the Hybrid RG. The current Hybrid teardown accepts connection and target scope as queue parameters, so restrict queue/parameter rights and preferably pin them in production YAML.

Return nonsecret VM, Arc resource, service-connection, and policy evidence. No secrets.
```

## 9. Preflight verification checklist

### Identity and Azure

- [ ] Tenant ID, subscription ID, application/client IDs, application object IDs, and service-principal object IDs are recorded separately.
- [ ] Deploy, readiness, assignment, bootstrap, and decommission object IDs are distinct.
- [ ] Service-connection names resolve to the recorded application IDs; names alone are not accepted as proof.
- [ ] Custom-role names, role-definition IDs, role-assignment IDs, and exact scopes are captured.
- [ ] Deploy/readiness/image roles contain no delete actions.
- [ ] Azure and Hybrid deployment extension-write rights are classified as guest SYSTEM execution, JIT/brokered, restricted to intended pipelines, monitored, and allowlisted by policy where available.
- [ ] Azure and Hybrid readiness Run Command rights are classified as guest SYSTEM execution, JIT/restricted to intended pipelines, and monitored.
- [ ] Assignment role `roleAssignments/write` is constrained, brokered, JIT, or covered by explicit risk acceptance.
- [ ] Bootstrap/decommission elevation has approver, activation, expiry, and removal evidence.
- [ ] Image Builder managed-identity principal ID and RG role assignment are captured.
- [ ] The subscription planning-inventory role contains only `*/read`; use of the runtime readiness principal versus a separate JIT planner has an approved decision.

Useful nonsecret checks:

```powershell
az ad sp show --id <application-client-id> --query '{appId:appId,objectId:id,displayName:displayName}'
az role assignment list --assignee-object-id <service-principal-object-id> --all --query '[].{role:roleDefinitionName,scope:scope}'
```

### API consent

- [ ] Entra API permissions show **Application**, not Delegated.
- [ ] Admin-consent status/screenshots cover each exact Graph permission.
- [ ] Defender consent shows WindowsDefenderATP `Machine.Read.All` for the readiness app.
- [ ] Optional Graph write permissions are absent unless cleanup is approved, and have a removal date.

### Azure DevOps

- [ ] Pipeline IDs and YAML paths are recorded.
- [ ] Each ARM connection uses WIF and the intended app registration.
- [ ] “Grant access permission to all pipelines” is off.
- [ ] Service-connection and variable-group pipeline permissions list only required pipeline IDs.
- [ ] Environment checks are visible in UI; YAML environment references alone are not treated as approval evidence.
- [ ] Variable groups contain placeholders/IDs as expected; secret values are masked and not included in evidence.
- [ ] Repository and pipeline edit/queue/admin permissions are reviewed.
- [ ] A PAT queue identity, if temporarily retained, has `Queue builds` only on intended pipeline(s), not project-wide queue rights.
- [ ] Hybrid teardown queue-time service connection and target parameters are pinned or governed by restricted queue/parameter permissions and dual approvals.
- [ ] Hybrid platform/decommission workspace read-write is scoped to the exact existing AVD workspace and is removed when temporary elevation ends.

### ServiceNow and user readiness

- [ ] Integration user is web-service-only and has no interactive admin role.
- [ ] OAuth app user, API auth scope, ACLs, and exact RITM PATCH route are recorded.
- [ ] REST Message name, method identity, endpoint organization/project/pipeline ID, and HTTP method `POST` are recorded.
- [ ] Requested-for maps to an active user and hostname remains derived from RITM.
- [ ] Callback can update only approved fields and `work_notes`.
- [ ] Queue test returns HTTP 200/201 and a run ID without exposing authorization headers.
- [ ] Test user has the required AVD, Windows, Intune, and MDE licensing.
- [ ] Intune policy/app assignments and MDE onboarding are confirmed before host testing.
- [ ] No Conditional Access request or change is included.

## 10. Production hardening

Compared with the developer POC:

- Replace the PAT when an approved, tested Entra-backed Azure DevOps service-to-service method is available; until then, keep the PAT short-lived and minimally scoped and restrict its owner to queueing only intended pipelines.
- Store ServiceNow secrets, PATs, SAS URIs, and other credentials in approved vaults; define owners, expiry, and rotation.
- Use PIM/JIT for bootstrap and destructive access, with approvals and short activation windows.
- Keep separate app registrations/service principals for deploy, readiness, assignment, bootstrap, image operation, and decommission.
- Constrain or broker role-assignment writes; a custom role with `roleAssignments/write` can indirectly escalate even without explicit delete actions.
- Treat VM/Arc extension writes and Run Command as guest SYSTEM execution; use JIT/brokering, pipeline restrictions, monitoring, and extension allowlisting rather than relying on the absence of ARM delete actions.
- Separate teardown planning from runtime readiness or formally accept subscription-wide inventory exposure.
- Do not authorize service connections or variable groups for all pipelines.
- Configure environment checks in the UI; a YAML environment reference creates no approval by itself.
- Require protected branches/code owners for Bicep, pipeline, identity, and teardown changes.
- Centralize Entra sign-in, Azure Activity, ADO audit, ServiceNow integration, Intune, MDE, and Proxmox logs with alerting and retention.
- Run periodic access reviews for app owners, API consents, RBAC, ADO permissions, ServiceNow ACLs, and human platform roles.
- Remove temporary Graph write permissions and stale federated credentials after use.
- Replace developer-instance constants and fixed tenant/organization/project IDs in reusable automation with protected configuration.
- Resolve image-pipeline privilege and scheduled parameters, assignment-role delegation, planning-identity separation, Hybrid teardown pinning, and the optional Hybrid login-role mismatch before production.

## 11. What to request first

1. Confirm subscription, tenant, POC/production naming, owning teams, and whether Hybrid is in scope.
2. Request distinct Entra app registrations/service principals and record all IDs.
3. Request Graph/MDE application permissions and admin consent for ordinary identities.
4. Create WIF Azure DevOps service connections with restricted pipeline authorization.
5. Decide the production controls for assignment writes, planning inventory, image scheduling, and optional Hybrid teardown before requesting final RBAC.
6. Request temporary bootstrap Owner and configure every referenced environment/service-connection approval check.
7. Deploy platform, then run access bootstrap and verify custom roles, assignments, conditions, and scopes.
8. Configure Intune/MDE policy and license the test user.
9. Configure protected variable groups and the ServiceNow integration.
10. Build/verify the image and Image Builder managed identity.
11. Test one request end to end; request decommission elevation or optional directory-write consent only when an approved teardown is scheduled.
