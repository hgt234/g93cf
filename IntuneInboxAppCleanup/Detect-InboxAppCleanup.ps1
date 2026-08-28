#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Keep this list synchronized with Remediate-InboxAppCleanup.ps1.
$targetPackageNames = @(
    'Microsoft.GetHelp'
    'Microsoft.MixedReality.Portal'
    'Microsoft.WindowsMaps'
)

try {
    $installedNames = @(
        Get-AppxPackage -AllUsers -PackageTypeFilter Bundle,Main -ErrorAction Stop |
            Select-Object -ExpandProperty Name -Unique
    )
    $provisionedNames = @(
        Get-AppxProvisionedPackage -Online -ErrorAction Stop |
            Select-Object -ExpandProperty DisplayName -Unique
    )

    $remaining = @(
        foreach ($packageName in $targetPackageNames) {
            $locations = @()

            if ($installedNames -contains $packageName) {
                $locations += 'installed for an existing user'
            }
            if ($provisionedNames -contains $packageName) {
                $locations += 'provisioned for new users'
            }

            if ($locations.Count -gt 0) {
                '{0} ({1})' -f $packageName, ($locations -join ', ')
            }
        }
    )

    if ($remaining.Count -gt 0) {
        Write-Output ('Inbox app cleanup required: {0}' -f ($remaining -join '; '))
        exit 1
    }

    Write-Output 'Targeted inbox apps are neither installed nor provisioned.'
    exit 0
}
catch {
    Write-Output ('Unable to inventory Appx packages: {0}' -f $_.Exception.Message)
    exit 1
}
