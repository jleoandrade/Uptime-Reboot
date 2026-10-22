# Re-runs the install command line EXACTLY as written in AppEnforce.log (same executable, same arguments,
# same working directory) and shows PowerShell's own error message. Run in an elevated Windows PowerShell 5.1.
# Safe: Install-UptimeReboot.ps1 never restarts the computer, it only returns an exit code.

$appEnforceLog = 'C:\Windows\CCM\Logs\AppEnforce.log'

$commandMatch = Select-String -Path $appEnforceLog -Pattern 'Executing Command line: "(.+?)" (.+?) with user context' | Select-Object -Last 1
$directoryMatch = Select-String -Path $appEnforceLog -Pattern 'Working directory (.+?)\]LOG\]' | Select-Object -Last 1
if (-not $commandMatch -or -not $directoryMatch) { 'STOP: command line or working directory not found in AppEnforce.log'; return }

$executable = $commandMatch.Matches[0].Groups[1].Value
$arguments = $commandMatch.Matches[0].Groups[2].Value
$workingDirectory = $directoryMatch.Matches[0].Groups[1].Value
$expected = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install-UptimeReboot.ps1 -ThresholdMinutes 60'

"Executable : $executable"
"Directory  : $workingDirectory"
"Arguments  : [$arguments]"
"Expected   : [$expected]"
"Identical  : $($arguments -ceq $expected)"

$startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $executable
$startInfo.Arguments = $arguments
$startInfo.WorkingDirectory = $workingDirectory
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = [System.Diagnostics.Process]::Start($startInfo)
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()

"Exit code  : $($process.ExitCode)"
"STDOUT     : $($stdout.Trim())"
"STDERR     : $($stderr.Trim())"
