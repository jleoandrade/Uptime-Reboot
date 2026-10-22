<#
.SYNOPSIS
    SCCM Application "Uptime Reboot" - install program (Script Installer deployment type).
    Variant: Lab - 1 hour with user message

.DESCRIPTION
    Runs as SYSTEM when the detection method reports the application as NOT detected
    (uptime at or above the threshold). It re-validates the uptime and only RETURNS an exit code.
    It never restarts the computer: notification, countdown and restart belong to the SCCM client.

    When $ShowUserMessage is $true and the restart is required, the script also shows an informational
    message box in every ACTIVE user session (Windows API WTSSendMessage, called from PowerShell).
    The message does not wait for the user and never changes the exit code: if it cannot be shown,
    the failure is only logged.

    Exit codes (must match the Return Codes tab of the deployment type):
        0      Success (no reboot)  Uptime is below the threshold on re-validation. Nothing to do.
        17010  Soft Reboot          Uptime is at or above the threshold. SCCM schedules the restart.
        17001  Failure (no reboot)  Uptime could not be determined. Fail-safe: no restart requested.
        17002  Failure (no reboot)  Invalid configuration or unexpected error. Fail-safe: no restart requested.

    Idempotent: the script only reads WMI, appends to its own log and (optionally) shows a message.
    Running it any number of times changes nothing on the computer.

    Log: C:\ProgramData\Corporate\UptimeReboot\UptimeReboot.log (CMTrace format, rotated at 2 MB).

.PARAMETER ThresholdMinutes
    Maximum allowed uptime in minutes. Default for this variant: 60.
    MUST be the same value as $ThresholdMinutes in the detection method.

.NOTES
    Version 2.0
    - 1.0  Initial version.
    - 1.1  Literal log path and trap: exit code 1 always means the script never started.
    - 2.0  Optional user message (WTSSendMessage) and one code base for the three variants
           (Production 7 days, Production 7 days with message, Lab 1 hour with message).
           The variants differ ONLY in the "Variant configuration" block below.

.EXAMPLE
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install-UptimeReboot.ps1 -ThresholdMinutes 60
#>

[CmdletBinding()]
param(
    [int]$ThresholdMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Safety net: any terminating error outside the try/catch below returns 17002 (failure, no reboot) instead of
# PowerShell's generic exit code 1. With this trap, exit code 1 can only mean "PowerShell could not start the script".
trap {
    # Logs the real error when Write-Log already exists; never lets a logging failure change the exit code
    try { Write-Log "Unexpected error outside try/catch (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message). Fail-safe: no restart requested." -Severity Error } catch { }
    exit 17002
}

# ------------------------------------------------------------------------------------------------
# Variant configuration (the ONLY block that differs between the three variants)
# ------------------------------------------------------------------------------------------------
$VariantName     = 'Lab - 1 hour with user message'
$ShowUserMessage = $true
$MessageTitle    = 'Automatic workstation restart'
$MessageLines    = @(
    'For security reasons, computers that have been on for more than 1 hour are restarted automatically. You will receive Software Center notifications 10 minutes in advance.',
    '',
    'Important: the "Snooze" option only hides the notification temporarily; it does not postpone the restart. The exact time is shown in the "Your computer is about to restart" window. Save your work before that time, or restart when convenient using the Restart button.'
)

# ------------------------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------------------------
$ExitNoAction        = 0        # Success (no reboot)
$ExitRebootRequired  = 17010    # Soft Reboot
$ExitUptimeUnknown   = 17001    # Failure (no reboot)
$ExitUnexpectedError = 17002    # Failure (no reboot)

$MinThresholdMinutes = 15       # Lower bound: protects against a typo such as -ThresholdMinutes 1
$MaxThresholdMinutes = 43200    # Upper bound: 30 days
$MaxUptimeMinutes    = 5256000  # Sanity limit: 10 years. Anything above is treated as invalid data.
$WmiAttempts         = 3        # WMI read attempts before giving up (fail-safe)
$WmiRetrySeconds     = 5

$LogDirectory   = 'C:\ProgramData\Corporate\UptimeReboot'
$LogFile        = 'C:\ProgramData\Corporate\UptimeReboot\UptimeReboot.log'   # Literal path: no cmdlet runs outside try/catch
$LogMaxBytes    = 2MB
$LogComponent   = 'Install'

# ------------------------------------------------------------------------------------------------
# Logging (CMTrace format). Logging must NEVER break the script: every failure is swallowed.
# ------------------------------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Severity = 'Info'
    )
    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            [void](New-Item -Path $LogDirectory -ItemType Directory -Force)
        }

        # Rotate: keep one previous file (.lo_), like the SCCM client logs
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -ge $LogMaxBytes)) {
            Move-Item -LiteralPath $LogFile -Destination ([IO.Path]::ChangeExtension($LogFile, '.lo_')) -Force
        }

        $type = @{ Info = 1; Warning = 2; Error = 3 }[$Severity]
        $now = Get-Date
        $bias = -[int][TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
        $line = '<![LOG[{0}]LOG]!><time="{1}{2:+0;-0;+0}" date="{3}" component="{4}" context="{5}" type="{6}" thread="{7}" file="">' -f
            $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'),
            $LogComponent, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $type, $PID

        [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    }
    catch {
        # Intentionally ignored: a log failure must not change the result of the script
    }
}

