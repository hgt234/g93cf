# Endpoint Explorer

Read-only inventory explorer for an Intune-managed Windows fleet. One pull of
device and app inventory from Microsoft Graph is cached locally as JSON. The
script then renders a single self-contained HTML report that you open by
double-clicking it. The report works offline and makes no external requests.

The report shows:

- **Overview cards:** device count, active / stale / never checked in,
  Co-managed / Intune MDM / ConfigMgr only, compliance, distinct apps, and the
  top app.
- **Charts:** management type, last check-in buckets, compliance, and OS version.
  Click a bar to filter the device table.
- **Devices:** a searchable, sortable, filterable table with name, primary user
  (UPN), last check-in, activity, management type, OS version, model, serial,
  and compliance. Click a row to see every field and, when collected, the
  installed apps with versions.
- **Installed apps:** the fleet app summary with name, publisher, versions,
  platform, and device count. Click a row to see per-version counts and, when
  collected, the devices that have the app.

## Files

| File | Purpose |
|---|---|
| `Export-EndpointInventory.ps1` | Entry point (Windows PowerShell 5.1) |
| `EndpointExplorer.Common.ps1` | Graph transport and read-only boundary, classification, caching, rendering |
| `New-EndpointDemoReport.ps1` | Writes a demo report from generated mock data (no Graph) |
| `EndpointExplorer.Tests.ps1` | Offline Pester 5 tests |
| `PSScriptAnalyzerSettings.psd1` | Windows PowerShell 5.1 compatibility rules |

## Prerequisites

- Windows PowerShell 5.1 (PowerShell 7 also works).
- `Microsoft.Graph.Authentication`. Avoid 2.41.0 and 2.41.1, which cannot sign in:

  ```powershell
  Install-Module Microsoft.Graph.Authentication -RequiredVersion 2.40.0 -Scope CurrentUser
  ```

- Two read permissions, delegated or application. The script never requests a
  write scope.
  - **`DeviceManagementManagedDevices.Read.All`** covers `managedDevices` and
    `detectedApps`.
  - **`Device.Read.All`** covers the Entra device list. It supplies each device's
    Entra object ID, which the rollout export needs for group import.
    PhasedRollout uses the same scope.
- When `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are set (Azure Automation /
  managed identity), the script uses a managed-identity token instead of
  `Connect-MgGraph`. The identity needs the same application permissions.

## Usage

```powershell
# Daily run: pulls from Graph, or reuses a snapshot younger than 24 h
.\Export-EndpointInventory.ps1

# Preview: performs all Graph reads, prints counts and target paths, writes nothing
.\Export-EndpointInventory.ps1 -UseDeviceCode -WhatIf

# Full pull including per-device apps, plus CSVs for Excel / Power BI
.\Export-EndpointInventory.ps1 -IncludeDeviceApps -Refresh -ExportCsv

