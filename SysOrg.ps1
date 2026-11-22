#Requires -Version 5.1
<#
  SysOrg - portable, preview-first file organizer (Windows PowerShell 5.1+)
  Revision 2.1: Windows-native, type-first, numbered copies.

  Interactive:  .\SysOrg.ps1
  CLI examples: .\SysOrg.ps1 -ProfileDrives          (drive hierarchy profile: role, artifacts, known folders, scope)
                .\SysOrg.ps1 -DetectDrives
                .\SysOrg.ps1 -AuditDrive C           (folder safety map: cannot-alter vs organizable)
                .\SysOrg.ps1 -ScanDrive C            (profile folders + known folders; preview -> optional execute)
                .\SysOrg.ps1 -ScanDrive C -FullDrive (whole drive; restores pre-1.2 behavior)
                .\SysOrg.ps1 -ScanDrive C -NoCache   (ignore the cached inventory)
                .\SysOrg.ps1 -ScanDrive D -ReportOnly
                .\SysOrg.ps1 -ScanDrive C -WritablePath 'C:\Work\Exports'  (extend the writable scope)
                .\SysOrg.ps1 -ExecutePlan .\Plans\plan-20260101-093000.json
                .\SysOrg.ps1 -ExecutePlan <plan> -Force   (resume after a crash; journaled actions skipped)
                .\SysOrg.ps1 -UndoPlan plan-20260101-093000
                .\SysOrg.ps1 -Migrate C              (map old Photo/Video/... trees to the Windows naming; preview first)
                .\SysOrg.ps1 -ScheduledReport        (report-only, used by Task Scheduler)
#>
[CmdletBinding()]
param(
    [switch]$DetectDrives,
    [switch]$ProfileDrives,
    [string[]]$ScanDrive,
    [string[]]$AuditDrive,
    [string[]]$Migrate,
    [switch]$ReportOnly,
    [switch]$FullDrive,
    [switch]$NoCache,
    [switch]$Force,
    [string[]]$WritablePath,
    [string]$ExecutePlan,
    [string]$UndoPlan,
    [switch]$ScheduledReport,
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
$appRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRoot = Join-Path $appRoot 'Modules'
Import-Module (Join-Path $moduleRoot 'SysOrg.Core.psm1')        -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.KnownFolders.psm1') -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.Drives.psm1')      -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.Scan.psm1')        -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.Plan.psm1')        -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.Audit.psm1')       -Force

if(-not $ConfigPath){ $ConfigPath = Join-Path $appRoot 'SysOrg.config.psd1' }
# v2.1.1 fail closed: a config that exists but cannot be parsed may carry user
# exclusions we know nothing about. Interactive/execute sessions stop; the
# report-only scheduled session may continue with safe defaults after a loud warning.
try {
    $Config  = Import-SysOrgConfig -Path $ConfigPath -AppRoot $appRoot
} catch {
    if($ScheduledReport){
        Write-Warning ("CONFIG PARSE FAILED ({0}) - scheduled report continues with SAFE DEFAULTS; user exclusions from the config are NOT applied. Nothing will be moved (report-only mode)." -f $_.Exception.Message)
        $Config = Import-SysOrgConfig -Path $ConfigPath -AppRoot $appRoot -AllowDegradedMode
    } else {
        throw
    }
}
$folders = New-SysOrgAppFolders -AppRoot $appRoot
$logFolder = $folders.Logs

# -WritablePath extends the writable scope on any drive (design section 5.1).
# v2.1.1: the input is resolved to a FULL CANONICAL path first - a relative path used to
# be stored raw and never matched any absolute path at mutability-check time.
if($WritablePath -and @($WritablePath).Count -gt 0){
    foreach($wp in $WritablePath){
        try{
            $full = Resolve-SysOrgWritablePath -Path $wp
            $sd = $Config.Policy.SystemDrive
            if($sd -is [hashtable]){ $sd.WritablePaths = @($sd.WritablePaths) + $full }
            $dd = $Config.Policy.DataDrives
            if($dd -is [hashtable]){ $dd.WritablePaths = @($dd.WritablePaths) + $full }
            Write-SysOrgLog "Writable scope extended via -WritablePath: $full" -LogFolder $logFolder
        } catch { Write-Warning "Could not apply -WritablePath '$wp': $($_.Exception.Message)" }
    }
}

