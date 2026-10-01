Set-StrictMode -Version Latest

function New-GraphHeaders {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AccessToken)

    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw 'A Microsoft Graph access token is required.'
    }

    return @{ Authorization = "Bearer $AccessToken"; Accept = 'application/json' }
}

function Invoke-GraphGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [ValidateRange(1, 10)][int]$MaximumAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
            $retryable = $statusCode -in @(429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -eq $MaximumAttempts) {
                throw "Microsoft Graph GET failed ($statusCode): $Uri`n$($_.Exception.Message)"
            }
            $delaySeconds = [Math]::Min(60, [Math]::Pow(2, $attempt))
            Write-Warning "Graph returned HTTP $statusCode. Retrying in $delaySeconds seconds (attempt $attempt/$MaximumAttempts)."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-GraphCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri
    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {
        $response = Invoke-GraphGet -Uri $nextLink -Headers $Headers
        $valueProperty = $response.PSObject.Properties['value']
        if ($null -ne $valueProperty) {
            foreach ($item in @($valueProperty.Value)) { $items.Add($item) }
        }
        else {
            $items.Add($response)
        }
        $nextLinkProperty = $response.PSObject.Properties['@odata.nextLink']
        $nextLink = if ($null -ne $nextLinkProperty) { [string]$nextLinkProperty.Value } else { $null }
    }
    return ,$items.ToArray()
}
