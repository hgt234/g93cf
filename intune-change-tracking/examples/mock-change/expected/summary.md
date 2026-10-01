# Intune state diff

Environment: production  
Generated: 2026-09-24 21:52:22Z

| Added | Modified | Deleted | Documented | Unrecorded |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 2 | 0 | 1 | **1** |

## Changed objects

| Record status | Change | Object | Record/ticket | Path |
| --- | --- | --- | --- | --- |
| **unrecorded** | modified | Corporate Wi-Fi |  | `device-configurations/22222222-2222-2222-2222-222222222222.json` |
| **documented** | modified | Windows - Security Baseline | 2026/2026-09-24-enable-vulnerable-driver-blocklist.md / SEC-1842 | `settings-catalog/11111111-1111-1111-1111-111111111111.json` |

> [!WARNING]
> 1 changed Intune object(s) have no active matching change record.

## Matching Intune audit events

These are correlations by Intune object ID, not proof that one event produced every line in the diff.

| Time (UTC) | Actor | Activity | Object path | Result |
| --- | --- | --- | --- | --- |
| 09/24/2026 02:18:44 | admin.two@contoso.example | Patch DeviceConfiguration | `device-configurations/22222222-2222-2222-2222-222222222222.json` | success |
| 09/24/2026 02:12:05 | admin.one@contoso.example | Patch DeviceManagementConfigurationPolicy | `settings-catalog/11111111-1111-1111-1111-111111111111.json` | success |
