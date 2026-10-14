#requires -Version 5.1
<#
.SYNOPSIS
Exports a read-only Intune device and app inventory to a cached JSON snapshot
and a self-contained, interactive HTML report.

.DESCRIPTION
Pulls Intune managed devices and discovered-app inventory from Microsoft Graph
v1.0 once, caches the result as EndpointInventory.json, and renders
EndpointInventory.html: device counts, last check-in, Intune MDM vs co-managed
vs ConfigMgr only, primary user, compliance, and installed apps with versions.
The HTML file works offline by double-click (no external requests). With
-IncludeDeviceApps it can also build PhasedRollout-compatible exports for
selected app versions, in the browser and without Graph calls.

Graph access is GET only (DeviceManagementManagedDevices.Read.All and
Device.Read.All, for the Entra object IDs that rollout exports need). A fresh
snapshot (younger than -MaxAgeHours) is reused without contacting Graph.
WhatIf still reads Graph when a pull is needed; it suppresses all local writes.

The output contains device names, UPNs, and serial numbers. Treat it as
sensitive; the default location is under the git-ignored exports/ folder.

.PARAMETER OutputDirectory
Folder for the snapshot, report, and CSVs. Relative paths resolve against the
current location. Defaults to exports/EndpointExplorer.

.PARAMETER TenantId
Tenant to sign in to with Connect-MgGraph. Ignored for managed identity.

.PARAMETER UseDeviceCode
Signs in with the device code flow.

.PARAMETER AllPlatforms
Includes every managed device and app platform. Default is Windows only.

.PARAMETER IncludeDeviceApps
Also resolves which devices have each detected app (one batched Graph
subrequest per app name/version record). Enables per-device app drill-down.

.PARAMETER MaxAgeHours
Reuses a cached snapshot younger than this. 0 always pulls. Defaults to 24.

.PARAMETER Refresh
Always pulls from Graph, regardless of the cached snapshot's age.

.PARAMETER FromCache
Renders only from the cached snapshot; never connects to Graph. Fails if the
snapshot is missing or invalid. Cannot be combined with -Refresh.

.PARAMETER ActiveWithinDays
Devices whose last Intune check-in is older than this are Stale. 0 disables
the threshold. Defaults to 30. Applied when rendering, including from cache.

.PARAMETER AppInventoryPath
Intune "Discovered apps" raw-data export (AppInvRawData) as .zip or .csv, from
Apps > Monitor > Discovered apps > Export in the Intune admin center, or from
Export-EndpointAppInventoryReport.ps1. Supplies per-device apps without any
Graph calls (replaces the slow -IncludeDeviceApps lookups) and is applied to a
fresh or cached snapshot; the updated snapshot is saved.

.PARAMETER ExportCsv
Also writes EndpointDevices.csv, EndpointApps.csv, and (when per-device apps
are present) EndpointDeviceApps.csv.

.PARAMETER PassThru
Returns the snapshot object.

.EXAMPLE
.\Export-EndpointInventory.ps1
Pulls (or reuses a snapshot younger than 24 h) and writes the HTML report.

.EXAMPLE
.\Export-EndpointInventory.ps1 -UseDeviceCode -WhatIf
Performs all Graph reads and prints counts and file paths, but writes nothing.

.EXAMPLE
.\Export-EndpointInventory.ps1 -IncludeDeviceApps -Refresh -ExportCsv
Forces a full pull including per-device apps and writes CSVs as well.

.EXAMPLE
.\Export-EndpointInventory.ps1 -AppInventoryPath C:\Temp\AppInvRawData.zip
Adds per-device apps from a Discovered apps export, with no per-app Graph lookups.

.EXAMPLE
.\Export-EndpointInventory.ps1 -FromCache -ActiveWithinDays 14
Re-renders the report from the cached snapshot with a 14-day activity window.

.NOTES
Requires Microsoft.Graph.Authentication (not 2.41.0/2.41.1) unless a managed
identity (IDENTITY_ENDPOINT/IDENTITY_HEADER) is available. See README.md.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory = 'exports/EndpointExplorer',
    [string] $TenantId,
    [switch] $UseDeviceCode,
    [switch] $AllPlatforms,
    [switch] $IncludeDeviceApps,
    [ValidateRange(0, 8760)] [int] $MaxAgeHours = 24,
    [switch] $Refresh,
    [switch] $FromCache,
    [ValidateRange(0, 3650)] [int] $ActiveWithinDays = 30,
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $AppInventoryPath,
    [switch] $ExportCsv,
    [switch] $PassThru
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EndpointExplorer.Common.ps1')

# All local writes happen inside Invoke-EndpointInventory, each behind its own
# ShouldProcess call. -WhatIf/-Confirm reach it through $PSBoundParameters.
Invoke-EndpointInventory @PSBoundParameters
