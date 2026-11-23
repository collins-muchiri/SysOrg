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
                .\SysOrg.ps1 -MigrateProfile Findable (v3.0: migrate the v2.1 layout to the Findable layout; preview first)
                .\SysOrg.ps1 -ScheduledReport        (report-only, used by Task Scheduler)
                .\SysOrg.ps1 -Benchmark              (v3.0 Phase 0: corpus + cold/warm scan, duplicates, plan, execute timings)
                .\SysOrg.ps1 -Benchmark -BenchmarkFiles 20000 -BenchmarkCorpus D:\corpus
#>
[CmdletBinding()]
param(
    [switch]$DetectDrives,
    [switch]$ProfileDrives,
    [string[]]$ScanDrive,
    [string[]]$AuditDrive,
    [string[]]$Migrate,
    [string]$MigrateProfile,
    [switch]$ReportOnly,
    [switch]$FullDrive,
    [switch]$NoCache,
    [switch]$Force,
    [string[]]$WritablePath,
    [string]$ExecutePlan,
    [string]$UndoPlan,
    [switch]$ScheduledReport,
    [string]$ConfigPath,
    [switch]$Benchmark,
    [int]$BenchmarkFiles = 100000,
    [string]$BenchmarkCorpus,
    [int]$BenchmarkSeed = 42,
    [string]$Find,
    [string]$Explain,
    [switch]$Score,
    [switch]$Learn,
    [int]$Parallelism = 0,
    [string]$Root,
    [switch]$Timing,
    [string]$SimilarFolders
)
$ErrorActionPreference = 'Stop'
$appRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRoot = Join-Path $appRoot 'Modules'
Import-Module (Join-Path $moduleRoot 'SysOrg.Core.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.KnownFolders.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Drives.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Layout.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Metadata.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Classify.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Cache.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Catalog.psm1')     -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Scan.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Plan.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Audit.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'SysOrg.Score.psm1')       -Force -DisableNameChecking

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

# v2.1.1: running elevated is unusual for a file organizer - warn prominently.
$script:SysOrgElevatedSession = $false
try { $script:SysOrgElevatedSession = [bool](Test-SysOrgElevated) } catch { $script:SysOrgElevatedSession = $false }
if($script:SysOrgElevatedSession){
    Write-Host ''
    Write-Host 'WARNING: SysOrg is running AS ADMINISTRATOR.' -ForegroundColor Red
    Write-Host '  With admin rights, moves can touch folders your user account cannot normally modify.' -ForegroundColor Yellow
    Write-Host '  Every execute or undo will additionally require typing ''yes''.' -ForegroundColor Yellow
    Write-SysOrgLog 'Session started elevated (Administrator).' -Level WARN -LogFolder $logFolder
}
# v2.1.1: when elevated, any execute or undo additionally requires typing 'yes'.
function Confirm-SysOrgElevated {
    if(-not $script:SysOrgElevatedSession){ return $true }
    return (Confirm-SysOrgStrict -Prompt 'ELEVATED SESSION: confirm this execute/undo with admin rights')
}

# v3.0.2 A1: the phase flag tells the catch-alls whether the failure happened
# BEFORE anything moved ('preview' -> "Nothing was modified.") or DURING
# execution ('execute' -> point at the undo journal). Every menu iteration
# resets it to 'preview'; flows set it to 'execute' only around mutating calls.
$script:SysOrgPhase = 'preview'

