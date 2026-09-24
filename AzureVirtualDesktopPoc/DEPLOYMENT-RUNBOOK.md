# AVD POC deployment and acceptance runbook

This runbook takes the repository from a fresh Azure subscription/tenant, Azure DevOps project, and ServiceNow developer instance to one fully automated personal Windows 11 desktop. Complete the phases in order. Normal deployment paths are additive and block Azure what-if `Delete` and `Recreate` changes. Only the isolated decommission pipeline is destructive.

## 0. Record the POC inputs

Choose one immutable POC ID and do not reuse its resource group for anything else.

| Input | Example | Notes |
|---|---|---|
| POC ID | `POC01` | Must match the safety tag and decommission confirmation. |
| Subscription ID | GUID | Dedicated POC subscription is preferred. |
| Tenant ID | GUID | Must be the tenant used by the Azure subscription, Intune, and AVD users. |
| Region | `centralus` | Confirm VM SKU and Windows 11 image availability. |
| Resource group | `rg-avd-poc01` | POC-only; never place shared resources here. |
| VNet | `10.80.0.0/16` | Change if this overlaps an existing or future corporate network. |
| Test RITM | `RITM0000001` | Expected computer name: `AVD0000001`; leading zeros are retained. |
| Test user | `user@contoso.com` | Needs AVD, Windows, Intune, and MDE licensing appropriate to the tenant. |
| ServiceNow URL | `https://devNNNNNN.service-now.com` | No trailing slash is required. |
| Azure DevOps organization/project | names | Record the numeric pipeline ID after creating the request pipeline. |

The YAML currently uses Microsoft-hosted `windows-latest` agents. This is the shortest Azure-hosted POC path and does not require inbound access to the private VNet. A Managed DevOps Pool can replace these `pool` blocks later without changing the Azure architecture.

## 1. Prove the Azure prerequisites

Sign in with an account that can register providers and deploy at subscription scope:

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>

pwsh ./AzureVirtualDesktopPoc/scripts/Register-AvdResourceProviders.ps1 `
  -SubscriptionId <subscription-id>

pwsh ./AzureVirtualDesktopPoc/scripts/Test-AvdPocPrerequisites.ps1 `
  -SubscriptionId <subscription-id> `
  -TenantId <tenant-id> `
  -Location centralus `
  -VmSize Standard_E4bs_v5
```

Provider registration is additive; the helper never unregisters a provider. The prerequisite helper is read-only except for its local JSON report. Also confirm:

- the test user can be assigned the required licenses;
- **Standard EBDSv5 Family vCPUs** quota covers each `Standard_E4bs_v5` session host;
- **Standard Dsv6 Family vCPUs** quota includes four vCPUs for the temporary `Standard_D4s_v6` Image Builder VM;
- Azure Policy does not deny NAT Gateway, Standard public IP, AVD, user-assigned identity, Compute Gallery, or Azure Image Builder resources;
- the three configured CIDRs do not overlap with connected networks.

## 2. Prepare Azure DevOps identities and controls

Create these Azure Resource Manager service connections using workload identity federation (WIF):

| Name | Used by | Initial scope |
|---|---|---|
| `sc-avd-poc-bootstrap` | platform, access bootstrap, first image foundation | Subscription; Owner only during bootstrap, then disable or remove the assignment. |
| `sc-avd-poc-deploy` | session-host provisioning | No initial role; the access pipeline assigns its POC role. |
| `sc-avd-poc-readiness` | readiness polling | No initial role; the access pipeline assigns its POC role. |
| `sc-avd-poc-assignment` | user/desktop assignment | No initial role; the access pipeline assigns its POC role. |
| `sc-avd-poc-decommission` | full teardown | Keep disabled or unprivileged; grant temporary POC-only delete authority for approved teardown, then revoke it. |

Use separate Entra app registrations for the three ordinary service connections. In Azure DevOps, authorize each connection only for the pipeline that needs it; do not enable “Grant access permission to all pipelines.” Record each service principal's **object ID**, not its application/client ID, for the access pipeline.

Grant these **application** API permissions and tenant admin consent. Azure RBAC does not grant Graph or Defender API access:

- deployment identity: Microsoft Graph `User.Read.All`;
- readiness identity: Microsoft Graph `Device.Read.All` and `DeviceManagementManagedDevices.Read.All`, plus WindowsDefenderATP `Machine.Read.All`;
- assignment identity: Microsoft Graph `User.Read.All`.

Only the decommission identity may receive temporary Graph device-delete permissions, and only when `removeDirectoryRecords=true` is approved. Do not add delete permissions to ordinary identities. Authorize each service connection only for its named pipeline; never grant access to all pipelines.

