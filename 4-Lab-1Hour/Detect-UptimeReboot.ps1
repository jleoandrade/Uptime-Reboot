<#
SCCM Application "Uptime Reboot" - detection method (paste into: Deployment Type > Detection Method >
"Use a custom script to detect the presence of this deployment type" > Script type: PowerShell).
SCCM rules for script detection:
exit 0 + text on STDOUT -> Installed (no action)
exit 0 + nothing on STDOUT -> Not installed (required deployment runs the install program)
any text on STDERR, or exit <> 0 -> Unknown (avoided on purpose: nothing here writes to STDERR)
Behavior of this script:
Uptime < threshold -> "Detected" on STDOUT -> no action
Uptime >= threshold -> NO output -> install program runs (and re-validates)
Uptime cannot be determined -> "Detected" on STDOUT -> fail-safe: never trigger a restart on a guess
Read-only and idempotent: reads WMI and appends to its own log. Never use Write-Host here
(it also reaches STDOUT when SCCM captures the output).
#>
$ThresholdMinutes = 60 # LAB: 60 (1 hour). PRODUCTION: 10080 (7 days). Keep in sync with the install command line.
$ErrorActionPreference = 'Stop'
$MaxUptimeMinutes = 5256000 # Sanity limit: 10 years. Anything above is treated as invalid data.
$LogDirectory = 'C:\ProgramData\Corporate\UptimeReboot'
$LogFile = Join-Path $LogDirectory 'UptimeReboot.log'
$LogMaxBytes = 2MB
$LogComponent = 'Detection'
Logging (CMTrace format). Must never write to STDOUT/STDERR and never break detection.
function Write-Log {
param([string]$Message, [int]$Type = 1) # 1 = Info, 2 = Warning, 3 = Error
try {
if (-not (Test-Path -LiteralPath $LogDirectory)) {
[void](New-Item -Path $LogDirectory -ItemType Directory -Force)
}
if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -ge $LogMaxBytes)) {
Move-Item -LiteralPath $LogFile -Destination ([IO.Path]::ChangeExtension($LogFile, '.lo_')) -Force
}
$now = Get-Date
$bias = -[int][TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
$line = '<![LOG[{0}]LOG]!><time="{1}{2:+0;-0;+0}" date="{3}" component="{4}" context="{5}" type="{6}" thread="{7}" file="">' -f
$Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'),
$LogComponent, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $Type, $PID
[IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
}
catch {
# Intentionally ignored: a log failure must not change the detection result
}
}
$detected = $true # Fail-safe default: "Detected" means "no restart"
try {
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$lastBoot = $os.LastBootUpTime
$now = $os.LocalDateTime
if (-not ($lastBoot -is [datetime]) -or -not ($now -is [datetime])) {
throw 'LastBootUpTime or LocalDateTime is empty or not a date'
}
$uptimeMinutes = ($now - $lastBoot).TotalMinutes
if ($uptimeMinutes -lt 0) { throw "LastBootUpTime ($lastBoot) is later than the current time ($now)" }
if ($uptimeMinutes -gt $MaxUptimeMinutes) { throw "Uptime of $([math]::Round($uptimeMinutes)) minutes is above the sanity limit" }
$uptimeText = "Uptime $([math]::Round($uptimeMinutes, 1)) min (last boot $($lastBoot.ToString('yyyy-MM-dd HH:mm:ss')), threshold $ThresholdMinutes min)"
if ($uptimeMinutes -lt $ThresholdMinutes) {
Write-Log "$uptimeText. Result: DETECTED (no action)."
}
else {
$detected = $false
Write-Log "$uptimeText. Result: NOT DETECTED (application required, install program will re-validate)." -Type 2
}
}
catch {
$detected = $true
Write-Log "Uptime could not be determined: $($_.Exception.Message). Result: DETECTED (fail-safe, no restart)." -Type 3
}
if ($detected) { Write-Output 'Detected' }
exit 0
