<#
.SYNOPSIS
    Validation tool for the "Uptime Reboot" lab, server side. Read-only. NOT part of the solution.

.DESCRIPTION
    Run on a computer with the Configuration Manager console (Windows PowerShell 5.1), from any folder.
    Checks, with PASS/FAIL/INFO:
      1. Deployment type: install command line, revision, return codes (17010 = Soft Reboot).
      2. Deployment: Required, deadline, maintenance window overrides, soft deadline.
      3. Client settings that reach the lab computers: priority and configured groups.
      4. Software Deployment schedule of the solution client setting (must be every 1 hour) and which
         setting wins for that group on the lab computers.
      5. Computer Agent differences between the solution client setting and the settings below it.
    Changes nothing.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Test-UptimeRebootServer.ps1
#>

[CmdletBinding()]
param(
    [string]$ApplicationName = 'Lab - Uptime Maximum 1h',
    [string]$DeploymentTypeName = 'Lab - Uptime Maximum 1h',
    [string]$CollectionName = 'LAB-Uptime',
    [string]$ClientSettingName = 'Uptime Reboot',

    # Threshold expected in the install command line: 60 (LAB) or 10080 (PRODUCTION)
    [int]$ThresholdMinutes = 60,
    [string[]]$ComputerName = @('LAB-2120993', 'LAB-DP5570'),
    [string]$SiteCode
)

$ErrorActionPreference = 'Stop'
$ExpectedCommand = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Install-UptimeReboot.ps1 -ThresholdMinutes $ThresholdMinutes"
$Results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Check, [string]$Result, [string]$Evidence) {
    $Results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Evidence = $Evidence })
}

function Get-SettingValues($Setting) {
    # Client setting group values as "Name = Value" lines (works for dictionaries and objects)
    if ($null -eq $Setting) { return @() }
    if ($Setting -is [System.Collections.IDictionary]) { return @($Setting.GetEnumerator() | ForEach-Object { '{0} = {1}' -f $_.Key, $_.Value }) }
    @($Setting.PSObject.Properties | Where-Object { $_.Name -notmatch '^(PS|Cim)' } | ForEach-Object { '{0} = {1}' -f $_.Name, $_.Value })
}

function Test-SettingGroup([string]$Name, [string]$Group) {
    [bool](Get-CMClientSetting -Name $Name -Setting $Group -ErrorAction SilentlyContinue)
}

# --- ConfigurationManager module and site drive ---
if (-not (Get-Module -Name ConfigurationManager)) {
    if (-not $env:SMS_ADMIN_UI_PATH) { throw 'Configuration Manager console not found on this computer (SMS_ADMIN_UI_PATH is empty).' }
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1')
}
$siteDrive = Get-PSDrive -PSProvider CMSite | Where-Object { -not $SiteCode -or $_.Name -eq $SiteCode } | Select-Object -First 1
if (-not $siteDrive) { throw 'No Configuration Manager site drive found. Pass -SiteCode.' }
$provider = $siteDrive.Root
$namespace = "root\SMS\site_$($siteDrive.Name)"

