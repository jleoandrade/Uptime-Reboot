<#
.SYNOPSIS
    Sets return code 17010 to Soft Reboot on the "Uptime Reboot" deployment type and shows the result.

.DESCRIPTION
    Run on a computer with the Configuration Manager console installed (ConfigMgr 2107 or later),
    from any folder: the script loads the ConfigurationManager module and switches to the site drive itself.
    Idempotent: if 17010 is already Soft Reboot, nothing is changed.
    Shows the deployment type revision and the return codes before and after. The client must receive a
    revision HIGHER than the one shown in AppDiscovery.log for the change to take effect.

.EXAMPLE
    .\Set-UptimeRebootReturnCode.ps1
    Finds the application automatically (applications named *Uptime* with the deployment type below).

.EXAMPLE
    .\Set-UptimeRebootReturnCode.ps1 -ApplicationName 'Lab - Uptime Maximum 1h' -SiteCode S01

.EXAMPLE
    .\Set-UptimeRebootReturnCode.ps1 -ReleaseLock
    Releases a stale lock ("Lock on object ... was not granted") and then applies the change.
#>

param(
    # Application name as shown in Software Library > Applications (Name column). Optional: found automatically.
    [string]$ApplicationName,

    # Deployment type name as shown in AppDiscovery.log / AppEnforce.log
    [string]$DeploymentTypeName = 'Lab - Uptime Maximum 1h',

    # Site code. Optional: the site the console is connected to is used.
    [string]$SiteCode,

    # SMS Provider server. Only needed when the site drive is not created automatically (use with -SiteCode).
    [string]$SiteServer,

    # Releases a STALE SEDO lock on the application before the change (console closed, crashed or disconnected).
    # Use only after confirming nobody has the application or deployment type properties open.
    [switch]$ReleaseLock
)

$ErrorActionPreference = 'Stop'
$RebootCode = 17010

# --- Load the ConfigurationManager module and switch to the site drive ---
if (-not (Get-Module -Name ConfigurationManager)) {
    if (-not $env:SMS_ADMIN_UI_PATH) { throw 'Configuration Manager console not found on this computer (SMS_ADMIN_UI_PATH is empty).' }
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1')
}
$siteDrive = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Where-Object { -not $SiteCode -or $_.Name -eq $SiteCode } | Select-Object -First 1
if (-not $siteDrive -and $SiteCode -and $SiteServer) {
    $siteDrive = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer
}
if (-not $siteDrive) { throw 'No Configuration Manager site drive found. Run again with -SiteCode <code> -SiteServer <SMS Provider FQDN>.' }

Push-Location -Path "$($siteDrive.Name):\"
try {
    "Site: $($siteDrive.Name) ($($siteDrive.Root))"

    # --- Find the deployment type ---
    if ($ApplicationName) { $applicationNames = @($ApplicationName) }
    else { $applicationNames = @(Get-CMApplication -Name '*Uptime*' -Fast | Select-Object -ExpandProperty LocalizedDisplayName) }

    $found = @(foreach ($name in $applicationNames) {
        $deploymentType = Get-CMDeploymentType -ApplicationName $name -DeploymentTypeName $DeploymentTypeName -ErrorAction SilentlyContinue
        if ($deploymentType) { [pscustomobject]@{ ApplicationName = $name; DeploymentType = $deploymentType } }
    })

    if ($found.Count -ne 1) {
        "STOP: expected exactly 1 application with deployment type '$DeploymentTypeName', found $($found.Count)."
        'Applications named *Uptime* on this site:'
        Get-CMApplication -Name '*Uptime*' -Fast | Select-Object LocalizedDisplayName, CIVersion | Format-Table -AutoSize | Out-String
        'Run again with -ApplicationName set to one of the names above.'
        return
    }

    $ApplicationName = $found[0].ApplicationName
    $deploymentType = $found[0].DeploymentType
    "Application: $ApplicationName | Deployment type: $DeploymentTypeName"

    # --- SEDO lock: an open Properties window (any console, any admin) blocks every change ---
    $application = Get-CMApplication -Name $ApplicationName
    '===== Lock details (empty = not locked)'
    Get-CMObjectLockDetails -InputObject $application | Format-List | Out-String
    if ($ReleaseLock) {
        Unlock-CMObject -InputObject $application -Force
        'Lock released (-ReleaseLock).'
    }

    "===== BEFORE - deployment type revision (CIVersion): $($deploymentType.CIVersion)"
    Get-CMDeploymentTypeReturnCode -InputObject $deploymentType | Format-Table -AutoSize | Out-String

    # --- Set 17010 to Soft Reboot (idempotent) ---
    $current = Get-CMDeploymentTypeReturnCode -InputObject $deploymentType | Where-Object { $_.Code -eq $RebootCode }
    if (-not $current) {
        Add-CMDeploymentTypeReturnCode -InputObject $deploymentType -ReturnCode $RebootCode -Name 'UptimeRebootRequired' `
            -CodeType SoftReboot -Description 'Uptime at or above threshold'
        "Return code $RebootCode added as Soft Reboot."
    }
    elseif ("$($current.Class)" -ne 'SoftReboot') {
        Set-CMDeploymentTypeReturnCode -InputObject $deploymentType -ReturnCode $RebootCode -CodeType SoftReboot
        "Return code $RebootCode changed from $($current.Class) to Soft Reboot."
    }
    else {
        "Return code $RebootCode is already Soft Reboot. Nothing changed."
    }

    $deploymentType = Get-CMDeploymentType -ApplicationName $ApplicationName -DeploymentTypeName $DeploymentTypeName
    "===== AFTER - deployment type revision (CIVersion): $($deploymentType.CIVersion)"
    Get-CMDeploymentTypeReturnCode -InputObject $deploymentType | Format-Table -AutoSize | Out-String
}
finally {
    Pop-Location
}
