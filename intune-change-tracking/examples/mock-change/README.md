# Mock change export

This example shows what a scheduled run looks like after two portal changes:

1. `Windows - Security Baseline` changes the vulnerable driver blocklist from disabled to enabled. It has a matching active change record and is labeled **documented**.
2. `Corporate Wi-Fi` changes its session timeout from 10 to 30 minutes. It has no record and is labeled **unrecorded**. The mock audit data attributes it to `admin.two@contoso.example`.

The example record is intentionally valid until 2099 so this repeatable fixture does not expire. Real records created by `New-ChangeRecord.ps1` default to a 14-day validity window.

Rebuild the expected report:

```powershell
pwsh ../../scripts/Compare-IntuneState.ps1 `
  -BaselinePath ./baseline `
  -CurrentPath ./current `
  -OutputPath ./expected `
  -AuditPath ./audit-events.json `
  -ChangeRecordsPath ./change-records `
  -EnvironmentName production
```

Set `-FailOnUndocumentedChanges` to see enforcement mode. It writes the report and then exits unsuccessfully when unrecorded changes exist.

