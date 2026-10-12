@{
    Severity = @('Error', 'Warning')
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleCommands = @{
            Enable = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
            )
            # The 5.1 profile only knows the inbox Pester 3.4. Tests require
            # Pester 5 (#requires -Modules), so its commands are not checked
            # against the inbox version.
            IgnoreCommands = @('Describe', 'Context', 'It', 'BeforeAll', 'BeforeEach', 'AfterAll', 'AfterEach', 'Should', 'Mock', 'Invoke-Pester', 'New-PesterConfiguration')
        }
    }
}