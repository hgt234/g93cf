#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$moreInfoUrl = 'https://www.cisecurity.org/benchmark/microsoft_windows_desktop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$categoryRules = [ordered]@{
    AccountPoliciesCompliant = 'Account Policies'
    AdminTemplatesControlPanelCompliant = 'Administrative Templates: Control Panel'
    AdminTemplatesNetworkCompliant = 'Administrative Templates: Network'
    AdminTemplatesPrintersCompliant = 'Administrative Templates: Printers'
    AdminTemplatesStartMenuAndTaskbarCompliant = 'Administrative Templates: Start Menu and Taskbar'
    AdminTemplatesSystemCompliant = 'Administrative Templates: System'
    AdminTemplatesWindowsComponentsCompliant = 'Administrative Templates: Windows Components'
    AdvancedAuditPolicyCompliant = 'Advanced Audit Policy Configuration'
    DefenderApplicationGuardCompliant = 'Microsoft Defender Application Guard'
    MSSLegacyCompliant = 'MSS (Legacy)'
    MSSecurityGuideCompliant = 'MS Security Guide'
    SecurityOptionsCompliant = 'Security Options'
    SystemServicesCompliant = 'System Services'
    UserRightsAssignmentCompliant = 'User Rights Assignment'
    WindowsFirewallCompliant = 'Windows Firewall'
}

function New-BooleanRule {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Description
    )
    [ordered]@{
        SettingName = $Name
        Operator = 'IsEquals'
        DataType = 'Boolean'
        Operand = $true
        MoreInfoUrl = $moreInfoUrl
        RemediationStrings = @(
            [ordered]@{
                Language = 'en_US'
                Title = "$Title Actual value: {ActualValue}."
                Description = $Description
            }
        )
    }
}

function Write-RulesFile {
    param(
        [Parameter(Mandatory)] [string]$Scope,
        [Parameter(Mandatory)] [string[]]$CategoryNames,
        [Parameter(Mandatory)] [string]$Path
    )

    $rules = @(
        New-BooleanRule -Name OverallCompliant -Title "The CIS Windows 11 24H2 $Scope assessment found noncompliant settings." -Description 'Contact IT. The detailed HardeningKitty results are stored locally on the endpoint.'
        New-BooleanRule -Name AssessmentHealthy -Title "The CIS Windows 11 24H2 $Scope assessment did not complete every expected check." -Description 'Contact IT to review execution context, endpoint language, engine installation, and the local assessment report.'
        New-BooleanRule -Name EngineIntegrity -Title 'The pinned HardeningKitty engine failed integrity validation.' -Description 'Contact IT to reinstall the approved assessment engine package.'
        foreach ($name in $CategoryNames) {
            $label = [string]$categoryRules[$name]
            New-BooleanRule -Name $name -Title "$label controls require attention." -Description 'Contact IT; security settings are managed centrally.'
        }
    )
    $document = [ordered]@{ Rules = $rules }
    [System.IO.File]::WriteAllText($Path, ($document | ConvertTo-Json -Depth 8), $utf8NoBom)
    Write-Output "Built $Path"
}

Write-RulesFile -Scope Machine -CategoryNames @($categoryRules.Keys) -Path (Join-Path $PSScriptRoot 'MachineCustomComplianceRules.json')
Write-RulesFile -Scope User -CategoryNames @(
    'AdminTemplatesStartMenuAndTaskbarCompliant'
    'AdminTemplatesSystemCompliant'
    'AdminTemplatesWindowsComponentsCompliant'
) -Path (Join-Path $PSScriptRoot 'UserCustomComplianceRules.json')
