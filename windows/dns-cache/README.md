# Windows DNS Client Cache Settings

`DNS_Cache_Settings.reg` configures maximum cache lifetimes for the Windows DNS
Client service.

## Registry changes

The file writes two `DWORD` values under:

```text
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters
```

| Value | Registry data | Effective duration | Purpose |
| --- | --- | --- | --- |
| `MaxCacheTtl` | `0x3600` | 13,824 seconds (3h 50m 24s) | Limits how long positive DNS responses remain cached. |
| `MaxNegativeCacheTtl` | `0x5` | 5 seconds | Limits how long failed DNS lookups remain cached. |

Registry files represent `DWORD` data in hexadecimal. Therefore,
`dword:00003600` is `0x3600`, or 13,824 decimal seconds. To configure exactly
3,600 seconds, the registry data would need to be `dword:00000e10` instead.

These values set maximum lifetimes. A DNS response with a shorter TTL can
expire before the configured maximum.

## Install

1. Review `DNS_Cache_Settings.reg` and confirm that the durations are suitable.
2. Right-click the file and select **Merge**, or double-click it.
3. Approve the Registry Editor and User Account Control prompts.
4. Restart Windows, or restart the DNS Client service from an elevated shell.

To restart the service with PowerShell:

```powershell
Restart-Service -Name Dnscache
```

Windows may prevent the service from being restarted on some systems. Reboot
the computer if the command fails.

## Verify

From an elevated PowerShell session, inspect the configured values:

```powershell
Get-ItemProperty `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' `
    -Name MaxCacheTtl, MaxNegativeCacheTtl
```

To view the current DNS Client cache:

```powershell
Get-DnsClientCache
```

To clear cached entries while testing:

```powershell
Clear-DnsClientCache
```

## Remove the settings

Remove both custom values from an elevated PowerShell session:

```powershell
$path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
Remove-ItemProperty -Path $path -Name MaxCacheTtl, MaxNegativeCacheTtl
Restart-Service -Name Dnscache
```

Reboot if the DNS Client service cannot be restarted. Removing the values lets
Windows use its normal defaults again.

## Safety notes

- Back up the registry key before applying changes.
- Incorrect registry changes can cause system or networking problems.
- A short negative-cache lifetime causes Windows to retry failed lookups more
  quickly, which can increase DNS query traffic.
- This file configures the Windows DNS Client cache, not the DNS Server role.
