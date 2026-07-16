# WSL GitHub Repo Sync Task Scheduler and Notification Setup

This document describes two Windows Task Scheduler tasks:

- `\WSL GitHub Repo Sync`: syncs repos from WSL Ubuntu to
  `C:\Users\WINDOWS_USERNAME\Documents\GitHub`.
- `\WSL2.reposync.apprise.notification`: watches the sync task and sends an Apprise notification when the sync action completes.

The notification task depends on the `Microsoft-Windows-TaskScheduler/Operational` event log. If that log is disabled, the sync task can run normally but the notification task will not trigger.

## Configure the templates

Copy the two `*.template.xml` files and replace these values before importing
them in Task Scheduler:

| Placeholder | Replace with |
| --- | --- |
| `WINDOWS_DOMAIN` | Windows computer or domain name |
| `WINDOWS_USERNAME` | Windows account name |
| `WINDOWS_USER_SID` | SID returned by `whoami /user` |
| `WSL_USERNAME` | Linux username inside WSL |

The notification script also requires its Apprise endpoint. Pass it with
`-AppriseUrl`, for example:

```powershell
pwsh.exe -NoProfile `
    -File "C:\Scripts\github_reposync_apprise_notify.ps1" `
    -AppriseUrl "http://APPRISE_HOST:8000/notify/apprise" `
    -EventRecordId EVENT_RECORD_ID
```

## Paths

| Item | Path |
| --- | --- |
| Sync task export | `WSL GitHub Repo Sync.template.xml` |
| Notification task export | `WSL2.reposync.apprise.notification.template.xml` |
| Notification script | `C:\Scripts\github_reposync_apprise_notify.ps1` |
| Notification log | `C:\Scripts\github_reposync_apprise_notify.log` |
| Notification state | `C:\Scripts\github_reposync_apprise_notify.processed-events.json` |
| WSL source | `\\wsl.localhost\Ubuntu\home\WSL_USERNAME\code` |
| Windows destination | `C:\Users\WINDOWS_USERNAME\Documents\GitHub` |
| Apprise endpoint | `http://APPRISE_HOST:8000/notify/apprise` |

## Required Prerequisites

Run these from an elevated PowerShell session.

PowerShell 7 is required because the notifier validates the Apprise HTTP
status with `Invoke-RestMethod -StatusCodeVariable`. Confirm `pwsh.exe` is
available:

```powershell
pwsh.exe --version
```

Enable Task Scheduler history:

```powershell
wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
```

Confirm it is enabled:

```powershell
wevtutil gl Microsoft-Windows-TaskScheduler/Operational
```

Expected output includes:

```text
enabled: true
```

Confirm the log is actively writing records:

```powershell
Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' |
    Select-Object LogName, IsEnabled, RecordCount, LastWriteTime
```

Before importing either task, sign in as
`WINDOWS_DOMAIN\WINDOWS_USERNAME` and validate the exact distribution, Linux
identity, source directory, and `rsync` command that the task will use:

```powershell
wsl.exe --list --verbose

$wslIdentity = (wsl.exe -d Ubuntu -u WSL_USERNAME -- whoami | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "WSL identity check failed with exit code $LASTEXITCODE."
}
if ($wslIdentity -ne 'WSL_USERNAME') {
    throw "Expected WSL user 'WSL_USERNAME', but whoami returned '$wslIdentity'."
}

wsl.exe -d Ubuntu -u WSL_USERNAME -- rsync --version
if ($LASTEXITCODE -ne 0) {
    throw "rsync availability check failed with exit code $LASTEXITCODE."
}

wsl.exe -d Ubuntu -u WSL_USERNAME -- test -d /home/WSL_USERNAME/code/
if ($LASTEXITCODE -ne 0) {
    throw 'The WSL source directory /home/WSL_USERNAME/code/ does not exist.'
}

New-Item -ItemType Directory -Force `
    -Path 'C:\Users\WINDOWS_USERNAME\Documents\GitHub' | Out-Null

wsl.exe -d Ubuntu -u WSL_USERNAME -- rsync -avz --delete `
    /home/WSL_USERNAME/code/ `
    '/mnt/c/Users/WINDOWS_USERNAME/Documents/GitHub/'

