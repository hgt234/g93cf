#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Keep this list synchronized with Detect-InboxAppCleanup.ps1.
$targetPackageNames = @(
    'Microsoft.GetHelp'
    'Microsoft.MixedReality.Portal'
    'Microsoft.WindowsMaps'
)

$removed = New-Object 'System.Collections.Generic.List[string]'
$failures = New-Object 'System.Collections.Generic.List[string]'
$installedInventory = @(
    Get-AppxPackage -AllUsers -PackageTypeFilter Bundle,Main -ErrorAction Stop
)
$provisionedInventory = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)

foreach ($packageName in $targetPackageNames) {
    $matchingInstalledPackages = @(
        $installedInventory |
            Where-Object { $_.Name -eq $packageName } |
            Sort-Object -Property PackageFullName -Unique
    )
    $bundlePackages = @($matchingInstalledPackages | Where-Object { $_.IsBundle })

    # Remove-AppxPackage -AllUsers must operate on a parent bundle when one exists.
    if ($bundlePackages.Count -gt 0) {
        $installedPackages = $bundlePackages
    }
    else {
        $installedPackages = $matchingInstalledPackages
    }

    foreach ($package in $installedPackages) {
        if ($package.NonRemovable) {
            $failures.Add(('{0} is protected (NonRemovable=True): {1}' -f
                    $packageName, $package.PackageFullName))
            continue
        }

        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            $removed.Add(('installed:{0}' -f $package.PackageFullName))
        }
        catch {
            $failures.Add(('{0} installed package {1}: {2}' -f
                    $packageName, $package.PackageFullName, $_.Exception.Message))
        }
    }

    $provisionedPackages = @(
        $provisionedInventory |
            Where-Object { $_.DisplayName -eq $packageName } |
            Sort-Object -Property PackageName -Unique
    )

    foreach ($package in $provisionedPackages) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName `
                -AllUsers -ErrorAction Stop | Out-Null
            $removed.Add(('provisioned:{0}' -f $package.PackageName))
        }
        catch {
            $failures.Add(('{0} provisioned package {1}: {2}' -f
                    $packageName, $package.PackageName, $_.Exception.Message))
        }
    }
}

# Appx cmdlets can return without a terminating error while leaving a package in place.
# Reinventory so Intune receives an accurate result.
$remainingInstalled = @(
    Get-AppxPackage -AllUsers -PackageTypeFilter Bundle,Main -ErrorAction Stop |
        Where-Object { $targetPackageNames -contains $_.Name } |
        Select-Object -ExpandProperty PackageFullName -Unique
)
$remainingProvisioned = @(
    Get-AppxProvisionedPackage -Online -ErrorAction Stop |
        Where-Object { $targetPackageNames -contains $_.DisplayName } |
        Select-Object -ExpandProperty PackageName -Unique
)

foreach ($packageFullName in $remainingInstalled) {
    $message = 'Installed package remains: {0}' -f $packageFullName
    if (-not $failures.Contains($message)) {
        $failures.Add($message)
    }
}
foreach ($packageName in $remainingProvisioned) {
    $message = 'Provisioned package remains: {0}' -f $packageName
    if (-not $failures.Contains($message)) {
        $failures.Add($message)
    }
}

if ($failures.Count -gt 0) {
    Write-Output ('Inbox app cleanup incomplete. {0}' -f ($failures -join ' | '))
    exit 1
}

if ($removed.Count -eq 0) {
    Write-Output 'No targeted inbox apps were present.'
}
else {
    Write-Output ('Inbox app cleanup completed: {0}' -f ($removed -join '; '))
}
exit 0