Create approval checks on these Azure DevOps environments:

- `avd-poc-platform`;
- `avd-poc-access-bootstrap`;
- `avd-poc-decommission` (mandatory before destructive execution).

## 3. Create the Azure DevOps pipelines

Commit this directory to the repository that Azure DevOps will use, then create YAML pipelines in this order:

1. `AVD POC - Platform` from `AzureVirtualDesktopPoc/pipelines/azure-pipelines-platform.yml`.
2. `AVD POC - Access` from `AzureVirtualDesktopPoc/pipelines/azure-pipelines-access.yml`.
3. `AVD POC - Image` from `AzureVirtualDesktopPoc/pipelines/azure-pipelines-image.yml`.
4. `AVD POC - Session Host` from `AzureVirtualDesktopPoc/pipelines/azure-pipelines-session-host.yml`.
5. `AVD POC - Decommission` from `AzureVirtualDesktopPoc/pipelines/azure-pipelines-decommission.yml`.

Do not enable CI triggers for the platform, access, request, or decommission pipelines. The image pipeline is on-demand and has a monthly schedule on `main`.

## 4. Deploy the shared platform

Edit `infra/parameters/poc.bicepparam`. Run the platform pipeline with:

- `azureServiceConnection`: `sc-avd-poc-bootstrap`;
- the selected subscription ID and region;
- `parametersFile`: the committed POC parameter file.

Approve only after inspecting the published `what-if.json`. A successful run creates the tagged resource group, personal AVD host pool, desktop application group, workspace, VNet, three private subnets, NSG, NAT Gateway, and one Standard public IP used only by NAT.

Capture the subnet IDs:

```powershell
$rg = 'rg-avd-poc01'
$vnet = 'vnet-avd-poc01'
az network vnet subnet show -g $rg --vnet-name $vnet -n snet-sessionhosts --query id -o tsv
az network vnet subnet show -g $rg --vnet-name $vnet -n snet-imagebuilder --query id -o tsv
az network vnet subnet show -g $rg --vnet-name $vnet -n snet-imagebuilder-aci --query id -o tsv
```

Run the access pipeline with the three service-principal object IDs. It creates and assigns the POC-scoped no-delete deployment, readiness, and assignment roles. Do not substitute client IDs for object IDs.

## 5. Configure Intune and Defender for Endpoint

Configure this before the first session-host test. Routine runs do not block on Intune inventory/compliance; the separate final-acceptance run does.

1. Confirm automatic Windows MDM enrollment is enabled for the licensed test user population.
2. Create a dynamic Entra device group for the POC, for example:

   ```text
   (device.displayName -startsWith "AVD")
   ```

   In a shared tenant, use a more selective naming prefix for production; this broad rule is POC-only.
3. Assign a Windows compliance policy and the required corporate configuration profiles to that group.
4. Connect Intune and Microsoft Defender for Endpoint.
5. Create an Intune Endpoint detection and response policy using the automatic connector onboarding package and assign it to the POC device group.
6. Assign required Win32/Microsoft 365 applications as device-targeted installs. Ensure the installed display names match `AVD_REQUIRED_APP_NAMES_JSON`.
7. Conditional Access is out of scope; do not touch it.

Do not enroll, Intune-register, or MDE-onboard the generalized image. Those operations occur on each deployed VM.

## 6. Build the corporate image

The Image Builder customizer must be reachable over HTTPS. The template uses `Standard_D4s_v6`. Use immutable content:

- public repository: raw URL pinned to a commit SHA;
- private repository: publish the script to a dedicated Azure Storage blob and use a short-lived read-only SAS URL for the build.

If the custom-script storage account/container is POC-owned inside `rg-avd-poc01`, teardown deletes it. Recreate it, upload the exact script, and issue a new read-only URI before rebuilding the image. Do not assume the previous URI survives reset.

Run the image pipeline with `sc-avd-poc-bootstrap`, both Image Builder subnet IDs, the immutable script URL, and staging group `rg-avd-poc01-aib-stage`. The first build can take several hours. Retrieve the resulting gallery definition/version from the `avd-image-build` artifact or Azure CLI:

```powershell
az sig image-definition show `
  -g rg-avd-poc01 `
  --gallery-name acgavdpoc01 `
  --gallery-image-definition win11-avd-personal `
  --query id -o tsv

az sig image-version list `
  -g rg-avd-poc01 `
  --gallery-name acgavdpoc01 `
  --gallery-image-definition win11-avd-personal `
  --query "sort_by([], &publishingProfile.publishedDate)[-1].id" -o tsv
```