if ($LASTEXITCODE -ne 0) {
    throw "WSL repository preflight failed with exit code $LASTEXITCODE."
}
```

Do not import the task until `whoami` prints `WSL_USERNAME`, `rsync --version`
succeeds, the source-directory check returns exit code `0`, and the exact sync
command completes successfully.

## Task 1: WSL GitHub Repo Sync

### Sync purpose

Runs `rsync` inside WSL to mirror `~/code/` into the Windows GitHub folder.

### Schedule

- Trigger type: Daily calendar trigger
- Start time: `4:00 AM`
- Start date: `2026-07-02`
- Repeat: every 1 day
- Starts when available: enabled
- Run level: highest available
- Logon type: interactive token

### Sync action

Program:

```text
wsl.exe
```

Arguments:

```text
-d Ubuntu -u WSL_USERNAME -- rsync -avz --delete /home/WSL_USERNAME/code/ "/mnt/c/Users/WINDOWS_USERNAME/Documents/GitHub/"
```

Notes:

- `--delete` removes destination files that no longer exist in the WSL source.
- The trailing slash on `~/code/` means "sync the contents of `code`" rather than creating a nested `code` directory at the destination.
- Task Scheduler reports the action result in Event ID `201`.

### Sync XML template

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2026-07-01T17:04:20.6063066</Date>
    <Author>WINDOWS_DOMAIN\WINDOWS_USERNAME</Author>
    <Description>Syncs WSL repositories to the Windows Documents folder.</Description>
    <URI>\WSL GitHub Repo Sync</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-07-02T04:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>WINDOWS_USER_SID</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wsl.exe</Command>
      <Arguments>-d Ubuntu -u WSL_USERNAME -- rsync -avz --delete /home/WSL_USERNAME/code/ "/mnt/c/Users/WINDOWS_USERNAME/Documents/GitHub/"</Arguments>
    </Exec>
  </Actions>
</Task>
```

## Task 2: WSL2 Repo Sync Apprise Notification

### Notification purpose

Runs a PowerShell script when the sync task completes. The event trigger passes
the unique Event 201 record ID to the script. The script loads only that record,
extracts its action `ResultCode`, suppresses duplicate retries, and posts a
notification to Apprise.

### Recommended Event Trigger

Use this custom event filter. Event ID `201` is preferred because it includes the action result code. Task Scheduler may not display the custom XML clearly in every exported or summary view, so keep this filter documented here as the source of truth for the notification trigger.

```xml
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-TaskScheduler/Operational">
    <Select Path="Microsoft-Windows-TaskScheduler/Operational">
      *[System[(EventID=201)]]
      and
      *[EventData[Data[@Name='TaskName']='\WSL GitHub Repo Sync']]
    </Select>
  </Query>
</QueryList>
```

The event trigger also maps `Event/System/EventRecordID` to the
`EventRecordId` action argument. It does not include the `ResultCode`; the
script reads that value from the correlated Event 201 record.

### Settings

- Run level: highest available
- Logon type: interactive token
- Allow task to be run on demand: enabled
- If already running: queue a new instance
- Stop the task if it runs longer than: `1 hour`
- Force stop if it does not end when requested: enabled
- Restart on failure: every `1 minute`, up to `3` attempts
- Wake the computer to run this task: disabled
- Run task as soon as possible after missed start: disabled

### Notification action

Program:

```text
pwsh.exe
```

Arguments:

```text
-NoProfile -WindowStyle Hidden -File "C:\Scripts\github_reposync_apprise_notify.ps1" -AppriseUrl "http://APPRISE_HOST:8000/notify/apprise" -EventRecordId "$(EventRecordId)"
```

### Notification Script

Save as:

```text
C:\Scripts\github_reposync_apprise_notify.ps1
```

