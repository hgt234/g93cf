# Operating model

## Normal change

1. Run `New-ChangeRecord.ps1` and fill in the rollback line.
2. Commit the record on a branch. The Git author is the change owner.
3. Open a pull request. The reviewer confirms policy, reason, target, validation,
   and rollback—not a duplicate transcription of every Intune setting.
4. After approval, make the portal change in the agreed window.
5. Run the snapshot pipeline on demand or wait for its schedule.
6. Review `summary.md` first, then `state.patch` for exact values and
   assignments. Link the pipeline run/commit to the ticket if required.

This keeps the human form deliberately short. “Who” and “when” come from Git;
“what exactly changed” comes from the exported diff; the record only captures
context automation cannot infer.

## Emergency change

Make the change, restore service/security, then create a record with
`-ChangeType emergency`. The follow-up pull request documents reason, target,
validation, and rollback. The audit-event correlation helps identify portal
activity that occurred before the record.

## Drift or unexplained change

The comparison report automatically labels a changed object `unrecorded` when no
active record matches its object GUID or exact policy name. Azure DevOps receives
a warning; enforcement mode can also fail the run before snapshot replacement.
Generated records are active for 14 days by default, preventing an old policy record
from matching unrelated future drift.

If a snapshot diff has no matching approved record:

1. inspect the correlated audit event and Intune's native audit log;
2. ask the actor/owner whether the change was authorized;
3. create a retrospective record if authorized, or revert through Intune if not;
4. never “fix” drift by editing generated JSON—the current framework is
   detection-only.

Audit correlation is best effort. Some Graph objects or events do not expose the
same resource ID, events can fall outside the lookback window, and one activity
can affect several objects.

## Review responsibilities

| Role | Responsibility |
| --- | --- |
| Requester/admin | Minimal intent record, safe implementation, validation |
| Reviewer | Reason, blast radius, assignment, rollback, timing |
| Snapshot bot | Read-only export, deterministic diff, evidence publication |
| Platform owner | Permission review, failed-job response, retention, beta API maintenance |

## Suggested service levels

- Nightly snapshot for normal operations.
- On-demand snapshot immediately before and after high-risk changes.
- Investigate failed exports within one business day.
- Review unmatched production drift within one business day.
- Quarterly review of Graph permissions, resource coverage, exclusions, and
  Azure DevOps retention.

## What the Git history means

- `changes/**` commits: approved or retrospective human intent.
- `state/**` commits: observed tenant configuration at a point in pipeline
  history; the commit time is the observation time.
- pipeline artifact: convenient report, raw diff, and recent audit context for
  that observation.

Git is not the only audit authority. Retain native Intune audit logs or route
them to Azure Monitor according to the organization's audit requirements.

