$configurationPath = Join-Path $envProgramData 'ClientName\ComplexLobApp2'
if (-not (Test-Path -LiteralPath $configurationPath -PathType Container)) {
    New-Item -Path $configurationPath -ItemType Directory -Force | Out-Null
}
Set-ADTRegistryKey -Key 'HKEY_LOCAL_MACHINE\SOFTWARE\ClientName\ComplexLobApp2' `
    -Name 'ManagedBy' -Value 'IntuneAppFactory' -Type String
Write-ADTLogEntry -Message "Verified managed configuration directory '$configurationPath'."