```powershell
param(
    [string]$AppriseUrl = 'http://APPRISE_HOST:8000/notify/apprise',
    [Parameter(Mandatory)]
    [ValidateRange(1, 9223372036854775807)]
    [long]$EventRecordId,
    [ValidateNotNullOrEmpty()]
    [string]$StorageDirectory = 'C:\Scripts',
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

    if ([string]$rawResultCode -eq '0') {
        $Type = 'success'
        $Title = "Task Success: $TaskName"
        $Body = "The repo sync action completed successfully. Exit Code: $ResultCode"
    } else {
        $Type = 'failure'
        $Title = "Task FAILURE: $TaskName"
        $Body = "The repo sync action completed with a non-zero exit code. Exit Code: $ResultCode"
    }

    $Payload = @{
        title = $Title
        body  = $Body
        type  = $Type
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
```

### Notification XML template

This XML reflects the exported notification task. The `Subscription` value is XML-escaped in the task export, but it represents the custom Event ID `201` filter shown above.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2026-07-14T10:35:05.7009268</Date>
    <Author>WINDOWS_DOMAIN\WINDOWS_USERNAME</Author>
    <Description>Sends a notification to the local LAN Apprise-API instance for the 'WSL GitHub Repo Sync' task.</Description>
    <URI>\WSL2.reposync.apprise.notification</URI>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-TaskScheduler/Operational"&gt;&lt;Select Path="Microsoft-Windows-TaskScheduler/Operational"&gt;
      *[System[(EventID=201)]]
      and
      *[EventData[Data[@Name='TaskName']='\WSL GitHub Repo Sync']]
    &lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <ValueQueries>
        <Value name="EventRecordId">Event/System/EventRecordID</Value>
      </ValueQueries>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>WINDOWS_USER_SID</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>pwsh.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -File "C:\Scripts\github_reposync_apprise_notify.ps1" -AppriseUrl "http://APPRISE_HOST:8000/notify/apprise" -EventRecordId "$(EventRecordId)"</Arguments>
    </Exec>
  </Actions>
</Task>
```

## Validation

Run the notification-flow regression suite on Windows with Pester:

```powershell
Invoke-Pester -Path '.\tests\GithubRepoSyncNotify.Tests.ps1' -CI
```

The suite covers exact event correlation, missing events, duplicate replay,
malformed state, Apprise exceptions and non-200 responses, successful logging,
and state persistence without contacting a live Apprise service.

### Check Registered Tasks

```powershell
schtasks /Query /TN "\WSL GitHub Repo Sync" /V /FO LIST
schtasks /Query /TN "\WSL2.reposync.apprise.notification" /V /FO LIST
```

Look for:

- `Scheduled Task State: Enabled`
- `Last Result: 0`
- Sync task `Next Run Time`
- Notification task `Schedule Type: When an event occurs`

### Check Recent Sync Events

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 200 |
    Where-Object { $_.Message -like '*WSL GitHub Repo Sync*' } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```

The important event is:

- `201`: action completed; includes `ResultCode`

Useful related events:

- `100`: task started
- `102`: task instance finished
- `103`: task failed
- `200`: action started

### Check the Notifier Log

```powershell
Get-Content -LiteralPath 'C:\Scripts\github_reposync_apprise_notify.log' -Tail 50
```

Expected success line:

```text
Sent success notification for EventID=201 EventRecordId=<record-id> ResultCode=0.
```

Expected failure line:

```text
Sent failure notification for EventID=201 EventRecordId=<record-id> ResultCode=<nonzero-code>.
```

### Test Apprise Connectivity

```powershell
Test-NetConnection -ComputerName APPRISE_HOST -Port 8000
```

Expected:

```text
TcpTestSucceeded : True
```

### Test the Notification Script Manually

Temporarily disable the automatic notification task, record the current Event
201 boundary, run the sync task, and wait for a newer matching record. This
prevents the manual notifier from reading a previous sync run:

