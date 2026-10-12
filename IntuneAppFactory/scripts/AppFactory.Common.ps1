#requires -Version 5.1

Set-StrictMode -Version 3.0

function Get-AppFactoryManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RootPath
    )

    Get-ChildItem -LiteralPath $RootPath -Filter 'app.json' -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            try {
                $manifest = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                Add-Member -InputObject $manifest -NotePropertyName '_manifestPath' -NotePropertyValue $_.FullName
                $manifest
            }
            catch {
                [pscustomobject]@{
                    schemaVersion = $null
                    id = Split-Path (Split-Path $_.FullName -Parent) -Leaf
                    _manifestPath = $_.FullName
                    _parseError = $_.Exception.Message
                }
            }
        }
}

function Test-AppFactoryPlaceholder {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return $false }
    return ([string] $Value) -match '^(REPLACE-|\{REPLACE-)'
}

function Test-AppFactoryManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject] $Manifest
    )

    process {
        $issues = [System.Collections.Generic.List[object]]::new()
        $id = if ($Manifest.PSObject.Properties.Name -contains 'id') { $Manifest.id } else { '<unknown>' }

        function Add-Issue {
            param([string] $Severity, [string] $Message)
            $issues.Add([pscustomobject]@{ Severity = $Severity; AppId = $id; Message = $Message })
        }

        if ($Manifest.PSObject.Properties.Name -contains '_parseError') {
            Add-Issue 'Error' "Invalid JSON: $($Manifest._parseError)"
            return $issues
        }

        foreach ($property in @('schemaVersion', 'id', 'displayName', 'publisher', 'classification', 'lifecycle', 'assignment', 'owner')) {
            if (-not ($Manifest.PSObject.Properties.Name -contains $property) -or $null -eq $Manifest.$property -or
                (($Manifest.$property -is [string]) -and [string]::IsNullOrWhiteSpace($Manifest.$property))) {
                Add-Issue 'Error' "Required property '$property' is missing."
            }
        }
        if (@($issues | Where-Object Severity -eq 'Error').Count -gt 0) { return $issues }

        if ($Manifest.schemaVersion -ne 1) { Add-Issue 'Error' 'schemaVersion must be 1.' }
        if ($Manifest.classification -notin @('baseline', 'selfService')) {
            Add-Issue 'Error' "classification must be 'baseline' or 'selfService'."
        }

        $strategy = $Manifest.lifecycle.strategy
        $intent = $Manifest.assignment.intent
        if ($strategy -notin @('microsoftStore', 'enterpriseCatalogAutoUpdate', 'psadtWin32')) {
            Add-Issue 'Error' "Unknown lifecycle strategy '$strategy'."
        }
        if ($intent -notin @('required', 'available')) {
            Add-Issue 'Error' "Assignment intent must be 'required' or 'available'."
        }
        if ($intent -eq 'available' -and $Manifest.assignment.target -eq 'allDevices') {
            Add-Issue 'Error' 'Available applications must be user-targeted; allDevices is not valid for this model.'
        }
        if ($Manifest.classification -eq 'selfService' -and $intent -ne 'available') {
            Add-Issue 'Error' 'selfService applications must use an available assignment.'
        }

        switch ($strategy) {
            'enterpriseCatalogAutoUpdate' {
                if ($intent -ne 'required') {
                    Add-Issue 'Error' 'Enterprise App Catalog hands-off auto-update requires a required assignment.'
                }
                if ($Manifest.lifecycle.autoUpdate -ne $true) {
                    Add-Issue 'Error' 'Enterprise App Catalog strategy requires lifecycle.autoUpdate=true.'
                }
                if (-not ($Manifest.lifecycle.PSObject.Properties.Name -contains 'catalogProductName')) {
                    Add-Issue 'Error' 'catalogProductName is required for an Enterprise App Catalog app.'
                }
            }
            'microsoftStore' {
                if (-not ($Manifest.lifecycle.PSObject.Properties.Name -contains 'storeProductId')) {
                    Add-Issue 'Error' 'storeProductId is required for a Microsoft Store app.'
                }
                if ($Manifest.lifecycle.autoUpdate -ne $true) {
                    Add-Issue 'Error' 'Microsoft Store applications should retain Store auto-update in this model.'
                }
            }
            'psadtWin32' {
                foreach ($property in @('version', 'updateAuthority')) {
                    if (-not ($Manifest.lifecycle.PSObject.Properties.Name -contains $property)) {
                        Add-Issue 'Error' "PSADT lifecycle property '$property' is required."
                    }
                }
                foreach ($property in @('payload', 'detection')) {
                    if (-not ($Manifest.PSObject.Properties.Name -contains $property)) {
                        Add-Issue 'Error' "PSADT property '$property' is required."
                    }
                }
                if ($intent -eq 'available') {
                    if ($Manifest.lifecycle.autoUpdate -ne $true -or
                        $Manifest.lifecycle.autoUpdateMechanism -ne 'intuneAvailableSupersedence') {
                        Add-Issue 'Error' 'Available PSADT apps must use Intune available-app supersedence auto-update.'
                    }
                }
                if (($Manifest.PSObject.Properties.Name -contains 'detection') -and
                    $Manifest.detection.operator -ne 'greaterThanOrEqual') {
                    Add-Issue 'Error' 'Version detection must accept the packaged version or newer.'
                }
                if (($Manifest.PSObject.Properties.Name -contains 'payload')) {
                    foreach ($property in @('fileName', 'expectedPublisher', 'sha256')) {
                        if (-not ($Manifest.payload.PSObject.Properties.Name -contains $property)) {
                            Add-Issue 'Error' "Payload property '$property' is required."
                        }
                        elseif (Test-AppFactoryPlaceholder $Manifest.payload.$property) {
                            Add-Issue 'Warning' "Payload property '$property' is still an example placeholder."
                        }
                    }
                }
                if (Test-AppFactoryPlaceholder $Manifest.lifecycle.version) {
                    Add-Issue 'Warning' "Lifecycle version is still an example placeholder."
                }
            }
        }

        return $issues
    }
}