# v3.0.2 A1: one shared handler for every CLI entry point. Logs the FULL
# exception (type, message, script stack trace, invocation position) to the
# log file, prints a one-line message pointing at the log and prints the
# honest "Nothing was modified." (or the execute-phase warning).
function Invoke-SysOrgCliStep {
    param([Parameter(Mandatory)][string]$Step,[Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
    } catch {
        $logPath = Write-SysOrgErrorDiagnostic -ErrorRecord $_ -LogFolder $logFolder -Phase $script:SysOrgPhase
        if($script:SysOrgPhase -eq 'preview'){
            Write-Host ("{0} failed: {1}  Nothing was modified." -f $Step, $_.Exception.Message) -ForegroundColor Red
        } else {
            Write-Host ("{0} failed DURING EXECUTION: {1}  A partial move may have happened - the undo journal restores it." -f $Step, $_.Exception.Message) -ForegroundColor Red
        }
        if($logPath){ Write-Host ("  Full diagnostics: {0}   (run .\SysOrg.ps1 -Diagnostics for a support bundle)" -f $logPath) -ForegroundColor DarkYellow }
        else { Write-Host '  Full diagnostics: log write failed - see Logs folder permissions.' -ForegroundColor DarkYellow }
    } finally {
        $script:SysOrgPhase = 'preview'
    }
}

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
function Invoke-SysOrgReviewFlow {
<#
.SYNOPSIS
    v3.0.1 B6: the interactive review when MOST planned moves are below the review
    threshold. The plan is NOT presented as a ready-to-execute default.
.DESCRIPTION
    Offers [A] approve only confident moves (>= Classify.ReviewConfidence),
    [R] review the low-confidence moves one by one (accept / skip / set destination -
    a chosen destination is saved as a learned rule, inert until Rules.ApplyLearned),
    [S] skip all uncertain files (they stay in place), [N] cancel.
    Returns $true when a (possibly filtered) plan was saved and execution may proceed;
    $false to abort. The plan object is mutated in place (actions removed / destinations
    set) and re-saved by the caller so the integrity hash is recomputed.
#>
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$PlansFolder,$Config)
    $revConf = [double](Get-SysOrgSetting $Config 'Classify.ReviewConfidence' 0.70)
    $lowCount = 0
    foreach($a in @($Plan.Actions)){
        if("$($a.Action)" -ne 'Move'){ continue }
        if($a.PSObject.Properties['Kind'] -and "$($a.Kind)" -eq 'Folder'){ continue }
        if($a.PSObject.Properties['Confidence'] -and ($null -ne $a.Confidence) -and ([double]$a.Confidence -lt $revConf)){ $lowCount++ }
    }
    Write-Host ''
    Write-Host ('NOT READY TO EXECUTE AS-IS: {0} of the planned moves are below the review threshold ({1}).' -f $lowCount, $revConf) -ForegroundColor Yellow
    Write-Host '  [A] approve only the confident moves (confidence >= {0})' -f $revConf -ForegroundColor White
    Write-Host '  [R] review the low-confidence moves one by one (accept / skip / set destination)' -ForegroundColor White
    Write-Host '  [S] skip ALL uncertain files (they stay in place)' -ForegroundColor White
    Write-Host '  [N] cancel - nothing is modified' -ForegroundColor White
    $choice = (Read-Host 'Choice').Trim().ToUpper()
    $rulesPath = ''
    try { $rulesPath = ((Get-SysOrgDestinationRoot -Letter ("$($Plan.Drive)".TrimEnd(':')) -Config $Config) + '\_Index\LearnedRules.psd1') } catch { $rulesPath = '' }

    if($choice -eq 'A'){
        $planNew = Get-SysOrgPlanFiltered -Plan $Plan -ConfidenceFloor $revConf
        $Plan.Actions = $planNew.Actions
        Write-Host ('Approved {0} confident move(s); {1} uncertain file(s) stay in place.' -f @($Plan.Actions).Count, $lowCount) -ForegroundColor Green
        return $true
    }
    if($choice -eq 'S'){
        $planNew = Get-SysOrgPlanFiltered -Plan $Plan -ConfidenceFloor $revConf
        $Plan.Actions = $planNew.Actions
        Write-Host ('All uncertain files skipped - they stay in place. {0} confident move(s) remain.' -f @($Plan.Actions).Count) -ForegroundColor Green
        return $true
    }
    if($choice -eq 'R'){
        $kept = New-Object System.Collections.Generic.List[object]
        $lowMoves = @(@($Plan.Actions) | Where-Object {
            ("$($_.Action)" -eq 'Move') -and (-not ($_.PSObject.Properties['Kind'] -and "$($_.Kind)" -eq 'Folder')) -and
            ($_.PSObject.Properties['Confidence']) -and ($null -ne $_.Confidence) -and ([double]$_.Confidence -lt $revConf) })
        $index = 0
        foreach($a in @($Plan.Actions)){
            $isLow = $false
            if($lowMoves -contains $a){ $isLow = $true }
            if(-not $isLow){ [void]$kept.Add($a); continue }
            $index++
            Write-Host ''
            Write-Host ('[{0}/{1}] {2}' -f $index, $lowMoves.Count, $a.Source) -ForegroundColor White
            $reasonTxt = ''
            if($a.PSObject.Properties['ConfidenceReason'] -and "$($a.ConfidenceReason)"){ $reasonTxt = ('  reason: ' + $a.ConfidenceReason) }
            Write-Host ('    -> {0}   [confidence {1}]{2}' -f $a.Destination, $a.Confidence, $reasonTxt) -ForegroundColor Gray
            $sub = (Read-Host '    [a]ccept / [s]kip / [d]estination / [q]uit-cancel').Trim().ToLower()
            if($sub -eq 'a'){ [void]$kept.Add($a); continue }
            if($sub -eq 's'){ continue }
            if($sub -eq 'd'){
                $leaf = (Read-Host '    destination leaf (relative to the destination root, e.g. Documents\Work)').Trim()
                if(Test-SysOrgReviewDestinationPath -Leaf $leaf){
                    $newDest = ((($Plan.DestinationRoot).TrimEnd('\')) + '\' + ($leaf.Replace('/','\').Trim('\')) + '\' + (Split-Path $a.Source -Leaf))
                    $a.Destination = $newDest
                    $a.Reason = ('Review: you chose the destination (was: {0})' -f $a.Reason)
                    [void]$kept.Add($a)
                    # save the correction as a learned rule - inert until Rules.ApplyLearned = $true
                    if($rulesPath){
                        try{
                            $stem = [System.IO.Path]::GetFileNameWithoutExtension($a.Source)
                            $tokens = @([regex]::Matches($stem, '[A-Za-z0-9]{3,}') | ForEach-Object { "$($_.Value)" })
                            $longest = ''
                            foreach($t in $tokens){ if($t.Length -gt $longest.Length){ $longest = $t } }
                            if($longest){
                                $leafTemplate = ($leaf.Replace('/','\').Trim('\'))
                                [void](Save-SysOrgLearnedRule -Path $rulesPath -Name ('review-' + $longest.ToLower()) `
                                    -NameRegex ('(?i)' + [regex]::Escape($longest)) -Destination ($leafTemplate + '\{Year}'))
                                Write-Host '    Saved as a learned rule (applies only after Rules.ApplyLearned = $true).' -ForegroundColor DarkGray
                            }
                        } catch { Write-Host ("    Rule save failed (the move itself is kept): {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow }
                    }
                    continue
                }
                Write-Host '    Invalid destination leaf - the file is SKIPPED (stays in place).' -ForegroundColor Yellow
                continue
            }
            if($sub -eq 'q'){ Write-Host 'Review cancelled. Nothing was modified.' -ForegroundColor Yellow; return $false }
            Write-Host '    Unknown choice - the file is SKIPPED (stays in place).' -ForegroundColor Yellow
            continue
        }
        $Plan.Actions = $kept.ToArray()
        Write-Host ('Review complete: {0} move(s) remain.' -f @($Plan.Actions).Count) -ForegroundColor Green
        return $true
    }
    Write-Host 'Nothing was modified.' -ForegroundColor Yellow
    return $false
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
    # v2.1.1: reports live under the app folder (Reports\), never at a drive root.
    $repFolder = Join-Path $appRoot 'Reports'
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
    # v3.0.1 D2: on Data/Removable drives FullDrive is never the silent default -
    # the top-level folders are presented with risk labels and the choice is remembered.
    $driveRole = 'Data'
    try { $driveRole = "$((@(Get-SysOrgDrive -Letters $Letter))[0].Location)" } catch { $driveRole = 'Data' }
    $rememberedRoots = $null
    try { $rememberedRoots = Get-SysOrgUserScanRoots -Letter $Letter -AppRoot $appRoot } catch { $rememberedRoots = $null }
    if(($driveRole -ne 'Internal') -and $WholeDrive -and (-not $PreviewOnly) -and (-not $rememberedRoots)){
        $opts = @(Get-SysOrgScanRootOptions -Letter $Letter -Config $Config)
        if($opts.Count -gt 0){
            Write-Host ''
            Write-Host ("Drive {0}: is a {1} drive. FullDrive scope is NOT the default - choose what to scan:" -f $Letter, $driveRole) -ForegroundColor White
            $i = 0
            foreach($o in $opts){
                $i++
                $riskTxt = if($o.Risk){ "  [$($o.Risk)]" } else { '' }
                $defTxt = if($o.DefaultInclude){ 'Y' } else { 'n' }
                Write-Host ('  [{0}] {1}  (include? {2}){3}' -f $i, $o.Name, $defTxt, $riskTxt) -ForegroundColor $(if($o.Risk){ 'Yellow' } else { 'Gray' })
            }
            Write-Host 'Folders labeled vault/model/app/VCS/OS are EXCLUDED by default and are never moved. Enter=accept the defaults, or list folders to INCLUDE (numbers or names), or ALL:'
            $answer = Read-Host 'Selection'
            $chosen = New-Object System.Collections.Generic.List[string]
            $a = "$answer".Trim()
            if($a -ieq 'all'){
                foreach($o in $opts){ [void]$chosen.Add([string]$o.Path) }
            } elseif([string]::IsNullOrWhiteSpace($a)){
                foreach($o in $opts){ if($o.DefaultInclude){ [void]$chosen.Add([string]$o.Path) } }
            } else {
                $tokens = @($a.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                foreach($t in $tokens){
                    if($t -match '^\d+$'){
                        $idx = [int]$t
                        if($idx -ge 1 -and $idx -le $opts.Count){ [void]$chosen.Add([string]$opts[$idx-1].Path) }
                    } else {
                        $match = @($opts | Where-Object { $_.Name -ieq $t })
                        if($match.Count -gt 0){ [void]$chosen.Add([string]$match[0].Path) }
                    }
                }
            }
            if($chosen.Count -gt 0){
                $null = Save-SysOrgUserScanRoots -Letter $Letter -Roots $chosen.ToArray() -AppRoot $appRoot
                Write-Host ("Scan roots for drive {0}: saved ({1} folder(s)). Future scans reuse this choice until you change it." -f $Letter, $chosen.Count) -ForegroundColor Green
                $rootsOverride = $chosen.ToArray()
            } else {
                Write-Host 'Nothing selected - nothing was scanned and nothing was modified.' -ForegroundColor Yellow
                return
            }
        }
    }
    elseif($rememberedRoots -and (@($rememberedRoots).Count -gt 0) -and $WholeDrive){
        # v3.0.2 A2: remembered scan roots are USED, not only remembered - before this
        # fix they merely suppressed the picker prompt while the walk re-resolved the
        # scope from the config, silently scanning folders the user had deselected.
        $rootsOverride = @(@($rememberedRoots) | ForEach-Object { "$_" })
    }
    # v3.0.1 C1: per-phase wall times behind -Timing (profile-first speed work)
    $phaseTimings = @{}
    function Get-SysOrgPhaseStart { param([string]$Phase)
        if(-not $Timing){ return $null }
        return [System.Diagnostics.Stopwatch]::StartNew()
    }
    function Stop-SysOrgPhase { param($Sw,[string]$Phase)
        if($null -eq $Sw){ return }
        $Sw.Stop()
        $phaseTimings[$Phase] = [Math]::Round($Sw.Elapsed.TotalSeconds, 2)
    }
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
    # v3.0.1 C2: the walk itself detects projects and prunes dependency dirs
    $walkProjects = New-Object System.Collections.Generic.List[object]
    $walkPreserved = New-Object System.Collections.Generic.List[object]
    # v3.0.1 D2: remembered scan roots win over everything for Data/Removable drives
    if($rootsOverride -and @($rootsOverride).Count -gt 0){
        $rootsInfo = [pscustomobject]@{ Scope='custom'; Initial=@($rootsOverride) }
    } else {
        $rootsInfo = Get-SysOrgScanRoots -Letter $Letter -Config $Config -DefaultScope:(-not $WholeDrive) -KnownFolders @($prof.KnownFolders)
    }
    $cacheStats = @{}
    $invParams = @{ Letter=$Letter; Config=$Config; CacheFolder=$folders.Cache; AuditTrail=$trail; KnownFolders=@($prof.KnownFolders); ProjectFoldersOut=$walkProjects; PreservedOut=$walkPreserved; CacheStatsOut=$cacheStats }
    if($NoCacheSwitch){ $invParams.NoCache = $true }
    if(-not $WholeDrive){ $invParams.DefaultScope = $true }
    # v3.0.2 A2: a user-chosen scope (picker choice or remembered roots) must reach
    # the WALK - previously the walk re-resolved roots from the config and scanned
    # folders the user had deselected. Default-scope and FullDrive runs keep the
    # inventory's own resolution so their cache keys and behaviour are unchanged.
    if($rootsOverride -and @($rootsOverride).Count -gt 0){
        $invParams.Roots = @(@($rootsOverride) | ForEach-Object { "$_" })
    }
    # @() collect: the inventory streams records (empty scan emits nothing)
    $swEnum = Get-SysOrgPhaseStart -Phase 'enumerate'
    $inv = @(Get-SysOrgInventory @invParams)
    Stop-SysOrgPhase $swEnum 'enumerate'
    # v3.0.1 C3: the preview states the cache age and how many files changed
    if($cacheStats.FromCache){
        Write-Host ("Inventory cache: age {0}h - {1} file(s) reused, {2} changed since the last scan." -f $cacheStats.AgeHours, $cacheStats.Reused, $cacheStats.Changed) -ForegroundColor DarkGray
    }
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
    if($Timing){
        $summary = Get-SysOrgTimingSummary -Timings $phaseTimings
        if($summary){
            Write-Host ''
            Write-Host $summary -ForegroundColor Cyan
        }
    }
    Write-Host ''
    Write-Host 'By routing category:' -ForegroundColor White
    $inv | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ('  {0,-15} {1}' -f $_.Name, $_.Count)
    }
    Write-Host ''
    Write-SysOrgLog 'Detecting duplicates (hashes candidate files; can take a while)...' -LogFolder $logFolder
    # v3.0 Phase 3.1/3.4/3.5: the persistent file-state cache + parallel hashing
    $cachePath = Join-Path $folders.Cache 'filestate.ndjson'
    $cacheLoad = Read-SysOrgFileStateCache -Path $cachePath
    $fileCache = $cacheLoad.Entries
    if($cacheLoad.Corrupted){ Write-Warning 'The file-state cache was corrupted - falling back to a full rescan (nothing was harmed).' }
    $newCacheEntries = @{}
    $par = Get-SysOrgParallelism -Config $Config -DriveProfile $prof
    if($Parallelism -gt 0){ $par = $Parallelism }
    $swDups = Get-SysOrgPhaseStart -Phase 'duplicates'
    $dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $Config -FileCache $fileCache -NewEntries $newCacheEntries -Parallelism $par)
    Stop-SysOrgPhase $swDups 'duplicates'
    Write-Host ("Duplicate groups found: {0}" -f @($dups).Count)
    # v3.0.1 B5: re-download version pairs - report-only, never moved
    $versionPairs = @(Get-SysOrgVersionPairs -Inventory $inv -Config $Config -DupGroups $dups -FileCache $fileCache -NewEntries $newCacheEntries)[0]
    if($versionPairs -and @($versionPairs.Versions).Count -gt 0){
        Write-Host ("Possible newer-version pairs (report only): {0}" -f @($versionPairs.Versions).Count) -ForegroundColor Yellow
    }
    # v3.0.1 C2: projects come from the walk when pruning is enabled; the standalone
    # walk stays as the fallback for Prune.Enabled=$false
    if([bool](Get-SysOrgSetting $Config 'Prune.Enabled' $true)){
        $projects = @($walkProjects.ToArray())
    } else {
        $projects = @(Get-SysOrgProjectFolders -Roots @($rootsInfo.Initial) -Config $Config -DriveProfile $prof -KnownFolders @($prof.KnownFolders))
    }
    if(@($projects).Count -gt 0){ Write-Host ("Code project folders detected: {0} (moved whole, .git intact)" -f @($projects).Count) }
    # v3.0.2 A2: THE PLAN-BUILD CRASH FIX. $walkPreserved is a New-Object-created
    # System.Collections.Generic.List[object] that the walk fills through the
    # PreservedOut out-parameter. Collecting it with @() hits the PowerShell
    # engine's PSToObjectArrayBinder -> PSEnumerableBinder.MaybeDebase, which
    # builds an Expression.Condition with mismatched branch types and throws
    # 'ArgumentException: Argument types do not match' - exactly the option-3
    # crash observed on the real Windows run (the line only executes when the
    # walk preserved at least one dependency/project folder, which is why a run
    # with 0 projects and 0 duplicates built a plan fine). Normalize with
    # .ToArray() FIRST - the same pattern the v2.1.1 CI leg established for
    # New-SysOrgPlan, Get-SysOrgNameFamilies and the multipart sets.
    $walkPreservedItems = $walkPreserved.ToArray()
    if($walkPreservedItems.Count -gt 0){
        $depCount = @($walkPreservedItems | Where-Object { $_.Kind -eq 'Dependency' }).Count
        $projCount = @($walkPreservedItems | Where-Object { $_.Kind -eq 'Project' }).Count
        Write-Host ("Preserved without enumeration: {0} dependency folder(s), {1} project folder(s)" -f $depCount, $projCount) -ForegroundColor DarkGray
    }
    # v3.0.1 D4: the app folder itself inside a scan root - recommend moving it
    if(Test-SysOrgAppUnderScanRoot -AppRoot $appRoot -ScanRoots @($rootsInfo.Initial)){
        Write-Host ("WARNING: the SysOrg app folder ({0}) sits INSIDE a scanned root." -f $appRoot) -ForegroundColor Yellow
        Write-Host '  It stays fully protected (never scanned, never moved), but we recommend moving it out of the scanned tree - e.g. to the drive root or a tools folder.' -ForegroundColor Yellow
    }
    # v3.0.1 B2: user collections - user-named folders inside the scan roots move as
    # ONE unit (structure intact), chosen by the majority classification of contents.
    $collections = @(Get-SysOrgUserCollections -Inventory $inv -Roots @($rootsInfo.Initial) -Config $Config -KnownFolders @($prof.KnownFolders))
    if(@($collections).Count -gt 0){ Write-Host ("User collections detected: {0} (each moves whole, never flattened)" -f @($collections).Count) }
    $swPlan = Get-SysOrgPhaseStart -Phase 'plan'
    # v3.0.1 D1: re-running an identical scan (same inputs) reuses the existing plan
    # instead of building a duplicate - compared via an input fingerprint.
    $inputFingerprint = Get-SysOrgPlanInputFingerprint -Letter $Letter -Inventory $inv -Config $Config -DriveProfile $prof
    $reusePlanPath = $null
    if([bool](Get-SysOrgSetting $Config 'Plans.ReuseIdentical' $true)){
        $plansDirNow = $folders.Plans
        foreach($pf in @(Get-ChildItem -LiteralPath $plansDirNow -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 30)){
            try{
                $pp = Get-Content -LiteralPath $pf.FullName -Raw | ConvertFrom-Json
                if($pp.PSObject.Properties['InputFingerprint'] -and "$($pp.InputFingerprint)" -eq $inputFingerprint){
                    $alreadyExecuted = (Test-Path -LiteralPath (Join-Path $folders.Undo ("undo-{0}.csv" -f $pp.PlanId)))
                    if(-not $alreadyExecuted){
                        $reusePlanPath = $pf.FullName
                        $plan = $pp
                        break
                    }
                }
            } catch { continue }
        }
    }
    if($reusePlanPath){
        Write-Host ("Reusing existing plan {0} (identical scan inputs - nothing was re-planned)." -f $plan.PlanId) -ForegroundColor Cyan
    } else {
        $plan = New-SysOrgPlan -Letter $Letter -Inventory $inv -DriveProfile $prof -DupGroups $dups -Config $Config -KnownFolders @($prof.KnownFolders) -ProjectFolders $projects -UserCollections $collections -VersionPairs $versionPairs -FileCache $fileCache -NewCacheEntries $newCacheEntries
    }
    Stop-SysOrgPhase $swPlan 'plan'
    # persist the updated file-state cache (best effort - it is a performance cache)
    foreach($k in @($newCacheEntries.Keys)){ $fileCache[$k] = $newCacheEntries[$k] }
    $null = Save-SysOrgFileStateCache -Path $cachePath -Entries $fileCache
    if($plan.PSObject.Properties['InputFingerprint']){
        $plan.InputFingerprint = $inputFingerprint
    } else {
        [void]($plan | Add-Member -NotePropertyName InputFingerprint -NotePropertyValue $inputFingerprint)
    }
    $sum = Show-SysOrgPlan -Plan $plan -Config $Config
    # v3.0 Phase 5: before/after findability score in the preview.
    # v3.0.1 A2: the full inventory is passed so before/after are scored over the SAME
    # population (untouched + moved) - a moved-files-only 'after' can never distort the verdict.
    $scoreDelta = $null
    try { $scoreDelta = Get-SysOrgPlanScoreDelta -Plan $plan -Config $Config -Root $plan.DestinationRoot -Inventory $inv } catch { $scoreDelta = $null }
    if($scoreDelta){ Show-SysOrgScoreDelta -Delta $scoreDelta }
    $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $folders.Plans
    Write-Host ("Plan saved: {0}" -f $planPath) -ForegroundColor Green
    # v3.0.1 B6: when more than half of the planned moves are below the review
    # threshold the plan is NOT a ready-to-execute default - run the review flow
    # ([A] approve confident / [R] one by one / [S] skip uncertain / [N] cancel).
    if(Test-SysOrgPlanNeedsReview -Plan $plan -Config $Config){
        if(-not (Invoke-SysOrgReviewFlow -Plan $plan -PlansFolder $folders.Plans -Config $Config)){
            return
        }
        # re-save: the review may have filtered actions or set destinations - the
        # integrity hash must cover exactly what will execute
        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $folders.Plans
        Write-Host ("Plan updated after review: {0}" -f $planPath) -ForegroundColor Green
    }
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
    # v2.1.1: elevated sessions must type 'yes' before any execute.
    if(-not (Confirm-SysOrgElevated)){
        Write-Host 'Elevated confirmation declined. Nothing was modified.' -ForegroundColor Yellow
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
    # v3.0.2 A1: from here on a failure means moves may have happened
    $script:SysOrgPhase = 'execute'
    $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $Config -AppRoot $appRoot
    $script:SysOrgPhase = 'preview'
    Write-Host ''
    Write-Host ("Done. Moved={0} (numbered copies={1})  Copied={2}  Folders={3}  Quarantined={4}  Failed={5}" -f `
        $res.Summary.Moved, $res.Summary.Numbered, $res.Summary.Copied, $res.Summary.FolderMoves, $res.Summary.Quarantined, $res.Summary.Failed) -ForegroundColor Green
    Write-Host ("Undo journal: {0}" -f $res.UndoFile)
    # v3.0 Phase 4: catalog + offline index after every executed plan
    $catPath = Update-SysOrgCatalog -PlanPath $planPath -UndoPath $res.UndoFile -Root $plan.DestinationRoot -PlanId $plan.PlanId
    if($catPath){
        Write-Host ("Catalog updated: {0}" -f $catPath) -ForegroundColor Green
        $html = Save-SysOrgIndexPage -Root $plan.DestinationRoot
        $rme = Save-SysOrgIndexReadme -Root $plan.DestinationRoot
        Write-Host ("Offline index: {0}" -f $html) -ForegroundColor Green
        $si = Test-SysOrgSearchIndexStatus -Root $plan.DestinationRoot
        if($si.Status -ne 'Ok'){ Write-Warning ('Windows Search: ' + $si.Reason) }
    }
}
function Invoke-SysOrgMigrationFlow {
    param([string]$Letter,[string]$TargetProfile)
    if($TargetProfile){
        # v3.0 Phase 6: layout migration (v2.1 tree -> Findable), preview-first
        Write-SysOrgLog "Building layout migration preview for drive $Letter`: ..." -LogFolder $logFolder
        try{
            $plan = New-SysOrgLayoutMigrationPlan -Letter $Letter -Config $Config -TargetProfile $TargetProfile
        } catch {
            Write-Host ("Layout migration: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            return
        }
        [void](Show-SysOrgPlan -Plan $plan -Config $Config)
        if(@($plan.Actions).Count -eq 0){
            Write-Host 'Everything is already in its Findable place - nothing to migrate. Nothing was modified.' -ForegroundColor Yellow
            return
        }
        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $folders.Plans
        Write-Host ("Migration plan saved: {0}" -f $planPath) -ForegroundColor Green
        if(-not (Confirm-SysOrg 'Apply this layout migration now (whole folders move where possible; fully journaled)?')){
            Write-Host 'Migration NOT applied. Nothing was modified.' -ForegroundColor Yellow
            return
        }
        if(-not (Confirm-SysOrgElevated)){
            Write-Host 'Elevated confirmation declined. Nothing was modified.' -ForegroundColor Yellow
            return
        }
        # v3.0.2 A1: from here on a failure means moves may have happened
        $script:SysOrgPhase = 'execute'
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $Config -AppRoot $appRoot
        $script:SysOrgPhase = 'preview'
        Write-Host ''
        Write-Host ("Layout migration done. Moved={0}  Folders={1}  Failed={2}" -f $res.Summary.Moved, $res.Summary.FolderMoves, $res.Summary.Failed) -ForegroundColor Green
        Write-Host ("Undo journal: {0}" -f $res.UndoFile)
        $catPath = Update-SysOrgCatalog -PlanPath $planPath -UndoPath $res.UndoFile -Root $plan.DestinationRoot -PlanId $plan.PlanId
        if($catPath){
            Write-Host ("Catalog updated: {0}" -f $catPath) -ForegroundColor Green
            $html = Save-SysOrgIndexPage -Root $plan.DestinationRoot
            $null = Save-SysOrgIndexReadme -Root $plan.DestinationRoot
            Write-Host ("Offline index: {0}" -f $html) -ForegroundColor Green
        }
        return
    }
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
    # v2.1.1: elevated sessions must type 'yes' before any execute.
    if(-not (Confirm-SysOrgElevated)){
        Write-Host 'Elevated confirmation declined. Nothing was modified.' -ForegroundColor Yellow
        return
    }
    # v3.0.2 A1: from here on a failure means moves may have happened
    $script:SysOrgPhase = 'execute'
    $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $Config -AppRoot $appRoot
    $script:SysOrgPhase = 'preview'
    Write-Host ''
    Write-Host ("Migration done. Moved={0}  Folders={1}  Failed={2}" -f $res.Summary.Moved, $res.Summary.FolderMoves, $res.Summary.Failed) -ForegroundColor Green
    Write-Host ("Undo journal: {0}" -f $res.UndoFile)
}
function Invoke-SysOrgPlanFile {
    <# Shared preview -> confirm -> execute path (P1-2). Used by CLI and menu option 5. #>
    param([Parameter(Mandatory)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path)){ Write-Host 'Plan file not found.' -ForegroundColor Red; return }
    $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if($plan.PSObject.Properties['InputFingerprint']){
        $plan.InputFingerprint = $inputFingerprint
    } else {
        [void]($plan | Add-Member -NotePropertyName InputFingerprint -NotePropertyValue $inputFingerprint)
    }
    $sum = Show-SysOrgPlan -Plan $plan -Config $Config
    $prompt = 'Execute this plan now (files will be moved)?'
    if($sum.OneDriveSyncOut -gt 0){
        $prompt = ('Execute this plan now? {0} file(s) will be moved OUT of OneDrive sync (removed from the cloud).' -f $sum.OneDriveSyncOut)
    }
    if(-not (Confirm-SysOrg -Prompt $prompt)){
        Write-Host 'Nothing was modified.' -ForegroundColor Yellow; return
    }
    # v2.1.1: elevated sessions must type 'yes' before any execute.
    if(-not (Confirm-SysOrgElevated)){
        Write-Host 'Elevated confirmation declined. Nothing was modified.' -ForegroundColor Yellow; return
    }
    if($plan.PSObject.Properties['DestinationStyle'] -and "$($plan.DestinationStyle)" -eq 'KnownFolders'){
        if(-not (Confirm-SysOrgStrict -Prompt 'Second confirmation: files will be filed into your real known folders (Documents/Pictures/...)')){
            Write-Host 'Second confirmation declined. Nothing was modified.' -ForegroundColor Yellow; return
        }
    }
    # v3.0.2 A1: from here on a failure means moves may have happened
    $script:SysOrgPhase = 'execute'
    $res = Invoke-SysOrgPlan -PlanPath $Path -Config $Config -AppRoot $appRoot -Force:$Force
    $script:SysOrgPhase = 'preview'
    Write-Host ("Done. Moved={0} (numbered copies={1})  Copied={2}  Folders={3}  Quarantined={4}  Failed={5}" -f `
        $res.Summary.Moved, $res.Summary.Numbered, $res.Summary.Copied, $res.Summary.FolderMoves, $res.Summary.Quarantined, $res.Summary.Failed) -ForegroundColor Green
    Write-Host ("Undo journal: {0}" -f $res.UndoFile)
    # v3.0 Phase 4: catalog + offline index after every executed plan
    if($plan.PSObject.Properties['DestinationRoot'] -and $plan.PSObject.Properties['PlanId']){
        $catPath = Update-SysOrgCatalog -PlanPath $Path -UndoPath $res.UndoFile -Root $plan.DestinationRoot -PlanId $plan.PlanId
        if($catPath){
            Write-Host ("Catalog updated: {0}" -f $catPath) -ForegroundColor Green
            $html = Save-SysOrgIndexPage -Root $plan.DestinationRoot
            $null = Save-SysOrgIndexReadme -Root $plan.DestinationRoot
            Write-Host ("Offline index: {0}" -f $html) -ForegroundColor Green
            $si = Test-SysOrgSearchIndexStatus -Root $plan.DestinationRoot
            if($si.Status -ne 'Ok'){ Write-Warning ('Windows Search: ' + $si.Reason) }
        }
    }
}

function Invoke-SysOrgBenchmarkFlow {
<#
.SYNOPSIS
    v3.0 Phase 0: measures cold scan, warm scan, duplicate detection, plan build and
    execute on the synthetic corpus and writes a benchmark report.
.DESCRIPTION
    Never prompts and never touches anything inside the corpus except the generated
    '_Organized' and '_SysOrgApp' subfolders (destination root + app folders for the
    benchmark session). The report lands in <AppRoot>\Reports\benchmark-<stamp>.md.
    Peak memory is the process-wide PeakWorkingSet64 sampled after each step (cumulative
    by nature of the OS counter; documented in BENCHMARKS.md).
#>
    param([string]$Corpus,[int]$Files,[int]$BenchSeed)
    if(-not $Corpus){ $Corpus = Join-Path $appRoot 'BenchmarkCorpus' }
    $Corpus = [System.IO.Path]::GetFullPath($Corpus)
    $gen = Join-Path $appRoot 'Tools\New-SysOrgCorpus.ps1'
    $results = New-Object System.Collections.Generic.List[object]
    function Measure-SysOrgBenchStep {
        # Runs $Step once and records wall time + process peak working set.
        param([string]$Name,[scriptblock]$Step)
        $t = Measure-Command $Step
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        try { $proc.Refresh() } catch { }
        $r = [pscustomobject]@{ Step=$Name; Seconds=[math]::Round($t.TotalSeconds,3); PeakWorkingSetMB=[math]::Round($proc.PeakWorkingSet64/1MB,1) }
        Write-Host ("  {0,-22} {1,8:N3} s   (peak WS {2} MB)" -f $r.Step, $r.Seconds, $r.PeakWorkingSetMB)
        return $r
    }

    Write-Host '=== SysOrg benchmark (v3.0 Phase 0) ===' -ForegroundColor White
    if(-not (Test-Path -LiteralPath $Corpus)){
        Write-Host ("Generating corpus ({0} files, seed {1}) ..." -f $Files, $BenchSeed)
        $results.Add((Measure-SysOrgBenchStep -Name 'corpus-generate' -Step { & $gen -Root $Corpus -FileCount $Files -Seed $BenchSeed -Clean }))
    }

    # benchmark-session config: destinations live under the corpus, no action cap
    $benchCfg = @{} + $Config
    $benchCfg.OrganizedRoots = @{ '*' = (Join-Path $Corpus '_Organized') }
    $benchCfg.MaxPlanActions = 1000000
    $benchApp = Join-Path $Corpus '_SysOrgApp'
    if(-not (Test-Path -LiteralPath $benchApp)){ New-Item -ItemType Directory -Path $benchApp -Force | Out-Null }

    # drive profile: real on Windows, a synthetic Data profile on portable hosts
    $prof = $null
    try { $prof = @(Get-SysOrgDriveProfile -Config $benchCfg -Letters 'C')[0] } catch { $prof = $null }
    if(-not $prof){
        $prof = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='Data'; Drive=$null; Artifacts=@(); KnownFolders=@();
                                   DownloadRoots=@(); TopLevelDirs=@(); ProposedScope='FullDrive';
                                   DestinationRoot=(Get-SysOrgDestinationRoot -Letter 'C' -Config $benchCfg) }
        Write-Host 'No real drive profile available (portable host) - using a synthetic Data profile.' -ForegroundColor Yellow
    }

    Write-Host 'Measuring...' -ForegroundColor White
    $inv = $null
    $results.Add((Measure-SysOrgBenchStep -Name 'cold-scan' -Step { $script:BenchInv = @(Get-SysOrgInventory -Letter 'C' -Config $benchCfg -Roots @($Corpus) -NoCache) }))
    $inv = $script:BenchInv
    # refresh the JSON cache once, then measure the cached (warm) read
    $null = Get-SysOrgInventory -Letter 'C' -Config $benchCfg -Roots @($Corpus) -CacheFolder $benchApp\Cache
    $results.Add((Measure-SysOrgBenchStep -Name 'warm-scan' -Step { $script:BenchInv2 = @(Get-SysOrgInventory -Letter 'C' -Config $benchCfg -Roots @($Corpus) -CacheFolder $benchApp\Cache) }))
    $dups = @()
    # v3.0: the file-state cache lives with the benchmark app folder
    $benchCachePath = Join-Path (Join-Path $benchApp 'Cache') 'filestate.ndjson'
    $cacheLoad = Read-SysOrgFileStateCache -Path $benchCachePath
    $fileCache = $cacheLoad.Entries
    $newCacheEntries = @{}
    $par = Get-SysOrgParallelism -Config $benchCfg -DriveProfile $prof
    $results.Add((Measure-SysOrgBenchStep -Name 'duplicate-detect' -Step { $script:BenchDups = @(Find-SysOrgDuplicates -Inventory $inv -Config $benchCfg -FileCache $fileCache -NewEntries $newCacheEntries -Parallelism $par) }))
    $dups = $script:BenchDups
    $plan = $null
    $results.Add((Measure-SysOrgBenchStep -Name 'plan-build' -Step { $script:BenchPlan = New-SysOrgPlan -Letter 'C' -Inventory $inv -DriveProfile $prof -DupGroups $dups -Config $benchCfg -FileCache $fileCache -NewCacheEntries $newCacheEntries }))
    $plan = $script:BenchPlan
    foreach($k in @($newCacheEntries.Keys)){ $fileCache[$k] = $newCacheEntries[$k] }
    $null = Save-SysOrgFileStateCache -Path $benchCachePath -Entries $fileCache
    $res = $null
    $results.Add((Measure-SysOrgBenchStep -Name 'execute-plan' -Step {
        $script:BenchPlanPath = Save-SysOrgPlan -Plan $plan -PlansFolder (Join-Path $benchApp 'Plans')
        $script:BenchExec = Invoke-SysOrgPlan -PlanPath $script:BenchPlanPath -Config $benchCfg -AppRoot $benchApp
    }))

    $res = $script:BenchExec
    Write-Host ''
    Write-Host ("Inventory: {0} files   Duplicate groups: {1}   Plan actions: {2}" -f @($inv).Count, @($dups).Count, @($plan.Actions).Count)
    if($res){ Write-Host ("Executed: moved={0} copied={1} failed={2}" -f $res.Summary.Moved, $res.Summary.Copied, $res.Summary.Failed) }

    # markdown report under <AppRoot>\Reports
    $repFolder = Join-Path $appRoot 'Reports'
    if(-not (Test-Path -LiteralPath $repFolder)){ New-Item -ItemType Directory -Path $repFolder -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $repPath = Join-Path $repFolder ('benchmark-{0}.md' -f $stamp)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# SysOrg benchmark report')
    [void]$lines.Add('')
    [void]$lines.Add(('- Date: {0}' -f (Get-Date -Format s)))
    $hostOs = 'portable host'
    if($env:OS){ $hostOs = $env:OS }
    [void]$lines.Add(('- Host: {0} ({1})' -f $env:COMPUTERNAME, $hostOs))
    [void]$lines.Add(('- PSVersion: {0}' -f $PSVersionTable.PSVersion))
    [void]$lines.Add(('- Corpus: {0} ({1} files configured, seed {2})' -f $Corpus, $Files, $BenchSeed))
    [void]$lines.Add(('- Inventory: {0} files, duplicate groups: {1}, plan actions: {2}' -f @($inv).Count, @($dups).Count, @($plan.Actions).Count))
    [void]$lines.Add('')
    [void]$lines.Add('| Step | Seconds | Peak WS (MB) |')
    [void]$lines.Add('|------|---------|--------------|')
    foreach($r in $results){ [void]$lines.Add(('| {0} | {1} | {2} |' -f $r.Step, $r.Seconds, $r.PeakWorkingSetMB)) }
    [void]$lines.Add('')
    [System.IO.File]::WriteAllLines($repPath, $lines)
    Write-Host ("Benchmark report saved: {0}" -f $repPath) -ForegroundColor Green
}

# ---------------- non-interactive modes ----------------
# v3.0.2 A1: every CLI entry point runs through Invoke-SysOrgCliStep so a
# terminating error produces a FULL diagnostic log (type, message, script stack
# trace, invocation position), a one-line user message pointing at the log and
# the honest "Nothing was modified." - never a raw red stack dump.
if($ProfileDrives){
    Invoke-SysOrgCliStep -Step 'Drive profiling' -Action { [void](Invoke-SysOrgProfileFlow -Letters $null) }
    return
}
if($DetectDrives){
    Invoke-SysOrgCliStep -Step 'Drive detection' -Action {
        $drives = @(Get-SysOrgDrive)
        $drives | Format-Table Drive,Label,FileSystem,SizeGB,FreeGB,MediaType,BusType,Location,Confidence,DetectionBasis -AutoSize | Out-Host
        foreach($d in $drives){
            Write-SysOrgLog ("Drive {0} [{1} / {2} / {3}] confidence={4}: {5}" -f $d.Drive,$d.MediaType,$d.BusType,$d.Location,$d.Confidence,$d.DetectionBasis) -LogFolder $logFolder
        }
    }
    return
}
if($ScheduledReport){
    Invoke-SysOrgCliStep -Step 'Scheduled report' -Action {
        # P0-4: Get-SysOrgDrive exposes the letter as 'Drive' (formatted 'C:'), not 'Letter'
        $letters = @(Get-SysOrgSetting $Config 'ScheduledDrives' @('*'))
        foreach($d in @(Get-SysOrgDrive)){
            $letter = $d.Drive.TrimEnd(':')
            if(($letters -contains '*') -or ($letters -contains $letter)){
                # v2.1.1: the '*' default covers fixed, NON-REMOVABLE drives only - no scheduled
                # reports for USB sticks or card readers. Explicitly listed letters are honored.
                if(($letters -contains '*') -and ("$($d.Location)" -ne 'Internal')){ continue }
                try {
                    [void](New-SysOrgScanReport -Letter $letter -Config $Config -AppRoot $appRoot)
                } catch {
                    Write-SysOrgLog "Scheduled report failed for $letter`: $($_.Exception.Message)" -Level ERROR -LogFolder $logFolder
                }
            }
        }
    }
    return
}
if($AuditDrive){
    Invoke-SysOrgCliStep -Step 'Folder audit' -Action {
        foreach($l in $AuditDrive){
            $ll = $l.Trim().TrimEnd(':').ToUpper()
            Invoke-SysOrgFolderAuditFlow -Letter $ll
        }
    }
    return
}
if($Benchmark){
    Invoke-SysOrgCliStep -Step 'Benchmark' -Action { Invoke-SysOrgBenchmarkFlow -Corpus $BenchmarkCorpus -Files $BenchmarkFiles -BenchSeed $BenchmarkSeed }
    return
}
if($Score){
    Invoke-SysOrgCliStep -Step 'Findability score' -Action {
        # v3.0 Phase 5: score an existing organized tree and check it against the targets
        $scoreRoot = $null
        if($Root){ $scoreRoot = $Root }
        else {
            $scoreLetter = if($ScanDrive -and @($ScanDrive).Count -gt 0){ ($ScanDrive[0].Trim().TrimEnd(':').ToUpper()) } else { 'C' }
            try { $scoreRoot = Get-SysOrgDestinationRoot -Letter $scoreLetter -Config $Config } catch { $scoreRoot = ('{0}:\_Organized' -f $scoreLetter) }
        }
        $s = Get-SysOrgTreeScore -Root $scoreRoot -Config $Config
        if($s.Files -eq 0){
            # v3.0.1 D5: an empty tree is not a score
            Write-Host ''
            Write-Host 'No organized tree yet.' -ForegroundColor Yellow
            Write-Host ('  Nothing has been organized into {0} so far. Run -ScanDrive with execute to fill it.' -f $scoreRoot) -ForegroundColor Gray
            return
        }
        Show-SysOrgFindabilityScore -Score $s -Label ('organized tree ' + $scoreRoot) -Config $Config -WithTargets
    }
    return
}
if($SimilarFolders){
    Invoke-SysOrgCliStep -Step 'Similar-folder report' -Action {
        # v3.0.1 D3: similar-folder report - fingerprint folders by their file-hash sets,
        # list pairs with >= 80% overlap. REPORT ONLY: nothing is ever moved or merged.
        $sfRoot = $SimilarFolders
        if(-not (Test-Path -LiteralPath $sfRoot)){ Write-Host ("Folder not found: {0}" -f $sfRoot) -ForegroundColor Red; return }
        Write-Host ("Fingerprinting folders under {0} (report only - nothing moves) ..." -f $sfRoot) -ForegroundColor White
        $rep = Get-SysOrgSimilarFolders -Roots @($sfRoot) -Config $Config
        Write-Host ("Folders fingerprinted: {0}   similar pairs (>= {1}): {2}" -f $rep.FoldersCompared, 0.80, @($rep.Pairs).Count) -ForegroundColor White
        foreach($p2 in ($rep.Pairs | Select-Object -First 20)){
            Write-Host ('  {0}  ({1} file(s), {2}, {3})' -f $p2.FolderA, $p2.FilesA, (Format-SysOrgFileSize $p2.BytesA), $p2.LastWriteA) -ForegroundColor Gray
            Write-Host ('  {0}  ({1} file(s), {2}, {3})' -f $p2.FolderB, $p2.FilesB, (Format-SysOrgFileSize $p2.BytesB), $p2.LastWriteB) -ForegroundColor Gray
            Write-Host ('    overlap {0} ({1} identical file(s)) - decide yourself which copy to keep; SysOrg never merges.' -f $p2.Overlap, $p2.Common) -ForegroundColor Yellow
        }
        if(@($rep.Pairs).Count -eq 0){ Write-Host 'No similar folder pairs found.' -ForegroundColor Gray }
    }
    return
}
if($Learn){
    Invoke-SysOrgCliStep -Step 'Learn' -Action {
        # v3.0.1 B3: build (or refresh) the self-supervised model from the user's own
        # curated folders and print what it learned and the labels it trusts.
        $learnRoot = $null
        if($Root){ $learnRoot = $Root }
        else {
            $learnLetter = if($ScanDrive -and @($ScanDrive).Count -gt 0){ ($ScanDrive[0].Trim().TrimEnd(':').ToUpper()) } else { 'C' }
            try { $learnRoot = Get-SysOrgDestinationRoot -Letter $learnLetter -Config $Config } catch { $learnRoot = ('{0}:\_Organized' -f $learnLetter) }
        }
        Write-Host ("Building the learn model from your own folder structure (model: {0}\_Index\model.json) ..." -f $learnRoot) -ForegroundColor White
        try { $lm = New-SysOrgLearnModel -Config $Config -DestinationRoot $learnRoot }
        catch { Write-Host ("Learn failed: {0}" -f $_.Exception.Message) -ForegroundColor Red; return }
        if($lm -and $lm.Model){
            $minFiles = [int](Get-SysOrgSetting $Config 'Learn.MinFilesPerLabel' 5)
            $labelNames = @(Get-SysOrgLearnLabelNames -Model $lm.Model)
            Write-Host ("Learned {0} trusted label(s):" -f $labelNames.Count) -ForegroundColor Green
            foreach($ll in $labelNames){
                $L = Get-SysOrgLearnLabel -Model $lm.Model -Name $ll
                $topTokens = @()
                if($L.Tokens -is [hashtable] -or $L.Tokens -is [System.Collections.Specialized.OrderedDictionary]){
                    $topTokens = @($L.Tokens.Keys | Sort-Object { -[int]$L.Tokens[$_] }, { $_ } | Select-Object -First 8)
                }
                else { $topTokens = @($L.Tokens.PSObject.Properties | Sort-Object { -[int]$_.Value }, { $_.Name } | Select-Object -First 8 | ForEach-Object { $_.Name }) }
                $trust = 'trusted'
                if([int]$L.Files -lt $minFiles){ $trust = 'NOT trusted (too few files)' }
                Write-Host ("  {0}: {1} training file(s) [{2}]" -f $ll, $L.Files, $trust)
                Write-Host ("    top signals: {0}" -f ($topTokens -join ', ')) -ForegroundColor Gray
            }
            Write-Host ("Model fingerprint {0} ({1})." -f $lm.Fingerprint.Substring(0,12), $(if($lm.Rebuilt){ 'rebuilt' } else { 'unchanged - reused' })) -ForegroundColor Gray
            Write-Host 'The model never moves anything by itself - it sharpens confidence and appears in -Explain.' -ForegroundColor DarkGray
        }
        else {
            Write-Host 'No trusted labels yet: the model needs folders with at least 5 files each' -ForegroundColor Yellow
            Write-Host '(e.g. existing subfolders of Documents like Documents\Work or Documents\Personal).' -ForegroundColor Yellow
        }
    }
    return
}
if($PSBoundParameters.ContainsKey('Find')){
    Invoke-SysOrgCliStep -Step 'Find' -Action {
        # v3.0 Phase 4.2: instant search over the catalog (falls back to a live scan)
        if([string]::IsNullOrWhiteSpace($Find)){ $Find = '*' }
        $findRoot = $null
        if($Root){ $findRoot = $Root }
        else {
            $findLetter = if($ScanDrive -and @($ScanDrive).Count -gt 0){ ($ScanDrive[0].Trim().TrimEnd(':').ToUpper()) } else { 'C' }
            try { $findRoot = Get-SysOrgDestinationRoot -Letter $findLetter -Config $Config } catch { $findRoot = ('{0}:\_Organized' -f $findLetter) }
        }
        $results = @(Find-SysOrgFile -Root $findRoot -Name $Find -Config $Config)
        Write-Host ("{0} result(s):" -f $results.Count) -ForegroundColor White
        foreach($r in ($results | Select-Object -First 40)){
            Write-Host ('  ' + $r.CurrentPath + '  [' + $r.Category + $(if($r.Family){ ' | family ' + $r.Family }) + ']')
        }
        if($results.Count -gt 40){ Write-Host ('  ... and {0} more' -f ($results.Count - 40)) -ForegroundColor DarkGray }
    }
    return
}
if($Explain){
    Invoke-SysOrgCliStep -Step 'Explain' -Action {
        # v3.0 Phase 2.9: the full Decision for ONE file - every signal, rule and the
        # confidence math. Read-only: nothing is moved, nothing is planned.
        if(-not (Test-Path -LiteralPath $Explain)){
            Write-Host ("File not found: {0}" -f $Explain) -ForegroundColor Red
            return
        }
        $ext = [System.IO.Path]::GetExtension($Explain).ToLowerInvariant()
        try { $cat = Get-SysOrgCategory -Extension $ext -Config $Config } catch { $cat = 'Other' }
        $profX = $null
        if($env:OS -eq 'Windows_NT'){
            try { $profX = @(Get-SysOrgDriveProfile -Config $Config -Letters 'C')[0] } catch { $profX = $null }
        } else {
            # portable host: no real drive profile - a synthetic Data profile keeps the
            # mutability stage out of the way for this read-only explanation
            $profX = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='Data'; ProposedScope='FullDrive'
                KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        }
        $dec = Invoke-SysOrgClassifyPipeline -Path $Explain -Extension $ext -Category "$cat" -Config $Config -DriveProfile $profX -IncludeMetadata
        # v3.0.1 B3: -Explain includes the structure-model signal when a model exists
        if(Get-SysOrgSetting $Config 'Learn.Enabled' $true){
            try{
                $explainRoot = $null
                try { $explainRoot = Get-SysOrgDestinationRoot -Letter 'C' -Config $Config } catch { $explainRoot = 'C:\_Organized' }
                $lmX = New-SysOrgLearnModel -Config $Config -DestinationRoot $explainRoot
                if($lmX -and $lmX.Model){ $dec = Invoke-SysOrgClassifyPipeline -Path $Explain -Extension $ext -Category "$cat" -Config $Config -DriveProfile $profX -IncludeMetadata -LearnModel $lmX.Model }
            } catch { }
        }
        Show-SysOrgDecision -Decision $dec
    }
    return
}
if($UndoPlan){
    Invoke-SysOrgCliStep -Step 'Undo' -Action {
        # v2.1.1: elevated sessions must type 'yes' before any undo.
        if(-not (Confirm-SysOrgElevated)){
            Write-Host 'Elevated confirmation declined. Nothing was modified.' -ForegroundColor Yellow
            return
        }
        $script:SysOrgPhase = 'execute'
        $res = Undo-SysOrgPlan -PlanId $UndoPlan -AppRoot $appRoot -Config $Config
        $script:SysOrgPhase = 'preview'
        Write-Host ("Undo complete. Restored={0}  Failed={1}  SkippedMissing={2}  SkippedChanged={3}" -f $res.Restored, $res.Failed, $res.SkippedMissing, $res.SkippedChanged)
        # v3.0 Phase 4.1: point catalog entries back at the original locations
        $planJsonPath = Join-Path $folders.Plans ("{0}.json" -f $UndoPlan)
        $undoRoot = $null
        if(Test-Path -LiteralPath $planJsonPath){
            try { $undoRoot = ((Get-Content -LiteralPath $planJsonPath -Raw | ConvertFrom-Json).DestinationRoot) } catch { $undoRoot = $null }
        }
        if($undoRoot){ $null = Update-SysOrgCatalogOnUndo -PlanId $UndoPlan -AppRoot $appRoot -Root $undoRoot }
    }
    return
}
if($ExecutePlan){
    Invoke-SysOrgCliStep -Step 'Execute plan' -Action { Invoke-SysOrgPlanFile -Path $ExecutePlan }
    return
}
if($MigrateProfile){
    Invoke-SysOrgCliStep -Step 'Layout migration' -Action {
        # v3.0 Phase 6: migrate an existing v2.1 organized tree to the Findable layout
        if("$MigrateProfile" -ine 'Findable'){
            Write-Host ("Unknown layout profile '{0}' - only 'Findable' is supported as a migration target." -f $MigrateProfile) -ForegroundColor Yellow
            return
        }
        $migLetters = @()
        if($Migrate -and @($Migrate).Count -gt 0){ $migLetters = @($Migrate) }
        else { $migLetters = @('C') }
        foreach($l in $migLetters){
            Invoke-SysOrgMigrationFlow -Letter ($l.Trim().TrimEnd(':').ToUpper()) -TargetProfile 'Findable'
        }
    }
    return
}
if($Migrate){
    Invoke-SysOrgCliStep -Step 'Migration' -Action {
        if(@($Migrate).Count -gt 0){
            foreach($l in $Migrate){ Invoke-SysOrgMigrationFlow -Letter ($l.Trim().TrimEnd(':').ToUpper()) }
        } else {
            foreach($d in @(Get-SysOrgDrive)){
                Invoke-SysOrgMigrationFlow -Letter ($d.Drive.TrimEnd(':'))
            }
        }
    }
    return
}
if($ScanDrive){
    Invoke-SysOrgCliStep -Step 'Scan' -Action {
        foreach($l in $ScanDrive){
            $ll = $l.Trim().TrimEnd(':').ToUpper()
            if($ReportOnly){ Invoke-SysOrgScanFlow -Letter $ll -PreviewOnly -WholeDrive:$FullDrive -NoCacheSwitch:$NoCache }
            else { Invoke-SysOrgScanFlow -Letter $ll -WholeDrive:$FullDrive -NoCacheSwitch:$NoCache }
        }
    }
    return
}

# ---------------- interactive menu ----------------
$running = $true
while($running){
    # v3.0.2 A1: every menu iteration starts in the preview phase - the catch-all
    # can honestly say "Nothing was modified." until a flow sets the execute phase.
    $script:SysOrgPhase = 'preview'
    Write-Host ''
    Write-Host '==== SysOrg - portable file organizer (preview-first) ====' -ForegroundColor White
    Write-Host ' [1] Profile drives (role, protected artifacts, known folders, writable scope)'
    Write-Host ' [2] Audit folders: which can / cannot be altered (safety map)'
    Write-Host ' [3] Organize a drive (profile -> scan -> plan -> preview -> optional execute)'
    Write-Host ' [4] Scan a drive, report only (no plan, no changes)'
    Write-Host ' [5] Execute a saved plan file (preview + confirm)'
    Write-Host ' [6] Undo a plan (restore files to original locations)'
    Write-Host ' [7] Migrate old organized trees (Photo/Video/... -> Windows naming; preview first)'
    Write-Host ' [8] Open working folder (plans, undo journals, logs, reports)'
    Write-Host ' [9] Find files in the catalog (instant search)'
    Write-Host ' [10] Score the organized tree (findability)'
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
                  # v3.0.1 D1: the plan picker - 10 newest plans, accept a number, an id, a path, or a folder
                  $list = @(Get-SysOrgPlanList -PlansFolder $folders.Plans -Top 10)
                  if($list.Count -gt 0){
                      Write-Host ''
                      Write-Host 'Newest plans:' -ForegroundColor White
                      $i = 0
                      foreach($row in $list){
                          $i++
                          $status = if($row.Executed){ 'executed' } else { 'not executed' }
                          Write-Host ('  [{0}] {1}  drive {2}  {3} move(s)  {4}  [{5}]' -f $i, $row.PlanId, $row.Drive, $row.MoveCount, $row.Age, $status)
                      }
                  }
                  $p = Read-Host 'Plan (number, plan id, full path, or folder)'
                  $resolved = Resolve-SysOrgPlanChoice -Choice $p -PlansFolder $folders.Plans
                  if(-not $resolved){ Write-Host 'No matching plan found - nothing was modified.' -ForegroundColor Yellow; continue }
                  Invoke-SysOrgPlanFile -Path $resolved
                }
            '6' {
                  $id = Read-Host 'Plan id (e.g. plan-20260101-093000-123)'
                  # v2.1.1: elevated sessions must type 'yes' before any undo.
                  if(-not (Confirm-SysOrgElevated)){
                      Write-Host 'Elevated confirmation declined. Nothing was modified.' -ForegroundColor Yellow
                      continue
                  }
                  $script:SysOrgPhase = 'execute'
                  $res = Undo-SysOrgPlan -PlanId $id -AppRoot $appRoot -Config $Config
                  $script:SysOrgPhase = 'preview'
                  Write-Host ("Restored={0}  Failed={1}  SkippedMissing={2}  SkippedChanged={3}" -f $res.Restored, $res.Failed, $res.SkippedMissing, $res.SkippedChanged)
                }
            '7' { $l = Get-SysOrgLetterInput -Prompt 'Drive letter to migrate'; Invoke-SysOrgMigrationFlow -Letter $l }
            '8' { Start-Process explorer.exe $appRoot }
            '9' { $q = Read-Host 'Search (wildcard, e.g. *invoice*)'; $res = @(Find-SysOrgFile -Root (Get-SysOrgDestinationRoot -Letter (Get-SysOrgLetterInput -Prompt 'Destination drive letter') -Config $Config) -Name $q -Config $Config 3>$null); Write-Host ("{0} result(s):" -f $res.Count); $res | Select-Object -First 30 | ForEach-Object { Write-Host ('  ' + $_.CurrentPath + '  [' + $_.Category + ']') } }
            '10' { $sr = Get-SysOrgDestinationRoot -Letter (Get-SysOrgLetterInput -Prompt 'Destination drive letter') -Config $Config; $sc = Get-SysOrgTreeScore -Root $sr -Config $Config; if($sc.Files -eq 0){ Write-Host ''; Write-Host 'No organized tree yet.' -ForegroundColor Yellow; Write-Host ('  Nothing has been organized into {0} so far. Run option 3 (organize a drive) first.' -f $sr) -ForegroundColor Gray } else { Show-SysOrgFindabilityScore -Score $sc -Label $sr -Config $Config -WithTargets } }
            '0' { $running = $false }
            default { Write-Host 'Unknown option.' }
        }
    } catch {
        # v3.0.2 A1: the full diagnostic (exception type, message, script stack
        # trace, invocation position) goes to the log file; the user gets a
        # one-line message pointing at the log and the honest phase verdict.
        $logPath = Write-SysOrgErrorDiagnostic -ErrorRecord $_ -LogFolder $logFolder -Phase $script:SysOrgPhase
        Write-SysOrgLog ("Menu action failed: {0}" -f $_.Exception.Message) -Level ERROR -LogFolder $logFolder
        if($script:SysOrgPhase -eq 'preview'){
            Write-Host ("Menu action failed: {0}  Nothing was modified." -f $_.Exception.Message) -ForegroundColor Red
        } else {
            Write-Host ("Menu action failed DURING EXECUTION: {0}  A partial move may have happened - the undo journal restores it." -f $_.Exception.Message) -ForegroundColor Red
        }
        if($logPath){ Write-Host ("  Full diagnostics: {0}   (run .\SysOrg.ps1 -Diagnostics for a support bundle)" -f $logPath) -ForegroundColor DarkYellow }
    } finally {
        # v3.0.2 A1: the next menu iteration always starts in the preview phase.
        $script:SysOrgPhase = 'preview'
    }
}
