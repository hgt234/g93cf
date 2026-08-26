# Managed Drive Mapper for Intune

This package installs one user-context mapping engine and a centralized JSON mapping table.
It is designed for Entra-joined Windows devices that reach on-premises SMB shares through
Kerberos SSO and may not have VPN connectivity at sign-in.

## Behavior

- Runs at user sign-in, ten seconds after Windows reports a connected network, and every
  five minutes.
- Runs unelevated as the interactive user; credentials are never requested, collected, or
  stored.
- Changes mappings only for users whose UPN suffix is explicitly allowed in configuration.
- Installs one device-wide task. Intune user assignment does not restrict that task to the
  assigned user after installation.
- Expands environment variables such as `%USERNAME%` in UNC paths.
- Requires FQDN file-server names by default.
- Resolves nested on-premises AD membership using the computed `tokenGroups` attribute.
- Caches group SIDs for four hours to protect domain controllers from frequent queries.
- Leaves group-dependent mappings unchanged while AD is unreachable.
- Tests TCP 445 before mapping, then retries silently on a later run.
- Tracks ownership and removes only mappings that it created and whose paths still match.
- Never overwrites an unmanaged local or network drive using the same letter.

## Files

| File | Purpose |
|---|---|
| `Payload/Mappings.json` | The only mapping and group-entitlement table |
| `Payload/Invoke-DriveMapper.ps1` | User-context reconciliation engine |
| `Payload/Register-DriveMapperTask.ps1` | Creates or repairs the scheduled task |
| `Payload/Test-DriveMapperTask.ps1` | Verifies the task action, principal, triggers, and settings |
| `Install-DriveMapper.ps1` | Intune Win32 system-context installer |
| `Uninstall-DriveMapper.ps1` | Removes the application and task |
| `Detect-DriveMapper.ps1` | Intune Win32 custom detection script |
| `Remediation/*` | Optional scheduled-task health detection and repair |
| `Build-IntuneWin.ps1` | Wrapper for Microsoft's IntuneWinAppUtil |
| `Test-DriveMapperSolution.ps1` | Parser, JSON, configuration, and PSScriptAnalyzer checks |

## 1. Configure mappings

Edit `Payload/Mappings.json`. The included examples are disabled so an unedited package
cannot create placeholder mappings.

For a home drive:

```json
{
  "Enabled": true,
  "DriveLetter": "H",
  "Path": "\\\\fs01.corp.contoso.com\\home\\%USERNAME%",
  "Label": "Home",
  "RequiredGroupSidsAny": [],
  "RequiredGroupSidsAll": [],
  "ExcludedGroupSids": []
}
```

For a drive available to members of either group, including nested membership:

```json
{
  "Enabled": true,
  "DriveLetter": "S",
  "Path": "\\\\fs01.corp.contoso.com\\shared",
  "Label": "Shared",
  "RequiredGroupSidsAny": [
    "S-1-5-21-111111111-222222222-333333333-1001",
    "S-1-5-21-111111111-222222222-333333333-1002"
  ],
  "RequiredGroupSidsAll": [],
  "ExcludedGroupSids": []
}
```

Set these top-level values:

- `AllowedUserUpnSuffixes`: required list of permitted user UPN suffixes. This prevents the
  machine-wide task from changing mappings for unrelated local, guest, or cross-tenant users.
- `AdDomainFqdn`: on-premises AD DNS name. Required only when any group rule exists.
- `DirectoryServer`: normally blank in `Domain` mode. Set a DC FQDN to pin single-domain
  lookup or an actual global catalog FQDN when using `GlobalCatalog` mode.
- `DirectorySearchMode`: use `Domain` for `AdDomainFqdn` only. Use `GlobalCatalog` for a
  forest-wide UPN search; this mode requires `DirectoryServer` to identify a ready GC.
- `GroupCacheHours`: membership refresh interval; four hours is the recommended default.
- `RequireFqdnForFileServers`: keep `true` when clients do not receive an AD DNS suffix.
- `AdoptExistingMappings`: keep `false` unless the engine should assume ownership of an
  already-existing mapping whose path exactly matches the configuration.

Use group SIDs instead of names or distinguished names. From a management workstation with
the ActiveDirectory module:

```powershell
Get-ADGroup -Identity 'File Share - Shared' | Select-Object Name, SID
```

Rules are evaluated as follows:

1. At least one SID in `RequiredGroupSidsAny` must match when the array is nonempty.
2. Every SID in `RequiredGroupSidsAll` must match.
3. No SID in `ExcludedGroupSids` may match.

An empty set of all three arrays makes a mapping available to every targeted user. SMB and
NTFS permissions remain the final authorization boundary.

The signed-in UPN must match the user's on-premises AD `userPrincipalName` for group lookup.
If it does not, the mapper falls back to a unique `sAMAccountName` match within
`AdDomainFqdn`; it never performs an ambiguous forest-wide SAM lookup.

