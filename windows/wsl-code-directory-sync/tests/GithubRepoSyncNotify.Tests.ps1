BeforeAll {
    function Assert-Condition {
        param(
            [Parameter(Mandatory)][bool]$Condition,
            [Parameter(Mandatory)][string]$Message
        )

        if (-not $Condition) {
            throw $Message
        }
    }

    function New-FakeTaskEvent {
        param(
            [long]$RecordId = 42,
            [string]$TaskName = '\WSL GitHub Repo Sync',
            [string]$ResultCode = '0',
            [datetime]$TimeCreated = [datetime]'2026-07-16T12:00:00Z',
            [int]$Id = 201,
            [string]$TaskInstanceId = '',
            [string]$ActionName = 'pwsh.exe'
        )

        $event = [pscustomobject]@{
            Id          = $Id
            RecordId    = $RecordId
            TimeCreated = $TimeCreated
            TaskName    = $TaskName
            ResultCode  = $ResultCode
            TaskInstanceId = $TaskInstanceId
            ActionName = $ActionName
            MachineName = 'sync-node.example.test'
        }
        $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value {
            $escapedTaskName = [Security.SecurityElement]::Escape($this.TaskName)
            $escapedResultCode = [Security.SecurityElement]::Escape($this.ResultCode)
            $escapedInstance = [Security.SecurityElement]::Escape($this.TaskInstanceId)
            $escapedAction = [Security.SecurityElement]::Escape($this.ActionName)
            return @"
<Event>
  <EventData>
    <Data Name="TaskName">$escapedTaskName</Data>
    <Data Name="ResultCode">$escapedResultCode</Data>
    <Data Name="TaskInstanceId">$escapedInstance</Data>
    <Data Name="ActionName">$escapedAction</Data>
  </EventData>
</Event>
"@
        }
        return $event
    }

    function New-FakeSyncRun {
        param([string]$Root, [string]$Stderr = '', [hashtable]$Overrides = @{})

        $directory = Join-Path $Root ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $summary = @{
            StartedAt = '2026-07-16T11:59:41Z'
            FinishedAt = '2026-07-16T11:59:58Z'
            Status = 'Completed'
            Executable = 'wsl.exe'
            Arguments = @('-d', 'Ubuntu', '-u', 'aaron', '--cd', '~', '--', 'rsync')
            DryRun = $false
            ExitCode = 23
            Error = $null
        }
        foreach ($key in $Overrides.Keys) { $summary[$key] = $Overrides[$key] }
        $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'run.json') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $directory 'stderr.log') -Value $Stderr -Encoding utf8
        return $directory
    }
}

