#Requires -Version 5.1
<#
  SysOrg - portable, preview-first file organizer (Windows PowerShell 5.1+)

  Interactive:  .\SysOrg.ps1
  CLI examples: .\SysOrg.ps1 -DetectDrives
                .\SysOrg.ps1 -ScanDrive C            (scan -> preview -> optional execute)
                .\SysOrg.ps1 -ScanDrive D -ReportOnly
                .\SysOrg.ps1 -ExecutePlan .\Plans\plan-20250714-093000.json
                .\SysOrg.ps1 -UndoPlan plan-20250714-093000
                .\SysOrg.ps1 -ScheduledReport        (report-only, used by Task Scheduler)
#>
[CmdletBinding()]
param(
    [switch]$DetectDrives,
    [string[]]$ScanDrive,
    [switch]$ReportOnly,
    [string]$ExecutePlan,
    [string]$UndoPlan,
    [switch]$ScheduledReport,
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
$appRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRoot = Join-Path $appRoot 'Modules'
Import-Module (Join-Path $moduleRoot 'SysOrg.Core.psm1')  -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.Drives.psm1') -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.Scan.psm1')  -Force
Import-Module (Join-Path $moduleRoot 'SysOrg.Plan.psm1')  -Force

if(-not $ConfigPath){ $ConfigPath = Join-Path $appRoot 'SysOrg.config.psd1' }
$Config  = Import-SysOrgConfig -Path $ConfigPath -AppRoot $appRoot
$folders = New-SysOrgAppFolders -AppRoot $appRoot
$logFolder = $folders.Logs

function Confirm-SysOrg {
    param([string]$Prompt)
    $a = Read-Host "$Prompt [y/N]"
    return ($a -match '^[Yy]')
}
function Get-SysOrgLetterInput {
    param([string]$Prompt='Drive letter')
    do { $l = (Read-Host $Prompt).Trim().TrimEnd(':').ToUpper() } while(-not ($l -match '^[A-Z]$'))
    return $l
}
function Invoke-SysOrgScanFlow {
    param([string]$Letter,[switch]$PreviewOnly)
    Write-SysOrgLog "Scanning drive $Letter`: ..." -LogFolder $logFolder
    $inv = Get-SysOrgInventory -Letter $Letter -Config $Config -CacheFolder $folders.Cache
    Write-Host ("Scanned {0} files." -f $inv.Count)
    Write-Host ''
    Write-Host 'By category:' -ForegroundColor White
    $inv | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ('  {0,-15} {1}' -f $_.Name, $_.Count)
    }
    Write-Host ''
    Write-SysOrgLog 'Detecting duplicates (hashes candidate files; can take a while)...' -LogFolder $logFolder
    $dups = Find-SysOrgDuplicates -Inventory $inv -Config $Config
    Write-Host ("Duplicate groups found: {0}" -f @($dups).Count)
    $clusters = Get-SysOrgProjectClusters -Inventory $inv -Config $Config
    Write-Host ("Project clusters found: {0}" -f @($clusters.Clusters).Count)
    $plan = New-SysOrgPlan -Letter $Letter -Inventory $inv -ClusterResult $clusters -DupGroups $dups -Config $Config
    Show-SysOrgPlan -Plan $plan
    $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $folders.Plans
    Write-Host ("Plan saved: {0}" -f $planPath) -ForegroundColor Green
    if($PreviewOnly){ return }
    if(-not (Confirm-SysOrg 'Execute this plan now (files will be moved)?')){
        Write-Host 'Plan NOT executed. Nothing was modified.' -ForegroundColor Yellow
        return
    }
    $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $Config -AppRoot $appRoot
    Write-Host ''
    Write-Host ("Done. Moved={0}  Quarantined={1}  Failed={2}" -f $res.Summary.Moved, $res.Summary.Quarantined, $res.Summary.Failed) -ForegroundColor Green
    Write-Host ("Undo journal: {0}" -f $res.UndoFile)
}

