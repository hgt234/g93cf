@{
    AppVendor = 'Client Name'
    AppName = 'Complex LOB App 2'
    AppVersion = '2.0.0'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AllowDeferral = $true
    ProcessesToClose = @(
        @{ Name = 'ComplexLobApp2'; Description = 'Complex LOB App 2' }
    )
    Installer = @{
        Type = 'Exe'
        FileName = 'ComplexLobApp2-Setup.exe'
        InstallArguments = '/quiet /norestart'
        UninstallFilePath = '%ProgramFiles%\ClientName\Complex LOB App 2\uninstall.exe'
        UninstallArguments = '/quiet /norestart'
    }
    Hooks = @{
        PreInstall = 'PreInstall.ps1'
        PostInstall = 'PostInstall.ps1'
        PostUninstall = 'PostUninstall.ps1'
    }
}

