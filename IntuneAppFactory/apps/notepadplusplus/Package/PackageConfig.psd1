@{
    AppVendor = 'Notepad++ Team'
    AppName = 'Notepad++'
    AppVersion = 'REPLACE-WITH-VENDOR-VERSION'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AllowDeferral = $true
    ProcessesToClose = @(
        @{ Name = 'notepad++'; Description = 'Notepad++' }
    )
    Installer = @{
        Type = 'Exe'
        FileName = 'notepad-plus-plus-x64.exe'
        InstallArguments = '/S'
        UninstallFilePath = '%ProgramFiles%\Notepad++\uninstall.exe'
        UninstallArguments = '/S'
    }
    Hooks = @{}
}

