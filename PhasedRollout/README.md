# Phased Rollout Export (10 / 30 / 60)

Read-only tool that finds every device with a given app and splits it into
non-overlapping rollout phases (10% / 30% / 60% by default). It only reads
tenant data and writes local CSVs for review and manual Entra group import.

It is standalone: it shares no code, groups, or state with the EUC pilot
program, and it can never change group membership.

## Files

| File | Purpose |
|---|---|
| `phased-rollout-creator.ps1` | Read-only device export with disjoint rollout phases |
| `Test-PhasedRolloutCreator.ps1` | Offline read-only boundary, paging, retry, and phase CSV tests |
| `PSScriptAnalyzerSettings.psd1` | Windows PowerShell 5.1 compatibility rules |

## Usage

From one deployed Intune app (devices with an `installed` status):

```powershell
.\phased-rollout-creator.ps1 -JoinAppId <app-guid> -ExportDirectory C:\Temp\Rollout
```

### Find devices by app name and version

To target older installs of any app, search Intune's discovered-app inventory
instead of a deployed app GUID. For example, all Windows devices with 7-Zip
below version 12:

```powershell
# Preview: lists the matched app records and device counts, writes no files
.\phased-rollout-creator.ps1 -AppName '7-Zip*' -MaxVersion 12 -UseDeviceCode -WhatIf

# Small validation run: resolves only the first 10 matching devices
.\phased-rollout-creator.ps1 -AppName '7-Zip*' -MaxVersion 12 -ExportDirectory C:\Temp\7zip -MaxDevices 10

# Full export
.\phased-rollout-creator.ps1 -AppName '7-Zip*' -MaxVersion 12 -ExportDirectory C:\Temp\7zip
```

- `-AppName` is a case-insensitive wildcard matched against display names
  (7-Zip names include the version, such as `7-Zip 19.00 (x64)`).
- `-MaxVersion` is **exclusive** ("below"); `-MinVersion` is inclusive. Both
  accept `12`, `9.20`, or `23.01.0.0`. `-Platform` defaults to `windows`.
- When a version bound is set, records with an unparseable version are
  excluded and listed in a warning.
- A device with several matching versions appears once, at its lowest version.
- Discovered-app inventory refreshes about every 7 days per device, so recent
  upgrades can still show the old version.

### Active devices only

Only devices that checked in to Intune within the last **90 days**
(`-ActiveWithinDays 90`, the default) are placed in the phases, so the
percentages are of active devices. Older devices, and devices that never
checked in, are still exported with `ActivityState = Inactive`, `Phase = 0`, and
an `Inactive (no check-in for 90+ days)` label, plus their own
`Inactive-EntraGroupImport-<timestamp>.csv`. `-ActiveWithinDays 0` turns the
filter off.

Activity uses the Intune managed device `lastSyncDateTime` (the portal's
**Last check-in**), the same signal as Intune device cleanup rules; it updates
on every MDM sync. Entra `approximateLastSignInDateTime` can lag by up to about
14 days, so it is exported as `EntraApproxLastSignIn` for reference only. If
one Entra device has several Intune records, the most recent check-in counts.
Both dates come from the existing device lookups, so no extra Graph calls are
made.

### Validation runs and user data

`-MaxDevices N` (either mode) still reads the full report or inventory, but
resolves only the first N matching devices sorted by Intune device ID. That
gives the same sample on every run. Skipped devices can leave fewer than N rows
(a warning says so). Phases are calculated on the sample, and sample files are
named `...-sample<N>-<timestamp>.csv`.

`PrimaryUserPrincipalName` is the device's **current Intune primary user**,
read from the managed device when the script runs. Report and inventory rows
only decide which devices qualify; their per-user rows (anyone who signed in)
are never exported. Each device appears once. Devices without a primary user
(shared or kiosk) are exported with a blank UPN and a warning; add
`-RequirePrimaryUser` to skip them.

## Phases

The script resolves devices and Intune primary-user UPNs, sorts canonical
Entra device GUIDs using ordinal comparison, and partitions them into
**10% / 30% / 60%** phases. `-PhasePercentages 10,30,60` can specify another
positive integer split totaling 100. Whole-device rounding uses largest
remainders, with earlier phases winning ties; small populations can have empty
phases. Each resolved device appears exactly once.

Ordering is repeatable for the same population across cultures; it is not a
random shuffle. Population changes can move devices between phases. Save the
original CSVs for a rollout rather than regenerating membership during it.

## Outputs

Timestamped UTF-8 CSVs in `-ExportDirectory`:

- `PhasedRolloutDetail-<timestamp>.csv`: `Phase`, `PhaseLabel`, `DeviceName`,
  `EntraObjectId`, `EntraDeviceId`, `IntuneManagedDeviceId`,
  `PrimaryUserPrincipalName`, `AppName`, `AppVersion`, `InstallState`
  (`installed` or `detected`), `StatusLastModified`, `ActivityState`,
  `LastCheckIn`, and `EntraApproxLastSignIn`. Active devices come first, in
  phase order, followed by inactive devices. `AppName` and `AppVersion` are
  filled only by `-AppName` runs. `StatusLastModified` is the earliest
  install-report status change (`-JoinAppId` only), not a guaranteed
  installation date.
- `Phase<N>-EntraGroupImport-<timestamp>.csv`: one device-object-ID import file
  per phase, plus `Inactive-EntraGroupImport-<timestamp>.csv`, in Entra's
  group-member import format. Import these manually into separate assigned
  Entra device groups (**Entra ID > Groups > your group > Members > Bulk
  operations > Import members**; see
  [Microsoft's bulk import instructions](https://learn.microsoft.com/en-us/entra/identity/users/groups-bulk-import-members)).

## Permissions and read-only boundary

The script requests only three read scopes:
`DeviceManagementApps.Read.All`, `DeviceManagementManagedDevices.Read.All`,
and `Device.Read.All`. Local runs sign in with `Connect-MgGraph`
(`Microsoft.Graph.Authentication`, avoid 2.41.0/2.41.1); when
`IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are present it uses a managed
identity token instead.

**Read-only boundary:** Graph POSTs are allowed only for synchronous install
report queries and batches of device GET requests. Direct GETs are allowed only
for the discovered-app list, each discovered app's device list, and the Intune
and Entra device lists. Membership changes, device actions, arbitrary
endpoints, and `exportJobs` creation are rejected before any HTTP call. Only
the local output directory and CSVs are created. `-WhatIf` still gathers data
and displays phase counts, but suppresses local output creation.

## Reliability

Report pages request device/user ordering and advance by the actual returned
row count. A missing/invalid total, changing total, repeated full report row,
or incomplete report stops the run before exports. Legitimate per-user rows
are retained, then deduplicated by Entra device identity. These checks detect
common paging failures but do not make a live report an atomic snapshot.
Recent installs can be missing due to reporting lag; rerun after data settles.
An empty report stops the run. A non-empty report with no resolved installed
devices produces header-only CSVs and a warning.

`-DeviceLookup Batch` resolves each device with batches of at most 20 GETs;
`Bulk` lists all Intune and Entra devices once (1,000 per page); `Auto` (the
default) uses Bulk above 1,000 devices. Retries honor `Retry-After`, use
jittered fallback delays, and refresh managed-identity authentication once on
HTTP or batch-subrequest 401 failures. Export jobs were evaluated for scale
but intentionally excluded because they create tenant-side resources.

## Validation

From this folder:

```powershell
.\Test-PhasedRolloutCreator.ps1
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The tests mock authentication and the HTTP transport only; no Graph calls,
tenant credentials, or consent are needed.
