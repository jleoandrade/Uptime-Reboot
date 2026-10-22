<#
.SYNOPSIS
    Validation tool for the "Uptime Reboot" lab. Runs on a lab computer. NOT part of the solution: never deploy it.

.DESCRIPTION
    -Mode Monitor (default)
        1. Shows the client state: uptime, application revision, deployment flags, restart settings and the
           Application Deployment Evaluation schedule (decoded: must be every 1 hour).
        2. With -RefreshPolicy: runs Machine Policy Retrieval (021) and Evaluation (022) and waits 3 minutes.
        3. Waits (polling every -PollSeconds) and prints every step of the cycle as it happens:
           detection -> install 17010 -> PendingSoftReboot -> mandatory restart scheduled (deadline) -> restart.
        It never triggers the application evaluation (121): the natural cycle is preserved.
        The computer restarts while the script is running; that is the expected end of this mode.

    -Mode Verify
        Run after the restart. Checks the evidence of the last restart and prints PASS/FAIL.

    Everything is read-only, except -RefreshPolicy (client policy refresh only).
    Output is saved in C:\ProgramData\Corporate\UptimeReboot\Validation (survives the restart).

.EXAMPLE
    .\Test-UptimeRebootClient.ps1 -RefreshPolicy
    First run after the client setting change: refreshes policy, shows the schedule and waits for the cycle.

.EXAMPLE
    .\Test-UptimeRebootClient.ps1 -Mode Verify
    After the restart: PASS/FAIL report.
#>

[CmdletBinding()]
param(
    [ValidateSet('Monitor', 'Verify')]
    [string]$Mode = 'Monitor',

    # Machine Policy Retrieval + Evaluation before monitoring (needed once after a client setting change)
    [switch]$RefreshPolicy,

    # Maximum time to wait in Monitor mode
    [int]$MaxWaitMinutes = 240,

    # Interval between log checks in Monitor mode
    [int]$PollSeconds = 60,

    [string]$LogRoot = 'C:\Windows\CCM\Logs',
    [string]$SolutionLog = 'C:\ProgramData\Corporate\UptimeReboot\UptimeReboot.log',
    [string]$OutputDirectory = 'C:\ProgramData\Corporate\UptimeReboot\Validation'
)

$ErrorActionPreference = 'Stop'
$EvaluationScheduleId = '{00000000-0000-0000-0000-000000000121}'
$Culture = [Globalization.CultureInfo]::InvariantCulture

# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------
function Write-Line([string]$Text) {
    Write-Host ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text)
}

function Get-LogEntry {
    # Reads CMTrace-format lines matching a pattern from one or more files (wildcards allowed)
    param([string]$Path, [string]$Pattern)
    foreach ($file in @(Get-ChildItem -Path $Path -ErrorAction SilentlyContinue)) {
        foreach ($match in @(Select-String -LiteralPath $file.FullName -Pattern $Pattern -ErrorAction SilentlyContinue)) {
            if ($match.Line -match '^<!\[LOG\[(.*)\]LOG\]!><time="(\d{1,2}:\d{2}:\d{2})\.\d+[^"]*" date="(\d{1,2}-\d{1,2}-\d{4})"') {
                [pscustomobject]@{
                    Time   = [datetime]::ParseExact("$($Matches[3]) $($Matches[2])", 'M-d-yyyy H:mm:ss', $Culture)
                    Text   = $Matches[1].Trim()
                    Source = $file.Name
                }
            }
        }
    }
}

function ConvertFrom-ScheduleToken([string]$Token) {
    # Decodes an SMS schedule token. Only the interval type (2) is decoded in detail.
    $value = [Convert]::ToUInt64($Token, 16)
    $type = ($value -shr 19) -band 0x7
    if ($type -ne 2) { return [pscustomobject]@{ Token = $Token; Type = $type; DaySpan = $null; HourSpan = $null; MinuteSpan = $null; Text = "schedule type $type (not a simple interval)" } }
    $days = [int](($value -shr 3) -band 0x1F)
    $hours = [int](($value -shr 8) -band 0x1F)
    $minutes = [int](($value -shr 13) -band 0x3F)
    [pscustomobject]@{ Token = $Token; Type = $type; DaySpan = $days; HourSpan = $hours; MinuteSpan = $minutes; Text = "every $days day(s) $hours hour(s) $minutes minute(s)" }
}