# ---------------- non-interactive modes ----------------
if($DetectDrives){
    Get-SysOrgDrive | Format-Table Drive,Label,FileSystem,SizeGB,FreeGB,MediaType,BusType,Location,Confidence,DetectionBasis -AutoSize | Out-Host
    foreach($d in @(Get-SysOrgDrive)){
        Write-SysOrgLog ("Drive {0} [{1} / {2} / {3}] confidence={4}: {5}" -f $d.Drive,$d.MediaType,$d.BusType,$d.Location,$d.Confidence,$d.DetectionBasis) -LogFolder $logFolder
    }
    return
}
if($ScheduledReport){
    $letters = @(Get-SysOrgSetting $Config 'ScheduledDrives' @('*'))
    foreach($d in @(Get-SysOrgDrive)){
        if(($letters -contains '*') -or ($letters -contains $d.Letter)){
            try { [void](New-SysOrgScanReport -Letter $d.Letter -Config $Config -AppRoot $appRoot) }
            catch { Write-SysOrgLog "Scheduled report failed for $($d.Letter): $($_.Exception.Message)" -Level ERROR -LogFolder $logFolder }
        }
    }
    return
}
if($UndoPlan){
    $res = Undo-SysOrgPlan -PlanId $UndoPlan -AppRoot $appRoot -Config $Config
    Write-Host ("Undo complete. Restored={0}  Failed={1}  SkippedMissing={2}" -f $res.Restored, $res.Failed, $res.SkippedMissing)
    return
}
if($ExecutePlan){
    if(-not (Test-Path -LiteralPath $ExecutePlan)){ throw "Plan not found: $ExecutePlan" }
    Show-SysOrgPlan -Plan (Get-Content -LiteralPath $ExecutePlan -Raw | ConvertFrom-Json)
    if(-not (Confirm-SysOrg 'Execute this plan now (files will be moved)?')){ Write-Host 'Nothing was modified.'; return }
    $res = Invoke-SysOrgPlan -PlanPath $ExecutePlan -Config $Config -AppRoot $appRoot
    Write-Host ("Done. Moved={0}  Quarantined={1}  Failed={2}" -f $res.Summary.Moved, $res.Summary.Quarantined, $res.Summary.Failed)
    return
}
if($ScanDrive){
    foreach($l in $ScanDrive){
        $ll = $l.Trim().TrimEnd(':').ToUpper()
        if($ReportOnly){ Invoke-SysOrgScanFlow -Letter $ll -PreviewOnly }
        else { Invoke-SysOrgScanFlow -Letter $ll }
    }
    return
}

# ---------------- interactive menu ----------------
$running = $true
while($running){
    Write-Host ''
    Write-Host '==== SysOrg - portable file organizer (preview-first) ====' -ForegroundColor White
    Write-Host ' [1] Detect drives (type + confidence)'
    Write-Host ' [2] Scan a drive and build a plan (preview, then optional execute)'
    Write-Host ' [3] Scan a drive, report only (no plan, no changes)'
    Write-Host ' [4] Execute a saved plan file'
    Write-Host ' [5] Undo a plan (restore files to original locations)'
    Write-Host ' [6] Open working folder (plans, undo journals, logs)'
    Write-Host ' [0] Exit'
    $choice = Read-Host 'Choose'
    switch($choice){
        '1' { Get-SysOrgDrive | Format-Table Drive,Label,SizeGB,FreeGB,MediaType,BusType,Location,Confidence,DetectionBasis -AutoSize | Out-Host }
        '2' { $l = Get-SysOrgLetterInput -Prompt 'Drive letter to organize'; Invoke-SysOrgScanFlow -Letter $l }
        '3' {
              $l = Get-SysOrgLetterInput -Prompt 'Drive letter to report'
              $inv = Get-SysOrgInventory -Letter $l -Config $Config -CacheFolder $folders.Cache
              Write-Host ("Files: {0}" -f $inv.Count)
              $inv | Group-Object Category | Sort-Object Count -Descending | Format-Table Name,Count -AutoSize | Out-Host
              $dups = Find-SysOrgDuplicates -Inventory $inv -Config $Config
              Write-Host ("Duplicate groups: {0} (report only - nothing moved)" -f @($dups).Count)
            }
        '4' {
              $p = Read-Host 'Path to plan JSON'
              if(Test-Path -LiteralPath $p){
                  $res = Invoke-SysOrgPlan -PlanPath $p -Config $Config -AppRoot $appRoot
                  Write-Host ("Moved={0}  Quarantined={1}  Failed={2}" -f $res.Summary.Moved, $res.Summary.Quarantined, $res.Summary.Failed)
              } else { Write-Host 'Plan file not found.' -ForegroundColor Red }
            }
        '5' {
              $id = Read-Host 'Plan id (e.g. plan-20250714-093000)'
              $res = Undo-SysOrgPlan -PlanId $id -AppRoot $appRoot -Config $Config
              Write-Host ("Restored={0}  Failed={1}  Skipped={2}" -f $res.Restored, $res.Failed, $res.SkippedMissing)
            }
        '6' { Start-Process explorer.exe $appRoot }
        '0' { $running = $false }
        default { Write-Host 'Unknown option.' }
    }
}