Push-Location -Path "$($siteDrive.Name):\"
try {
    Write-Host "===== Site $($siteDrive.Name) ($provider)"

    # ------------------------------------------------------------------------------------------
    # 1. Deployment type
    # ------------------------------------------------------------------------------------------
    $deploymentType = Get-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $DeploymentTypeName
    if (-not $deploymentType) { throw "Deployment type '$DeploymentTypeName' not found in '$ApplicationName'." }
    $installCommand = ([xml]$deploymentType.SDMPackageXML).AppMgmtDigest.DeploymentType.Installer.CustomData.InstallCommandLine
    Add-Result 'DT revision' 'INFO' "CIVersion $($deploymentType.CIVersion)"
    Add-Result 'DT install command line' $(if ($installCommand -ceq $ExpectedCommand) { 'PASS' } else { 'FAIL' }) "[$installCommand]"

    $returnCodes = @(Get-CMDeploymentTypeReturnCode -InputObject $deploymentType)
    $softReboot = $returnCodes | Where-Object { $_.Code -eq 17010 }
    Add-Result 'Return code 17010 = SoftReboot' $(if ("$($softReboot.Class)" -eq 'SoftReboot') { 'PASS' } else { 'FAIL' }) ("17010 = $($softReboot.Class)")
    Add-Result 'Return codes' 'INFO' (($returnCodes | ForEach-Object { '{0}={1}' -f $_.Code, $_.Class }) -join ', ')

    # ------------------------------------------------------------------------------------------
    # 2. Deployment
    # ------------------------------------------------------------------------------------------
    $deployment = Get-CMApplicationDeployment -Name $ApplicationName | Where-Object { $_.CollectionName -eq $CollectionName } | Select-Object -First 1
    if (-not $deployment) {
        Add-Result 'Deployment' 'FAIL' "No deployment of '$ApplicationName' to '$CollectionName'"
    }
    else {
        Add-Result 'Deployment is Required' $(if ($deployment.OfferTypeID -eq 0) { 'PASS' } else { 'FAIL' }) "OfferTypeID $($deployment.OfferTypeID)"
        Add-Result 'Deadline in the past' $(if ($deployment.EnforcementDeadline -and $deployment.EnforcementDeadline -le (Get-Date)) { 'PASS' } else { 'FAIL' }) "$($deployment.EnforcementDeadline)"
        Add-Result 'Install outside maintenance window' $(if ($deployment.OverrideServiceWindows) { 'PASS' } else { 'FAIL' }) "OverrideServiceWindows $($deployment.OverrideServiceWindows)"
        Add-Result 'Restart outside maintenance window' $(if ($deployment.RebootOutsideOfServiceWindows) { 'PASS' } else { 'FAIL' }) "RebootOutsideOfServiceWindows $($deployment.RebootOutsideOfServiceWindows)"
        Add-Result 'Delay enforcement (soft deadline) off' $(if (-not $deployment.SoftDeadlineEnabled) { 'PASS' } else { 'FAIL' }) "SoftDeadlineEnabled $($deployment.SoftDeadlineEnabled)"
    }

    # ------------------------------------------------------------------------------------------
    # 3. Client settings that reach the lab computers
    # ------------------------------------------------------------------------------------------
    $collectionIds = @(foreach ($device in $ComputerName) {
        Get-WmiObject -ComputerName $provider -Namespace $namespace -Class SMS_FullCollectionMembership -Filter "Name = '$device'" |
            Select-Object -ExpandProperty CollectionID
    }) | Sort-Object -Unique
    $allSettings = @(Get-WmiObject -ComputerName $provider -Namespace $namespace -Class SMS_ClientSettings)
    $assignments = @(Get-WmiObject -ComputerName $provider -Namespace $namespace -Class SMS_ClientSettingsAssignment |
        Where-Object { $collectionIds -contains $_.CollectionID })

    $reaching = @($assignments | Group-Object -Property ClientSettingsID | ForEach-Object {
        $settingsId = $_.Name
        $setting = $allSettings | Where-Object { "$($_.SettingsID)" -eq $settingsId } | Select-Object -First 1
        [pscustomobject]@{
            Priority           = [int]$setting.Priority
            Name               = $setting.Name
            Collections        = ($_.Group | ForEach-Object { $_.CollectionID } | Sort-Object -Unique) -join ', '
            SoftwareDeployment = Test-SettingGroup $setting.Name 'SoftwareDeployment'
            ComputerRestart    = Test-SettingGroup $setting.Name 'ComputerRestart'
            ComputerAgent      = Test-SettingGroup $setting.Name 'ComputerAgent'
        }
    } | Sort-Object -Property Priority)

    Write-Host "===== Client settings deployed to collections of: $($ComputerName -join ', ')"
    $reaching | Format-Table -AutoSize | Out-String -Width 300 | Write-Host

    $ours = $reaching | Where-Object { $_.Name -eq $ClientSettingName } | Select-Object -First 1
    if (-not $ours) {
        Add-Result 'Solution client setting reaches the computers' 'FAIL' "'$ClientSettingName' is not deployed to their collections"
    }
    else {
        # ------------------------------------------------------------------------------------------
        # 4. Software Deployment schedule and winner
        # ------------------------------------------------------------------------------------------
        $softwareDeployment = Get-SettingValues (Get-CMClientSetting -Name $ClientSettingName -Setting SoftwareDeployment)
        $token = ($softwareDeployment -join ' ') | Select-String -Pattern '\b[0-9A-Fa-f]{16}\b' | ForEach-Object { $_.Matches[0].Value } | Select-Object -First 1
        if ($token) {
            $decoded = Convert-CMSchedule -ScheduleString $token
            $hourly = ($decoded.DaySpan -eq 0 -and $decoded.HourSpan -eq 1 -and $decoded.MinuteSpan -eq 0)
            Add-Result "'$ClientSettingName' evaluation = 1 hour" $(if ($hourly) { 'PASS' } else { 'FAIL' }) ("$token = DaySpan $($decoded.DaySpan), HourSpan $($decoded.HourSpan), MinuteSpan $($decoded.MinuteSpan)")
        }
        else {
            Add-Result "'$ClientSettingName' evaluation = 1 hour" 'INFO' ('Schedule token not found. Values: ' + ($softwareDeployment -join '; '))
        }

        $sdWinner = $reaching | Where-Object { $_.SoftwareDeployment } | Select-Object -First 1
        Add-Result 'Software Deployment winner' $(if ($sdWinner.Name -eq $ClientSettingName) { 'PASS' } else { 'FAIL' }) "$($sdWinner.Name) (priority $($sdWinner.Priority))"

        $crWinner = $reaching | Where-Object { $_.ComputerRestart } | Select-Object -First 1
        if ($crWinner) {
            $crValues = Get-SettingValues (Get-CMClientSetting -Name $crWinner.Name -Setting ComputerRestart)
            Add-Result 'Computer Restart winner' 'INFO' ("$($crWinner.Name) (priority $($crWinner.Priority)): " + ($crValues -join '; '))
        }

        # ------------------------------------------------------------------------------------------
        # 5. Computer Agent differences (only matters if the solution setting configures it)
        # ------------------------------------------------------------------------------------------
        if ($ours.ComputerAgent) {
            $oursAgent = Get-SettingValues (Get-CMClientSetting -Name $ClientSettingName -Setting ComputerAgent)
            foreach ($other in @($reaching | Where-Object { $_.ComputerAgent -and $_.Priority -gt $ours.Priority })) {
                $otherAgent = Get-SettingValues (Get-CMClientSetting -Name $other.Name -Setting ComputerAgent)
                $differences = @(Compare-Object -ReferenceObject $otherAgent -DifferenceObject $oursAgent)
                if ($differences.Count -eq 0) {
                    Add-Result "Computer Agent vs '$($other.Name)'" 'PASS' 'Identical values'
                }
                else {
                    Add-Result "Computer Agent vs '$($other.Name)'" 'REVIEW' "$($differences.Count) line(s) differ, listed below"
                    Write-Host "===== Computer Agent: '$ClientSettingName' (=>) vs '$($other.Name)' (<=)"
                    $differences | Sort-Object InputObject, SideIndicator | Format-Table InputObject, SideIndicator -AutoSize | Out-String -Width 300 | Write-Host
                }
            }
        }
        else {
            Add-Result 'Computer Agent' 'PASS' "'$ClientSettingName' does not configure Computer Agent"
        }
    }

    Write-Host '===== RESULT'
    $Results | Format-Table -AutoSize -Wrap | Out-String -Width 300 | Write-Host
    $failed = @($Results | Where-Object Result -eq 'FAIL').Count
    Write-Host $(if ($failed -eq 0) { 'RESULT: NO FAILURES' } else { "RESULT: $failed FAILURE(S)" })
}
finally {
    Pop-Location
}
