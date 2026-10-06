param(
    [string]$AppriseUrl = 'http://APPRISE_HOST:8000/notify/apprise',
    [Parameter(Mandatory)]
    [ValidateRange(1, 9223372036854775807)]
    [long]$EventRecordId,
    [ValidateNotNullOrEmpty()]
    [string]$StorageDirectory = 'C:\Scripts',
    [ValidateNotNullOrEmpty()]
    [string]$SyncLogDirectory = 'C:\Scripts\wsl-repo-sync-logs',
    [Parameter(DontShow)]
    [scriptblock]$EventReader = {
        param($LogName, $FilterXPath)
        Get-WinEvent -LogName $LogName -FilterXPath $FilterXPath `
            -ErrorAction SilentlyContinue
    },
    [Parameter(DontShow)]
    [scriptblock]$RequestInvoker = {
        param($Uri, $Body)
        Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -TimeoutSec 15 `
            -StatusCodeVariable statusCode | Out-Null
        return $statusCode
    }
)

$ErrorActionPreference = 'Stop'

$TaskName = "\WSL GitHub Repo Sync"
$LogPath = "Microsoft-Windows-TaskScheduler/Operational"
$LogFile = Join-Path $StorageDirectory 'github_reposync_apprise_notify.log'
$StateFile = Join-Path $StorageDirectory 'github_reposync_apprise_notify.processed-events.json'

if ($AppriseUrl -match 'APPRISE_HOST') {
    throw 'Set -AppriseUrl to your Apprise API endpoint before running this script.'
}

if (-not (Test-Path -LiteralPath $StorageDirectory)) {
    New-Item -ItemType Directory -Path $StorageDirectory -Force | Out-Null
}

function Write-NotifyLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $LogFile -Value "[$timestamp] $Message"
}

function Format-ResultCode {
    param($Code)

    if ($null -eq $Code -or $Code -eq '') {
        return 'unknown'
    }

    $codeText = [string]$Code
    if ($codeText -match '^\d+$' -and [int64]$codeText -gt 2147483647) {
        return ("0x{0:X}" -f [int64]$codeText)
    }

    return $codeText
}

function Get-EventDataValue {
    param(
        [object]$Event,
        [string]$Name
    )

    $xml = [xml]$Event.ToXml()
    $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    return $node.'#text'
}

function Get-NativeResultCode {
    param([string]$Code)

    $number = 0L
    if (-not [long]::TryParse($Code, [ref]$number)) { return $null }
    # Event 201 may wrap a native process result in HRESULT_FROM_WIN32.
    if (($number -band 0xFFFF0000L) -eq 0x80070000L) {
        return ($number -band 0xFFFFL)
    }
    return $number
}

function ConvertTo-AlertText {
    param([string]$Text, [int]$Limit = 160)

    if ($Text -match '(?i)BEGIN [A-Z ]*PRIVATE KEY|Authorization:\s*Bearer|WEBPASSWORD|(?:^|[^a-z0-9_])(?:password|passwd|token|secret|api[_-]?key)\s*[:=]') {
        return '[sensitive detail omitted]'
    }
    $value = ($Text -replace '[\x00-\x1f\x7f]', ' ').Trim()
    if ($value.Length -gt $Limit) { return $value.Substring(0, $Limit - 3) + '...' }
    return $value
}

