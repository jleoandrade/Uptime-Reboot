<#
.SYNOPSIS
SCCM Application "Uptime Reboot" - install program (Script Installer deployment type).
.DESCRIPTION
Runs as SYSTEM when the detection method reports the application as NOT detected
(uptime at or above the threshold). It re-validates the uptime and only RETURNS an exit code.
It never restarts the computer: notification, countdown and restart belong to the SCCM client.
Exit codes (must match the Return Codes tab of the deployment type):
0 Success (no reboot) Uptime is below the threshold on re-validation. Nothing to do.
17010 Soft Reboot Uptime is at or above the threshold. SCCM schedules the restart.
17001 Failure (no reboot) Uptime could not be determined. Fail-safe: no restart requested.
17002 Failure (no reboot) Invalid configuration or unexpected error. Fail-safe: no restart requested.
Idempotent: the script only reads WMI and appends to its own log. Running it any number of times
changes nothing on the computer.
Log: C:\ProgramData\Corporate\UptimeReboot\UptimeReboot.log (CMTrace format, rotated at 2 MB).
.PARAMETER ThresholdMinutes
Maximum allowed uptime in minutes. LAB: 60. PRODUCTION: 10080 (7 days).
MUST be the same value as $ThresholdMinutes in the detection method.
.EXAMPLE
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install-UptimeReboot.ps1 -ThresholdMinutes 60
#>
[CmdletBinding()]
param(
[int]$ThresholdMinutes = 60
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
------------------------------------------------------------------------------------------------
Constants
------------------------------------------------------------------------------------------------
$ExitNoAction = 0 # Success (no reboot)
$ExitRebootRequired = 17010 # Soft Reboot
$ExitUptimeUnknown = 17001 # Failure (no reboot)
$ExitUnexpectedError = 17002 # Failure (no reboot)
$MinThresholdMinutes = 15 # Lower bound: protects against a typo such as -ThresholdMinutes 1
$MaxThresholdMinutes = 43200 # Upper bound: 30 days
$MaxUptimeMinutes = 5256000 # Sanity limit: 10 years. Anything above is treated as invalid data.
$WmiAttempts = 3 # WMI read attempts before giving up (fail-safe)
$WmiRetrySeconds = 5
$LogDirectory = 'C:\ProgramData\Corporate\UptimeReboot'
$LogFile = Join-Path $LogDirectory 'UptimeReboot.log'
$LogMaxBytes = 2MB
$LogComponent = 'Install'
------------------------------------------------------------------------------------------------
Logging (CMTrace format). Logging must NEVER break the script: every failure is swallowed.
------------------------------------------------------------------------------------------------
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
------------------------------------------------------------------------------------------------
Uptime from Win32_OperatingSystem. Returns an object; Success = $false means "unknown".
LocalDateTime and LastBootUpTime come from the same WMI instance, so both use the same clock.
------------------------------------------------------------------------------------------------
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
Success = $true
UptimeMinutes = [math]::Round($minutes, 1)
LastBootUpTime = $lastBoot
Reason = $null
}
}
catch {
$reason = $_.Exception.Message
if ($attempt -lt $Attempts) { Start-Sleep -Seconds $RetrySeconds }
}
}
return [pscustomobject]@{ Success = $false; UptimeMinutes = $null; LastBootUpTime = $null; Reason = $reason }
}
------------------------------------------------------------------------------------------------
Main
------------------------------------------------------------------------------------------------
$exitCode = $ExitUnexpectedError
try {
Write-Log "===== Install started. ThresholdMinutes=$ThresholdMinutes, PowerShell=$($PSVersionTable.PSVersion), 64-bit process=$([Environment]::Is64BitProcess) ====="
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
}
}
}
catch {
Write-Log "Unexpected error: $($_.Exception.Message). Fail-safe: no restart requested." -Severity Error
$exitCode = $ExitUnexpectedError
}
Write-Log "===== Install finished with exit code $exitCode ====="
exit $exitCode