function Confirm-SysOrg {
    param([string]$Prompt)
    $a = Read-Host "$Prompt [y/N]"
    return ($a -match '^[Yy]')
}
function Confirm-SysOrgStrict {
    param([string]$Prompt)
    $a = Read-Host "$Prompt (type 'yes' to confirm)"
    return ($a -ieq 'yes')
}
function Get-SysOrgLetterInput {
    param([string]$Prompt='Drive letter')
    do { $l = (Read-Host $Prompt).Trim().TrimEnd(':').ToUpper() } while(-not ($l -match '^[A-Z]$'))
    return $l
}
function Show-SysOrgFolderAudit {
    param($Audit)
    Write-Host ''
    Write-Host ("FOLDER SAFETY MAP - drive {0}: (audit depth {1})" -f $Audit.DriveLetter, $Audit.MaxDepth) -ForegroundColor White
    Write-Host ("  CANNOT BE ALTERED (protected): {0}" -f $Audit.Summary.Protected) -ForegroundColor Red
    Write-Host ("  READ-ONLY (restricted):        {0}" -f $Audit.Summary.Restricted) -ForegroundColor Yellow
    Write-Host ("  CAN BE ORGANIZED:              {0}" -f $Audit.Summary.Organizable) -ForegroundColor Green
    Write-Host ''
    Write-Host '-- CANNOT BE ALTERED --' -ForegroundColor Red
    $Audit.Folders | Where-Object { $_.Status -eq 'Protected' } | Sort-Object Depth,Path | ForEach-Object {
        Write-Host ('  [' + $_.Reason + '] ' + $_.Path)
    }
    Write-Host ''
    Write-Host '-- READ-ONLY FOR CURRENT USER (excluded from plans by default) --' -ForegroundColor Yellow
    $Audit.Folders | Where-Object { $_.Status -eq 'Restricted' } | Sort-Object Depth,Path | ForEach-Object {
        Write-Host ('  ' + $_.Path)
    }
    Write-Host ''
    Write-Host '-- CAN BE ORGANIZED --' -ForegroundColor Green
    $Audit.Folders | Where-Object { $_.Status -eq 'Organizable' } | Sort-Object Depth,Path | ForEach-Object {
        Write-Host ('  ' + $_.Path)
    }
    Write-Host ''
}
function Invoke-SysOrgFolderAuditFlow {
    param([string]$Letter)
    $audit = Get-SysOrgFolderAudit -Letter $Letter -Config $Config -MaxDepth (Get-SysOrgSetting $Config 'FolderAudit.MaxTopLevelDepth' 2)
    Show-SysOrgFolderAudit -Audit $audit
    $destRoot  = Get-SysOrgDestinationRoot -Letter $Letter -Config $Config
    $repFolder = Join-Path $destRoot (Get-SysOrgSetting $Config 'ReportsFolderName' '_Reports')
    $rep = Write-SysOrgFolderAuditReport -Audit $audit -ReportFolder $repFolder
    Write-Host ("Audit report saved: {0}" -f $rep) -ForegroundColor Green
}
function Invoke-SysOrgProfileFlow {
    param([string[]]$Letters)
    $drives = @(Get-SysOrgDrive -Letters $Letters)
    $drives | Format-Table Drive,Label,FileSystem,SizeGB,FreeGB,MediaType,BusType,Location,Confidence,DetectionBasis -AutoSize | Out-Host
    foreach($d in $drives){
        Write-SysOrgLog ("Drive {0} [{1} / {2} / {3}] confidence={4}: {5}" -f $d.Drive,$d.MediaType,$d.BusType,$d.Location,$d.Confidence,$d.DetectionBasis) -LogFolder $logFolder
    }
    # W1: hierarchy profile - role, artifacts, known folders (with redirection/OneDrive
    # flags), download roots, top-level tree and the proposed writable scope per volume.
    $profiles = @(Get-SysOrgDriveProfile -Config $Config -Letters $Letters)
    Show-SysOrgDriveProfileReport -Profiles $profiles
    return $profiles
}
function Invoke-SysOrgScanFlow {
    param([string]$Letter,[switch]$PreviewOnly,[switch]$WholeDrive,[switch]$NoCacheSwitch)
    # W1: no plan is built without a drive profile
    Write-SysOrgLog "Profiling and scanning drive $Letter`: ..." -LogFolder $logFolder
    $profiles = @(Get-SysOrgDriveProfile -Config $Config -Letters $Letter)
    $prof = $null
    if($profiles.Count -gt 0){ $prof = $profiles[0] }
    if(-not $prof){
        Write-Host ("Drive {0}: could not be profiled; nothing was scanned and no plan was built." -f $Letter) -ForegroundColor Yellow
        return
    }
    Write-Host ("Drive {0}\  role={1}  proposed scope={2}" -f $prof.Letter, $prof.Role, $prof.ProposedScope) -ForegroundColor White
    $trail = New-Object System.Collections.Generic.List[object]
    $rootsInfo = Get-SysOrgScanRoots -Letter $Letter -Config $Config -DefaultScope:(-not $WholeDrive) -KnownFolders @($prof.KnownFolders)
    $invParams = @{ Letter=$Letter; Config=$Config; CacheFolder=$folders.Cache; AuditTrail=$trail; KnownFolders=@($prof.KnownFolders) }
    if($NoCacheSwitch){ $invParams.NoCache = $true }
    if(-not $WholeDrive){ $invParams.DefaultScope = $true }
    # @() collect: the inventory streams records (empty scan emits nothing)
    $inv = @(Get-SysOrgInventory @invParams)
    if(@($inv).Count -eq 0){
        Write-Host 'Nothing was scanned; no plan was built. Nothing was modified.' -ForegroundColor Yellow
        return
    }
    Write-Host ("Scanned {0} files." -f @($inv).Count)
    $longPaths = @($inv | Where-Object { $_.Category -eq 'SkippedLongPath' })
    if($longPaths.Count -gt 0){
        Write-Host ("Paths >= 260 characters recorded but not planned (PowerShell 5.1 limit): {0}" -f $longPaths.Count) -ForegroundColor Yellow
    }
    $cannotAlter = @($trail | Where-Object { $_.Status -eq 'Protected' })
    $readOnly    = @($trail | Where-Object { $_.Status -eq 'Restricted' })
    Write-Host ("Folders that cannot be altered: {0}   Read-only folders skipped: {1}" -f $cannotAlter.Count, $readOnly.Count) -ForegroundColor Yellow
    foreach($t in @($cannotAlter | Select-Object -First 6)){ Write-Host ('  [cannot alter] ' + $t.Reason + ' -> ' + $t.Path) -ForegroundColor DarkYellow }
    Write-Host ''
    Write-Host 'By routing category:' -ForegroundColor White
    $inv | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ('  {0,-15} {1}' -f $_.Name, $_.Count)
    }
    Write-Host ''
    Write-SysOrgLog 'Detecting duplicates (hashes candidate files; can take a while)...' -LogFolder $logFolder
    $dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $Config)
    Write-Host ("Duplicate groups found: {0}" -f @($dups).Count)
    $projects = @(Get-SysOrgProjectFolders -Roots @($rootsInfo.Initial) -Config $Config -DriveProfile $prof -KnownFolders @($prof.KnownFolders))
    if(@($projects).Count -gt 0){ Write-Host ("Code project folders detected: {0} (moved whole, .git intact)" -f @($projects).Count) }
    $plan = New-SysOrgPlan -Letter $Letter -Inventory $inv -DriveProfile $prof -DupGroups $dups -Config $Config -KnownFolders @($prof.KnownFolders) -ProjectFolders $projects
    $sum = Show-SysOrgPlan -Plan $plan -Config $Config
    $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $folders.Plans
    Write-Host ("Plan saved: {0}" -f $planPath) -ForegroundColor Green
    if($PreviewOnly){ return }
    # W8: the confirmation prompt names the OneDrive sync-out count
    $prompt = 'Execute this plan now (files will be moved)?'
    if($sum.OneDriveSyncOut -gt 0){
        $prompt = ('Execute this plan now? {0} file(s) will be moved OUT of OneDrive sync (removed from the cloud).' -f $sum.OneDriveSyncOut)
    }
    if(-not (Confirm-SysOrg -Prompt $prompt)){
        Write-Host 'Plan NOT executed. Nothing was modified.' -ForegroundColor Yellow
        return
    }
    # W8 / 6.3: targeting the REAL known folders requires a second explicit confirmation
    if("$($plan.DestinationStyle)" -eq 'KnownFolders'){
        $extra = ''
        if($sum.OneDriveIntoCloud -gt 0){ $extra = (' {0} destination(s) are OneDrive-backed; moved files will sync to the cloud.' -f $sum.OneDriveIntoCloud) }
        if(-not (Confirm-SysOrgStrict -Prompt ("Second confirmation: files will be filed into your real known folders (Documents/Pictures/...).$extra"))){
            Write-Host 'Second confirmation declined. Nothing was modified.' -ForegroundColor Yellow
            return
        }
    }
    $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $Config -AppRoot $appRoot
    Write-Host ''
    Write-Host ("Done. Moved={0} (numbered copies={1})  Copied={2}  Folders={3}  Quarantined={4}  Failed={5}" -f `
        $res.Summary.Moved, $res.Summary.Numbered, $res.Summary.Copied, $res.Summary.FolderMoves, $res.Summary.Quarantined, $res.Summary.Failed) -ForegroundColor Green
    Write-Host ("Undo journal: {0}" -f $res.UndoFile)
}
function Invoke-SysOrgMigrationFlow {
    param([string]$Letter)
    Write-SysOrgLog "Building migration preview for drive $Letter`: ..." -LogFolder $logFolder
    try{
        $plan = New-SysOrgMigrationPlan -Letter $Letter -Config $Config
    } catch {
        Write-Host ("Migration: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return
    }
    if(@($plan.Actions).Count -eq 0){
        Write-Host 'No legacy folders found - nothing to migrate. Nothing was modified.' -ForegroundColor Yellow
        return
    }
    [void](Show-SysOrgPlan -Plan $plan -Config $Config)
    $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $folders.Plans
    Write-Host ("Migration plan saved: {0}" -f $planPath) -ForegroundColor Green
    if(-not (Confirm-SysOrg 'Apply this migration now (old category folders are renamed/mapped)?')){
        Write-Host 'Migration NOT applied. Nothing was modified.' -ForegroundColor Yellow
        return
    }
    $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $Config -AppRoot $appRoot
    Write-Host ''
    Write-Host ("Migration done. Moved={0}  Folders={1}  Failed={2}" -f $res.Summary.Moved, $res.Summary.FolderMoves, $res.Summary.Failed) -ForegroundColor Green
    Write-Host ("Undo journal: {0}" -f $res.UndoFile)
}
function Invoke-SysOrgPlanFile {
    <# Shared preview -> confirm -> execute path (P1-2). Used by CLI and menu option 5. #>
    param([Parameter(Mandatory)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path)){ Write-Host 'Plan file not found.' -ForegroundColor Red; return }
    $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $sum = Show-SysOrgPlan -Plan $plan -Config $Config
    $prompt = 'Execute this plan now (files will be moved)?'
    if($sum.OneDriveSyncOut -gt 0){
        $prompt = ('Execute this plan now? {0} file(s) will be moved OUT of OneDrive sync (removed from the cloud).' -f $sum.OneDriveSyncOut)
    }
    if(-not (Confirm-SysOrg -Prompt $prompt)){
        Write-Host 'Nothing was modified.' -ForegroundColor Yellow; return
    }
    if($plan.PSObject.Properties['DestinationStyle'] -and "$($plan.DestinationStyle)" -eq 'KnownFolders'){
        if(-not (Confirm-SysOrgStrict -Prompt 'Second confirmation: files will be filed into your real known folders (Documents/Pictures/...)')){
            Write-Host 'Second confirmation declined. Nothing was modified.' -ForegroundColor Yellow; return
        }
    }
    $res = Invoke-SysOrgPlan -PlanPath $Path -Config $Config -AppRoot $appRoot -Force:$Force
    Write-Host ("Done. Moved={0} (numbered copies={1})  Copied={2}  Folders={3}  Quarantined={4}  Failed={5}" -f `
        $res.Summary.Moved, $res.Summary.Numbered, $res.Summary.Copied, $res.Summary.FolderMoves, $res.Summary.Quarantined, $res.Summary.Failed) -ForegroundColor Green
    Write-Host ("Undo journal: {0}" -f $res.UndoFile)
}

# ---------------- non-interactive modes ----------------
if($ProfileDrives){
    [void](Invoke-SysOrgProfileFlow -Letters $null)
    return
}
if($DetectDrives){
    $drives = @(Get-SysOrgDrive)
    $drives | Format-Table Drive,Label,FileSystem,SizeGB,FreeGB,MediaType,BusType,Location,Confidence,DetectionBasis -AutoSize | Out-Host
    foreach($d in $drives){
        Write-SysOrgLog ("Drive {0} [{1} / {2} / {3}] confidence={4}: {5}" -f $d.Drive,$d.MediaType,$d.BusType,$d.Location,$d.Confidence,$d.DetectionBasis) -LogFolder $logFolder
    }
    return
}
if($ScheduledReport){
    # P0-4: Get-SysOrgDrive exposes the letter as 'Drive' (formatted 'C:'), not 'Letter'
    $letters = @(Get-SysOrgSetting $Config 'ScheduledDrives' @('*'))
    foreach($d in @(Get-SysOrgDrive)){
        $letter = $d.Drive.TrimEnd(':')
        if(($letters -contains '*') -or ($letters -contains $letter)){
            try {
                [void](New-SysOrgScanReport -Letter $letter -Config $Config -AppRoot $appRoot)
            } catch {
                Write-SysOrgLog "Scheduled report failed for $letter`: $($_.Exception.Message)" -Level ERROR -LogFolder $logFolder
            }
        }
    }
    return
}
if($AuditDrive){
    foreach($l in $AuditDrive){
        $ll = $l.Trim().TrimEnd(':').ToUpper()
        Invoke-SysOrgFolderAuditFlow -Letter $ll
    }
    return
}
if($UndoPlan){
    $res = Undo-SysOrgPlan -PlanId $UndoPlan -AppRoot $appRoot -Config $Config
    Write-Host ("Undo complete. Restored={0}  Failed={1}  SkippedMissing={2}  SkippedChanged={3}" -f $res.Restored, $res.Failed, $res.SkippedMissing, $res.SkippedChanged)
    return
}
if($ExecutePlan){
    Invoke-SysOrgPlanFile -Path $ExecutePlan
    return
}
if($Migrate){
    if(@($Migrate).Count -gt 0){
        foreach($l in $Migrate){ Invoke-SysOrgMigrationFlow -Letter ($l.Trim().TrimEnd(':').ToUpper()) }
    } else {
        foreach($d in @(Get-SysOrgDrive)){
            Invoke-SysOrgMigrationFlow -Letter ($d.Drive.TrimEnd(':'))
        }
    }
    return
}
if($ScanDrive){
    foreach($l in $ScanDrive){
        $ll = $l.Trim().TrimEnd(':').ToUpper()
        if($ReportOnly){ Invoke-SysOrgScanFlow -Letter $ll -PreviewOnly -WholeDrive:$FullDrive -NoCacheSwitch:$NoCache }
        else { Invoke-SysOrgScanFlow -Letter $ll -WholeDrive:$FullDrive -NoCacheSwitch:$NoCache }
    }
    return
}