function Find-SyncRun {
    param([object]$Completion, [object]$NativeCode)

    $unavailable = [pscustomobject]@{ Run = $null; Reason = 'No uniquely correlated wrapper run is available.' }
    try {
        $instance = Get-EventDataValue -Event $Completion -Name 'TaskInstanceId'
        $guid = [guid]::Empty
        if ($null -eq $NativeCode -or -not [guid]::TryParse($instance, [ref]$guid)) { return $unavailable }
        $startFilter = "*[System[(EventID=200)]] and *[EventData[Data[@Name='TaskInstanceId']='$instance']]"
        $starts = @(& $EventReader $LogPath $startFilter | Where-Object {
            $_.Id -eq 200 -and
            (Get-EventDataValue -Event $_ -Name 'TaskName') -eq $TaskName -and
            (Get-EventDataValue -Event $_ -Name 'TaskInstanceId') -eq $instance
        })
        if ($starts.Count -ne 1 -or -not (Test-Path -LiteralPath $SyncLogDirectory -PathType Container)) { return $unavailable }
        $action = Get-EventDataValue -Event $starts[0] -Name 'ActionName'
        if ([IO.Path]::GetFileName($action) -notin @('pwsh', 'pwsh.exe')) { return $unavailable }
        $startTime = $starts[0].TimeCreated.ToUniversalTime()
        $endTime = $Completion.TimeCreated.ToUniversalTime()
        $candidates = @(
            foreach ($directory in Get-ChildItem -LiteralPath $SyncLogDirectory -Directory) {
                if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $path = Join-Path $directory.FullName 'run.json'
                try {
                    $file = Get-Item -LiteralPath $path
                    if ($file.Length -gt 65536 -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $run = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                    if ($run.Status -notin @('Completed', 'WrapperFailed') -or
                        $run.DryRun -isnot [bool] -or $run.DryRun -or
                        $run.Executable -cne 'wsl.exe' -or $run.Arguments[7] -cne 'rsync' -or
                        $null -eq $run.ExitCode -or $run.ExitCode -ne $NativeCode) { continue }
                    # ConvertFrom-Json can return DateTime objects on newer PowerShell.
                    $started = ([datetimeoffset]$run.StartedAt).UtcDateTime
                    $finished = ([datetimeoffset]$run.FinishedAt).UtcDateTime
                    if ($started -lt $startTime -or $started -gt $startTime.AddSeconds(30) -or
                        $finished -lt $started -or $finished -gt $endTime -or
                        $finished -lt $endTime.AddSeconds(-30)) { continue }
                    [pscustomobject]@{ Summary = $run; Directory = $directory.FullName; Started = $started; Finished = $finished }
                }
                catch { continue }
            }
        )
        if ($candidates.Count -eq 1) { return [pscustomobject]@{ Run = $candidates[0]; Reason = $null } }
    }
    catch { $unavailable.Reason = 'Wrapper logs or task-start evidence could not be read.' }
    return $unavailable
}

function Get-FailureDiagnostics {
    param([string]$Path)

    try {
        $file = Get-Item -LiteralPath $Path
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $offset = [math]::Max(0, $stream.Length - 8192)
            [void]$stream.Seek($offset, 'Begin')
            $buffer = [byte[]]::new(8192)
            $count = $stream.Read($buffer, 0, $buffer.Length)
            $lines = [Text.Encoding]::UTF8.GetString($buffer, 0, $count) -split '\r?\n'
            if ($offset -gt 0) { $lines = $lines | Select-Object -Skip 1 }
        }
        finally { $stream.Dispose() }
        $details = @(
            foreach ($line in $lines) {
                if ($line -match '^Error code:\s*(Wsl/[A-Za-z0-9_/-]+)\s*$') {
                    [pscustomobject]@{ Class = 'wsl-failure'; Text = 'WSL error: ' + (ConvertTo-AlertText $Matches[1]) }
                    continue
                }
                if ($line -notmatch '^rsync(?:\s+error)?[:\[]') { continue }
                $reason = $null
                $class = $null
                switch -Regex ($line) {
                    'Permission denied|Operation not permitted' { $class = 'filesystem-permission'; $reason = 'Permission denied or operation not permitted'; break }
                    'No space left on device' { $class = 'filesystem-space'; $reason = 'No space left on device'; break }
                    'Read-only file system' { $class = 'read-only-filesystem'; $reason = 'Read-only file system'; break }
                    'Input/output error|cyclic redundancy check' { $class = 'filesystem-io'; $reason = 'Filesystem I/O error'; break }
                    'Operation not supported|Function not implemented' { $class = 'filesystem-operation'; $reason = 'Filesystem operation unsupported'; break }
                    'No such file or directory|file has vanished' { $class = 'source-or-path-missing'; $reason = 'File or directory missing'; break }
                }
                if (-not $reason) { continue }
                $operation = 'unknown'
                if ($line -match '\b(opendir|readdir|readlink|mkstemp|mkdir|rename|unlink|symlink|chmod|chown|lstat|stat|open|read errors mapping|read|write|set times|set permissions)\b') { $operation = $Matches[1] }
                $failedPath = 'unknown'
                if ($line -match '"([^"\r\n]+)"') { $failedPath = ConvertTo-AlertText $Matches[1] 120 }
                [pscustomobject]@{ Class = $class; Text = "Operation: $operation; path: $failedPath; reason: $reason" }
            }
        )
        $details | Sort-Object Text -Unique | Select-Object -First 3
    }
    catch { return }
}

