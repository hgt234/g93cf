@{
    AppVendor = 'Client Name'
    AppName = 'LOB App 1'
    AppVersion = '1.0.0'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AllowDeferral = $false
    ProcessesToClose = @()
    Installer = @{
        Type = 'Msi'
        FileName = 'LobApp1-x64.msi'
        InstallArguments = 'ALLUSERS=1 /qn /norestart'
        ProductCode = '{REPLACE-WITH-MSI-PRODUCT-CODE}'
        UninstallArguments = '/qn /norestart'
    }
    Hooks = @{
        PostInstall = 'PostInstall.ps1'
    }
}