## 2. Validate locally

Install PSScriptAnalyzer once for the current user. PowerShell 7.2.11 or later can run these
cross-platform checks; run them in Windows PowerShell 5.1 as well before release because that
is the deployment runtime.

```powershell
Install-PSResource -Name PSScriptAnalyzer -Scope CurrentUser
# Windows PowerShell 5.1 with PowerShellGet 2.x can use:
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
```

Run parsing, PowerShell 5.1 compatibility analysis, JSON parsing, and mapping-rule validation:

```powershell
.\Test-DriveMapperSolution.ps1
```

Parser, JSON, and mapping checks can run without PSScriptAnalyzer when bootstrapping a host:

```powershell
.\Test-DriveMapperSolution.ps1 -SkipScriptAnalyzer
```

On a pilot Entra-joined client, run the engine as the signed-in user while connected to VPN:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ManagedDriveMapper\Invoke-DriveMapper.ps1 -ForceGroupRefresh -Verbose
```

Do not run that test elevated. Elevated and normal logon sessions have different mapped
drive namespaces.

## 3. Package and deploy as an Intune Win32 app

Build the `.intunewin` file after obtaining Microsoft's IntuneWinAppUtil:

```powershell
.\Build-IntuneWin.ps1 -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe
```

Create a Windows app (Win32) in Intune with these values:

- Install behavior: **System**
- Device restart behavior: **No specific action**
- 64-bit client: **Yes**
- Install command:

```text
cmd.exe /d /c Install-DriveMapper.cmd
```

- Uninstall command:

```text
cmd.exe /d /c Uninstall-DriveMapper.cmd
```

The packaged wrappers expand `%SystemRoot%` internally and select 64-bit Windows PowerShell.
This is required because Intune does not expand environment variables in the uninstall field.

- Detection rule: **Use a custom detection script**, upload `Detect-DriveMapper.ps1`, run
  as 64-bit, and do not enforce signature checking unless the scripts are signed.
- Assignment: required device groups only. Every allowed-suffix user who signs into an
  assigned device can run the task; JSON group rules decide individual drive eligibility.
  Do not rely on an Intune user assignment to scope this machine-wide installation.

When publishing an update, increment `Payload/Version.json` and `$expectedVersion` in
`Detect-DriveMapper.ps1`, then replace/supersede the Win32 package. Mapping logic remains in
one package and mapping definitions remain solely in `Mappings.json`.

## 4. Optional Intune Remediations health check

The required Win32 app already self-reinstalls when its detection rule fails. If faster task
repair is desired, create an Intune Remediations package using:

- Detection: `Remediation/Detect-DriveMapperHealth.ps1`
- Remediation: `Remediation/Remediate-DriveMapperHealth.ps1`
- Run using logged-on credentials: **No**
- Run in 64-bit PowerShell: **Yes**
- Schedule: daily is normally sufficient

This remediation repairs the scheduled task only. Missing payload files deliberately cause
the Win32 detection rule to fail so Intune can reinstall the authoritative package.

## Troubleshooting

Per-user log and state are stored at:

```text
%LOCALAPPDATA%\ManagedDriveMapper\DriveMapper.log
%LOCALAPPDATA%\ManagedDriveMapper\State.json
%LOCALAPPDATA%\ManagedDriveMapper\GroupCache.json
%LOCALAPPDATA%\ManagedDriveMapper\Health.json
```

Force a fresh LDAP membership query:

```powershell
& C:\ProgramData\ManagedDriveMapper\Invoke-DriveMapper.ps1 -ForceGroupRefresh -Verbose
```

Check the deployment and task:

```powershell
Get-ScheduledTask -TaskName 'Managed Drive Mapper' | Get-ScheduledTaskInfo
Get-Content "$env:LOCALAPPDATA\ManagedDriveMapper\DriveMapper.log" -Tail 100
Test-NetConnection fs01.corp.contoso.com -Port 445
klist
```

Expected offline behavior is a warning that the LDAP server or file server is unavailable.
Existing mappings are retained and the next network event or five-minute run retries.
Non-transient mapping failures set the task result to failure and write `Health.json` with a
`Degraded` status. Offline dependency failures write `TransientFailure` and remain retryable.

If the user can reach TCP 445 but mapping reports access denied or credentials are requested,
fix Kerberos/Cloud Trust, SPNs, share permissions, or DNS first. The mapper intentionally has
no password fallback.

## Uninstall behavior

Uninstall removes the machine application and scheduled task. It preserves user logs, state,
and existing persistent drive mappings because a SYSTEM-context uninstall cannot safely
identify and alter every user's interactive drive namespace. Retire mappings through
`Mappings.json` before uninstalling if they should be removed automatically.