function Get-RebootDeadline([string]$Text) {
    # Rebootby is Unix time (UTC). 0 means non-mandatory (no deadline).
    if ($Text -match 'Rebootby = (\d+)') {
        $seconds = [int64]$Matches[1]
        if ($seconds -gt 0) { return [DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime }
        return 'none (Rebootby = 0, non-mandatory)'
    }
    $null
}

function Get-Uptime {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    [pscustomobject]@{ LastBoot = $os.LastBootUpTime; Minutes = [math]::Round(($os.LocalDateTime - $os.LastBootUpTime).TotalMinutes, 1) }
}

function Get-EvaluationSchedule {
    $token = $null
    $message = Get-CimInstance -Namespace root\ccm\Policy\Machine\ActualConfig -ClassName CCM_Scheduler_ScheduledMessage -ErrorAction SilentlyContinue |
        Where-Object { $_.ScheduledMessageID -eq $EvaluationScheduleId } | Select-Object -First 1
    if ($message -and (($message.Triggers -join ';') -match 'ScheduleString=([0-9A-Fa-f]{16})')) { $token = $Matches[1] }

    $nextFire = $null
    $fireEntry = Get-LogEntry -Path (Join-Path $LogRoot 'Scheduler*.lo*') -Pattern '000000000121.*will fire at' | Sort-Object Time | Select-Object -Last 1
    # Fallback: the token is also in the Scheduler.log line when the policy class cannot be read
    if (-not $token -and $fireEntry -and $fireEntry.Text -match "SMSTrigger '([0-9A-Fa-f]{16})'") { $token = $Matches[1] }
    if ($fireEntry -and $fireEntry.Text -match 'will fire at (.+?) with') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($Matches[1], @('M/d/yyyy h:mm:ss tt', 'M/d/yyyy H:mm:ss'), $Culture, 'None', [ref]$parsed)) { $nextFire = $parsed }
        else { $nextFire = $Matches[1] }
    }

    [pscustomobject]@{
        Decoded  = if ($token) { ConvertFrom-ScheduleToken $token } else { $null }
        NextFire = $nextFire
    }
}

function Show-ClientState {
    $uptime = Get-Uptime
    Write-Line ('Computer {0} | Last boot {1:yyyy-MM-dd HH:mm:ss} | Uptime {2} min' -f $env:COMPUTERNAME, $uptime.LastBoot, $uptime.Minutes)

    $application = Get-CimInstance -Namespace root\ccm\ClientSDK -ClassName CCM_Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*Uptime*' } | Select-Object -First 1
    if ($application) { Write-Line ('Application "{0}" | Revision {1} | InstallState {2}' -f $application.Name, $application.Revision, $application.InstallState) }
    else { Write-Line 'Application *Uptime* not found in the client (CCM_Application).' }

    $assignment = Get-CimInstance -Namespace root\ccm\Policy\Machine\ActualConfig -ClassName CCM_ApplicationCIAssignment -ErrorAction SilentlyContinue |
        Where-Object { $_.AssignmentName -like '*Uptime*' } | Select-Object -First 1
    if ($assignment) { Write-Line ('Deployment: OverrideServiceWindows={0} | RebootOutsideOfServiceWindows={1}' -f $assignment.OverrideServiceWindows, $assignment.RebootOutsideOfServiceWindows) }

    $reboot = Get-CimInstance -Namespace root\ccm\Policy\Machine\ActualConfig -ClassName CCM_RebootSettings -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($reboot) { Write-Line ('Restart settings: NoEnforcement={0} | RebootCountdown={1} s | FinalWindow={2} s | Dialog={3}' -f $reboot.NoEnforcement, $reboot.RebootCountdown, $reboot.RebootCountdownFinalWindow, $reboot.RebootNotificationsDialog) }

    $schedule = Get-EvaluationSchedule
    if ($schedule.Decoded) { Write-Line ('Application evaluation schedule: {0} ({1})' -f $schedule.Decoded.Text, $schedule.Decoded.Token) }
    else { Write-Line 'Application evaluation schedule: not found in policy.' }
    if ($schedule.NextFire) { Write-Line ('Next automatic application evaluation (Scheduler.log): {0}' -f $schedule.NextFire) }
    $schedule
}

