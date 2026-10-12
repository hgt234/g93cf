# Example only: stop the companion service before an in-place upgrade.
$service = Get-Service -Name 'ComplexLobAgent' -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') {
    Write-ADTLogEntry -Message 'Stopping ComplexLobAgent before installation.'
    Stop-Service -Name $service.Name -Force -ErrorAction Stop
}

