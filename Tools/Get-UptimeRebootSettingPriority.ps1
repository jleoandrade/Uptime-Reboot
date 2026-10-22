<#
.SYNOPSIS
    Read-only. Lists the custom client settings that reach the lab devices, with priority and the
    groups that matter for the Uptime Reboot solution (Software Deployment, Computer Restart).

.DESCRIPTION
    Run from the Configuration Manager console PowerShell, on the site drive (PS A03:\>).
    Uses the SMS Provider WMI classes SMS_FullCollectionMembership, SMS_ClientSettingsAssignment
    and SMS_ClientSettings, and Get-CMClientSetting to check which groups each setting configures.
    Changes nothing.
#>

param(
    [string[]]$ComputerName = @('LAB-2120993', 'LAB-DP5570'),
    [string]$SiteCode = 'A03'
)

$ErrorActionPreference = 'Stop'
$provider = (Get-PSDrive -Name $SiteCode -PSProvider CMSite).Root
$namespace = "root\SMS\site_$SiteCode"

# Collections the devices belong to
$collectionIds = @(foreach ($device in $ComputerName) {
    Get-WmiObject -ComputerName $provider -Namespace $namespace -Class SMS_FullCollectionMembership -Filter "Name = '$device'" |
        Select-Object -ExpandProperty CollectionID
}) | Sort-Object -Unique

# Client settings deployed to those collections
$settings = @(Get-WmiObject -ComputerName $provider -Namespace $namespace -Class SMS_ClientSettings)
$assignments = @(Get-WmiObject -ComputerName $provider -Namespace $namespace -Class SMS_ClientSettingsAssignment |
    Where-Object { $collectionIds -contains $_.CollectionID })

$assignments | Group-Object -Property ClientSettingsID | ForEach-Object {
    $settingsId = $_.Name
    $setting = $settings | Where-Object { "$($_.SettingsID)" -eq $settingsId } | Select-Object -First 1
    [pscustomobject]@{
        Priority           = $setting.Priority
        Name               = $setting.Name
        Collections        = ($_.Group | ForEach-Object { $_.CollectionID } | Sort-Object -Unique) -join ', '
        SoftwareDeployment = [bool](Get-CMClientSetting -Name $setting.Name -Setting SoftwareDeployment -ErrorAction SilentlyContinue)
        ComputerRestart    = [bool](Get-CMClientSetting -Name $setting.Name -Setting ComputerRestart -ErrorAction SilentlyContinue)
        ComputerAgent      = [bool](Get-CMClientSetting -Name $setting.Name -Setting ComputerAgent -ErrorAction SilentlyContinue)
    }
} | Sort-Object -Property Priority | Format-Table -AutoSize
