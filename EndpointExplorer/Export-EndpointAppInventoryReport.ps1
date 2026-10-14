#requires -Version 5.1
<#
.SYNOPSIS
Downloads Intune's "Discovered apps" raw-data report (AppInvRawData) for
Export-EndpointInventory.ps1 -AppInventoryPath.

.DESCRIPTION
Creates one Intune report export job (POST /v1.0/deviceManagement/reports/
exportJobs, reportName AppInvRawData), polls it until it completes, and
downloads the zipped CSV. One export returns every device/app row, so it
replaces thousands of throttled per-app Graph lookups.

This is the only part of EndpointExplorer that creates anything in the tenant
(a temporary export job; no device or configuration changes). Microsoft Graph
documents only ReadWrite permissions for creating export jobs, which is why it
is a separate, optional script: Export-EndpointInventory.ps1 stays read-only.
Without a ReadWrite permission, download the same report from the Intune admin
center instead (Apps > Monitor > Discovered apps > Export, raw data).

The download URL is a temporary SAS link; it is not logged. The downloaded file
contains device names and app inventory: keep it under the git-ignored
exports/ folder.

.PARAMETER OutputDirectory
Folder for AppInvRawData-<timestamp>.zip. Defaults to exports/EndpointExplorer.

.PARAMETER TenantId
Tenant to sign in to with Connect-MgGraph. Ignored for managed identity.

.PARAMETER UseDeviceCode
Signs in with the device code flow.

.PARAMETER Scope
Permission to request. Graph lists these for creating export jobs, from least
to most privileged; the default is the least privileged one.

.PARAMETER TimeoutMinutes
Gives up if the job has not completed in this time. Defaults to 30.

.PARAMETER PollSeconds
Seconds between status checks. Defaults to 15 (the exportJobs API allows 48
requests per minute per app).

.PARAMETER PassThru
Returns the downloaded file.

.EXAMPLE
.\Export-EndpointAppInventoryReport.ps1 -UseDeviceCode
Creates the export, downloads it, and prints the next command to run.

.EXAMPLE
.\Export-EndpointAppInventoryReport.ps1 -WhatIf
Shows what would be created and downloaded, without signing in or calling Graph.

.NOTES
Report and columns: https://learn.microsoft.com/en-us/mem/intune/fundamentals/reports-export-graph-available-reports
Export flow: https://learn.microsoft.com/en-us/mem/intune/fundamentals/reports-export-graph-apis
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory = 'exports/EndpointExplorer',
    [string] $TenantId,
    [switch] $UseDeviceCode,
    [ValidateSet('DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementApps.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All')]
    [string] $Scope = 'DeviceManagementConfiguration.ReadWrite.All',
    [ValidateRange(1, 180)] [int] $TimeoutMinutes = 30,
    [ValidateRange(5, 300)] [int] $PollSeconds = 15,
    [switch] $PassThru
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EndpointExplorer.Common.ps1')

# The job creation and the file write are behind ShouldProcess inside
# Invoke-EndpointAppInventoryExport; -WhatIf/-Confirm reach it through $PSBoundParameters.
Invoke-EndpointAppInventoryExport @PSBoundParameters