# ---------------- interactive menu ----------------
$running = $true
while($running){
    Write-Host ''
    Write-Host '==== SysOrg - portable file organizer (rev 2.1, preview-first) ====' -ForegroundColor White
    Write-Host ' [1] Profile drives (role, protected artifacts, known folders, writable scope)'
    Write-Host ' [2] Audit folders: which can / cannot be altered (safety map)'
    Write-Host ' [3] Organize a drive (profile -> scan -> plan -> preview -> optional execute)'
    Write-Host ' [4] Scan a drive, report only (no plan, no changes)'
    Write-Host ' [5] Execute a saved plan file (preview + confirm)'
    Write-Host ' [6] Undo a plan (restore files to original locations)'
    Write-Host ' [7] Migrate old organized trees (Photo/Video/... -> Windows naming; preview first)'
    Write-Host ' [8] Open working folder (plans, undo journals, logs, reports)'
    Write-Host ' [0] Exit'
    $choice = Read-Host 'Choose'
    # P2-4: one bad drive or folder never kills the whole app
    try {
        switch($choice){
            '1' { [void](Invoke-SysOrgProfileFlow -Letters $null) }
            '2' { $l = Get-SysOrgLetterInput -Prompt 'Drive letter to audit'; Invoke-SysOrgFolderAuditFlow -Letter $l }
            '3' { $l = Get-SysOrgLetterInput -Prompt 'Drive letter to organize'; Invoke-SysOrgScanFlow -Letter $l }
            '4' {
                  $l = Get-SysOrgLetterInput -Prompt 'Drive letter to report'
                  $inv = @(Get-SysOrgInventory -Letter $l -Config $Config -CacheFolder $folders.Cache -DefaultScope)
                  if(@($inv).Count -gt 0){
                      Write-Host ("Files: {0}" -f @($inv).Count)
                      $inv | Group-Object Category | Sort-Object Count -Descending | Format-Table Name,Count -AutoSize | Out-Host
                      $dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $Config)
                      Write-Host ("Duplicate groups: {0} (report only - nothing moved)" -f @($dups).Count)
                  }
                }
            '5' {
                  $p = Read-Host 'Path to plan JSON'
                  Invoke-SysOrgPlanFile -Path $p
                }
            '6' {
                  $id = Read-Host 'Plan id (e.g. plan-20260101-093000)'
                  $res = Undo-SysOrgPlan -PlanId $id -AppRoot $appRoot -Config $Config
                  Write-Host ("Restored={0}  Failed={1}  SkippedMissing={2}  SkippedChanged={3}" -f $res.Restored, $res.Failed, $res.SkippedMissing, $res.SkippedChanged)
                }
            '7' { $l = Get-SysOrgLetterInput -Prompt 'Drive letter to migrate'; Invoke-SysOrgMigrationFlow -Letter $l }
            '8' { Start-Process explorer.exe $appRoot }
            '0' { $running = $false }
            default { Write-Host 'Unknown option.' }
        }
    } catch {
        Write-SysOrgLog "Menu action failed: $($_.Exception.Message)" -Level ERROR -LogFolder $logFolder
    }
}
