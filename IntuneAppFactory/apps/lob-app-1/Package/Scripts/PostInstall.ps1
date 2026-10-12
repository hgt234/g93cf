# This hook is dot-sourced inside an active PSADT session.
Set-ADTRegistryKey -Key 'HKEY_LOCAL_MACHINE\SOFTWARE\ClientName\LobApp1' `
    -Name 'ManagedBy' -Value 'IntuneAppFactory' -Type String

