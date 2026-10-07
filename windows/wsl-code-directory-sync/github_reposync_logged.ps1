#requires -Version 7.2
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Distribution,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WslUsername,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination,
    [string]$LogDirectory = 'C:\Scripts\wsl-repo-sync-logs',
    [switch]$DryRun,
    [Parameter(DontShow)]
    [scriptblock]$WslInvoker = {
        param($Arguments, $StdoutPath, $StderrPath)
        $identityArguments = $Arguments[0..3]
        $commandArguments = $Arguments[7..($Arguments.Count - 1)]
        # Array-splatted ~ expands to the Windows home in PowerShell 7.6.
        & wsl.exe @identityArguments --cd '~' -- @commandArguments 1> $StdoutPath 2> $StderrPath
        return $LASTEXITCODE
    }
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exitCode = 1
$summaryPath = $null
$summary = $null

try {
    $wslArguments = @(
        '-d', $Distribution, '-u', $WslUsername, '--cd', '~', '--',
        'rsync', '-avz', '--delete', '--delete-excluded', '--exclude=.vexp/'
    )
    if ($DryRun) {
        $wslArguments += '--dry-run'
    }
    $wslArguments += @('./code/', $Destination)

    $startedAt = [datetime]::UtcNow
    $runName = '{0}-{1}' -f $startedAt.ToString('yyyyMMddTHHmmssfffZ'), `
        [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $LogDirectory $runName
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $stdoutPath = Join-Path $runDirectory 'stdout.log'
    $stderrPath = Join-Path $runDirectory 'stderr.log'
    Set-Content -LiteralPath $stdoutPath -Value '' -NoNewline -Encoding utf8
    Set-Content -LiteralPath $stderrPath -Value '' -NoNewline -Encoding utf8
    $summaryPath = Join-Path $runDirectory 'run.json'
    $summary = [ordered]@{
        StartedAt  = $startedAt.ToString('o')
        FinishedAt = $null
        Status     = 'Running'
        Executable = 'wsl.exe'
        Arguments  = $wslArguments
        DryRun     = [bool]$DryRun
        ExitCode   = $null
        Error      = $null
    }
    $summary | ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $summaryPath -Encoding utf8

    $nativeResult = & $WslInvoker $wslArguments $stdoutPath $stderrPath
    if ($null -eq $nativeResult -or $nativeResult -is [array]) {
        throw 'The WSL invocation did not return a single exit code.'
    }
    $exitCode = [int]$nativeResult
    $summary.Status = 'Completed'
}
catch {
    if ($summary) {
        $summary.Status = 'WrapperFailed'
        $summary.Error = $_.Exception.Message
    }
    [Console]::Error.WriteLine($_.Exception.Message)
}
finally {
    if ($summaryPath -and $summary) {
        $summary.FinishedAt = [datetime]::UtcNow.ToString('o')
        $summary.ExitCode = $exitCode
        try {
            $summary | ConvertTo-Json -Depth 3 |
                Set-Content -LiteralPath $summaryPath -Encoding utf8
        }
        catch {
            # Report a logging failure even when rsync succeeded.
            if ($exitCode -eq 0) {
                $exitCode = 1
            }
            [Console]::Error.WriteLine("Unable to finalize sync log: $($_.Exception.Message)")
        }
    }
}

exit $exitCode
