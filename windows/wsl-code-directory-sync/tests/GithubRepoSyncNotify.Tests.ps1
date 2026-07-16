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
        [datetime]$TimeCreated = [datetime]'2026-07-16T12:00:00Z'
    )

    $event = [pscustomobject]@{
        Id          = 201
        RecordId    = $RecordId
        TimeCreated = $TimeCreated
        TaskName    = $TaskName
        ResultCode  = $ResultCode
    }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value {
        $escapedTaskName = [Security.SecurityElement]::Escape($this.TaskName)
        $escapedResultCode = [Security.SecurityElement]::Escape($this.ResultCode)
        return @"
<Event>
  <EventData>
    <Data Name="TaskName">$escapedTaskName</Data>
    <Data Name="ResultCode">$escapedResultCode</Data>
  </EventData>
</Event>
"@
    }
    return $event
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