After the foundation exists, restrict the image service connection as far as your governance model permits and require approval for template changes. The image template identity itself uses the generated POC-scoped no-delete role.

## 7. Create the variable groups

Create `avd-poc-platform` from `config/avd-poc-platform.variables.example.yml`. Replace every placeholder, keep `AVD_VM_SIZE=Standard_E4bs_v5`, and set the gallery definition ID. Leave the version ID empty to resolve the latest non-excluded version.

`AVD_REQUIRED_APP_NAMES_JSON` uses exact, case-insensitive matches against 64-bit and 32-bit uninstall-registry `DisplayName` values. Use complete installed names, not substrings.

Routine builds use `AVD_REQUIRE_INTUNE_COMPLIANT=false` because Intune inventory and compliance are asynchronous. Final acceptance is a separate run:

```text
AVD_REQUIRE_INTUNE_COMPLIANT=true
AVD_REQUIRE_MDE=true
```

Keep MDE required for routine and final runs. BitLocker is not an acceptance requirement for this POC.

Create `avd-poc-servicenow` from `config/avd-poc-servicenow.variables.example.yml`. Basic authentication is supported for bootstrap: set `SN_USERNAME` and secret `SN_PASSWORD` and leave the OAuth pair empty. The canonical setup uses `SN_CLIENT_ID` and secret `SN_CLIENT_SECRET`; clear the Basic pair after switching. Each callback obtains a fresh token. Authorize both variable groups only for `AVD POC - Session Host`.

## 8. Configure the ServiceNow developer instance

### 8.1 RITM fields

On `sc_req_item`, create these POC fields:

- `u_avd_build_status`: String or choice values exactly `Queued`, `In Progress`, `Ready`, `Failed`, `Timed Out`;
- `u_avd_hostname`: String, length 15;
- `u_ado_run_id`: String;
- `u_ado_run_url`: URL or String.

Create a web-service-only integration account such as `avd.integration`. Bind it to the OAuth client-credentials application and a Table API auth scope restricted to the required PATCH. Its role/ACL may read and patch only applicable `sc_req_item` records, work notes, and POC fields. Basic authentication is only a supported bootstrap fallback.

### 8.2 Outbound call to Azure DevOps

Create an Azure DevOps PAT for the POC with only **Build: Read & execute**, a short expiry, and access limited to the POC organization. Store it in a ServiceNow Basic Auth credential; do not place it in script or catalog variables.

Create REST Message `Azure DevOps AVD`, HTTP method `Queue pipeline`:

```text
POST https://dev.azure.com/<organization>/<project>/_apis/pipelines/<pipeline-id>/runs?api-version=7.1
Content-Type: application/json
```

Attach the Basic credential (an arbitrary non-empty username and the PAT as password). Test it first with the JSON in `servicenow/README.md`; HTTP 200/201 and a run ID are success.

### 8.3 Catalog flow

Create a catalog item with a requested-for user variable and a Flow Designer flow triggered for its RITM. Add a custom Action with inputs `ritm_number`, `ritm_sys_id`, and `requested_for_upn`; paste `servicenow/Queue-AvdPipeline.js` into its script step. It derives the hostname and sends `ritmNumber`, `ritmSysId`, `requestedHostName`, and `requestedForUpn`.

In the flow:

1. verify the requested-for account has a usable UPN/email;
2. call the custom action;
3. update the RITM to `Queued`, set hostname/run ID/run URL;
4. start a two-hour timer branch;
5. if status is still neither `Ready` nor `Failed` after the timer, set `Timed Out` and notify support; never delete the VM from this timeout branch.

The Azure DevOps pipeline writes `In Progress`, `Ready`, or `Failed` back through the ServiceNow Table API.

## 9. Test in layers

Use one real test user and one real RITM. Do not start with the catalog item; isolate each boundary first.

### Test A — repository and Azure controls

```powershell
pwsh ./AzureVirtualDesktopPoc/tests/Test-AvdPoc.ps1
```

Confirm all six Bicep entry points compile: `main.bicep`, `access.bicep`, `image-main.bicep`, `session-host.bicep`, `hybrid-main.bicep`, and `hybrid-access.bicep`. Confirm what-if artifacts contain no delete/recreate operation and the resource group has exact tags `ManagedBy=AzureVirtualDesktopPoc` and `PocId=POC01`.

### Test B — ServiceNow callback only