try {
    $eventFilter = "*[System[(EventID=201) and (EventRecordID=$EventRecordId)]]"
    $Event = & $EventReader $LogPath $eventFilter |
        Where-Object { (Get-EventDataValue -Event $_ -Name 'TaskName') -eq $TaskName } |
        Select-Object -First 1

    if (-not $Event) {
        throw "Event 201 record $EventRecordId was not found for $TaskName."
    }

    # Include the UTC event timestamp so a cleared event log can legitimately
    # reuse a lower record ID without colliding with the previous generation.
    $eventKey = '{0}|{1}' -f $Event.RecordId, $Event.TimeCreated.ToUniversalTime().Ticks
    $processedEventKeys = @()
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $state = Get-Content -LiteralPath $StateFile -Raw |
                ConvertFrom-Json -ErrorAction Stop
            if ($state.LogPath -eq $LogPath) {
                $processedEventKeys = @($state.ProcessedEventKeys)
            }
        }
        catch {
            throw "Unable to read notification state file '$StateFile': $($_.Exception.Message)"
        }
    }

    if ($processedEventKeys -contains $eventKey) {
        Write-NotifyLog "Skipped duplicate notification for EventKey=$eventKey."
        return
    }

    $EventID = $Event.Id
    $ResultCode = 'unknown'
    $rawResultCode = Get-EventDataValue -Event $Event -Name 'ResultCode'
    $ResultCode = Format-ResultCode $rawResultCode

    $nativeCode = Get-NativeResultCode $rawResultCode
    $node = $Event.MachineName
    if ($node -notmatch '^[A-Za-z0-9.-]{1,253}$') { $node = [Environment]::MachineName }
    $shortNode = ($node -split '\.')[0]
    $observed = $Event.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $status = "Event 201 result=$ResultCode"
    if ($null -ne $nativeCode) { $status += "; native exit=$nativeCode" }
    $details = @(
        '- Component: WSL GitHub Repo Sync'
        '- Check: scheduled-repository-mirror'
        "- Status: $status"
        "- Timing: observed: $observed"
        "- Correlation: $eventKey"
    )
    $evidence = "$LogPath; Event 201 record $EventRecordId"
    $firstCheck = "Get-WinEvent -LogName '$LogPath' -FilterXPath '*[System[EventRecordID=$EventRecordId]]'"
    $diagnostics = @()
    if ([string]$rawResultCode -eq '0') {
        $Type = 'success'
        $Title = "✅ [Replication] success on $shortNode"
        $impact = 'Repository mirror action completed successfully.'
        $failureClass = $null
    } else {
        $Type = 'failure'
        $Title = "🚨 [Replication] failure on $shortNode"
        $impact = 'Windows backup mirror may be incomplete or stale; WSL is the authoritative source.'
        $failureClass = 'action-nonzero-exit'
        $correlated = Find-SyncRun $Event $nativeCode
        if ($correlated.Run) {
            $run = $correlated.Run
            $evidence = ConvertTo-AlertText $run.Directory 200
            $stderrPath = Join-Path $run.Directory 'stderr.log'
            $checkPath = $stderrPath
            $diagnostics = @(Get-FailureDiagnostics $stderrPath)
            if ($run.Summary.Status -eq 'WrapperFailed') {
                $failureClass = 'wrapper-failed'
                $checkPath = Join-Path $run.Directory 'run.json'
                $details += '- Diagnostics: wrapper exception recorded in run.json.'
            } elseif ($diagnostics.Count) {
                $failureClass = ($diagnostics.Class | Sort-Object -Unique) -join ', '
            } elseif ($nativeCode -eq 23) {
                $failureClass = 'rsync-partial-transfer'
            } else {
                $failureClass = 'rsync-nonzero-exit'
            }
            $duration = [math]::Round(($run.Finished - $run.Started).TotalSeconds, 1)
            $details += "- Run: started $($run.Started.ToString('o')); duration ${duration}s"
            $firstCheck = "Get-Content -LiteralPath '$($checkPath.Replace("'", "''"))' -Tail 20"
            if ($firstCheck.Length -gt 256 -or (ConvertTo-AlertText $checkPath 256) -cne $checkPath) {
                $firstCheck = 'Open the evidence directory and inspect stderr.log and run.json.'
            }
        } else {
            $details += '- Diagnostics: ' + $correlated.Reason
        }
    }

    $sections = @('Summary', '', '- Application: Replication',
        "- Node: $shortNode ($node)", "- Event: $Type", '', 'Impact', '', "- $impact")
    if ($failureClass) { $sections += "- Failure class: $failureClass" }
    $sections += @('', 'Details', '') + $details
    $nextStep = @('', 'Next step', '')
    if ($Type -eq 'failure') { $nextStep += "- First check: $firstCheck" }
    $nextStep += "- Evidence: $evidence"
    foreach ($diagnostic in $diagnostics) {
        $line = '- ' + $diagnostic.Text
        if ((($sections + $line + $nextStep) -join "`n").Length -le 2048) { $sections += $line }
    }
    $Body = ($sections + $nextStep) -join "`n"
    if ($Title.Length -gt 256 -or $Body.Length -gt 2048) { throw 'Notification exceeds the standard alert size limit.' }

    $Payload = @{
        title = $Title
        body  = $Body
        type  = $Type
        format = 'text'
    }

    $statusCode = & $RequestInvoker $AppriseUrl $Payload
    if ($statusCode -ne 200) {
        throw "Apprise returned HTTP $statusCode; expected HTTP 200."
    }

    $statePayload = @{
        LogPath            = $LogPath
        ProcessedEventKeys = @($processedEventKeys) + $eventKey
    } | ConvertTo-Json -Depth 3
    $temporaryStateFile = "$StateFile.tmp"
    Set-Content -LiteralPath $temporaryStateFile -Value $statePayload -Encoding utf8
    Move-Item -LiteralPath $temporaryStateFile -Destination $StateFile -Force
    Write-NotifyLog "Sent $Type notification for EventID=$EventID EventRecordId=$EventRecordId ResultCode=$ResultCode."
}
catch {
    Write-NotifyLog "ERROR: $($_.Exception.Message)"
    throw
}
