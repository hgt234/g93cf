# Intune change tracking with Git

This folder is a starter framework for replacing a manually maintained change
spreadsheet with two complementary records:

1. **Intent** - a small Markdown change record says what is changing, why, and
   who it targets. Git supplies the author, review, approval, and timestamp.
2. **Observed state** - a scheduled Azure DevOps pipeline reads Intune through
   Microsoft Graph, writes deterministic JSON, compares it with the previous
   snapshot, and publishes a Markdown report plus a raw patch.

The exporter is read-only. It does not import, update, or delete Intune objects.

## Repository layout

```text
intune-change-tracking/
|-- azure-pipelines.yml          Scheduled export/diff pipeline
|-- changes/                     Short human-authored intent records
|-- config/
|   |-- normalization.json       Properties omitted from snapshots
|   `-- resources.json           Graph resources to export
|-- docs/
|   |-- operating-model.md       Day-to-day workflow and controls
|   `-- setup-azure-devops.md    One-time identity/pipeline setup
|-- scripts/
|   |-- Compare-IntuneState.ps1  Builds Markdown, JSON, and patch reports
|   |-- Export-IntuneAudit.ps1   Gets recent audit events for attribution
|   |-- Export-IntuneState.ps1   Exports normalized configuration JSON
|   |-- New-ChangeRecord.ps1     Creates a minimal change record
|   |-- Sync-IntuneState.ps1     Safely updates the tracked snapshot
|   `-- Test-Framework.ps1       Offline structure and syntax checks
`-- state/                       Generated tenant snapshots (one folder/environment)
```

## Admin workflow

Create a record before a planned change:

```powershell
pwsh ./scripts/New-ChangeRecord.ps1 `
  -Policy "Windows - Security Baseline" `
  -Environment production `
  -ObjectId "11111111-1111-1111-1111-111111111111" `
  -Summary "Enable the vulnerable driver blocklist" `
  -Reason "SEC-1842 remediation" `
  -Target "All corporate Windows devices" `
  -Ticket "SEC-1842"
```

Commit it on a short-lived branch and use a pull request for review. The record
does not ask the admin to re-enter their name or the time; Git already records
both. After the portal change, the next scheduled snapshot shows the exact JSON
and assignment delta. Intune audit events are used to add actor/activity context
to the report when an event references the changed object ID.

For urgent changes, make the Intune change first, then add the record in a
follow-up pull request and mark it `emergency`.

The comparison labels changed objects as `documented` only when an active record
matches the object GUID (preferred) or exact policy name. Everything else is
`unrecorded`, produces an Azure DevOps warning, and can optionally fail the run.
Records default to a 14-day matching window so an old record cannot silently bless later drift.
See the [mock change export](examples/mock-change/README.md) for both cases.

## First run

1. Complete [Azure DevOps setup](docs/setup-azure-devops.md).
2. Review [config/resources.json](config/resources.json). Remove categories you
   do not use before granting permissions.
3. Create a pipeline from `intune-change-tracking/azure-pipelines.yml`.
4. Set `azureServiceConnection` and `snapshotBranch` in the pipeline variables.
5. Run once with `commitSnapshots: false` and inspect the published artifact.
6. Set `commitSnapshots: true` after the output is approved.

The first successful run reports every exported object as added. Later runs
report only added, modified, and deleted files.

## Local validation

```powershell
pwsh ./scripts/Test-Framework.ps1
```

For an interactive export, obtain a Microsoft Graph access token and place it
in the process-scoped `GRAPH_ACCESS_TOKEN` environment variable, then run:

```powershell
pwsh ./scripts/Export-IntuneState.ps1 `
  -EnvironmentName test `
  -OutputPath ./out/test
```

Never commit access tokens. Use a private repository: configuration profiles,
scripts, group IDs, app metadata, and assignment details can be sensitive.

## Deliberate boundaries

- The default resource list exports configuration, not users, devices, recovery
  keys, certificates, application binaries, or report/device inventory data.
- The pipeline detects portal drift; it does not enforce desired state.
- A Graph failure stops snapshot replacement so a permission or API outage can
  never look like a mass deletion.
- `beta` endpoints are isolated in `config/resources.json` and should be tested
  after Microsoft Graph changes.

