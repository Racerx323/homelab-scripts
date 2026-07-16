# System Repair Interactive Test Matrix

Run the automated Pester suite first:

```powershell
Invoke-Pester -Path '.\SystemRepairMenu.Tests.ps1' -CI
```

Complete the following checks on a disposable Windows test system. Import the
registry file from an Administrator session, exercise each menu item, and
remove it with `uninstall-system-repair-menu.reg` afterward.

| Scenario | Expected result |
| --- | --- |
| No Terminal process | UAC appears; approval opens one new Administrator Terminal window in `%SystemRoot%\System32`. |
| Existing unelevated Terminal | The existing process is not reused; approval opens a separate Administrator window. |
| Existing elevated Terminal | A separate Administrator window is still created because the launcher uses `-w new`. |
| Cancelled UAC | No Terminal window or repair process starts. |
| Missing `C:\Program Files\PowerShell\7\pwsh.exe` | Explorer reports that the launcher cannot be found; no fallback executable runs. |
| Missing `PowerShell 7` Terminal profile | Terminal reports the missing profile; no SFC or DISM process starts. |
| SFC Scan | The elevated tab runs `%SystemRoot%\System32\sfc.exe /scannow` through `%ComSpec%`. |
| DISM commands | Each elevated tab runs `%SystemRoot%\System32\Dism.exe` with the selected arguments through `%ComSpec%`. |
| View SFC Log | The encoded script writes to the Windows Desktop known folder, including a redirected Desktop. |
| Uninstall | The complete `SystemRepair` submenu is removed after Explorer refresh. |

For path-interception coverage, inspect the launched process command lines in
Process Explorer or Task Manager. They must resolve to `%ComSpec%`,
`%SystemRoot%\System32\sfc.exe`, and `%SystemRoot%\System32\Dism.exe`; a
same-named executable placed in a user directory must never be selected.
