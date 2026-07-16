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
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File "C:\Scripts\github_reposync_apprise_notify.ps1" `
    -AppriseUrl "http://APPRISE_HOST:8000/notify/apprise"
```

## Paths

| Item | Path |
| --- | --- |
| Sync task export | `WSL GitHub Repo Sync.template.xml` |
| Notification task export | `WSL2.reposync.apprise.notification.template.xml` |
| Notification script | `C:\Scripts\github_reposync_apprise_notify.ps1` |
| Notification log | `C:\Scripts\github_reposync_apprise_notify.log` |
| WSL source | `\\wsl.localhost\Ubuntu\home\WSL_USERNAME\code` |
| Windows destination | `C:\Users\WINDOWS_USERNAME\Documents\GitHub` |
| Apprise endpoint | `http://APPRISE_HOST:8000/notify/apprise` |

## Required Prerequisites

Run these from an elevated PowerShell session.

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
wsl
```

Arguments:

```text
rsync -avz --delete ~/code/ /mnt/c/Users/WINDOWS_USERNAME/Documents/GitHub
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
      <Command>wsl</Command>
      <Arguments>rsync -avz --delete /home/WSL_USERNAME/code/ /mnt/c/Users/WINDOWS_USERNAME/Documents/GitHub</Arguments>
    </Exec>
  </Actions>
</Task>
```

## Task 2: WSL2 Repo Sync Apprise Notification

### Notification purpose

Runs a PowerShell script when the sync task completes. The script reads the recent Task Scheduler events for `\WSL GitHub Repo Sync`, prefers Event ID `201`, extracts the action `ResultCode`, and posts a notification to Apprise.

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

It does not include the `ResultCode`.

### Settings

- Run level: highest available
- Logon type: interactive token
- Allow task to be run on demand: enabled
- If already running: do not start a new instance
- Stop the task if it runs longer than: `1 hour`
- Force stop if it does not end when requested: enabled
- Restart on failure: every `1 minute`, up to `3` attempts
- Wake the computer to run this task: disabled
- Run task as soon as possible after missed start: disabled

### Notification action

Program:

```text
powershell.exe
```

Arguments:

```text
-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\github_reposync_apprise_notify.ps1" -AppriseUrl "http://APPRISE_HOST:8000/notify/apprise"
```

### Notification Script

Save as:

```text
C:\Scripts\github_reposync_apprise_notify.ps1
```

```powershell
param(
    [string]$AppriseUrl = 'http://APPRISE_HOST:8000/notify/apprise'
)

$ErrorActionPreference = 'Stop'

$TaskName = "\WSL GitHub Repo Sync"
$LogPath = "Microsoft-Windows-TaskScheduler/Operational"
$LogFile = "C:\Scripts\github_reposync_apprise_notify.log"
$LookbackMinutes = 10

if ($AppriseUrl -match 'APPRISE_HOST') {
    throw 'Set -AppriseUrl to your Apprise API endpoint before running this script.'
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
        [System.Diagnostics.Eventing.Reader.EventRecord]$Event,
        [string]$Name
    )

    $xml = [xml]$Event.ToXml()
    $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    return $node.'#text'
}

try {
    $startTime = (Get-Date).AddMinutes(-$LookbackMinutes)
    $events = Get-WinEvent -FilterHashtable @{ LogName = $LogPath; Id = 201, 102, 103; StartTime = $startTime } |
        Where-Object { Get-EventDataValue -Event $_ -Name 'TaskName' -eq $TaskName } |
        Sort-Object TimeCreated -Descending

    if (-not $events) {
        Write-NotifyLog "No matching Task Scheduler event found for $TaskName in the last $LookbackMinutes minutes."
        exit 1
    }

    # Prefer Event 201 because it is the action-completed record and contains ResultCode.
    # Event 102 only means the task instance finished and does not prove the action succeeded.
    $Event = $events | Where-Object { $_.Id -eq 201 } | Select-Object -First 1
    if (-not $Event) {
        $Event = $events | Select-Object -First 1
    }

    $EventID = $Event.Id
    $EventTime = $Event.TimeCreated
    $ResultCode = 'unknown'
    $Type = 'warning'
    $Title = "Task Status Unknown: $TaskName"
    $Body = "Latest event for $TaskName was Event ID $EventID at $EventTime. No result code was available."

    switch ($EventID) {
        201 {
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
        }
        102 {
            $Type = 'warning'
            $Title = "Task Finished: $TaskName"
            $Body = "The task instance finished at $EventTime, but Event ID 102 does not include the action exit code. Check Event ID 201 for the real result."
        }
        103 {
            $Type = 'failure'
            $Title = "Task Failed: $TaskName"
            $Body = "Task Scheduler reported failure Event ID 103 at $EventTime."
        }
        default {
            $Type = 'warning'
            $Title = "Unexpected Task Event: $TaskName"
            $Body = "Unexpected Event ID $EventID was returned for $TaskName at $EventTime. Notification sent as warning."
        }
    }

    $Payload = @{
        title = $Title
        body  = $Body
        type  = $Type
    }

    Invoke-RestMethod -Method Post -Uri $AppriseUrl -Body $Payload -TimeoutSec 15 | Out-Null
    Write-NotifyLog "Sent $Type notification for EventID=$EventID ResultCode=$ResultCode."
}
catch {
    Write-NotifyLog "ERROR: $($_.Exception.Message)"
    exit 1
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
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
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
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\github_reposync_apprise_notify.ps1" -AppriseUrl "http://APPRISE_HOST:8000/notify/apprise"</Arguments>
    </Exec>
  </Actions>
</Task>
```

## Validation

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
Sent success notification for EventID=201 ResultCode=0.
```

Expected failure line:

```text
Sent failure notification for EventID=201 ResultCode=<nonzero-code>.
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

Run the sync task first so there is a recent Task Scheduler event:

```powershell
schtasks /Run /TN "\WSL GitHub Repo Sync"
```

Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\github_reposync_apprise_notify.ps1" -AppriseUrl "http://APPRISE_HOST:8000/notify/apprise"
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

If the script reports no matching event, the notification task may be firing too late for the 10-minute lookback. Increase:

```powershell
$LookbackMinutes = 10
```

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
2147942423
```

This is `0x80070057`, often shown by Windows as an invalid parameter error. In that case, test the WSL command directly:

```powershell
wsl rsync -avz --delete ~/code/ /mnt/c/Users/aaron/Documents/GitHub
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
- If the WSL distribution name or source path changes, test the `wsl rsync ...` command manually before relying on the scheduled task.