```powershell
$logName = 'Microsoft-Windows-TaskScheduler/Operational'
$syncTaskName = 'WSL GitHub Repo Sync'
$syncEventTaskName = '\WSL GitHub Repo Sync'
$notificationTaskName = 'WSL2.reposync.apprise.notification'
$eventXPath = "*[System[(EventID=201)]] and *[EventData[Data[@Name='TaskName']='$syncEventTaskName']]"

Disable-ScheduledTask -TaskName $notificationTaskName | Out-Null

try {
    $previousEvent = Get-WinEvent -LogName $logName -FilterXPath $eventXPath `
        -MaxEvents 1 -ErrorAction SilentlyContinue
    $beforeRecordId = if ($previousEvent) { $previousEvent.RecordId } else { 0 }

    Start-ScheduledTask -TaskName $syncTaskName
    $deadline = (Get-Date).AddMinutes(10)

    do {
        Start-Sleep -Seconds 2
        $event = Get-WinEvent -LogName $logName -FilterXPath $eventXPath `
            -MaxEvents 1 -ErrorAction SilentlyContinue
        if ((Get-Date) -gt $deadline) {
            throw 'Timed out waiting for a new Event 201 from the sync task.'
        }
    } until ($event -and $event.RecordId -gt $beforeRecordId)

    pwsh.exe -NoProfile `
        -File 'C:\Scripts\github_reposync_apprise_notify.ps1' `
        -AppriseUrl 'http://APPRISE_HOST:8000/notify/apprise' `
        -EventRecordId $event.RecordId
}
finally {
    Enable-ScheduledTask -TaskName $notificationTaskName | Out-Null
}
```

Check the Apprise notification and the script log.

## Troubleshooting

### Notification Task Does Not Fire

Confirm Task Scheduler history is enabled:

```powershell
wevtutil gl Microsoft-Windows-TaskScheduler/Operational
```

If `enabled: false`, run:

```powershell
wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
```

Then confirm new events are being written:

```powershell
wevtutil qe Microsoft-Windows-TaskScheduler/Operational /c:5 /rd:true /f:text
```

### Notification Task Runs but No Notification Arrives

Check the notifier log:

```powershell
Get-Content -LiteralPath 'C:\Scripts\github_reposync_apprise_notify.log' -Tail 50
```

Check Apprise connectivity:

```powershell
Test-NetConnection -ComputerName APPRISE_HOST -Port 8000
```

If the script reports that an event record was not found, verify the
`ValueQueries` mapping and the `-EventRecordId "$(EventRecordId)"` action
argument in the imported notification task.

### Sync Task Shows Success but Did Not Actually Sync

Check Event ID `201` for the real action `ResultCode`:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 200 |
    Where-Object { $_.Id -eq 201 -and $_.Message -like '*WSL GitHub Repo Sync*' } |
    Select-Object TimeCreated, Message |
    Format-List
```

Common result:

```text
2147942487
```

This is `0x80070057`, often shown by Windows as an invalid parameter error. In that case, test the WSL command directly:

```powershell
wsl.exe -d Ubuntu -u WSL_USERNAME -- rsync -avz --delete `
    /home/WSL_USERNAME/code/ `
    '/mnt/c/Users/WINDOWS_USERNAME/Documents/GitHub/'
```

### Event Filter Is Missing

Update the notification task trigger to use Event ID `201`. This is the custom XML that should be configured on the Apprise task's **On an event** trigger:

```xml
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-TaskScheduler/Operational">
    <Select Path="Microsoft-Windows-TaskScheduler/Operational">
      *[System[(EventID=201)]]
      and
      *[EventData[Data[@Name='TaskName']='\WSL GitHub Repo Sync']]
    </Select>
  </Query>
</QueryList>
```

## Maintenance Notes

- Re-export both Task Scheduler XML files after changing task configuration.
- Keep `C:\Scripts\github_reposync_apprise_notify.ps1` backed up with the task XML exports.
- If the Apprise server IP changes, update `$AppriseUrl` in the PowerShell script.
- If the sync task name changes, update both the notification task event filter and `$TaskName` in the script.
- Keep the event trigger's `EventRecordId` value query and action argument in
  sync; they provide exact event correlation and retry deduplication.
- The notifier stores processed keys as `<record-id>|<UTC-event-ticks>`. Exact
  replays are suppressed, while a cleared Task Scheduler event log can safely
  reuse lower record IDs because the new event timestamp creates a new key.
- If the WSL distribution name or source path changes, test the `wsl rsync ...` command manually before relying on the scheduled task.
