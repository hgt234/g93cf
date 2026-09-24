# Full CIS Windows 11 24H2 assessment for Intune

This package integrates the unmodified, pinned HardeningKitty 0.9.4 engine with Intune-safe
installation, assessment, reporting, exit codes, and Custom Compliance output. It is
audit-only. None of the supplied deployment scripts invoke HardeningKitty `HailMary`, GPO,
backup, or other write modes.

## Coverage

The package runs every row in HardeningKitty's CIS Microsoft Windows 11 Enterprise 24H2
finding lists:

| Scope | Findings | Profiles represented | Required context |
|---|---:|---|---|
| Machine | 647 | 450 L1, 144 L2, 53 BitLocker | SYSTEM/admin |
| User | 13 | 9 L1, 4 L2 | Logged-on user |
| Total | 660 | All included rows are evaluated | Two Intune assignments |

The benchmark reference in these lists is **CIS Microsoft Windows 11 Enterprise Benchmark
v4.0.0 for Windows 11 24H2**. “Full coverage” here means every finding supplied by the
pinned HardeningKitty lists is evaluated. It is not a CIS certification, and the finding
lists should still be compared with the benchmark document approved by your organization.

The adapter only accepts Windows client build `26100` and `en-US`. Windows Server 2025 also
uses build 26100, so the product-type check explicitly rejects it. HardeningKitty warns that
some analyses can be inaccurate on non-English systems; this integration fails closed rather
than returning potentially misleading compliance.

## Why there are separate machine and user packages

Machine controls require administrative access to security policy, audit policy, services,
HKLM, and other protected state. User controls must read the actual user's HKCU policy. A
single PowerShell context cannot evaluate both correctly.

Deploy both packages for complete coverage:

- Machine scripts: run as SYSTEM.
- User scripts: run using the logged-on user's credentials.

If Intune runs a user discovery script while no user is available and falls back to SYSTEM,
the adapter returns `AssessmentHealthy=false`; it does not audit the SYSTEM profile and call
that user compliant.

## Engine review decisions

HardeningKitty exposes `-Source Intune`, but version 0.9.4 displays an explicit warning that
the Intune source audit is still under development and is not comprehensive. The supplied
adapter therefore forces:

```powershell
Invoke-HardeningKitty -Mode Audit -Source GPO
```

Despite the parameter name, this path evaluates effective endpoint state and works for
settings materialized by Intune into the normal Windows policy/security stores. Using
`-Source Intune` would leave unsupported paths and would not provide the requested full-list
coverage.

The engine itself prints results and writes CSV but does not set a noncompliant process exit
code. The adapter parses the report, requires exactly 647 or 13 valid result rows, treats any
failed finding as noncompliant, writes structured JSON, and emits the exit/output contract
expected by Intune.

## Package contents

| Path | Purpose |
|---|---|
| `Vendor/HardeningKitty/0.9.4` | Minimal pinned upstream module, license, lists, and signed list manifest |
| `Invoke-CISWindows24H2Assessment.ps1` | Maintained audit adapter |
| `Deploy/Machine` | Machine Remediations and Custom Compliance scripts |
| `Deploy/User` | User Remediations and Custom Compliance scripts |
| `MachineCustomComplianceRules.json` | Machine Custom Compliance rules |
| `UserCustomComplianceRules.json` | User Custom Compliance rules |
| `EnginePackage` | Win32 app install/detect/uninstall scripts |
| `Build-EngineIntuneWin.ps1` | Creates the engine `.intunewin` package |
| `Build-IntunePackage.ps1` | Regenerates all four assessment scripts and both rules files |
| `Test-CISWindowsEndpointAssessment.ps1` | Syntax, signature, integrity, coverage, schema, and size tests |

## Step 1: build and deploy the engine Win32 app

Create the content package with Microsoft's IntuneWinAppUtil:

```powershell
.\Build-EngineIntuneWin.ps1 `
    -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe
```

Create a Windows Win32 app using the generated
`Output\Install-HardeningKittyEngine.intunewin`:

- Install behavior: **System**
- Device restart behavior: **No specific action**
- Install command:

```text
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-HardeningKittyEngine.ps1
```

- Uninstall command:

```text
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-HardeningKittyEngine.ps1
```

- Detection rule: use custom detection script
  `EnginePackage\Detect-HardeningKittyEngine.ps1`.

Assign the engine app as Required before assigning the assessment packages. The installed
path is:

```text
C:\Program Files\CISWindowsEndpointAssessment\HardeningKitty\0.9.4
```

The installer validates the package manifest and every payload SHA-256 before and after the
copy. The assessment scripts independently repeat that validation, so modifying the
installed manifest and payload together does not bypass the adapter's pinned manifest hash.

## Step 2: deploy audit-only Remediations

Start with Remediations so failures can be observed without affecting Conditional Access.

### Machine package

- Detection script: `Deploy\Machine\Detect-CISWindows24H2MachineCompliance.ps1`
- Remediation script: none
- Run using logged-on credentials: **No**
- Run in 64-bit PowerShell: **Yes**

### User package

- Detection script: `Deploy\User\Detect-CISWindows24H2UserCompliance.ps1`
- Remediation script: none
- Run using logged-on credentials: **Yes**
- Run in 64-bit PowerShell: **Yes**

Both scripts exit `0` only when every expected finding passes. A failed finding, missing row,
unsupported execution context, wrong Windows build/language, or integrity failure exits `1`.
Output is summarized below Intune's 2,048-character Remediations limit.

Detailed reports are stored at:

```text
Machine: C:\ProgramData\CISWindowsEndpointAssessment\Reports\Machine\Latest.json
         C:\ProgramData\CISWindowsEndpointAssessment\Reports\Machine\Latest-HardeningKitty.csv

User:    %LocalAppData%\CISWindowsEndpointAssessment\Reports\User\Latest.json
         %LocalAppData%\CISWindowsEndpointAssessment\Reports\User\Latest-HardeningKitty.csv
```

Reports intentionally omit hostname, domain, username, IP, serial number, and other explicit
device/user identifiers. The user report naturally resides beneath that user's profile but
the path is not returned to Intune.

## Step 3: optional Custom Compliance

After the Remediations pilot is stable, create two Windows Custom Compliance policies.

### Machine policy

- Discovery: `Deploy\Machine\Discover-CISWindows24H2MachineCompliance.ps1`
- Rules: `MachineCustomComplianceRules.json`
- Run using logged-on credentials: **No**
- Run in 64-bit PowerShell: **Yes**

### User policy

- Discovery: `Deploy\User\Discover-CISWindows24H2UserCompliance.ps1`
- Rules: `UserCustomComplianceRules.json`
- Run using logged-on credentials: **Yes**
- Run in 64-bit PowerShell: **Yes**

Each discovery script emits one compressed JSON line. `OverallCompliant` is the aggregate
result, `AssessmentHealthy` detects incomplete execution, `EngineIntegrity` detects payload
drift, and the remaining Boolean values identify failing HardeningKitty categories.

Pilot both policies before using them with Conditional Access. A strict full-list policy
includes L1, L2, and BitLocker findings and can expose settings that conflict with operational
requirements.

## Local execution

After the engine is installed, run from elevated 64-bit Windows PowerShell for the machine
scope:

```powershell
.\Invoke-CISWindows24H2Assessment.ps1 -Scope Machine -OutputMode Detailed
```

Run from the actual user's non-SYSTEM session for the user scope:

```powershell
.\Invoke-CISWindows24H2Assessment.ps1 -Scope User -OutputMode Detailed
```

For development, point at the vendored engine instead of installing it:

```powershell
.\Invoke-CISWindows24H2Assessment.ps1 -Scope Machine -OutputMode Detailed `
    -EngineRoot .\Vendor\HardeningKitty\0.9.4
```

## Validation and updates

Run after every change:

```powershell
.\Build-IntunePackage.ps1
.\Test-CISWindowsEndpointAssessment.ps1
```

The test suite verifies:

- all first-party and vendored PowerShell syntax;
- the pinned upstream commit and every SHA-256;
- the upstream detached finding-list signature and pinned signer thumbprint;
- exactly 647 machine and 13 user rows;
- complete category-to-compliance-rule mappings;
- forced audit/effective-state mode and absence of `HailMary` invocation;
- generated defaults, JSON rule schemas, and Intune size limits.

To update HardeningKitty, review a complete upstream release, replace all vendored files as a
unit, regenerate `PackageManifest.psd1`, update the adapter pins, rebuild, and retest. Do not
download `latest` dynamically on managed endpoints.

## Third-party software

HardeningKitty is developed by Michael Schneider/scip AG and distributed under the MIT
License. The unmodified upstream license is included at
`Vendor\HardeningKitty\0.9.4\LICENSE`. The vendored source is pinned to commit
`da0976073caad006c48b2478588c2f7fa572ab46`.
