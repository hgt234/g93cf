#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$workPath = 'C:\ProgramData\AvdImage'
$officeSetupPath = Join-Path $workPath 'setup.exe'
$officeConfigPath = Join-Path $workPath 'office.xml'
$logPath = Join-Path $workPath 'baseline.log'
New-Item -ItemType Directory -Path $workPath -Force | Out-Null

Start-Transcript -Path $logPath -Append
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $officeSetupPath

    $officeConfiguration = @'
<Configuration ID="AVD-Windows11-M365">
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Add>
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="AUTOACTIVATE" Value="1" />
  <Updates Enabled="TRUE" Channel="MonthlyEnterprise" />
  <RemoveMSI />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@
    $officeConfiguration | Set-Content -LiteralPath $officeConfigPath -Encoding utf8
    $officeProcess = Start-Process -FilePath $officeSetupPath -ArgumentList '/configure', $officeConfigPath -Wait -PassThru
    if ($officeProcess.ExitCode -notin @(0, 3010)) {
        throw "Microsoft 365 Apps installation returned exit code $($officeProcess.ExitCode)."
    }

    # Add other machine-wide, non-tenant-bound core software here. Keep tenant
    # enrollment, MDE onboarding, user data, and secrets out of the generalized image.
    [ordered]@{
        completedUtc = [DateTime]::UtcNow.ToString('o')
        officeChannel = 'MonthlyEnterprise'
        baseImage = 'Windows 11 Enterprise 24H2'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workPath 'baseline.complete') -Encoding utf8
}
finally {
    Stop-Transcript
}
