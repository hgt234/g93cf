# Azure DevOps setup

## 1. Create the workload identity

Create an Azure Resource Manager service connection that uses workload identity
federation. The service connection's enterprise application is the identity the
pipeline uses. Do not store a client secret in a variable group.

Grant Microsoft Graph **application** permissions to that enterprise application
and give tenant-wide admin consent. Start with only the permissions needed by
the resource categories left in `config/resources.json`:

| Permission | Used for |
| --- | --- |
| `DeviceManagementConfiguration.Read.All` | Policies, profiles, scripts, remediations, assignments |
| `DeviceManagementApps.Read.All` | Mobile app metadata/assignments and the Intune audit endpoint |
| `DeviceManagementServiceConfig.Read.All` | Autopilot and service configuration categories |

Microsoft can change the permission required by a beta endpoint. Confirm each
configured endpoint against its Microsoft Graph API page. Do not grant write
permissions to this exporter.

The service connection may have no Azure subscription RBAC role if your
organization permits a tenant-level connection used only to obtain a Graph
token. If Azure DevOps requires subscription scope, grant the least Azure role
that allows the connection to authenticate; that Azure role does not grant the
Microsoft Graph permissions above.

## 2. Configure the YAML pipeline

Create a pipeline from `intune-change-tracking/azure-pipelines.yml`, then update:

- `azureServiceConnection`: the service connection name.
- `snapshotBranch`: normally `main`.
- schedule/branch: change the YAML schedule if nightly at 03:17 UTC is not
  appropriate.
- `environmentName`: use one stable name per tenant such as `production` or
  `pilot`.
- `failOnUnrecordedChanges`: leave `false` for warning-only adoption, or set
  `true` to publish the report and fail before replacing the baseline.
- Create a separate scheduled pipeline per tenant/environment.

Run the pipeline manually with `commitSnapshots: false`. Download the
`intune-diff-<environment>` artifact and inspect `summary.md`, `changes.json`,
and `state.patch`.

## 3. Allow snapshot commits

The checkout uses `persistCredentials: true`, so the pipeline's Build Service
identity performs the push. Grant that identity **Contribute** on the repository.
If `main` has a branch policy, either:

1. allow only the Build Service identity to bypass the relevant policy for this
   generated snapshot path; or
2. change the commit step to push a bot branch and use your normal pull-request
   automation.

After the first export is approved, set the run parameter/default
`commitSnapshots` to `true`. YAML schedules use parameter defaults, so change the
default in YAML when scheduled runs should commit.

The pipeline has `trigger: none`; its bot commit does not recursively start a
new CI run.

## 4. Add branch controls for admin intent

Recommended minimum controls:

- Require pull requests for `changes/**` and framework changes.
- Require one Intune peer/reviewer for production changes.
- Keep `state/**` bot-generated; admins should not hand-edit snapshot JSON.
- Retain pipeline artifacts long enough to meet the audit requirement.
- Keep the Azure DevOps project and repository private.

Copy `templates/pull_request_template.md` to the repository-level location your
Azure DevOps project uses if you want the checklist to appear automatically.

## 5. Customize coverage safely

Every resource definition contains a list endpoint, a detail endpoint, and
optional child collections such as assignments. Add or remove entries in
`config/resources.json`; the exporter handles pagination for every collection.

Test one category at a time. A failed Graph call stops the job before the
tracked state is replaced. This is intentional: a 403, changed beta endpoint,
or temporary service failure must not be committed as deletion of valid state.

The default exclusions in `config/normalization.json` remove service-maintained
timestamps and versions. Do not exclude assignment targets or policy values.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| HTTP 401 | The service connection could not obtain/use a Graph token. |
| HTTP 403 on one category | Missing Graph application permission/admin consent, or the endpoint does not support application auth. |
| Push rejected | Build Service lacks Contribute/bypass rights or the target branch is wrong. |
| Every array looks reordered | Review `sortArrays`; deterministic sorting is enabled to remove API ordering noise. |
| Audit report is empty | No events in the two-day window, or the identity cannot read Intune audit events. |