# ------------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------------
[void](New-Item -Path $OutputDirectory -ItemType Directory -Force)
$transcript = Join-Path $OutputDirectory ('{0}-{1}-{2:yyyyMMdd-HHmmss}.log' -f $env:COMPUTERNAME, $Mode, (Get-Date))
Start-Transcript -Path $transcript -Force | Out-Null

try {
    if ($Mode -eq 'Monitor') {
        Write-Line '===== Uptime Reboot - Monitor mode (Ctrl+C to stop; nothing is changed on the computer)'
        $schedule = Show-ClientState

        if ($RefreshPolicy) {
            Write-Line 'Refreshing machine policy (021 + 022) and waiting 3 minutes...'
            [void](Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000021}' })
            [void](Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000022}' })
            Start-Sleep -Seconds 180
            $schedule = Show-ClientState
        }

        if ($schedule.Decoded -and -not ($schedule.Decoded.DaySpan -eq 0 -and $schedule.Decoded.HourSpan -eq 1)) {
            Write-Line 'WARNING: the evaluation schedule is NOT every 1 hour. The cycle will follow the schedule above.'
        }

        $since = (Get-Date).AddMinutes(-1)
        $stopAt = (Get-Date).AddMinutes($MaxWaitMinutes)
        $seen = @{}
        $lastStatus = Get-Date
        Write-Line ("Waiting for the cycle until {0:yyyy-MM-dd HH:mm} (checking every {1} s)..." -f $stopAt, $PollSeconds)

        while ((Get-Date) -lt $stopAt) {
            $entries = @(
                Get-LogEntry -Path $SolutionLog -Pattern '.'
                Get-LogEntry -Path (Join-Path $LogRoot 'AppEnforce*.lo*') -Pattern 'Matched exit code 17010|terminated with exitcode: 170'
                Get-LogEntry -Path (Join-Path $LogRoot 'RebootCoordinator*.lo*') -Pattern 'mandatory reboot|Scheduled reboot from agent|(CITaskMgr|DCMAgent).*Rebootby|Notified UI grace period|Reboot initiated'
                Get-LogEntry -Path (Join-Path $LogRoot 'Scheduler*.lo*') -Pattern '000000000121.*will fire at'
            ) | Where-Object { $_.Time -ge $since } | Sort-Object Time

            foreach ($entry in $entries) {
                $key = '{0}|{1:o}|{2}' -f $entry.Source, $entry.Time, $entry.Text
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $text = if ($entry.Text.Length -gt 220) { $entry.Text.Substring(0, 220) + '...' } else { $entry.Text }
                Write-Line ('{0,-24} {1:HH:mm:ss}  {2}' -f $entry.Source, $entry.Time, $text)
                $deadline = Get-RebootDeadline $entry.Text
                if ($deadline) { Write-Line ('>>> Restart deadline: {0}' -f $deadline) }
            }

            if (((Get-Date) - $lastStatus).TotalMinutes -ge 10) {
                $uptime = Get-Uptime
                Write-Line ('Still waiting. Uptime {0} min.' -f $uptime.Minutes)
                $lastStatus = Get-Date
            }
            Start-Sleep -Seconds $PollSeconds
        }
        Write-Line "Maximum wait reached ($MaxWaitMinutes min) without a restart. Check the schedule above."
    }
    else {
        Write-Line '===== Uptime Reboot - Verify mode (evidence of the last restart)'
        $schedule = Show-ClientState
        $lastBoot = (Get-Uptime).LastBoot
        $results = New-Object System.Collections.Generic.List[object]
        function Add-Result([string]$Check, [bool]$Passed, [string]$Evidence) {
            $results.Add([pscustomobject]@{ Check = $Check; Result = if ($Passed) { 'PASS' } else { 'FAIL' }; Evidence = $Evidence })
        }

        # 1. Evaluation schedule every 1 hour
        $hourly = [bool]($schedule.Decoded -and $schedule.Decoded.DaySpan -eq 0 -and $schedule.Decoded.HourSpan -eq 1)
        Add-Result 'Evaluation every 1 hour' $hourly ($(if ($schedule.Decoded) { $schedule.Decoded.Text } else { 'not found' }))

        # 2. Install returned 17010 before the restart
        $install = Get-LogEntry -Path $SolutionLog -Pattern 'Returning 17010' | Where-Object { $_.Time -lt $lastBoot } | Sort-Object Time | Select-Object -Last 1
        Add-Result 'Install returned 17010' ([bool]$install) ($(if ($install) { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f $install.Time, $install.Text } else { 'not found before the last boot' }))

        # 3. 17010 classified as Soft Reboot
        $matched = Get-LogEntry -Path (Join-Path $LogRoot 'AppEnforce*.lo*') -Pattern 'Matched exit code 17010' | Where-Object { $_.Time -lt $lastBoot } | Sort-Object Time | Select-Object -Last 1
        Add-Result '17010 = PendingSoftReboot' ([bool]($matched -and $matched.Text -match 'PendingSoftReboot')) ($(if ($matched) { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f $matched.Time, $matched.Text } else { 'not found' }))

        # 4. Mandatory restart scheduled: a restart request with a deadline (Rebootby > 0) after the 17010.
        #    CITaskMgr first logs a "non mandatory" request; the deployment (DCMAgent) then adds the deadline.
        $windowStart = if ($matched) { $matched.Time.AddMinutes(-1) } else { $lastBoot.AddDays(-1) }
        $requests = @(Get-LogEntry -Path (Join-Path $LogRoot 'RebootCoordinator*.lo*') -Pattern 'Rebootby = \d+' |
            Where-Object { $_.Time -ge $windowStart -and $_.Time -lt $lastBoot } | Sort-Object Time)
        $mandatory = $requests | Where-Object { $_.Text -match 'Rebootby = [1-9]' } | Select-Object -Last 1
        Add-Result 'Mandatory restart scheduled' ([bool]$mandatory) ($(if ($mandatory) { '{0:yyyy-MM-dd HH:mm:ss} restart deadline {1}' -f $mandatory.Time, (Get-RebootDeadline $mandatory.Text) } elseif ($requests) { 'only requests with Rebootby = 0 (non-mandatory)' } else { 'no restart request found' }))

        # 4b. Grace period shown to the user (informational)
        $grace = Get-LogEntry -Path (Join-Path $LogRoot 'RebootCoordinator*.lo*') -Pattern 'Notified UI grace period' |
            Where-Object { $_.Time -ge $windowStart -and $_.Time -lt $lastBoot } | Sort-Object Time | Select-Object -Last 1
        $results.Add([pscustomobject]@{ Check = 'Grace period sent to the user'; Result = 'INFO'; Evidence = $(if ($grace) { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f $grace.Time, $grace.Text } else { 'not found' }) })

        # 4c. Did the user click Restart in Software Center? (informational; explains a short warning time)
        $userRestart = Get-LogEntry -Path (Join-Path $LogRoot 'SCNotify*.lo*') -Pattern 'chose to restart|ButtonRestart|Initiating restart' |
            Where-Object { $_.Time -ge $windowStart -and $_.Time -lt $lastBoot } | Sort-Object Time | Select-Object -Last 1
        $results.Add([pscustomobject]@{ Check = 'User clicked Restart'; Result = 'INFO'; Evidence = $(if ($userRestart) { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f $userRestart.Time, $userRestart.Text } else { 'no evidence in SCNotify*.log' }) })

        # 5. Restart initiated by the SCCM client
        $restart = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074; StartTime = $lastBoot.AddDays(-1) } -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeCreated -le $lastBoot } | Sort-Object TimeCreated | Select-Object -Last 1
        $restartText = if ($restart) { ($restart.Message -split "`r?`n")[0] } else { '' }
        Add-Result 'Restart by CcmExec.exe' ($restartText -match 'CcmExec') ($(if ($restart) { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f $restart.TimeCreated, $restartText } else { 'event 1074 not found' }))

        # 6. Warning time between 17010 and the new boot (expected: 10 min of warning + shutdown/boot time).
        #    Event 1074 is NOT the restart moment: the client logs it when the final countdown starts and hands
        #    the restart to Windows with a timeout (the "You're about to be signed out" message).
        #    Without an active user session the client restarts right away (nobody to warn): then this check is INFO.
        if ($matched) {
            # User session state at the restart deadline (21 logon, 22 shell start, 23 logoff, 24 disconnected, 25 reconnected)
            $sessionState = 'unknown'
            $sessionEvidence = 'boot time before the 17010 not found in the install log line'
            if ($install -and $install.Text -match 'last boot (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $previousBoot = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $Culture)
                $checkpoint = if ($mandatory) { $mandatory.Time } else { $matched.Time }
                $lastSession = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21, 22, 23, 24, 25; StartTime = $previousBoot; EndTime = $checkpoint } -ErrorAction SilentlyContinue |
                    Sort-Object TimeCreated | Select-Object -Last 1
                if (-not $lastSession) { $sessionState = 'none'; $sessionEvidence = 'no user logon between the previous boot and the deadline' }
                else {
                    $sessionState = if ($lastSession.Id -in 21, 22, 25) { 'active' } else { 'not active' }
                    $sessionUser = (($lastSession.Message -split "`r?`n") -match 'User:') -join ' '
                    $sessionEvidence = '{0:yyyy-MM-dd HH:mm:ss} event {1} {2}' -f $lastSession.TimeCreated, $lastSession.Id, $sessionUser.Trim()
                }
            }
            $results.Add([pscustomobject]@{ Check = 'User session at the deadline'; Result = 'INFO'; Evidence = "$sessionState - $sessionEvidence" })

            $warningMinutes = [math]::Round(($lastBoot - $matched.Time).TotalMinutes, 1)
            $initiated = if ($restart) { [math]::Round(($restart.TimeCreated - $matched.Time).TotalMinutes, 1) } else { 'n/a' }
            $warningText = "$warningMinutes min between 17010 and the new boot (final countdown started after $initiated min)"
            if ($sessionState -eq 'none' -or $sessionState -eq 'not active') {
                $results.Add([pscustomobject]@{ Check = 'Warning time about 10 min'; Result = 'INFO'; Evidence = "$warningText. No active user session: immediate restart is the expected behavior." })
            }
            else {
                Add-Result 'Warning time about 10 min' ($warningMinutes -ge 9.5 -and $warningMinutes -le 16) $warningText
            }
        }

        # 7. No loop: first detection after the boot is DETECTED
        $afterBoot = Get-LogEntry -Path $SolutionLog -Pattern 'Result:' | Where-Object { $_.Time -ge $lastBoot } | Sort-Object Time | Select-Object -First 1
        Add-Result 'Detected after boot (no loop)' ([bool]($afterBoot -and $afterBoot.Text -match 'Result: DETECTED')) ($(if ($afterBoot) { '{0:yyyy-MM-dd HH:mm:ss} {1}' -f $afterBoot.Time, $afterBoot.Text } else { 'no detection yet after the boot: wait a few minutes and run again' }))

        $results | Format-Table -AutoSize -Wrap | Out-String -Width 400 | Write-Host
        $failed = @($results | Where-Object Result -eq 'FAIL').Count
        Write-Line ($(if ($failed -eq 0) { 'RESULT: ALL CHECKS PASSED' } else { "RESULT: $failed CHECK(S) FAILED" }))
    }
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Output saved to $transcript"
}
