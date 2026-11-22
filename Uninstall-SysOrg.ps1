#Requires -Version 5.1
param([switch]$KeepData)
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# P2-8: honor ScheduledTaskName from the config file instead of hardcoding
$taskName = 'SysOrg Weekly Scan'
$cfgFile = Join-Path $appRoot 'SysOrg.config.psd1'
if(Test-Path -LiteralPath $cfgFile){
    try {
        $cfg = Import-PowerShellDataFile -LiteralPath $cfgFile
        if($cfg.ScheduledTaskName){ $taskName = $cfg.ScheduledTaskName }
    } catch { Write-Warning "Could not read task name from config; using default." }
}

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host 'Scheduled task removed.'
} catch {
    # v2.1.1: only claim a task was removed when one actually was.
    schtasks.exe /Delete /F /TN $taskName 2>$null | Out-Null
    if($LASTEXITCODE -eq 0){ Write-Host 'Scheduled task removed via schtasks.' }
    else { Write-Host 'No scheduled task found (nothing to remove).' }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'SysOrg.lnk'
if(Test-Path -LiteralPath $lnk){ Remove-Item -LiteralPath $lnk -Force; Write-Host 'Shortcut removed.' }

if(-not $KeepData){
    # v2.1.1: the prompt must state what deleting Undo\ costs; the default stays "No".
    $a = Read-Host 'Also delete plans/undo journals/logs? Deleting Undo\ removes the ability to undo past organizing. Files already organized will NOT be touched. [y/N]'
    if($a -match '^[Yy]'){
        foreach($d in @('Plans','Undo','Logs','Cache','Reports')){
            $p = Join-Path $appRoot $d
            if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Write-Host 'Data folders removed.'
    }
}
Write-Host 'Uninstall complete. Organized files and _Duplicates folders were NOT modified.'