# Re-render from the cached snapshot only (never contacts Graph)
.\Export-EndpointInventory.ps1 -FromCache -ActiveWithinDays 14
```

| Parameter | Default | Meaning |
|---|---|---|
| `-OutputDirectory` | `exports/EndpointExplorer` | Relative to the current location |
| `-AllPlatforms` | off | Include all platforms (default: Windows devices and Windows apps only) |
| `-IncludeDeviceApps` | off | Resolve which devices have each app (the expensive part) |
| `-MaxAgeHours` | 24 | Reuse a cached snapshot younger than this; 0 always pulls |
| `-Refresh` | off | Always pull. Cannot be combined with `-FromCache` |
| `-FromCache` | off | Render only; fails if the snapshot is missing or invalid |
| `-ActiveWithinDays` | 30 | A check-in older than this is Stale; 0 disables the threshold |
| `-ExportCsv` | off | Also write the CSV files listed below |
| `-PassThru` | off | Return the snapshot object |
| `-TenantId`, `-UseDeviceCode` | | Sign-in options for `Connect-MgGraph` |

Output (all under the git-ignored `exports/` tree by default, overwritten each run):

| File | When |
|---|---|
| `EndpointInventory.json` | Every pull (the cached snapshot) |
| `EndpointInventory.html` | Every run |
| `EndpointDevices.csv`, `EndpointApps.csv` | `-ExportCsv` |
| `EndpointDeviceApps.csv` | `-ExportCsv` and the snapshot has per-device apps |

### Demo report (mock data)

To review the page design and behavior without a tenant, generate a demo:

```powershell
.\New-EndpointDemoReport.ps1                       # 3,000 devices with per-device apps
.\New-EndpointDemoReport.ps1 -WithoutDeviceApps    # as if -IncludeDeviceApps was not used
```

It writes `exports/EndpointExplorer/Demo/EndpointInventory.html` (git-ignored).
The data is deterministic for a given `-Seed` and obviously fake:
`example.test` users, placeholder GUIDs, and `DEMO` serial numbers. A DEMO DATA
warning appears in the report header. The data covers every management type and
compliance state, never-checked-in and stale devices, devices with no primary
user, non-ASCII and very long names, a device name containing a script tag (to
show escaping), and apps with many versions. It goes through the same
classification, aggregation, and rendering code as a real export. The snapshot
is valid, so you can re-render it through the real cache path with
`Export-EndpointInventory.ps1 -FromCache -OutputDirectory exports/EndpointExplorer/Demo`.

### Phased rollout export (from the report)

The report can produce the same files as
[PhasedRollout/phased-rollout-creator.ps1](../PhasedRollout/phased-rollout-creator.ps1)
entirely in the browser, with no Graph calls. This needs a snapshot pulled with
`-IncludeDeviceApps`.

1. In **Installed apps**, open an app (for example VLC media player).
2. Under **Versions**, tick the versions to target. You can also enter a version
   in **Below version** and click **Select**. The bound is exclusive, like
   `-MaxVersion`, and versions that cannot be parsed are left out.
3. Click **Create rollout export**. Set the phase percentages (default 10,30,60),
   **Active within days** (default 90, as in the script), and optionally
   **Require primary user**. The preview shows the device count per phase, the
   inactive count, and every skipped device with the reason.
4. Click **Download .zip**. The download is
   `PhasedRollout-<app>-<timestamp>.zip` and contains:
   - `PhasedRolloutDetail-<timestamp>.csv`
   - `Phase<N>-EntraGroupImport-<timestamp>.csv`
   - `Inactive-EntraGroupImport-<timestamp>.csv`

These match the script's `-AppName` mode file for file:

- **Same rules:** each device keeps its lowest selected version. Several Intune
  records for one Entra device are merged. Devices are ordered by
  EntraDeviceId, and phases use largest-remainder allocation.
- **Same skips:** devices with no Entra device ID or no Entra object are left out.
- **Same file format:** identical columns and quoting, UTF-8 with a BOM, and
  CRLF line endings.

A Pester test runs both the script and the report's export code (under Node.js)
on the same demo data and compares the files. It is skipped when Node.js is not
installed.

There is one difference: values come from the snapshot, not from Graph at
export time. Primary user, last check-in, and app versions are as of the
snapshot time shown in the panel, and the active cutoff is measured from that
time. Use `-Refresh` first if you need current data.

### Caching

A cached snapshot is reused only when all of these hold:

- it is valid;
- it is younger than `-MaxAgeHours`;
- it has the same platform scope;
- it has per-device apps, if `-IncludeDeviceApps` was requested.

Otherwise the script pulls a new one. An invalid snapshot is never rendered as
an empty report: `-FromCache` fails, and a normal run warns and pulls again.
Activity is recomputed from the stored check-in times when the report is
rendered. It is measured relative to the snapshot time, so `-ActiveWithinDays`
works from cache.

### Classification

| Management type | Rule (`managedDevice` v1.0) |
|---|---|
| Co-managed | `managementAgent` is `configurationManagerClientMdm` / `configurationManagerClientMdmEas`, or `deviceEnrollmentType` is `windowsCoManagement` |
| Intune MDM | `managementAgent` is `mdm` |
| ConfigMgr only | `managementAgent` is `configurationManagerClient` |
| EAS / legacy client | `eas`, `easMdm`, `intuneClient`, `easIntuneClient` |
| Other / Unknown | anything else (including `unknown`, `jamf`, `msSense`, ...) |

Activity uses Intune `lastSyncDateTime` (the portal's **Last check-in**):

| State | Bucket | Rule |
|---|---|---|
| Active | Recent | checked in within 7 days |
| Active | Aging | older than 7 days, still within `-ActiveWithinDays` |
| Stale | Stale | older than `-ActiveWithinDays` |
| Never | Never | missing or year-1 timestamp |

## Read-only boundary

All HTTP goes through one guarded transport. Before any request is sent,
`Assert-EndpointReadRequest` allows only the following and rejects everything
else, including writes, `reports/*`, `exportJobs`, device actions, beta
endpoints, and foreign hosts:

| Method | URI |
|---|---|
| GET | `/v1.0/deviceManagement/managedDevices(?...)` |
| GET | `/v1.0/deviceManagement/detectedApps(?...)` |
| GET | `/v1.0/deviceManagement/detectedApps/{id}/managedDevices(?...)` |
| GET | `/v1.0/devices(?...)` (Entra device list: object ID and approximate sign-in only) |
| POST | `/v1.0/$batch` with 1 to 20 bodiless GETs of `detectedApps/{id}/managedDevices?$select=id` |

Throttling: HTTP 429/502/503/504/509 are retried up to 5 attempts. The script
honors `Retry-After` and never shortens it; without that header it uses
jittered exponential backoff. Batch subrequests are retried individually. Every
local write is behind `ShouldProcess`, so `-WhatIf` writes nothing.

## Scale and runtime (about 3,000 devices)

- **Devices:** about 3 to 4 pages of 1,000.
- **Fleet apps:** a few pages. There is one record per app name, version, and
  platform, with an Intune `deviceCount`.
- **`-IncludeDeviceApps`:** one batched subrequest per app record, 20 per
  `$batch` call. Runtime grows with the number of distinct name/version records,
  not the device count. Expect a few hundred batch calls on a large fleet. Run
  it daily at most; the cache covers the rest.
- **App counts:** without per-device data, an app's device count is the sum of
  its per-version counts, so a device with two versions counts twice. The report
  says when counts are approximate. With `-IncludeDeviceApps` the count is exact.
- **File size:** with `-IncludeDeviceApps` the HTML file can be several MB.
  Per-device apps are stored as indexes into one shared app-record table to keep
  it small.

## Limitations

- Intune discovered apps refresh about every 7 days per device, so recent
  installs and removals can lag. Unmanaged apps appear only for corporate-owned
  devices.
- `operatingSystem` is not documented as filterable on `managedDevice`. The
  server-side Windows filter is only an optimization. If Graph rejects it or
  returns nothing, the script lists all devices and filters them locally, and
  records a warning in the report.
- `managementAgent` and `deviceEnrollmentType` reflect the last reported state
  and are subject to RBAC and scope tags.
- Entra `approximateLastSignInDateTime` is shown for reference only, because it
  can lag by up to about 14 days. Activity always uses Intune check-in.
- Snapshots from before the Entra object IDs were added (schema version 1) are
  rejected. A normal run pulls a fresh one; `-FromCache` fails until then.

## Sensitive data

The JSON, HTML, and CSV files contain device names, UPNs, serial numbers, and
app inventory. Keep them under `exports/`, which is git-ignored, and never
`git add -f` them. Share them only with people who already have access to that
data in Intune.

## Validation

From this folder:

```powershell
$findings = Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
if ($findings) { $findings | Format-Table -AutoSize; throw "PSScriptAnalyzer: $(@($findings).Count) finding(s)" }

Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99.99
Invoke-Pester -Path . -Output Detailed
```

The tests run fully offline. Only the HTTP transport, sign-in, and
`Start-Sleep` are mocked; requests are served from an in-memory fake tenant.
