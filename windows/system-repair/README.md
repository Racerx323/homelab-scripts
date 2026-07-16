# System Repair Tools Desktop Context Menu (.reg)

## Purpose

This registry script adds a **“System Repair Tools”** submenu to the **Windows Desktop background** right-click context menu. From that submenu you can:

- Run **System File Checker**: `sfc /scannow`
- Run **DISM health checks/repair**:
  - `/CheckHealth`
  - `/ScanHealth`
  - `/RestoreHealth`
- Extract **SFC** log lines tagged with **`[SR]`** from `CBS.log` into a text file and open it in Notepad

All tools are launched in **Windows Terminal** using the **PowerShell 7**
profile. Each menu command explicitly requests elevation through
`Start-Process -Verb RunAs`, so Windows displays a UAC prompt before opening
the Administrator terminal.

## Files

- `install-system-repair-menu.reg` installs the desktop context menu.
- `uninstall-system-repair-menu.reg` removes the desktop context menu.
- `tests/SystemRepairMenu.Tests.ps1` validates the registry launchers on
  Windows.
- `tests/README.md` defines the interactive UAC and Terminal test matrix.

---

## What This Script Changes

### Registry location

The script writes menu entries under:

`HKEY_CLASSES_ROOT\DesktopBackground\Shell\SystemRepair`

This affects the **desktop background** context menu (right-click on empty space on the desktop).

> Note: `HKEY_CLASSES_ROOT` is a merged view of machine and user class registrations. Writing here typically requires Administrator permissions.

---

## Prerequisites / Assumptions

This script is designed around these assumptions:

1. **Windows Terminal is installed**
2. **PowerShell 7 is installed at `C:\Program Files\PowerShell\7\pwsh.exe`**
3. **A Windows Terminal profile named “PowerShell 7” exists**

The registry commands address Windows Terminal through its standard absolute
app-execution-alias path under `%LOCALAPPDATA%\Microsoft\WindowsApps`. They do
not rely on the current directory or `PATH` to locate repair executables.

---

## Resulting Context Menu Structure

When installed, you should see:

### Desktop Right-Click → System Repair Tools

- Run SFC /Scannow
- View log for SFC
- Check Health of Windows Image
- Scan Health of Windows Image
- Repair Windows Image

> Windows 11 note: custom shell entries often appear under **“Show more options”** depending on OS configuration and shell behavior.

---

## Menu Item Details

### 1) System Repair Tools (submenu container)

Registry key:

- `[HKEY_CLASSES_ROOT\DesktopBackground\Shell\SystemRepair]`

Values:

- `MUIVerb` = **System Repair Tools** (label shown in the menu)
- `Icon` = **UserAccountControlSettings.exe** (icon for the submenu)
- `Position` = **Bottom** (places the menu group near the bottom)
- `SubCommands` = `""` (indicates this key contains subitems under `Shell\...`)

---

### 2) Run SFC /Scannow

Command executed:

```text
wt.exe -w new new-tab --title "SFC Scan" -p "PowerShell 7" -d "%SystemRoot%\System32" "%ComSpec%" /k "%SystemRoot%\System32\sfc.exe" /scannow
```

What it does:

- Uses PowerShell `Start-Process -Verb RunAs` to request UAC elevation
- Opens an elevated Windows Terminal tab titled **“SFC Scan”**
- Uses the **PowerShell 7** Terminal profile
- Runs **Command Prompt** and executes:
  - `sfc.exe /scannow`
- Keeps the console open after completion (`cmd.exe /k`) so you can read results

Why it uses `cmd.exe`:

- It avoids quoting/argument parsing edge cases that can occur when trying to launch `sfc.exe /scannow` via `pwsh -Command ...` from a registry shell verb.

---

### 3) View log for SFC

Command executed:

```text
wt.exe -w new new-tab --title "View SFC Log" -p "PowerShell 7" -d "%SystemRoot%\System32" "C:\Program Files\PowerShell\7\pwsh.exe" -NoExit -EncodedCommand <BASE64>
```

What it does:

- Opens a separate elevated Terminal window (`-w new`) with a tab titled
  **“View SFC Log”**
- Runs PowerShell 7 with `-NoExit` so the tab stays open
- Uses `-EncodedCommand` to reliably pass a multi-line script (avoids complex nested quoting in `.reg` strings)
- Extracts SFC lines marked `[SR]` from CBS log and writes them to your desktop, then opens Notepad

#### The decoded PowerShell script (what `-EncodedCommand` contains)

This is the exact script content in human-readable form:

```powershell
$ErrorActionPreference = 'Stop'
Write-Host "Extracting SFC [SR] lines from CBS.log..." -ForegroundColor Cyan
$src = Join-Path $env:windir 'Logs\CBS\CBS.log'
$desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
if ([string]::IsNullOrWhiteSpace($desktop)) {
    throw 'Windows did not return a Desktop known-folder path.'
}
$dst = Join-Path $desktop 'SFC_LOG.txt'
Select-String '\[SR\]' $src | ForEach-Object { $_.Line } | Set-Content -LiteralPath $dst -Encoding UTF8
Write-Host "Done. Opening: $dst" -ForegroundColor Green
notepad.exe $dst
```

Outputs:

- Reads: `%windir%\Logs\CBS\CBS.log`
- Writes: the current Windows Desktop known folder, including redirected
  Desktop locations such as OneDrive
