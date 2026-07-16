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
