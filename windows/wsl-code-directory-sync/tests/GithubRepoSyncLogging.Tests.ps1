BeforeAll {
    $script:wrapperPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
        'github_reposync_logged.ps1'
}

Describe 'WSL repository sync logging' {
    BeforeEach {
        $logDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:parameters = @{
            Distribution = 'Fixture Distro'
            WslUsername  = 'fixture-user'
            Destination  = '/mnt/c/Users/Fixture User/Documents/GitHub/'
            LogDirectory = $logDirectory
        }
    }

    It 'captures both native streams and preserves exit <Code>' -ForEach @(
        @{ Code = 0 }, @{ Code = 23 }
    ) {
        $nativeCode = $Code
        $nativeExecutable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $invoker = {
            param($Arguments, $StdoutPath, $StderrPath)
            $command = '[Console]::Out.WriteLine("fixture stdout"); ' +
                '[Console]::Error.WriteLine("fixture stderr"); exit ' + $nativeCode
            & $nativeExecutable -NoProfile -NonInteractive -Command $command `
                1> $StdoutPath 2> $StderrPath
            return $LASTEXITCODE
        }.GetNewClosure()
        # Exercise a caller that normally turns nonzero native exits into errors.
        $PSNativeCommandUseErrorActionPreference = $true

        & $wrapperPath @parameters -WslInvoker $invoker
        $LASTEXITCODE | Should -Be $Code

        $run = Get-ChildItem -LiteralPath $logDirectory -Directory
        Get-Content -LiteralPath (Join-Path $run.FullName 'stdout.log') -Raw |
            Should -Match 'fixture stdout'
        Get-Content -LiteralPath (Join-Path $run.FullName 'stderr.log') -Raw |
            Should -Match 'fixture stderr'
        $summary = Get-Content -LiteralPath (Join-Path $run.FullName 'run.json') -Raw |
            ConvertFrom-Json
        $summary.Status | Should -Be 'Completed'
        $summary.ExitCode | Should -Be $Code
        $summary.Error | Should -BeNullOrEmpty
        $summary.StartedAt | Should -Not -BeNullOrEmpty
        $summary.FinishedAt | Should -Not -BeNullOrEmpty
    }

    It 'keeps the mirror arguments and paths with spaces as separate argv entries' {
        $invoker = { param($Arguments, $StdoutPath, $StderrPath) 0 }

        & $wrapperPath @parameters -WslInvoker $invoker

        $run = Get-ChildItem -LiteralPath $logDirectory -Directory
        $summary = Get-Content -LiteralPath (Join-Path $run.FullName 'run.json') -Raw |
            ConvertFrom-Json
        ($summary.Arguments | ConvertTo-Json -Compress) | Should -Be (
            @('-d', 'Fixture Distro', '-u', 'fixture-user', '--cd', '~', '--',
                'rsync', '-avz', '--delete', '--delete-excluded', '--exclude=.vexp/',
                './code/', '/mnt/c/Users/Fixture User/Documents/GitHub/') |
                ConvertTo-Json -Compress
        )
    }

    It 'adds only the dry-run option for a diagnostic run' {
        $invoker = { param($Arguments, $StdoutPath, $StderrPath) 0 }

        & $wrapperPath @parameters -DryRun -WslInvoker $invoker

        $run = Get-ChildItem -LiteralPath $logDirectory -Directory
        $summary = Get-Content -LiteralPath (Join-Path $run.FullName 'run.json') -Raw |
            ConvertFrom-Json
        $summary.DryRun | Should -BeTrue
        $summary.Arguments | Should -Contain '--dry-run'
        $summary.Arguments.Count | Should -Be 15
        $summary.Arguments[-2] | Should -Be './code/'
        $summary.Arguments[-1] | Should -Be $parameters.Destination
    }

    It 'records a launch exception and exits with failure' {
        $invoker = { param($Arguments, $StdoutPath, $StderrPath) throw 'WSL launch failed' }

        & $wrapperPath @parameters -WslInvoker $invoker
        $LASTEXITCODE | Should -Be 1

        $run = Get-ChildItem -LiteralPath $logDirectory -Directory
        $summary = Get-Content -LiteralPath (Join-Path $run.FullName 'run.json') -Raw |
            ConvertFrom-Json
        $summary.Status | Should -Be 'WrapperFailed'
        $summary.Error | Should -Be 'WSL launch failed'
        $summary.ExitCode | Should -Be 1
    }

    It 'does not start WSL if logging cannot be initialized' {
        Set-Content -LiteralPath $logDirectory -Value 'This is a file, not a directory.'
        $called = [pscustomobject]@{ Value = $false }
        $invoker = {
            param($Arguments, $StdoutPath, $StderrPath)
            $called.Value = $true
            return 0
        }.GetNewClosure()

        & $wrapperPath @parameters -WslInvoker $invoker

        $LASTEXITCODE | Should -Be 1
        $called.Value | Should -BeFalse
    }

    It 'reports final log failure without hiding native exit <Code>' -ForEach @(
        @{ Code = 0; Expected = 1 }, @{ Code = 23; Expected = 23 }
    ) {
        $nativeCode = $Code
        $invoker = {
            param($Arguments, $StdoutPath, $StderrPath)
            $summaryPath = Join-Path (Split-Path -Parent $StdoutPath) 'run.json'
            Remove-Item -LiteralPath $summaryPath
            New-Item -ItemType Directory -Path $summaryPath | Out-Null
            return $nativeCode
        }.GetNewClosure()

        & $wrapperPath @parameters -WslInvoker $invoker

        $LASTEXITCODE | Should -Be $Expected
    }

    It 'retains separate logs for successive runs' {
        $invoker = { param($Arguments, $StdoutPath, $StderrPath) 0 }

        & $wrapperPath @parameters -WslInvoker $invoker
        & $wrapperPath @parameters -WslInvoker $invoker

        @(Get-ChildItem -LiteralPath $logDirectory -Directory).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $logDirectory -Filter 'run.json' -Recurse).Count |
            Should -Be 2
    }
}