- Opens: `SFC_LOG.txt` in Notepad

Icon:

- The menu item is set to use the Notepad icon:
  - `"Icon"="notepad.exe"`

---

### 4) DISM: Check Health of Windows Image

Command executed:

```text
wt.exe -w new new-tab --title "DISM CheckHealth" -p "PowerShell 7" -d "%SystemRoot%\System32" "%ComSpec%" /k "%SystemRoot%\System32\Dism.exe" /Online /Cleanup-Image /CheckHealth
```

What it does:

- Runs a quick check to see if the Windows image is flagged as corrupted and whether corruption is repairable.
- Keeps the console open after execution so results remain visible.

---

### 5) DISM: Scan Health of Windows Image

Command executed:

```text
wt.exe -w new new-tab --title "DISM ScanHealth" -p "PowerShell 7" -d "%SystemRoot%\System32" "%ComSpec%" /k "%SystemRoot%\System32\Dism.exe" /Online /Cleanup-Image /ScanHealth
```

What it does:

- Performs a deeper scan for component store corruption (can take longer).

---

### 6) DISM: Repair Windows Image (RestoreHealth)

Command executed:

```text
wt.exe -w new new-tab --title "DISM RestoreHealth" -p "PowerShell 7" -d "%SystemRoot%\System32" "%ComSpec%" /k "%SystemRoot%\System32\Dism.exe" /Online /Cleanup-Image /RestoreHealth
```

What it does:

- Attempts to repair the Windows image using Windows Update (by default) as the source.
- Can take a while depending on corruption and update source availability.

---

## Understanding the Windows Terminal Arguments Used

- `wt.exe`  
  Launch Windows Terminal.

- `new-tab`  
  Create a new tab (behavior depends on WT “new instance behavior”).

- `--title "..."`  
  Sets the tab title.

- `-p "PowerShell 7"`  
  Uses the Windows Terminal profile with that name.

- `-w new`

  Forces a separate elevated Terminal window. This avoids attempting to attach
  an elevated command to an existing unelevated Terminal process.

- `-d "%SystemRoot%\System32"`

  Uses the protected Windows system directory as the starting directory.

- `Start-Process -Verb RunAs`

  Starts `wt.exe` through the Windows elevation verb. This is the mechanism
  that guarantees the repair commands run as Administrator; `HasLUAShield`
  only controls the displayed icon.

---

## Installation Instructions

1. Right-click `install-system-repair-menu.reg` → **Merge**.
   - If prompted, approve UAC / registry merge prompts.

2. Restart Explorer if the menu does not immediately appear:
   - Task Manager → **Windows Explorer** → Restart  
   (or sign out/in)

3. Verify:
   - Right-click **empty desktop area** → look for **System Repair Tools** (may be under **Show more options** on Windows 11)

---

## Troubleshooting

### Menu doesn’t show up

- Ensure you right-click **desktop background** (not a file/folder).
- Restart Explorer after importing.
- On Windows 11, check **Show more options**.

### Each click opens a brand-new Terminal window

This is intentional. `-w new` isolates every elevated repair session from
existing unelevated or elevated Terminal instances.

### Commands open a tab but appear to do “nothing”

- SFC/DISM can take time—watch for progress output.
- For “View log for SFC”, the tab should print:
  - “Extracting…” then “Done… Opening: …”
  If you don’t see those messages, the command line may not be executing (usually profile name mismatch or WT behavior).

### “PowerShell 7” profile not found

- Confirm the profile name in Windows Terminal settings.
- If your profile is named differently, update every `-p "PowerShell 7"` entry to match exactly.

### Not elevated / Access denied / SFC or DISM fails

- Approve the UAC prompt displayed after selecting a menu command.
- Confirm the resulting Windows Terminal title shows **Administrator**.
- Confirm PowerShell 7 exists at
  `C:\Program Files\PowerShell\7\pwsh.exe` and the Windows Terminal alias exists
  at `%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe` if no prompt appears.
- Cancelling UAC is safe: the elevated Terminal and repair command do not run.

## Regression Tests

Run the static Windows regression suite with PowerShell 7 and Pester 5:

```powershell
Invoke-Pester -Path '.\tests\SystemRepairMenu.Tests.ps1' -CI
```

The automated suite verifies registry parsing, explicit UAC elevation,
separate Terminal windows, protected working directories, absolute repair
executables, the encoded log script, and matching uninstall behavior. Complete
the interactive scenarios in [tests/README.md](tests/README.md) on a Windows
test system before deployment; UAC cancellation and Terminal-instance behavior
cannot be exercised safely by unattended CI.

---

## Uninstall / Remove the Context Menu

To remove everything created by this script, delete the top-level key:

- `HKEY_CLASSES_ROOT\DesktopBackground\Shell\SystemRepair`

You can do this with a `.reg` uninstall file:

```reg
Windows Registry Editor Version 5.00

[-HKEY_CLASSES_ROOT\DesktopBackground\Shell\SystemRepair]
```

Merge `uninstall-system-repair-menu.reg`, then restart Explorer.

---

## Safety Notes

- This script modifies the Windows Registry. Use standard change-control hygiene:
  - Keep a backup copy of the `.reg`
  - Consider exporting the existing `DesktopBackground\Shell` key before changes
- SFC/DISM are safe built-in repair tools, but they can take time and may require reboots depending on results.
