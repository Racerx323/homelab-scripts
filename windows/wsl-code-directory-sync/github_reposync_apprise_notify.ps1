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
