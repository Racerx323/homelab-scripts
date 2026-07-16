function Assert-Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-LauncherScript {
    param([Parameter(Mandatory)][string]$RegistryLine)

    if ($RegistryLine -notmatch '^@="(.*)"$') {
        throw "Unable to decode the registry string from: $RegistryLine"
    }
    $decodedRegistryValue = [regex]::Replace(
        $Matches[1],
        '\\(["\\])',
        '$1'
    )

    if ($decodedRegistryValue -notmatch '-Command "(.+)"$') {
        throw "Unable to extract the PowerShell launcher from: $RegistryLine"
    }
    return $Matches[1]
}

Describe 'System Repair registry installation' {
    BeforeEach {
        $systemRepairDirectory = Split-Path -Parent $PSScriptRoot
        $installFile = Join-Path $systemRepairDirectory 'install-system-repair-menu.reg'
        $uninstallFile = Join-Path $systemRepairDirectory 'uninstall-system-repair-menu.reg'
        $installContent = Get-Content -LiteralPath $installFile -Raw
        $uninstallContent = Get-Content -LiteralPath $uninstallFile -Raw
        $commandLines = @(
            Get-Content -LiteralPath $installFile |
                Where-Object { $_ -match '^@=' }
        )
    }

    It 'defines all five menu commands and the matching uninstall key' {
        Assert-Condition ($commandLines.Count -eq 5) 'Expected five menu commands.'
        Assert-Condition (
            $installContent.Contains(
                '[HKEY_CLASSES_ROOT\DesktopBackground\Shell\SystemRepair]'
            )
        ) 'The install file does not define the SystemRepair root key.'
        Assert-Condition (
            $uninstallContent.Contains(
                '[-HKEY_CLASSES_ROOT\DesktopBackground\Shell\SystemRepair]'
            )
        ) 'The uninstall file does not remove the SystemRepair root key.'
    }

    It 'uses the absolute PowerShell 7 launcher for every command' {
        foreach ($line in $commandLines) {
            Assert-Condition (
                $line -match '^@="\\"C:\\\\Program Files\\\\PowerShell\\\\7\\\\pwsh\.exe\\"'
            ) "A command does not use the absolute PowerShell 7 path: $line"
        }
    }

    It 'parses every embedded PowerShell launcher without syntax errors' {
        foreach ($line in $commandLines) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-LauncherScript -RegistryLine $line),
                [ref]$tokens,
                [ref]$errors
            ) | Out-Null
            Assert-Condition ($errors.Count -eq 0) (
                "Launcher parse errors: $($errors.Message -join '; ')"
            )
        }
    }

    It 'elevates an isolated Terminal window from an absolute alias path' {
        foreach ($line in $commandLines) {
            $launcher = Get-LauncherScript -RegistryLine $line
            Assert-Condition (
                $launcher -match 'Start-Process -FilePath \(\$env:LOCALAPPDATA \+ ''\\Microsoft\\WindowsApps\\wt\.exe''\)'
            ) 'The launcher does not use the absolute Windows Terminal alias path.'
            Assert-Condition ($launcher -match '-Verb RunAs') (
                'The launcher does not request UAC elevation.'
            )
            Assert-Condition ($launcher.Contains("'-w','new'")) (
                'The launcher does not force a separate Terminal window.'
            )
            Assert-Condition (
                $launcher -match '''-d'',\(\[char\]34 \+ \$env:SystemRoot \+ ''\\System32'''
            ) 'The launcher does not use System32 as its working directory.'
        }
    }

    It 'uses ComSpec and absolute protected repair executables' {
        $repairLaunchers = @(0, 2, 3, 4 | ForEach-Object {
                Get-LauncherScript -RegistryLine $commandLines[$_]
            })

        foreach ($launcher in $repairLaunchers) {
            Assert-Condition ($launcher -match '\$env:ComSpec') (
                'A repair launcher does not invoke the shell through ComSpec.'
            )
            Assert-Condition ($launcher -match '\$env:SystemRoot') (
                'A repair launcher does not use an absolute system path.'
            )
            Assert-Condition ($launcher -notmatch "'cmd\.exe'") (
                'A repair launcher contains a bare cmd.exe executable.'
            )
            Assert-Condition ($launcher -notmatch "'wt\.exe'") (
                'A repair launcher contains a bare wt.exe executable.'
            )
        }

        Assert-Condition (
            $repairLaunchers[0] -match '\\System32\\sfc\.exe'
        ) 'The SFC launcher does not use the protected sfc.exe path.'
        Assert-Condition (
            $repairLaunchers[0].Contains("'/scannow'")
        ) 'The SFC launcher does not include /scannow.'

        $expectedDismOperations = @('/CheckHealth', '/ScanHealth', '/RestoreHealth')
        for ($index = 1; $index -le 3; $index++) {
            $launcher = $repairLaunchers[$index]
            $operation = $expectedDismOperations[$index - 1]
            Assert-Condition (
                $launcher -match '\\System32\\Dism\.exe'
            ) 'A DISM launcher does not use the protected Dism.exe path.'
            Assert-Condition (
                $launcher.Contains("'/Online','/Cleanup-Image','$operation'")
            ) "The DISM launcher does not include the expected $operation arguments."
        }
    }

    It 'keeps the encoded SFC log payload safe and parseable' {
        $viewLogCommand = $commandLines[1]
        Assert-Condition (
            $viewLogCommand -match "-EncodedCommand','([^']+)'"
        ) 'The View SFC Log command does not contain an encoded payload.'
        $decoded = [Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($Matches[1])
        )

        Assert-Condition (
            $decoded -match '\$ErrorActionPreference = ''Stop'''
        ) 'The encoded script does not stop on errors.'
        Assert-Condition (
            $decoded -match '\[Environment\]::GetFolderPath'
        ) 'The encoded script does not use the Desktop known-folder API.'
        Assert-Condition (
            $decoded -notmatch '\$env:userprofile'
        ) 'The encoded script contains the legacy userprofile Desktop path.'

        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $decoded,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        Assert-Condition ($errors.Count -eq 0) (
            "Encoded script parse errors: $($errors.Message -join '; ')"
        )
    }
}