Describe 'GitHub repository sync notification flow' {
    BeforeEach {
        $notifierPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
            'github_reposync_apprise_notify.ps1'
        $storageDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $storageDirectory | Out-Null
        $logFile = Join-Path $storageDirectory `
            'github_reposync_apprise_notify.log'
        $stateFile = Join-Path $storageDirectory `
            'github_reposync_apprise_notify.processed-events.json'
    }

    It 'correlates a matching event and persists successful notification state' {
        $event = New-FakeTaskEvent
        $eventReader = { param($LogName, $FilterXPath) $event }.GetNewClosure()
        $requestInvoker = { param($Uri, $Body) 200 }

        & $notifierPath -AppriseUrl 'http://apprise.test/notify' `
            -EventRecordId $event.RecordId -StorageDirectory $storageDirectory `
            -EventReader $eventReader -RequestInvoker $requestInvoker

        Assert-Condition (Test-Path -LiteralPath $stateFile) (
            'Successful notification did not create the state file.'
        )
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $expectedKey = '{0}|{1}' -f $event.RecordId, `
            $event.TimeCreated.ToUniversalTime().Ticks
        Assert-Condition ($state.ProcessedEventKeys -contains $expectedKey) (
            'Successful notification did not persist the event key.'
        )
        Assert-Condition (
            (Get-Content -LiteralPath $logFile -Raw) -match `
                'Sent success notification.*ResultCode=0'
        ) 'Successful notification was not logged.'
    }

    It 'reports a descriptive error when the correlated event is missing' {
        $eventReader = { param($LogName, $FilterXPath) @() }
        $requestInvoker = { param($Uri, $Body) 200 }
        $caught = $null

        try {
            & $notifierPath -AppriseUrl 'http://apprise.test/notify' `
                -EventRecordId 404 -StorageDirectory $storageDirectory `
                -EventReader $eventReader -RequestInvoker $requestInvoker
        }
        catch {
            $caught = $_
        }

        Assert-Condition ($null -ne $caught) 'Missing event did not throw.'
        Assert-Condition (
            $caught.Exception.Message -match 'Event 201 record 404 was not found'
        ) 'Missing event did not return the descriptive correlation error.'
        Assert-Condition (-not (Test-Path -LiteralPath $stateFile)) (
            'Missing event unexpectedly created notification state.'
        )
        Assert-Condition (
            (Get-Content -LiteralPath $logFile -Raw) -match 'ERROR: Event 201 record 404'
        ) 'Missing event was not logged.'
    }

    It 'suppresses an exact duplicate event-key replay' {
        $event = New-FakeTaskEvent
        $eventKey = '{0}|{1}' -f $event.RecordId, `
            $event.TimeCreated.ToUniversalTime().Ticks
        @{
            LogPath = 'Microsoft-Windows-TaskScheduler/Operational'
            ProcessedEventKeys = @($eventKey)
        } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
        $eventReader = { param($LogName, $FilterXPath) $event }.GetNewClosure()
        $script:requestCount = 0
        $requestInvoker = {
            param($Uri, $Body)
            $script:requestCount++
            return 200
        }

        & $notifierPath -AppriseUrl 'http://apprise.test/notify' `
            -EventRecordId $event.RecordId -StorageDirectory $storageDirectory `
            -EventReader $eventReader -RequestInvoker $requestInvoker

        Assert-Condition ($script:requestCount -eq 0) (
            'Duplicate event unexpectedly called Apprise.'
        )
        Assert-Condition (
            (Get-Content -LiteralPath $logFile -Raw) -match `
                'Skipped duplicate notification'
        ) 'Duplicate event was not logged as skipped.'
    }

    It 'rejects and logs a malformed state file' {
        Set-Content -LiteralPath $stateFile -Value '{not-json' -Encoding utf8
        $event = New-FakeTaskEvent
        $eventReader = { param($LogName, $FilterXPath) $event }.GetNewClosure()
        $requestInvoker = { param($Uri, $Body) 200 }
        $caught = $null

        try {
            & $notifierPath -AppriseUrl 'http://apprise.test/notify' `
                -EventRecordId $event.RecordId -StorageDirectory $storageDirectory `
                -EventReader $eventReader -RequestInvoker $requestInvoker
        }
        catch {
            $caught = $_
        }

        Assert-Condition ($null -ne $caught) 'Malformed state did not throw.'
        Assert-Condition (
            (Get-Content -LiteralPath $logFile -Raw) -match `
                'ERROR: Unable to read notification state file'
        ) 'Malformed state failure was not logged.'
    }

    It 'does not persist state when the Apprise request throws' {
        $event = New-FakeTaskEvent
        $eventReader = { param($LogName, $FilterXPath) $event }.GetNewClosure()
        $requestInvoker = { param($Uri, $Body) throw 'Apprise unavailable' }
        $caught = $null

        try {
            & $notifierPath -AppriseUrl 'http://apprise.test/notify' `
                -EventRecordId $event.RecordId -StorageDirectory $storageDirectory `
                -EventReader $eventReader -RequestInvoker $requestInvoker
        }
        catch {
            $caught = $_
        }

        Assert-Condition ($null -ne $caught) 'Apprise exception did not propagate.'
        Assert-Condition (-not (Test-Path -LiteralPath $stateFile)) (
            'Apprise exception unexpectedly persisted notification state.'
        )
        Assert-Condition (
            (Get-Content -LiteralPath $logFile -Raw) -match `
                'ERROR: Apprise unavailable'
        ) 'Apprise exception was not logged.'
    }

    It 'rejects non-200 Apprise responses without persisting state' {
        $event = New-FakeTaskEvent
        $eventReader = { param($LogName, $FilterXPath) $event }.GetNewClosure()
        $requestInvoker = { param($Uri, $Body) 204 }
        $caught = $null

        try {
            & $notifierPath -AppriseUrl 'http://apprise.test/notify' `
                -EventRecordId $event.RecordId -StorageDirectory $storageDirectory `
                -EventReader $eventReader -RequestInvoker $requestInvoker
        }
        catch {
            $caught = $_
        }

        Assert-Condition ($null -ne $caught) 'HTTP 204 did not throw.'
        Assert-Condition (
            $caught.Exception.Message -match 'Apprise returned HTTP 204'
        ) 'HTTP 204 did not return the expected status error.'
        Assert-Condition (-not (Test-Path -LiteralPath $stateFile)) (
            'HTTP 204 unexpectedly persisted notification state.'
        )
        Assert-Condition (
            (Get-Content -LiteralPath $logFile -Raw) -match `
                'ERROR: Apprise returned HTTP 204'
        ) 'HTTP 204 failure was not logged.'
    }
}

Describe 'Standard Apprise alert content and failure evidence' {
    BeforeEach {
        $notifierPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'github_reposync_apprise_notify.ps1'
        $storageDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $syncLogDirectory = Join-Path $storageDirectory 'sync-logs'
        $instance = '{12345678-1234-1234-1234-123456789012}'
        $completion = New-FakeTaskEvent -TaskInstanceId $instance -ResultCode '2147942423'
        $start = New-FakeTaskEvent -TaskInstanceId $instance -Id 200 -RecordId 40 `
            -TimeCreated ([datetime]'2026-07-16T11:59:40Z')
        $eventReader = {
            param($LogName, $FilterXPath)
            if ($FilterXPath -match 'EventID=201') { return $completion }
            return $start
        }.GetNewClosure()
        $capture = [pscustomobject]@{ Payload = $null; Count = 0 }
        $requestInvoker = {
            param($Uri, $Body)
            $capture.Payload = $Body
            $capture.Count++
            return 200
        }.GetNewClosure()
        $notifyParameters = @{
            AppriseUrl = 'http://apprise.test/notify'
            EventRecordId = 42
            StorageDirectory = $storageDirectory
            SyncLogDirectory = $syncLogDirectory
            EventReader = $eventReader
            RequestInvoker = $requestInvoker
        }
    }

    It 'renders the shared plain-text layout with correlated filesystem failure details' {
        $directory = New-FakeSyncRun -Root $syncLogDirectory -Stderr (
            'rsync: [receiver] mkstemp "/mnt/c/mirror/locked.txt" failed: Permission denied (13)'
        )

        & $notifierPath @notifyParameters

        $capture.Payload.title | Should -Be '🚨 [Replication] failure on sync-node'
        $capture.Payload.type | Should -Be 'failure'
        $capture.Payload.format | Should -Be 'text'
        $body = $capture.Payload.body
        foreach ($section in @('Summary', 'Impact', 'Details', 'Next step')) {
            $body | Should -Match "(?m)^$section$"
        }
        $body | Should -Match 'Node: sync-node \(sync-node.example.test\)'
        $body | Should -Match 'Failure class: filesystem-permission'
        $body | Should -Match 'Event 201 result=0x80070017; native exit=23'
        $body | Should -Match 'Operation: mkstemp; path: /mnt/c/mirror/locked.txt'
        $body | Should -Match 'duration 17s'
        $body | Should -Match ([regex]::Escape($directory))
        $body | Should -Not -Match 'HA and network|cyclic redundancy check|^rsync:'
    }

    It 'keeps a failure alert when no correlated log is available' {
        & $notifierPath @notifyParameters

        $capture.Count | Should -Be 1
        $capture.Payload.type | Should -Be 'failure'
        $capture.Payload.body | Should -Match 'No uniquely correlated wrapper run is available'
        $capture.Payload.body | Should -Match 'Event 201 record 42'
        $capture.Payload.body | Should -Not -Match 'filesystem-permission|CRC'
    }

    It 'rejects <Label> logs as evidence for this task completion' -ForEach @(
        @{ Label = 'dry-run'; Overrides = @{ DryRun = $true } }
        @{ Label = 'different exit code'; Overrides = @{ ExitCode = 24 } }
        @{ Label = 'old start'; Overrides = @{ StartedAt = '2026-07-16T11:58:00Z' } }
        @{ Label = 'future finish'; Overrides = @{ FinishedAt = '2026-07-16T12:00:01Z' } }
        @{ Label = 'unfinished'; Overrides = @{ Status = 'Running'; FinishedAt = $null } }
    ) {
        $directory = New-FakeSyncRun -Root $syncLogDirectory -Overrides $Overrides `
            -Stderr 'rsync: opendir "/wrong/run" failed: Permission denied (13)'

        & $notifierPath @notifyParameters

        $capture.Payload.body | Should -Match 'No uniquely correlated wrapper run is available'
        $capture.Payload.body | Should -Not -Match '/wrong/run|filesystem-permission'
        $capture.Payload.body | Should -Not -Match ([regex]::Escape($directory))
    }

    It 'does not attach ambiguous candidates or a different task instance' {
        New-FakeSyncRun -Root $syncLogDirectory -Stderr 'rsync: opendir "/first" failed: Permission denied (13)' | Out-Null
        New-FakeSyncRun -Root $syncLogDirectory -Stderr 'rsync: opendir "/second" failed: Permission denied (13)' | Out-Null

        & $notifierPath @notifyParameters

        $capture.Payload.body | Should -Not -Match '/first|/second|filesystem-permission'
        $start.TaskInstanceId = '{87654321-1234-1234-1234-123456789012}'
        Remove-Item -LiteralPath (Join-Path $storageDirectory 'github_reposync_apprise_notify.processed-events.json')

        & $notifierPath @notifyParameters

        $capture.Payload.body | Should -Match 'No uniquely correlated wrapper run is available'
    }

    It 'ignores malformed and oversized summaries without losing valid evidence' {
        $malformed = Join-Path $syncLogDirectory 'malformed'
        $oversized = Join-Path $syncLogDirectory 'oversized'
        New-Item -ItemType Directory -Path $malformed, $oversized -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $malformed 'run.json') -Value '{bad-json'
        Set-Content -LiteralPath (Join-Path $oversized 'run.json') -Value ('x' * 65537)
        New-FakeSyncRun -Root $syncLogDirectory -Stderr 'rsync: mkdir "/full/disk" failed: No space left on device (28)' | Out-Null

        & $notifierPath @notifyParameters

        $capture.Payload.body | Should -Match 'Failure class: filesystem-space'
        $capture.Payload.body | Should -Match '/full/disk'
    }

    It 'bounds diagnostics and omits raw output, sensitive values, and control characters' {
        $stderr = ('raw output token=never-send-this' + "`n") * 2000
        $stderr += 'rsync: mkstemp "password=do-not-send" failed: Permission denied (13)' + "`n"
        $stderr += 'rsync: mkdir "/safe' + [char]1 + 'path" failed: No space left on device (28)'
        New-FakeSyncRun -Root $syncLogDirectory -Stderr $stderr | Out-Null

        & $notifierPath @notifyParameters

        $capture.Payload.title.Length | Should -BeLessOrEqual 256
        $capture.Payload.body.Length | Should -BeLessOrEqual 2048
        $capture.Payload.body | Should -Not -Match 'never-send-this|do-not-send|raw output|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'
        $capture.Payload.body | Should -Match '\[sensitive detail omitted\]|/safe path'
        $capture.Payload.body | Should -Match 'Next step'
    }

    It 'reports a wrapper exception through its evidence pointer without publishing the exception' {
        $completion.ResultCode = '1'
        New-FakeSyncRun -Root $syncLogDirectory -Overrides @{
            Status = 'WrapperFailed'; ExitCode = 1; Error = 'token=private-value'
        } | Out-Null

        & $notifierPath @notifyParameters

        $capture.Payload.body | Should -Match 'Failure class: wrapper-failed'
        $capture.Payload.body | Should -Match 'run.json'
        $capture.Payload.body | Should -Not -Match 'private-value'
    }

    It 'omits sensitive log-directory names from evidence and first-check fields' {
        $notifyParameters.SyncLogDirectory = Join-Path $storageDirectory 'token=private-directory'
        New-FakeSyncRun -Root $notifyParameters.SyncLogDirectory -Stderr (
            'rsync: opendir "/safe/path" failed: Permission denied (13)'
        ) | Out-Null

        & $notifierPath @notifyParameters

        $capture.Payload.body | Should -Not -Match 'private-directory'
        $capture.Payload.body | Should -Match 'Evidence: \[sensitive detail omitted\]'
    }

    It 'uses the standard success title without claiming recovery' {
        $completion.ResultCode = '0'

        & $notifierPath @notifyParameters

        $capture.Payload.title | Should -Be '✅ [Replication] success on sync-node'
        $capture.Payload.type | Should -Be 'success'
        $capture.Payload.format | Should -Be 'text'
        $capture.Payload.body | Should -Not -Match 'recovery|Failure class|HA and network'
    }
}