# ------------------------------------------------------------------------------------------------
# Uptime from Win32_OperatingSystem. Returns an object; Success = $false means "unknown".
# LocalDateTime and LastBootUpTime come from the same WMI instance, so both use the same clock.
# ------------------------------------------------------------------------------------------------
function Get-SystemUptime {
    param([int]$Attempts = 1, [int]$RetrySeconds = 0)

    $reason = 'Not evaluated'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $lastBoot = $os.LastBootUpTime
            $now = $os.LocalDateTime

            if (-not ($lastBoot -is [datetime]) -or -not ($now -is [datetime])) {
                throw 'LastBootUpTime or LocalDateTime is empty or not a date'
            }

            $minutes = ($now - $lastBoot).TotalMinutes
            if ($minutes -lt 0) { throw "LastBootUpTime ($lastBoot) is later than the current time ($now)" }
            if ($minutes -gt $MaxUptimeMinutes) { throw "Uptime of $([math]::Round($minutes)) minutes is above the sanity limit" }

            return [pscustomobject]@{
                Success        = $true
                UptimeMinutes  = [math]::Round($minutes, 1)
                LastBootUpTime = $lastBoot
                Reason         = $null
            }
        }
        catch {
            $reason = $_.Exception.Message
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds $RetrySeconds }
        }
    }

    return [pscustomobject]@{ Success = $false; UptimeMinutes = $null; LastBootUpTime = $null; Reason = $reason }
}

# ------------------------------------------------------------------------------------------------
# User message. Shows an informational message box in every ACTIVE user session through the
# Windows API WTSSendMessage. It does not wait for the user (no timer, no blocking) and it NEVER
# throws: any failure is logged and the exit code is not affected.
# ------------------------------------------------------------------------------------------------
function Send-UserMessage {
    param([string]$Title, [string]$Text)
    try {
        if (-not ('UptimeReboot.SessionMessage' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace UptimeReboot
{
    public static class SessionMessage
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WTS_SESSION_INFO
        {
            public int SessionId;
            public string WinStationName;
            public int State;
        }

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr sessionInfo, out int count);

        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr memory);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WTSSendMessageW(IntPtr server, int sessionId, string title, int titleLength,
            string message, int messageLength, int style, int timeout, out int response, bool wait);

        private const int WtsActive = 0;
        private const int MessageStyle = 0x00000040 | 0x00040000;   // MB_OK | MB_ICONINFORMATION | MB_TOPMOST

        // Returns one line per active session: "<session id>:<sent|failed (error)>"
        public static string[] SendToActiveSessions(string title, string message)
        {
            List<string> results = new List<string>();
            IntPtr buffer;
            int count;
            if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out buffer, out count))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            try
            {
                int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                for (int i = 0; i < count; i++)
                {
                    WTS_SESSION_INFO info = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(buffer.ToInt64() + i * size), typeof(WTS_SESSION_INFO));
                    if (info.SessionId == 0 || info.State != WtsActive) { continue; }
                    int response;
                    bool sent = WTSSendMessageW(IntPtr.Zero, info.SessionId, title, title.Length * 2,
                        message, message.Length * 2, MessageStyle, 0, out response, false);
                    results.Add(info.SessionId + ":" + (sent ? "sent" : "failed (" + Marshal.GetLastWin32Error() + ")"));
                }
            }
            finally
            {
                WTSFreeMemory(buffer);
            }
            return results.ToArray();
        }
    }
}
'@
        }

        $results = @([UptimeReboot.SessionMessage]::SendToActiveSessions($Title, $Text))
        if ($results.Count -eq 0) {
            Write-Log 'User message: no active user session, nothing to show (the SCCM client restarts without countdown when nobody is logged on).'
        }
        else {
            Write-Log "User message: $($results -join ', ')."
        }
    }
    catch {
        Write-Log "User message could not be shown: $($_.Exception.Message). The restart notification of the SCCM client is not affected." -Severity Warning
    }
}

# ------------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------------
$exitCode = $ExitUnexpectedError
try {
    Write-Log "===== Install started. Variant=$VariantName, ThresholdMinutes=$ThresholdMinutes, ShowUserMessage=$ShowUserMessage, PowerShell=$($PSVersionTable.PSVersion), 64-bit process=$([Environment]::Is64BitProcess) ====="

    if ($ThresholdMinutes -lt $MinThresholdMinutes -or $ThresholdMinutes -gt $MaxThresholdMinutes) {
        Write-Log "ThresholdMinutes must be between $MinThresholdMinutes and $MaxThresholdMinutes. No restart requested." -Severity Error
        $exitCode = $ExitUnexpectedError
    }
    else {
        $uptime = Get-SystemUptime -Attempts $WmiAttempts -RetrySeconds $WmiRetrySeconds

        if (-not $uptime.Success) {
            Write-Log "Uptime could not be determined after $WmiAttempts attempt(s): $($uptime.Reason). Fail-safe: no restart requested." -Severity Error
            $exitCode = $ExitUptimeUnknown
        }
        elseif ($uptime.UptimeMinutes -lt $ThresholdMinutes) {
            Write-Log "Uptime $($uptime.UptimeMinutes) min (last boot $($uptime.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))) is below $ThresholdMinutes min. No restart requested."
            $exitCode = $ExitNoAction
        }
        else {
            Write-Log "Uptime $($uptime.UptimeMinutes) min (last boot $($uptime.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))) is at or above $ThresholdMinutes min. Returning $ExitRebootRequired (Soft Reboot): the SCCM client handles notification, countdown and restart." -Severity Warning
            $exitCode = $ExitRebootRequired
            if ($ShowUserMessage) {
                Send-UserMessage -Title $MessageTitle -Text ($MessageLines -join "`r`n")
            }
        }
    }
}
catch {
    Write-Log "Unexpected error: $($_.Exception.Message). Fail-safe: no restart requested." -Severity Error
    $exitCode = $ExitUnexpectedError
}

Write-Log "===== Install finished with exit code $exitCode ====="
exit $exitCode
