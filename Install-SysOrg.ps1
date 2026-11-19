#Requires -Version 5.1
<# One-time setup: folders, unblock files, execution policy, desktop shortcut,
   weekly report-only scheduled task. No admin rights required (best effort). #>
[CmdletBinding()]
param([switch]$NoScheduledTask)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host '==== SysOrg installer ====' -ForegroundColor White
Write-Host "App folder: $appRoot"

# 1) runtime folders
foreach($d in @('Logs','Plans','Undo','Cache','Modules')){
    $p = Join-Path $appRoot $d
    if(-not (Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
Write-Host 'Runtime folders ready (Logs, Plans, Undo, Cache).'

# 2) unblock downloaded files
Get-ChildItem -LiteralPath $appRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Write-Host 'Files unblocked.'

# 3) allow script execution for the current user
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
    Write-Host 'Execution policy: RemoteSigned (CurrentUser).'
} catch {
    Write-Warning "Could not set execution policy ($($_.Exception.Message)). The desktop shortcut still works because it passes -ExecutionPolicy Bypass."
}

# 4) desktop shortcut
$desktop = [Environment]::GetFolderPath('Desktop')
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desktop 'SysOrg.lnk'))
$lnk.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$appRoot\SysOrg.ps1`""
$lnk.WorkingDirectory = $appRoot
$lnk.Description       = 'SysOrg - portable file organizer (preview-first)'
$lnk.Save()
Write-Host 'Desktop shortcut created: SysOrg.lnk'

# 5) weekly REPORT-ONLY scheduled task (never moves files)
if(-not $NoScheduledTask){
    $taskName = 'SysOrg Weekly Scan'
    $action   = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$appRoot\SysOrg.ps1`" -ScheduledReport"
    $trigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 10:00
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
            -Description 'SysOrg scan report (report-only; never moves files)' -Force -ErrorAction Stop | Out-Null
        Write-Host "Scheduled task '$taskName' registered (weekly, Sunday 10:00, report-only)."
    } catch {
        Write-Warning "Register-ScheduledTask failed ($($_.Exception.Message)); trying schtasks.exe fallback..."
        $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}\SysOrg.ps1" -ScheduledReport' -f $appRoot
        schtasks.exe /Create /F /SC WEEKLY /D SUN /ST 10:00 /TN $taskName /TR $tr
    }
}

Write-Host ''
Write-Host 'Install complete. Launch SysOrg from the desktop shortcut and pick option 1 to detect drives.' -ForegroundColor Green
