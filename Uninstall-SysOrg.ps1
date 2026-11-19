#Requires -Version 5.1
param([switch]$KeepData)
$appRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'SysOrg Weekly Scan'

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host 'Scheduled task removed.'
} catch {
    schtasks.exe /Delete /F /TN $taskName 2>$null
    Write-Host 'Scheduled task removed via schtasks (or it was not present).'
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'SysOrg.lnk'
if(Test-Path -LiteralPath $lnk){ Remove-Item -LiteralPath $lnk -Force; Write-Host 'Shortcut removed.' }

if(-not $KeepData){
    $a = Read-Host 'Also delete plans/undo journals/logs? Files already organized will NOT be touched. [y/N]'
    if($a -match '^[Yy]'){
        foreach($d in @('Plans','Undo','Logs','Cache')){
            $p = Join-Path $appRoot $d
            if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Write-Host 'Data folders removed.'
    }
}
Write-Host 'Uninstall complete. Organized files and _Duplicates folders were NOT modified.'