Describe 'WSL GitHub repository sync task template' {
    It 'uses the logging wrapper with explicit WSL identity and destination' {
        $templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) `
            'WSL GitHub Repo Sync.template.xml'
        [xml]$taskXml = Get-Content -LiteralPath $templatePath -Raw
        $arguments = [string]$taskXml.Task.Actions.Exec.Arguments
        $expectedArguments = '-NoProfile -NonInteractive -WindowStyle Hidden ' +
            '-File "C:\Scripts\github_reposync_logged.ps1" ' +
            '-Distribution "WSL_DISTRIBUTION" -WslUsername "WSL_USERNAME" ' +
            '-Destination "/mnt/c/Users/WINDOWS_USERNAME/Documents/GitHub/"'

        Assert-Condition ($taskXml.Task.Actions.Exec.Command -ceq 'pwsh.exe') (
            'The sync task does not launch the PowerShell logging wrapper.'
        )

        Assert-Condition ($arguments -ceq $expectedArguments) (
            'The sync task arguments differ from the documented safe contract.'
        )

    }
}

Describe 'README manual notification test safety' {
    BeforeAll {
        $readmePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'README.md'
        $readmeContent = Get-Content -LiteralPath $readmePath -Raw
    }

    It 'requires the scheduled action to match the preflight contract' {
        Assert-Condition (
            $readmeContent.Contains(
                '$syncArguments -cne $expectedSyncArguments'
            )
        ) 'The manual test does not compare the complete sync arguments.'
        Assert-Condition (
            $readmeContent.Contains(
                '$syncExecutable -notin @(''pwsh'', ''pwsh.exe'')'
            )
        ) 'The manual test does not validate the sync executable.'
    }

    It 'requires a fresh task start before accepting its completion event' {
        Assert-Condition (
            $readmeContent.Contains(
                '[string]$syncTask.State -eq ''Running'''
            )
        ) 'The manual test does not reject an already-running sync task.'
        Assert-Condition (
            $readmeContent.Contains(
                '$startEvent.RecordId -gt $beforeRecordId'
            )
        ) 'The manual test does not require a new Event 100 start record.'
        Assert-Condition (
            $readmeContent.Contains(
                '$completionEvent.RecordId -gt $startEvent.RecordId'
            )
        ) 'The manual test does not correlate completion after the fresh start.'
    }
}