Create a test RITM, copy its 32-character `sys_id`, and run `Update-ServiceNowRitm.ps1` locally with the developer integration account. Confirm status, hostname, and work notes update. Use a disposable RITM because this intentionally writes to ServiceNow.

### Test C — manual Azure DevOps request

Queue the session-host pipeline manually with:

```text
ritmNumber=RITM0000001
ritmSysId=<real 32-character sys_id>
requestedHostName=AVD0000001
requestedForUpn=<licensed test user UPN>
```

Watch each gate. DSC can finish before its guest reboot and AVD registration are visible; readiness polling, not extension completion, is authoritative. Confirm the NIC has no public IP, NAT egress, Entra join, final-acceptance Intune compliance, MDE `Onboarded`/`Active`, exact required apps, AVD `Available`, and direct assignment.

### Test D — end-to-end catalog request

Submit the catalog item. Confirm the sequence:

```text
RITM created -> ADO run queued -> AVD1234 deployed -> readiness passed
-> user roles assigned -> personal host assigned -> RITM Ready -> user launches desktop
```

### Test E — safety and retry behavior

- Queue `RITM1234` with `AVD9999`; validation must fail before Azure provisioning.
- Requeue the same exact RITM/hostname/user; it must converge idempotently, not create a second VM.
- Requeue the same hostname for a different RITM or user; it must fail ownership validation.
- Temporarily require a nonexistent application; the request must time out/fail, preserve the VM, request drain mode, and update ServiceNow.
- Run the decommission pipeline with `execute=false`; review the inventory artifact and confirm that it selects only the explicitly named, exactly tagged POC groups.

## 10. Acceptance criteria

The POC is complete only when all of these are demonstrated:

- one catalog submission creates exactly one `AVD<digits>` Windows 11 VM;
- VM has a private NIC only and outbound internet uses the NAT Gateway public IP;
- VM is Entra joined, MDE active, and AVD Available; the separate final-acceptance run also proves Intune managed/compliant;
- required applications are detected on the machine;
- requested user receives both Azure login and AVD desktop rights and is the personal host's assigned user;
- ServiceNow records run correlation and reaches `Ready` only after all gates;
- failure preserves evidence and reports `Failed` without an automatic delete;
- repeat request is idempotent;
- decommission plan is scoped by explicit group names and exact safety tags;
- approved decommission removes the POC resource groups and stops NAT/VM/image storage spend;
- BitLocker is not required; Conditional Access is out of scope and must not be touched.

## 11. Decommission after testing

First run `AVD POC - Decommission` with `execute=false` and list both:

```text
rg-avd-poc01
rg-avd-poc01-aib-stage
```

Only after validating the artifact, temporarily grant the decommission service connection POC-only delete authority and rerun with `execute=true`, exact confirmation `DELETE POC01`, host-pool details, and optional directory cleanup. Approval on `avd-poc-decommission` is the final control. Revoke temporary permissions after capturing the execution report. MDE history remains until Defender retention expires.

Use [docs/TEARDOWN-REBUILD-VALIDATION.md](docs/TEARDOWN-REBUILD-VALIDATION.md) for the exact reset/rebuild sequence and `RITM0000001` reuse.

## Windows Azure CLI implementation notes

- Pipelines run PowerShell Core on `windows-latest`; use `az.cmd` explicitly when diagnosing Windows command resolution.
- Pass generated files as one literal `@file` argument, for example `--parameters "@$parameterPath"` and `--scripts "@$guestScriptPath"`.
- Use direct `Invoke-RestMethod` with a Graph token for directory inventory/deletion; do not use `az rest` for Graph cleanup.
- Request Graph with `az account get-access-token --resource-type ms-graph` and MDE with `--resource https://api.securitycenter.microsoft.com`. Tokens are audience-specific and are not interchangeable.
- AVD management calls use the pinned direct ARM REST API versions in the scripts.

The session-host pipeline generates a cryptographically random local administrator password for every deployment. It is passed as a secure Bicep parameter, removed with the temporary parameter file, and never published or retained. Use Entra login for normal administration.

## Microsoft reference material

- [Microsoft Entra joined session hosts in Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts)
- [Azure Resource Manager service connections with workload identity federation](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)
- [Azure DevOps Run Pipeline REST API](https://learn.microsoft.com/rest/api/azure/devops/pipelines/runs/run-pipeline?view=azure-devops-rest-7.1)
- [Azure VM Image Builder networking options](https://learn.microsoft.com/azure/virtual-machines/linux/image-builder-networking)
- [Configure Microsoft Defender for Endpoint with Intune](https://learn.microsoft.com/intune/device-security/microsoft-defender/configure-integration)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)
