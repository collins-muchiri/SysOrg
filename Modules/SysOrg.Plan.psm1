#Requires -Version 5.1
# SysOrg.Plan.psm1 - plan generation (mutability engine + type-first families + numbered copies),
#                    preview (destination tree, mutability summary, OneDrive warnings),
#                    execution (incremental journal, resume guard, folder moves),
#                    undo, migration plans (W12) and report-only scans.

# v2.1.1: plan IDs are validated wherever they index a journal path. Item 10 adds an
# optional millisecond suffix, so the pattern tolerates '-fff' but nothing else.
$script:PlanIdPattern = '^(plan|migrate)-\d{8}-\d{6}(-\d{3})?$'

function Get-SysOrgDestinationBase {
<#
.SYNOPSIS
    Resolves the destination base folder for a relative routing path (design 6.3).
.DESCRIPTION
    OrganizedRoot style: <root>\<RelBase>. KnownFolders style (opt-in): the resolved known
    folder for the top segment plus the remaining segments (Downloads\<Source>\<Sub> maps to
    the real Downloads folder). Returns Base plus the DisplayRoot used by the preview tree.
.EXAMPLE
    Get-SysOrgDestinationBase -RelBase 'Downloads\GitHub\Archives' -DriveProfile $prof -Config $cfg -KnownFolders $kf
#>
    param([Parameter(Mandatory)][string]$RelBase,[Parameter(Mandatory)]$DriveProfile,$Config,$KnownFolders)
    $root = Get-SysOrgDestinationRoot -Letter "$($DriveProfile.Letter)" -Config $Config
    $style = "$(Get-SysOrgSetting $Config 'DestinationStyle' 'OrganizedRoot')"
    if($style -ne 'KnownFolders'){
        return [pscustomobject]@{ Base=($root + '\' + $RelBase); DisplayRoot=$root }
    }
    $top = ($RelBase.Split('\'))[0]
    $kf = $null
    foreach($k in @($KnownFolders)){
        if("$($k.Name)" -ieq $top){ $kf = ("$($k.Path)").TrimEnd('\'); break }
    }
    if(-not $kf){ return [pscustomobject]@{ Base=($root + '\' + $RelBase); DisplayRoot=$root } }
    $tail = $null
    if($RelBase -match '^Downloads\\(.+)$'){ $tail = $Matches[1] }
    else {
        $segs = @($RelBase.Split('\'))
        if($segs.Count -gt 1){ $tail = (@($segs | Select-Object -Skip 1) -join '\') }
    }
    if($tail){ return [pscustomobject]@{ Base=($kf + '\' + $tail); DisplayRoot=$kf } }
    return [pscustomobject]@{ Base=$kf; DisplayRoot=$kf }
}

function New-SysOrgPlan {
<#
.SYNOPSIS
    Builds a preview-first plan from an inventory (design section 7 routing pipeline).
.DESCRIPTION
    Every record passes, in order: recorded-not-planned checks, destination check, protected
    paths, project-folder coverage, preservation (organized heuristic + localized category
    names), the MUTABILITY ENGINE (denials are recorded with reasons), SKIP types, then
    context routing (download provenance -> Downloads branch; else the type root), families
    within the context leaf, numbered exact copies (NumberCopies default) and date folders.
    NO PLAN IS BUILT WITHOUT A DRIVE PROFILE.
.EXAMPLE
    $plan = New-SysOrgPlan -Letter C -Inventory $inv -DriveProfile $prof -DupGroups $dups -Config $cfg -KnownFolders $kf -ProjectFolders $proj
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter,
          $Inventory,
          $DriveProfile,
          $DupGroups,
          $Config,
          $KnownFolders,
          $ProjectFolders)

    if(-not $Config){ throw 'New-SysOrgPlan requires -Config.' }
    if(-not $DriveProfile){ throw 'No drive profile was provided. A plan cannot be built without one (run -ProfileDrives first).' }
    if(-not $Inventory){ throw 'New-SysOrgPlan requires an inventory (run a scan first).' }
    if(-not $KnownFolders -or @($KnownFolders).Count -eq 0){ $KnownFolders = @(Get-SysOrgKnownFolders) }
    if(-not $ProjectFolders){ $ProjectFolders = @() }

    $planId    = 'plan-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $root      = Get-SysOrgDestinationRoot -Letter $Letter -Config $Config
    $style     = "$(Get-SysOrgSetting $Config 'DestinationStyle' 'OrganizedRoot')"
    $maxActions = [int](Get-SysOrgSetting $Config 'MaxPlanActions' 5000)
    $dateMode  = Get-SysOrgSetting $Config 'DateFolders' 'Year'
    $dlDateMode = Get-SysOrgSetting $Config 'Downloads.DateFolders' "$(Get-SysOrgSetting $Config 'DateFolders' 'Year')"
    $folderMap = Get-SysOrgFolderMap -Config $Config

    $copiesPolicy = "$(Get-SysOrgSetting $Config 'Copies.Policy' 'NumberCopies')"
    $qFolder      = "$(Get-SysOrgSetting $Config 'Copies.QuarantineFolderName' '_Duplicates')"
    $startIndex   = [int](Get-SysOrgSetting $Config 'Copies.StartIndex' 2)
    $suffixStyle  = "$(Get-SysOrgSetting $Config 'Copies.SuffixStyle' 'Parentheses')"
    $unknownSrc   = "$(Get-SysOrgSetting $Config 'Downloads.UnknownSourceFolder' '_NoSource')"
    $groupBy      = "$(Get-SysOrgSetting $Config 'Downloads.GroupBy' 'SourceFirst')"
    $useZone      = [bool](Get-SysOrgSetting $Config 'Downloads.UseZoneIdentifier' $true)
    $storeUrls    = [bool](Get-SysOrgSetting $Config 'Privacy.StoreFullUrlsInJournal' $true)

    $organizedSet = Get-SysOrgOrganizedDirSet -Inventory $Inventory -Config $Config
    $categoryNames = Get-SysOrgCategoryNames -KnownFolders $KnownFolders
    $kfPathSet = @{}
    foreach($k in @($KnownFolders)){ if($k.Path){ $kfPathSet[(("$($k.Path)").Replace('/','\').TrimEnd('\')).ToLowerInvariant()] = $true } }
    $oneDriveRoot = $env:OneDrive
    if($oneDriveRoot){ $oneDriveRoot = $oneDriveRoot.TrimEnd('\') }

    # project-folder coverage: files under a detected project move as one unit
    $projectDirSet = @{}
    foreach($pf in @($ProjectFolders)){ $projectDirSet[(("$($pf.Path)").Replace('/','\').TrimEnd('\')).ToLowerInvariant()] = $true }

    $multipart = Get-SysOrgMultipartSets -Inventory $Inventory -Config $Config
    $multipartMap = $multipart.Map
    $leaderSet = @{}
    foreach($s in @($multipart.Sets)){ $leaderSet["$($s.Leader)"] = $true }

    # normalize the inventory once: @() breaks on List[object], arrays are always safe
    $invArray = $Inventory
    if($Inventory -is [System.Collections.Generic.List[object]]){ $invArray = $Inventory.ToArray() }
    $byPath = @{}
    foreach($r in @($invArray)){ $byPath["$($r.FullName)"] = $r }

    $dupGroupOf = @{}; $dupMemberSet = @{}; $keeperSet = @{}
    foreach($dg in @($DupGroups)){
        $keeperSet["$($dg.KeepPath)"] = $true
        foreach($p in @($dg.Duplicates)){ $pp = "$p"; $dupMemberSet[$pp] = $true; $dupGroupOf[$pp] = $dg }
    }

    $actions = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $provRows = New-Object System.Collections.Generic.List[object]
    $odSyncOut = New-Object System.Collections.Generic.List[string]
    $odIntoCloud = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $mutAllowed = 0
    $mutDenied = @{}
    $capped = $false

    # NOTE: this nested helper only MUTATES objects ($skipped list, $mutDenied h[hashtable) -
    # scalar counters would be rebound in the child scope, a classic PowerShell trap.
    function Add-SysOrgPlanSkip {
        param([string]$Source,[string]$Reason)
        $skipped.Add([pscustomobject]@{ Source=$Source; Reason=$Reason })
        if($mutDenied.ContainsKey($Reason)){ $mutDenied[$Reason]++ } else { $mutDenied[$Reason] = 1 }
    }
    function Test-SysOrgPlanPreservedDir {
        param([string]$Directory)
        # Normalize separators both ways: pwsh on non-Windows hosts normalizes to '/',
        # and the walk must terminate even when Split-Path stops shortening the value.
        $cur = ("$Directory").Replace('/','\').TrimEnd('\')
        while($cur -and ($cur.Length -gt 3)){
            $lc = $cur.ToLowerInvariant()
            if($organizedSet.ContainsKey($lc)){ return 'Inside a folder that already looks organized (preserved)' }
            if(-not $kfPathSet.ContainsKey($lc)){
                $catName = Test-SysOrgCategoryFolderName -Name $cur -CategoryNames $categoryNames
                if($catName){ return ('Existing ' + $catName + ' folder (preserved, localized name recognized)') }
            }
            $next = Split-Path $cur -Parent
            if(-not $next -or ("$next").Length -ge $cur.Length){ break }
            $cur = "$next"
        }
        return $null
    }

    $context = @{}
    $partitionLookup = @{}
    $routed = New-Object System.Collections.Generic.List[object]

    foreach($f in @($Inventory)){
        if($actions.Count -ge $maxActions){ $capped = $true; break }
        $src = "$($f.FullName)"
        try{
            if([string]::IsNullOrWhiteSpace($src)){ continue }
            # 0) recorded but never planned (P2-5)
            if("$($f.Category)" -eq 'SkippedLongPath'){
                Add-SysOrgPlanSkip -Source $src -Reason 'Path >= 260 characters (recorded; PowerShell 5.1 cannot address it)'
                continue
            }
            if(Test-SysOrgDestinationPath -Path $src -Config $Config){ continue }
            # protected path (mutability engine, row 1 of the policy matrix)
            $parentDir = Split-Path $src -Parent
            if(Test-SysOrgExcludedPath -Path $parentDir -Config $Config){
                Add-SysOrgPlanSkip -Source $src -Reason 'Protected path'
                continue
            }
            # 2) code project folders move as one unit - their files are not planned individually
            $cur = $parentDir.Replace('/','\').ToLowerInvariant()
            $inProject = $false
            while($cur -and ($cur.Length -gt 3)){
                if($projectDirSet.ContainsKey($cur)){ $inProject = $true; break }
                $cur = Split-Path $cur -Parent
            }
            if($inProject){
                Add-SysOrgPlanSkip -Source $src -Reason 'Inside a detected code project folder (moved as one unit)'
                continue
            }
            # preservation: organized heuristic + localized category recognition (W2)
            $pres = Test-SysOrgPlanPreservedDir -Directory $parentDir
            if($pres){ Add-SysOrgPlanSkip -Source $src -Reason $pres; continue }
            # 1) mutability engine (W3)
            $mut = Test-SysOrgFileMutable -Path $src -Extension "$($f.Extension)" -DriveProfile $DriveProfile -Config $Config
            if(-not $mut.Allowed){
                Add-SysOrgPlanSkip -Source $src -Reason "$($mut.Reason)"
                continue
            }
            if("$($f.Category)" -eq 'SKIP'){
                Add-SysOrgPlanSkip -Source $src -Reason 'Non-organizable type (system PerceivedType)'
                continue
            }
            $mutAllowed++

            # 4) context: download root or Zone.Identifier -> Downloads branch
            $category = "$($f.Category)"
            $inDownloads = $false
            $srcNorm = $src.Replace('/','\')
            foreach($r in @($DriveProfile.DownloadRoots)){
                if([string]::IsNullOrWhiteSpace("$r")){ continue }
                $r2 = (("$r").Replace('/','\')).TrimEnd('\')
                if($srcNorm.StartsWith($r2 + '\',[StringComparison]::OrdinalIgnoreCase)){ $inDownloads = $true; break }
            }
            $prov = $null
            if($useZone -and ($inDownloads -or ($category -in @('Archives','Installers')))){
                $prov = Get-SysOrgZoneIdentifier -Path $src
            }
            $bucket = $null
            if($prov){ $bucket = Get-SysOrgSourceBucket -HostUrl "$($prov['HostUrl'])" -ReferrerUrl "$($prov['ReferrerUrl'])" -FileName "$($f.Name)" }
            $downloadContext = $inDownloads -or ($null -ne $prov) -or ($category -eq 'Installers')
            $sourceName = $null
            if($downloadContext){
                if((-not $bucket) -and ($inDownloads -or $prov)){
                    $bucket = Get-SysOrgSourceBucket -HostUrl '' -ReferrerUrl '' -FileName "$($f.Name)"
                }
                if($bucket){ $sourceName = "$bucket" } else { $sourceName = $unknownSrc }
                $rel = ''
                if($folderMap.ContainsKey($category)){ $rel = "$($folderMap[$category])" } else { $rel = "$($folderMap['Other'])" }
                $typeLeaf = ($rel.Split('\'))[-1]
                if($groupBy -eq 'TypeFirst'){ $pk = ('Downloads\{0}\{1}' -f $typeLeaf, $sourceName) }
                else { $pk = ('Downloads\{0}\{1}' -f $sourceName, $typeLeaf) }
                if($prov){
                    $row = @{ Source=$src; SourceBucket=$sourceName; HostUrl=''; ReferrerUrl='' }
                    if($storeUrls){
                        $row.HostUrl = "$($prov['HostUrl'])"
                        $row.ReferrerUrl = "$($prov['ReferrerUrl'])"
                    }
                    [void]$provRows.Add([pscustomobject]$row)
                }
            } else {
                if($folderMap.ContainsKey($category)){ $pk = "$($folderMap[$category])" } else { $pk = "$($folderMap['Other'])" }
            }
            $context[$src] = @{ Rel=$pk; Category=$category; Source=$sourceName; InDownloads=$inDownloads }
            $partitionLookup[$src] = $pk
            [void]$routed.Add($f)
        } catch {
            Add-SysOrgPlanSkip -Source $src -Reason ("Analysis error: {0}" -f $_.Exception.Message)
        }
    }
    if($capped){ [void]$warnings.Add(("Plan capped at {0} actions; the remaining files were skipped this run." -f $maxActions)) }

    # 5) families within the context leaf (W5)
    # @() cannot collect a generic List[object] (Argument types do not match) - use ToArray
    $fam = Get-SysOrgNameFamilies -Inventory $routed.ToArray() -PartitionLookup $partitionLookup -Config $Config

    # process multipart leaders first so members can join the leader's destination folder
    $ordered = @($routed.ToArray() | Sort-Object -Property @{e={ if($leaderSet.ContainsKey("$($_.FullName)")){ 0 } else { 1 } }})

    $actionFolderBySrc = @{}
    $setDestFolder = @{}
    $usedNames = @{}
    $familiesAudit = @($fam.Families)

    # pass 1: keepers, family members, singles, multipart units
    foreach($f in $ordered){
        if($actions.Count -ge $maxActions){ $capped = $true; break }
        $src = "$($f.FullName)"
        $cx = $context[$src]
        if(-not $cx){ continue }
        try{
            $isKeeper = $keeperSet.ContainsKey($src)
            $isDupMember = $dupMemberSet.ContainsKey($src)
            if($isDupMember -and (-not $isKeeper)){
                # NumberCopies: numbered in pass 2 when the keeper was routed; otherwise
                # the copy routes below as a normal single (keeps its own name)
                if($copiesPolicy -eq 'NumberCopies' -and $context.ContainsKey("$($dupGroupOf[$src].KeepPath)")){ continue }
                if($copiesPolicy -eq 'Quarantine'){ continue }    # pass 2
                if($copiesPolicy -eq 'ReportOnly'){ continue }    # pass 2
            }
            $famInfo = $null
            if($fam.Lookup.ContainsKey($src)){ $famInfo = $fam.Lookup[$src] }
            $relForDest = $cx.Rel
            if($famInfo -and $famInfo.Partition){ $relForDest = [string]$famInfo.Partition }
            $db = Get-SysOrgDestinationBase -RelBase $relForDest -DriveProfile $DriveProfile -Config $Config -KnownFolders $KnownFolders
            $destFolder = $db.Base
            $destRoot = $db.DisplayRoot
            $famName = $null
            $reason = ''
            if($famInfo){
                $famName = [string]$famInfo.Name
                $destFolder = $db.Base + '\' + $famName
                $reason = ('Family={0}' -f $famName)
                if($cx.Source){ $reason = ('Source={0}; Family={1}' -f $cx.Source, $famName) }
            } else {
                $dMode = $dateMode
                if($cx.InDownloads){ $dMode = $dlDateMode }
                if("$dMode" -eq 'Year'){ $relDate = ([datetime]$f.LastWriteTime).ToString('yyyy'); $destFolder = $db.Base + '\' + $relDate }
                elseif("$dMode" -eq 'YearMonth'){ $relDate = ([datetime]$f.LastWriteTime).ToString('yyyy-MM'); $destFolder = $db.Base + '\' + $relDate }
                $reason = ('Category={0}' -f $cx.Category)
                if($cx.Source){ $reason = ('Source={0}; Category={1}' -f $cx.Source, $cx.Category) }
            }
            $isLeader = $leaderSet.ContainsKey($src)
            if($multipartMap.ContainsKey($src)){
                $sk = $multipartMap[$src]
                if(-not $isLeader){
                    if($setDestFolder.ContainsKey($sk)){ $destFolder = $setDestFolder[$sk] }
                } else {
                    $setDestFolder[$sk] = $destFolder
                }
                $reason = ('Multipart set {0}; {1}' -f $sk, $reason)
            }
            $dest = $destFolder + '\' + $f.Name
            $nameKey = $destFolder.ToLowerInvariant() + '|' + ("$($f.Name)").ToLowerInvariant()
            $usedNames[$nameKey] = $true

            $syncOut = $false; $intoCloud = $false
            if($oneDriveRoot){
                $odNorm = (($oneDriveRoot.Replace('/','\')).TrimEnd('\'))
                $srcUnder = (($src.Replace('/','\')).StartsWith($odNorm + '\',[StringComparison]::OrdinalIgnoreCase)) -or ($src -ieq $oneDriveRoot)
                $dstUnder = (($dest.Replace('/','\')).StartsWith($odNorm + '\',[StringComparison]::OrdinalIgnoreCase))
                if($srcUnder -and (-not $dstUnder)){ $syncOut = $true; [void]$odSyncOut.Add($src) }
                if((-not $srcUnder) -and $dstUnder){ $intoCloud = $true; [void]$odIntoCloud.Add($dest) }
            }
            # v2.1.1: capture plan-time metadata so the executor can detect a source that
            # changed between planning and execution. Stored as a round-trip-safe UTC string.
            $actions.Add([pscustomobject]@{
                Action='Move'; Kind='File'; Source=$src; Destination=$dest; DestRoot=$destRoot
                SizeBytes=[int64]$f.Length; Family=$famName; CopyIndex=$null
                SourceBucket=$cx.Source; Reason=$reason; DifferentContent=$false
                PlannedLength=[int64]$f.Length
                PlannedLastWriteTimeUtc=([datetime]$f.LastWriteTime).ToUniversalTime().ToString('o')
                OneDriveSyncOut=$syncOut; OneDriveIntoCloud=$intoCloud
            })
            $actionFolderBySrc[$src] = $destFolder
        } catch {
            Add-SysOrgPlanSkip -Source $src -Reason ("Routing error: {0}" -f $_.Exception.Message)
        }
    }

    # pass 2: exact copies (W6)
    $copiesAudit = @{ Policy=$copiesPolicy; Numbered=0; Quarantined=0; Reported=0; Groups=@() }
    $groupsAudit = New-Object System.Collections.Generic.List[object]
    foreach($dg in @($DupGroups)){
        $keeperPath = "$($dg.KeepPath)"
        $keeperFolder = $actionFolderBySrc[$keeperPath]
        $members = @()
        foreach($p in @($dg.Duplicates)){
            $p2 = "$p"
            if(-not $byPath.ContainsKey($p2)){ continue }
            if(-not $context.ContainsKey($p2)){ continue }
            if($multipartMap.ContainsKey($p2)){ continue }   # multipart members: exempt from numbering and quarantine
            $members += $byPath[$p2]
        }
        $groupAudit = @{ Keeper=$keeperPath; Hash="$($dg.Hash)"; Copies=@(); Quarantined=@(); Reported=@() }
        if($members.Count -gt 0){
            if($copiesPolicy -eq 'Quarantine'){
                foreach($m in $members){
                    if($actions.Count -ge $maxActions){ $capped = $true; break }
                    $h = "$($dg.Hash)"
                    $hash8 = if($h -and ($h.Length -ge 8)){ $h.Substring(0,8) } else { 'dup' }
                    $qName = '{0}_{1}{2}' -f $m.Stem, $hash8, $m.Extension
                    $qDir = ($root + '\' + $qFolder + '\' + $planId)
                    $dest = ($qDir + '\' + $qName)
                    $syncOut = $false; $intoCloud = $false
                    if($oneDriveRoot){
                        $odNormQ = (($oneDriveRoot.Replace('/','\')).TrimEnd('\'))
                        $srcUnder = (("$($m.FullName)".Replace('/','\')).StartsWith($odNormQ + '\',[StringComparison]::OrdinalIgnoreCase))
                        $dstUnder = ($dest.Replace('/','\')).StartsWith($odNormQ + '\',[StringComparison]::OrdinalIgnoreCase)
                        if($srcUnder -and (-not $dstUnder)){ $syncOut = $true; [void]$odSyncOut.Add("$($m.FullName)") }
                        if((-not $srcUnder) -and $dstUnder){ $intoCloud = $true; [void]$odIntoCloud.Add($dest) }
                    }
                    $actions.Add([pscustomobject]@{
                        Action='Quarantine'; Kind='File'; Source="$($m.FullName)"; Destination=$dest; DestRoot=$root
                        SizeBytes=[int64]$m.Length; Family=$null; CopyIndex=$null; SourceBucket=$null
                        Reason='Exact duplicate (Quarantine policy); keeper identified during scan'
                        Hash="$($dg.Hash)"; DifferentContent=$false
                        PlannedLength=[int64]$m.Length
                        PlannedLastWriteTimeUtc=([datetime]$m.LastWriteTime).ToUniversalTime().ToString('o')
                        OneDriveSyncOut=$syncOut; OneDriveIntoCloud=$intoCloud
                    })
                    $copiesAudit.Quarantined++
                    $groupAudit.Quarantined += "$($m.FullName)"
                }
            }
            elseif($copiesPolicy -eq 'NumberCopies'){
                if($keeperFolder){
                    $keeperRec = $byPath[$keeperPath]
                    $renameToKeeper = [bool](Get-SysOrgSetting $Config 'Copies.RenameToKeeper' $false)
                    $withKeys = @()
                    foreach($m in $members){
                        $withKeys += [pscustomobject]@{ Rec=$m; Key=(Get-SysOrgNaturalKey -Name "$($m.FullName)") }
                    }
                    $orderedMembers = @(($withKeys | Sort-Object -Property @{e={$_.Rec.LastWriteTime.Ticks}}, @{e={$_.Key}}) | ForEach-Object { $_.Rec })
                    $n = $startIndex - 1
                    $folderKey = $keeperFolder.ToLowerInvariant()
                    foreach($m in $orderedMembers){
                        if($actions.Count -ge $maxActions){ $capped = $true; break }
                        if($renameToKeeper){
                            # v2.1.1 opt-in (Copies.RenameToKeeper=$true): the legacy rev 2.1.0
                            # behaviour - every copy takes the keeper's stem and is numbered.
                            $stem = "$($keeperRec.Stem)"
                            $ext = "$($keeperRec.Extension)"
                            $n++
                            $candidate = Get-SysOrgCopyName -Stem $stem -Extension $ext -Index $n -Style $suffixStyle
                            $i = $n
                            # 9.5: plan-time assignment checks the destination for existing files
                            while($usedNames.ContainsKey($folderKey + '|' + $candidate.ToLowerInvariant()) -or
                                  (Test-Path -LiteralPath ($keeperFolder + '\' + $candidate))){
                                $i++
                                if($i -gt 999){ $candidate = ([guid]::NewGuid().ToString('N').Substring(0,8)) + $ext; break }
                                $candidate = Get-SysOrgCopyName -Stem $stem -Extension $ext -Index $i -Style $suffixStyle
                            }
                            $copyIndex = $i
                        } else {
                            # v2.1.1 default: a copy keeps its OWN stem and extension; it is
                            # numbered only when the name collides in the destination folder.
                            $stem = "$($m.Stem)"
                            $ext = "$($m.Extension)"
                            $candidate = ($stem + $ext)
                            $copyIndex = $null
                            if($usedNames.ContainsKey($folderKey + '|' + $candidate.ToLowerInvariant()) -or
                               (Test-Path -LiteralPath ($keeperFolder + '\' + $candidate))){
                                $i = $startIndex - 1
                                while($true){
                                    $i++
                                    if($i -gt 999){ $candidate = ([guid]::NewGuid().ToString('N').Substring(0,8)) + $ext; $copyIndex = $i; break }
                                    $candidate = Get-SysOrgCopyName -Stem $stem -Extension $ext -Index $i -Style $suffixStyle
                                    if((-not $usedNames.ContainsKey($folderKey + '|' + $candidate.ToLowerInvariant())) -and
                                       (-not (Test-Path -LiteralPath ($keeperFolder + '\' + $candidate)))){
                                        $copyIndex = $i
                                        break
                                    }
                                }
                            }
                        }
                        $usedNames[$folderKey + '|' + $candidate.ToLowerInvariant()] = $true
                        $dest = $keeperFolder + '\' + $candidate
                        $keeperFam = $null
                        if($fam.Lookup.ContainsKey($keeperPath)){ $keeperFam = [string]$fam.Lookup[$keeperPath].Name }
                        $syncOut = $false; $intoCloud = $false
                        if($oneDriveRoot){
                            $odNorm2 = (($oneDriveRoot.Replace('/','\')).TrimEnd('\'))
                            $srcUnder = (("$($m.FullName)".Replace('/','\')).StartsWith($odNorm2 + '\',[StringComparison]::OrdinalIgnoreCase))
                            $dstUnder = ($dest.Replace('/','\')).StartsWith($odNorm2 + '\',[StringComparison]::OrdinalIgnoreCase)
                            if($srcUnder -and (-not $dstUnder)){ $syncOut = $true; [void]$odSyncOut.Add("$($m.FullName)") }
                            if((-not $srcUnder) -and $dstUnder){ $intoCloud = $true; [void]$odIntoCloud.Add($dest) }
                        }
                        $reason = if($renameToKeeper){
                            ('Exact copy {0} of {1}; content verified by SHA256' -f $copyIndex, ($orderedMembers.Count + 1))
                        } else {
                            'Exact copy (content verified by SHA256); keeps its own name'
                        }
                        $actions.Add([pscustomobject]@{
                            Action='Move'; Kind='File'; Source="$($m.FullName)"; Destination=$dest; DestRoot=$keeperFolder
                            SizeBytes=[int64]$m.Length; Family=$keeperFam; CopyIndex=$copyIndex; SourceBucket=$null
                            Reason=$reason
                            Hash="$($dg.Hash)"; DifferentContent=$false
                            PlannedLength=[int64]$m.Length
                            PlannedLastWriteTimeUtc=([datetime]$m.LastWriteTime).ToUniversalTime().ToString('o')
                            OneDriveSyncOut=$syncOut; OneDriveIntoCloud=$intoCloud
                        })
                        if($copyIndex){ $copiesAudit.Numbered++ }
                        $groupAudit.Copies += @{ Source="$($m.FullName)"; Assigned=$candidate; Index=$copyIndex }
                    }
                }
            }
            else {  # ReportOnly
                foreach($m in $members){
                    $copiesAudit.Reported++
                    $groupAudit.Reported += "$($m.FullName)"
                }
            }
        }
        [void]$groupsAudit.Add([pscustomobject]$groupAudit)
    }
    $copiesAudit.Groups = @($groupsAudit.ToArray())

    # code project folders: one MoveFolder unit each (mutability checked at the folder itself)
    $projCfgDest = "$(Get-SysOrgSetting $Config 'Projects.Destination' 'Documents\Projects\Code')"
    $docMap = "$($folderMap['Documents'])"
    foreach($pf in @($ProjectFolders)){
        if($actions.Count -ge $maxActions){ $capped = $true; break }
        try{
            $mut = Test-SysOrgFileMutable -Path "$($pf.Path)" -Extension '' -DriveProfile $DriveProfile -Config $Config -Container
            if(-not $mut.Allowed){
                Add-SysOrgPlanSkip -Source "$($pf.Path)" -Reason ("Project folder not moved: {0}" -f $mut.Reason)
                continue
            }
            $db = Get-SysOrgDestinationBase -RelBase $docMap -DriveProfile $DriveProfile -Config $Config -KnownFolders $KnownFolders
            $base = $db.Base
            if($projCfgDest -ieq 'Documents' -or $projCfgDest.StartsWith('Documents\',[StringComparison]::OrdinalIgnoreCase)){
                $tail = $projCfgDest.Substring('Documents'.Length).TrimStart('\')
                if($tail){ $base = $db.Base + '\' + $tail }
            } else {
                $base = $root + '\' + $projCfgDest
            }
            $dest = $base + '\' + "$($pf.SafeName)"
            # v2.1.1: preview data - per folder move, the file count, the number of
            # non-code files, and blocked-extension files OUTSIDE build-output directories
            # (surfaced in the preview; the folder still moves).
            $stats = Get-SysOrgFolderMoveStats -Path "$($pf.Path)" -Config $Config -DriveProfile $DriveProfile
            $syncOut = $false; $intoCloud = $false
            if($oneDriveRoot){
                $srcUnder = "$($pf.Path)".StartsWith($oneDriveRoot + '\',[StringComparison]::OrdinalIgnoreCase)
                $dstUnder = $dest.StartsWith($oneDriveRoot + '\',[StringComparison]::OrdinalIgnoreCase)
                if($srcUnder -and (-not $dstUnder)){ $syncOut = $true; [void]$odSyncOut.Add("$($pf.Path)") }
                if((-not $srcUnder) -and $dstUnder){ $intoCloud = $true; [void]$odIntoCloud.Add($dest) }
            }
            $actions.Add([pscustomobject]@{
                Action='Move'; Kind='Folder'; Source="$($pf.Path)"; Destination=$dest; DestRoot=$db.DisplayRoot
                SizeBytes=[int64]0; Family=$null; CopyIndex=$null; SourceBucket=$null
                Reason='Code project folder (markers detected); moved whole, .git intact'
                FilesInside=$stats.Files; NonCodeFilesInside=$stats.NonCode
                BlockedFilesCount=$stats.BlockedCount; BlockedFileSamples=$stats.BlockedSamples
                DifferentContent=$false; OneDriveSyncOut=$syncOut; OneDriveIntoCloud=$intoCloud
            })
        } catch {
            Add-SysOrgPlanSkip -Source "$($pf.Path)" -Reason ("Project folder error: {0}" -f $_.Exception.Message)
        }
    }

    # 9.4: plan-internal name collisions (different content, same destination) are flagged;
    # execution resolves them via Get-SysOrgUniquePath - originals are never rewritten here.
    $byDest = @{}
    foreach($a in $actions){
        if("$($a.Action)" -ne 'Move'){ continue }
        $k = "$($a.Destination)".ToLowerInvariant()
        if(-not $byDest.ContainsKey($k)){ $byDest[$k] = New-Object System.Collections.Generic.List[object] }
        [void]$byDest[$k].Add($a)
    }
    foreach($k in $byDest.Keys){
        if($byDest[$k].Count -gt 1){
            foreach($a in $byDest[$k]){ $a.DifferentContent = $true }
        }
    }

    $deniedList = @()
    $deniedTotal = 0
    foreach($k in ($mutDenied.Keys | Sort-Object)){
        $deniedList += [pscustomobject]@{ Reason=$k; Count=$mutDenied[$k] }
        $deniedTotal += $mutDenied[$k]
    }
    $deniedList = @($deniedList | Sort-Object Count -Descending)

    $profileSummary = $null
    try{
        $kfSimple = @()
        foreach($k in @($DriveProfile.KnownFolders)){
            $kfSimple += [pscustomobject]@{ Name="$($k.Name)"; Path="$($k.Path)"
                IsRedirected=[bool]$k.IsRedirected; UnderOneDrive=[bool]$k.UnderOneDrive }
        }
        $profileSummary = [pscustomobject]@{
            Letter="$($DriveProfile.Letter)"; Role="$($DriveProfile.Role)"
            ProposedScope="$($DriveProfile.ProposedScope)"
            Artifacts=@("$($DriveProfile.Artifacts)")
            DownloadRoots=@("$($DriveProfile.DownloadRoots)")
            KnownFolders=$kfSimple
        }
    } catch { $profileSummary = $null }

    return [pscustomobject]@{
        PlanId          = $planId
        Created         = (Get-Date).ToString('s')
        Computer        = $env:COMPUTERNAME
        Drive           = "$Letter`:"
        DestinationRoot = $root
        DestinationStyle= $style
        Mode            = ('Type-first families; preset={0}; copies={1}; style={2}' -f (Get-SysOrgSetting $Config 'NamingPreset' 'Windows'), $copiesPolicy, $style)
        DriveProfile    = $profileSummary
        Actions         = $actions.ToArray()
        Skipped         = $skipped.ToArray()
        Families        = $familiesAudit
        Copies          = [pscustomobject]$copiesAudit
        Mutability      = [pscustomobject]@{ Allowed=$mutAllowed; DeniedTotal=$deniedTotal; Denied=$deniedList }
        OneDrive        = [pscustomobject]@{ SyncOut=@($odSyncOut.ToArray()); IntoCloud=@($odIntoCloud.ToArray()) }
        Warnings        = @($warnings.ToArray())
        Provenance      = @($provRows.ToArray())
        ProvenanceFile  = ''
        Stats           = [pscustomobject]@{ Scanned=@($invArray).Count; Routed=$routed.Count }
    }
}

function New-SysOrgMigrationPlan {
<#
.SYNOPSIS
    Builds a previewable plan that maps old v1.x / rev 2.0 organized trees to the
    Windows naming (W12). Nothing is applied implicitly.
.DESCRIPTION
    Photo/Images -> Pictures, Video -> Videos, Audio and Video\Audio -> Music,
    Spreadsheets/Presentations/Fonts/Databases -> Documents, Archives -> Documents\Archives,
    Code -> Documents\Code, Other -> Documents\Other, Installers -> Downloads\Installers.
    Children move one level at a time (MoveFolder for subfolders), so the existing year
    structure survives intact. `_Duplicates` and `_Reports` folders are left untouched.
.EXAMPLE
    New-SysOrgMigrationPlan -Letter C -Config $cfg
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter,$Config)
    if(-not $Config){ throw 'New-SysOrgMigrationPlan requires -Config.' }
    $planId = 'migrate-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $root = Get-SysOrgDestinationRoot -Letter $Letter -Config $Config
    if(-not (Test-Path -LiteralPath $root)){ throw ("Nothing to migrate: destination root '{0}' does not exist." -f $root) }
    $maxActions = [int](Get-SysOrgSetting $Config 'MaxPlanActions' 5000)
    $reportsName = "$(Get-SysOrgSetting $Config 'ReportsFolderName' '_Reports')".ToLowerInvariant()

    $map = @{
        'photo'='Pictures'; 'images'='Pictures'
        'video'='Videos'; 'videos'='Videos'
        'audio'='Music'; 'music'='Music'
        'spreadsheets'='Documents'; 'presentations'='Documents'; 'fonts'='Documents'; 'databases'='Documents'
        'archives'='Documents\Archives'; 'code'='Documents\Code'; 'other'='Documents\Other'
        'installers'='Downloads\Installers'
    }

    $actions = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $topDirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)
    foreach($td in $topDirs){
        $leaf = $td.Name.ToLowerInvariant()
        if(($leaf -eq '_duplicates') -or ($leaf -eq $reportsName) -or ($leaf -eq '_sysorg')){
            [void]$skipped.Add([pscustomobject]@{ Source=$td.FullName; Reason='Left untouched (SysOrg runtime folder)' })
            continue
        }
        if(-not $map.ContainsKey($leaf)){ continue }   # Documents / Downloads / Windows-named roots stay
        $target = $map[$leaf]
        $children = @()
        try { $children = @(Get-ChildItem -LiteralPath $td.FullName -Force -ErrorAction SilentlyContinue) } catch { }
        foreach($ch in $children){
            # rev 2.0 Video\Audio -> Music extraction
            if(($leaf -eq 'video') -and $ch.PSIsContainer -and ($ch.Name.ToLowerInvariant() -eq 'audio')){
                $subs = @()
                try { $subs = @(Get-ChildItem -LiteralPath $ch.FullName -Force -ErrorAction SilentlyContinue) } catch { }
                foreach($sub in $subs){
                    $dest2 = ($root + '\Music\' + $sub.Name)
                    $kind2 = 'File'; if($sub.PSIsContainer){ $kind2 = 'Folder' }
                    $size2 = [int64]0; if(-not $sub.PSIsContainer){ $size2 = [int64]$sub.Length }
                    [void]$actions.Add([pscustomobject]@{
                        Action='Move'; Kind=$kind2; Source=$sub.FullName; Destination=$dest2; DestRoot=$root
                        SizeBytes=$size2; Family=$null; CopyIndex=$null; SourceBucket=$null
                        Reason='Migrate: Video\Audio -> Music'; DifferentContent=$false
                        OneDriveSyncOut=$false; OneDriveIntoCloud=$false
                    })
                }
                continue
            }
            $dest = ($root + '\' + $target + '\' + $ch.Name)
            $kind = 'File'; if($ch.PSIsContainer){ $kind = 'Folder' }
            $size = [int64]0; if(-not $ch.PSIsContainer){ $size = [int64]$ch.Length }
            [void]$actions.Add([pscustomobject]@{
                Action='Move'; Kind=$kind; Source=$ch.FullName; Destination=$dest; DestRoot=$root
                SizeBytes=$size; Family=$null; CopyIndex=$null; SourceBucket=$null
                Reason=('Migrate: {0} -> {1}' -f $td.Name, $target); DifferentContent=$false
                OneDriveSyncOut=$false; OneDriveIntoCloud=$false
            })
            if($actions.Count -ge $maxActions){ break }
        }
        if($actions.Count -ge $maxActions){ break }
    }
    return [pscustomobject]@{
        PlanId          = $planId
        Created         = (Get-Date).ToString('s')
        Computer        = $env:COMPUTERNAME
        Drive           = "$Letter`:"
        DestinationRoot = $root
        DestinationStyle= 'OrganizedRoot'
        Mode            = 'Migration preview (v1.x / rev 2.0 trees -> Windows naming); _Duplicates untouched'
        DriveProfile    = $null
        Actions         = $actions.ToArray()
        Skipped         = $skipped.ToArray()
        Families        = @()
        Copies          = [pscustomobject]@{ Policy='n/a'; Numbered=0; Quarantined=0; Reported=0; Groups=@() }
        Mutability      = [pscustomobject]@{ Allowed=$actions.Count; DeniedTotal=0; Denied=@() }
        OneDrive        = [pscustomobject]@{ SyncOut=@(); IntoCloud=@() }
        Warnings        = @()
        Provenance      = @()
        ProvenanceFile  = ''
        Stats           = [pscustomobject]@{ Scanned=0; Routed=$actions.Count }
    }
}

function Save-SysOrgPlan {
<#
.SYNOPSIS
    Serializes a plan to <PlansFolder>\<PlanId>.json and returns the path.
.DESCRIPTION
    Full download URLs (Provenance) are written ONLY to the local sidecar
    <PlanId>-provenance.csv (Privacy.StoreFullUrlsInJournal) - never into the JSON.
.EXAMPLE
    $p = Save-SysOrgPlan -Plan $plan -PlansFolder C:\SysOrg\Plans
#>
    param($Plan,[string]$PlansFolder)
    if(-not (Test-Path -LiteralPath $PlansFolder)){ New-Item -ItemType Directory -Path $PlansFolder -Force | Out-Null }
    $path = Join-Path $PlansFolder ('{0}.json' -f $Plan.PlanId)
    if($Plan.PSObject.Properties['ProvenanceFile']){
        $Plan.ProvenanceFile = (Join-Path $PlansFolder ('{0}-provenance.csv' -f $Plan.PlanId))
    }
    if($Plan.PSObject.Properties['Provenance'] -and @($Plan.Provenance).Count -gt 0){
        try{
            $rows = @('Source,SourceBucket,HostUrl,ReferrerUrl')
            foreach($p in @($Plan.Provenance)){
                # v2.1.1: proper CSV escaping - untrusted URLs can contain quotes and commas
                $rows += ((ConvertTo-SysOrgCsvField "$($p.Source)") + ',' + (ConvertTo-SysOrgCsvField "$($p.SourceBucket)") + ',' +
                          (ConvertTo-SysOrgCsvField "$($p.HostUrl)") + ',' + (ConvertTo-SysOrgCsvField "$($p.ReferrerUrl)"))
            }
            $rows | Set-Content -LiteralPath $Plan.ProvenanceFile -Encoding UTF8
        } catch { Write-Warning "Provenance sidecar could not be written: $($_.Exception.Message)" }
    }
    # v2.1.1: integrity hash over the canonical action list - the executor verifies it
    # and refuses to run a plan whose actions were edited after the save.
    if(-not $Plan.PSObject.Properties['IntegrityHash']){
        [void]($Plan | Add-Member -NotePropertyName IntegrityHash -NotePropertyValue '')
    }
    $Plan.IntegrityHash = Get-SysOrgPlanIntegrityHash -Actions $Plan.Actions
    ($Plan | Select-Object -Property * -ExcludeProperty Provenance) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-SysOrgPreviewTree {
<#
.SYNOPSIS
    Aggregates plan destinations into a two-level tree with counts and bytes (12.1).
.EXAMPLE
    $tree = Get-SysOrgPreviewTree -Plan $plan
#>
    param([Parameter(Mandatory)]$Plan)
    $roots = @{}
    foreach($a in @($Plan.Actions | Where-Object { "$($_.Action)" -eq 'Move' })){
        $dr = "$($Plan.DestinationRoot)"
        if($a.PSObject.Properties['DestRoot'] -and "$($a.DestRoot)"){ $dr = "$($a.DestRoot)" }
        $bytes = [int64]0
        if($a.PSObject.Properties['SizeBytes'] -and $a.SizeBytes){ $bytes = [int64]$a.SizeBytes }
        $rel = "$($a.Destination)"
        if($rel.StartsWith($dr + '\',[StringComparison]::OrdinalIgnoreCase)){ $rel = $rel.Substring($dr.Length + 1) }
        else { $rel = Split-Path $rel -Leaf }
        $segs = @($rel.Split('\'))
        if(-not $roots.ContainsKey($dr)){ $roots[$dr] = @{ Count=0; Bytes=[int64]0; Children=@{} } }
        $node = $roots[$dr]
        $node.Count++
        $node.Bytes += $bytes
        if($segs.Count -gt 0){
            $l1 = $segs[0]
            if(-not $node.Children.ContainsKey($l1)){ $node.Children[$l1] = @{ Count=0; Bytes=[int64]0; Sub=@{} } }
            $c1 = $node.Children[$l1]
            $c1.Count++
            $c1.Bytes += $bytes
            if($segs.Count -gt 1){
                $l2 = $segs[1]
                if(-not $c1.Sub.ContainsKey($l2)){ $c1.Sub[$l2] = @{ Count=0; Bytes=[int64]0 } }
                $c1.Sub[$l2].Count++
                $c1.Sub[$l2].Bytes += $bytes
            }
        }
    }
    return $roots
}

function Show-SysOrgPreviewTree {
<#
.SYNOPSIS
    Renders the two-level destination tree, natural-sorted (W7), with counts and bytes.
.EXAMPLE
    Show-SysOrgPreviewTree -Plan $plan -NaturalSort:$true
#>
    param([Parameter(Mandatory)]$Plan,[bool]$NaturalSort=$true)
    $tree = Get-SysOrgPreviewTree -Plan $Plan
    if($tree.Keys.Count -eq 0){
        Write-Host '  (no moves)' -ForegroundColor DarkGray
        return
    }
    foreach($rn in (Sort-SysOrgNatural -Values @($tree.Keys))){
        $node = $tree[$rn]
        if($tree.Keys.Count -gt 1){
            Write-Host ("  [{0}]  ({1} items, {2})" -f $rn, $node.Count, (Format-SysOrgFileSize $node.Bytes)) -ForegroundColor White
        }
        $names = @($node.Children.Keys)
        if($NaturalSort){ $names = Sort-SysOrgNatural -Values $names } else { $names = @($names | Sort-Object) }
        foreach($n in $names){
            $c = $node.Children[$n]
            Write-Host ("  {0}  ({1} items, {2})" -f $n, $c.Count, (Format-SysOrgFileSize $c.Bytes)) -ForegroundColor Gray
            $subs = @($c.Sub.Keys)
            if($NaturalSort){ $subs = Sort-SysOrgNatural -Values $subs } else { $subs = @($subs | Sort-Object) }
            $shown = 0
            foreach($s in $subs){
                if($shown -ge 8){ Write-Host ('      ... and {0} more' -f ($subs.Count - $shown)) -ForegroundColor DarkGray; break }
                $sc = $c.Sub[$s]
                Write-Host ("    {0}  ({1}, {2})" -f $s, $sc.Count, (Format-SysOrgFileSize $sc.Bytes)) -ForegroundColor DarkGray
                $shown++
            }
        }
    }
}

function Show-SysOrgPlan {
<#
.SYNOPSIS
    Prints the full plan preview (design section 12) and returns a summary for the
    confirmation prompt.
.DESCRIPTION
    Sections: plan header + drive profile, mutability summary (12.2), destination tree
    (12.1, natural-sorted), families and copies table (12.4), OneDrive sync-out warning
    (12.3), name-collision flags, affected top-level folders and sample moves.
.EXAMPLE
    $sum = Show-SysOrgPlan -Plan $plan -Config $cfg
    if($sum.OneDriveSyncOut -gt 0){ ... the confirmation prompt names the count ... }
#>
    [CmdletBinding()]
    param($Plan,[int]$SampleSize=20,$Config)
    $actions = @($Plan.Actions)
    $moves = @($actions | Where-Object { "$($_.Action)" -eq 'Move' })
    $folderMoves = @($moves | Where-Object { $_.PSObject.Properties['Kind'] -and "$($_.Kind)" -eq 'Folder' })
    $fileMoves  = @($moves | Where-Object { -not ($_.PSObject.Properties['Kind'] -and "$($_.Kind)" -eq 'Folder') })
    $quars = @($actions | Where-Object { "$($_.Action)" -eq 'Quarantine' })
    $bytes = [int64]0
    if($fileMoves.Count -gt 0){ $bytes = [int64]($fileMoves | Measure-Object -Property SizeBytes -Sum).Sum }

    $showDenied = $true; $natural = $true; $warnOD = $true
    if($Config){
        $showDenied = [bool](Get-SysOrgSetting $Config 'Preview.ShowDenied' $true)
        $natural    = [bool](Get-SysOrgSetting $Config 'Preview.NaturalSort' $true)
        $warnOD     = [bool](Get-SysOrgSetting $Config 'Preview.WarnOneDriveSyncOut' $true)
    }

    Write-Host ''
    Write-Host ("PLAN {0}  (drive {1} -> {2}, style {3})" -f $Plan.PlanId, $Plan.Drive, $Plan.DestinationRoot, $Plan.DestinationStyle) -ForegroundColor White
    if($Plan.PSObject.Properties['Mode'] -and $Plan.Mode){ Write-Host ("Mode: {0}" -f $Plan.Mode) }
    if($Plan.PSObject.Properties['DriveProfile'] -and $Plan.DriveProfile){
        Write-Host ("Drive profile: role={0}, scope={1}" -f $Plan.DriveProfile.Role, $Plan.DriveProfile.ProposedScope) -ForegroundColor Gray
    }
    Write-Host ("File moves: {0} ({1})   Folder moves: {2}   Quarantines: {3}   Skipped: {4}" -f `
        $fileMoves.Count, (Format-SysOrgFileSize $bytes), $folderMoves.Count, $quars.Count, @($Plan.Skipped).Count)
    if($Plan.PSObject.Properties['Warnings'] -and @($Plan.Warnings).Count -gt 0){
        foreach($w in @($Plan.Warnings)){ Write-Host ("WARNING: {0}" -f $w) -ForegroundColor Yellow }
    }

    # 12.2 mutability summary
    if($showDenied -and $Plan.PSObject.Properties['Mutability'] -and $Plan.Mutability){
        $m = $Plan.Mutability
        Write-Host ''
        Write-Host ("Mutability: {0} file(s) allowed; {1} denied (provably never touched):" -f $m.Allowed, $m.DeniedTotal) -ForegroundColor White
        foreach($d in @($m.Denied)){
            Write-Host ("  {0}  x{1}" -f $d.Reason, $d.Count) -ForegroundColor Yellow
        }
        $deniedReasons = @(@($m.Denied) | ForEach-Object { "$($_.Reason)" })
        $samples = @(@($Plan.Skipped) | Where-Object { $deniedReasons -contains "$($_.Reason)" } | Select-Object -First 5)
        foreach($s in $samples){ Write-Host ("    e.g. {0}" -f $s.Source) -ForegroundColor DarkYellow }
    }

    # 12.1 destination tree
    Write-Host ''
    Write-Host 'Destination tree:' -ForegroundColor White
    Show-SysOrgPreviewTree -Plan $Plan -NaturalSort:$natural

    # 12.4 families and copies table
    if($Plan.PSObject.Properties['Families'] -and @($Plan.Families).Count -gt 0){
        Write-Host ''
        Write-Host 'Families:' -ForegroundColor White
        foreach($fam in (@($Plan.Families) | Select-Object -First 15)){
            Write-Host ("  {0}  [{1}]  {2} file(s)  ({3})" -f $fam.Name, $fam.Partition, $fam.Members, $fam.Basis)
        }
        if(@($Plan.Families).Count -gt 15){ Write-Host ('  ... and {0} more families' -f (@($Plan.Families).Count - 15)) -ForegroundColor DarkGray }
    }
    if($Plan.PSObject.Properties['Copies'] -and $Plan.Copies){
        $c = $Plan.Copies
        Write-Host ''
        Write-Host ("Copies policy: {0}" -f $c.Policy) -ForegroundColor White
        if("$($c.Policy)" -eq 'NumberCopies' -and ([int]$c.Numbered -gt 0)){
            Write-Host ("  Numbered copies: {0}" -f $c.Numbered)
            foreach($g in (@($c.Groups) | Where-Object { @($_.Copies).Count -gt 0 } | Select-Object -First 10)){
                $names = @(@($g.Copies) | ForEach-Object { '{0} -> {1}' -f (Split-Path $_.Source -Leaf), $_.Assigned })
                Write-Host ("  keeper: {0}  |  {1}" -f (Split-Path $g.Keeper -Leaf), ($names -join '; ')) -ForegroundColor Gray
            }
        }
        if("$($c.Policy)" -eq 'Quarantine' -and ([int]$c.Quarantined -gt 0)){
            Write-Host ("  Quarantined duplicates: {0}" -f $c.Quarantined)
        }
        if("$($c.Policy)" -eq 'ReportOnly' -and ([int]$c.Reported -gt 0)){
            Write-Host ("  Copies reported (nothing moves): {0}" -f $c.Reported)
        }
    }

    # 12.3 OneDrive warnings
    $syncOutCount = 0; $intoCount = 0
    if($Plan.PSObject.Properties['OneDrive'] -and $Plan.OneDrive){
        $syncOutCount = @($Plan.OneDrive.SyncOut).Count
        $intoCount = @($Plan.OneDrive.IntoCloud).Count
        if($warnOD -and ($syncOutCount -gt 0 -or $intoCount -gt 0)){
            Write-Host ''
            if($syncOutCount -gt 0){
                Write-Host ("OneDrive sync-out warning: {0} file(s) will LEAVE OneDrive sync (removed from the cloud):" -f $syncOutCount) -ForegroundColor Yellow
                @($Plan.OneDrive.SyncOut) | Select-Object -First 8 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkYellow }
                if($syncOutCount -gt 8){ Write-Host ('  ... and {0} more' -f ($syncOutCount - 8)) -ForegroundColor DarkYellow }
            }
            if($intoCount -gt 0){
                Write-Host ("OneDrive note: {0} destination(s) are INSIDE OneDrive - moved files will sync to the cloud." -f $intoCount) -ForegroundColor Yellow
            }
        }
    }

    $dc = @($fileMoves | Where-Object { $_.PSObject.Properties['DifferentContent'] -and $_.DifferentContent })
    if($dc.Count -gt 0){
        Write-Host ''
        Write-Host ("Name collisions with different content: {0} (renamed safely at execution; originals are never overwritten)" -f $dc.Count) -ForegroundColor Yellow
    }

    # v2.1.1: per folder move, show the file count, the number of non-code files inside,
    # and any blocked-extension files found OUTSIDE build-output directories (surfaced -
    # the folder still moves; the user sees the risk before confirming).
    if($folderMoves.Count -gt 0){
        Write-Host ''
        Write-Host 'Folder moves:' -ForegroundColor White
        foreach($fm in $folderMoves){
            $info = ''
            if($fm.PSObject.Properties['FilesInside']){
                $info = ('  ({0} file(s), {1} non-code' -f $fm.FilesInside, $fm.NonCodeFilesInside)
                if($fm.PSObject.Properties['BlockedFilesCount'] -and ([int]$fm.BlockedFilesCount -gt 0)){
                    $info += (', {0} BLOCKED-EXTENSION file(s) outside build-output dirs, e.g. {1}' -f $fm.BlockedFilesCount, (@($fm.BlockedFileSamples) | Select-Object -First 3) -join ', ')
                }
                $info += ')'
            }
            Write-Host ('  ' + $fm.Source + ' -> ' + $fm.Destination + $info) -ForegroundColor Gray
        }
    }

    Write-Host ''
    Write-Host 'Affected top-level folders:' -ForegroundColor White
    $moves | Group-Object {
        $p = $_.Source.Split('\')
        $n = [Math]::Min(1, $p.Count - 1)
        if($p.Count -ge 3 -and $p[1] -ieq 'Users'){ $n = 2 }
        $p[0..$n] -join '\'
    } | Sort-Object Count -Descending | Select-Object -First 15 |
        ForEach-Object { Write-Host ('  {0}  ({1} files)' -f $_.Name, $_.Count) }

    Write-Host ''
    Write-Host 'Sample moves:' -ForegroundColor White
    $moves | Select-Object -First $SampleSize | ForEach-Object {
        Write-Host ('  ' + $_.Source) -ForegroundColor DarkGray
        Write-Host ('    -> {0}   [{1}]' -f $_.Destination, $_.Reason) -ForegroundColor Gray
    }
    if($moves.Count -gt $SampleSize){ Write-Host ('  ... and {0} more moves' -f ($moves.Count - $SampleSize)) }
    Write-Host ''

    $deniedTotal = 0
    if($Plan.PSObject.Properties['Mutability'] -and $Plan.Mutability){ $deniedTotal = [int]$Plan.Mutability.DeniedTotal }
    return [pscustomobject]@{
        Moves=$fileMoves.Count; FolderMoves=$folderMoves.Count; Quarantines=$quars.Count; Bytes=$bytes
        DeniedTotal=$deniedTotal; OneDriveSyncOut=$syncOutCount; OneDriveIntoCloud=$intoCount
        DifferentContent=$dc.Count
    }
}

function Invoke-SysOrgPlan {
<#
.SYNOPSIS
    Executes a saved plan; every completed action is appended to Undo\<PlanId>.csv
    immediately (P1-1), so a crash leaves a complete journal of what has been done.
.DESCRIPTION
    - Re-execution guard (P1-3): a plan with an existing undo journal is refused
      unless -Force is passed, in which case journaled sources are skipped (resume).
    - v2.1.1 - EVERY action is re-validated at execution time (the plan file is untrusted
      input): canonical path forms (no '..', no 8.3 short names, no \\?\ namespace),
      exclusion and mutability re-checks against a fresh drive profile, destination
      containment inside the plan root (or resolved known folders), reparse-point and
      cloud-placeholder refusals, plan-time size/timestamp drift checks, PlanId format
      validation and a SHA256 integrity hash over the action list. A failed validation is
      recorded per action as Failed with a reason - the run is never thrown away wholesale.
    - Folder actions (Kind='Folder') use the folder primitive (copy -> verify -> remove).
    - Hash economy (P2-1): same-volume Move actions are not hashed; cross-volume
      and quarantine actions are, using the scan-time hash when available.
    - Collision duplicates found at execution time are quarantined, never deleted.
    - 'CopiedVerified' results are counted as Copied, not Moved (P1-10).
    - Numbered copies whose planned name is now taken are re-numbered safely
      by Get-SysOrgUniquePath (never overwrites).
.EXAMPLE
    $res = Invoke-SysOrgPlan -PlanPath .\Plans\plan.json -Config $cfg -AppRoot C:\SysOrg
.EXAMPLE
    Invoke-SysOrgPlan -PlanPath .\Plans\plan.json -Config $cfg -AppRoot C:\SysOrg -Force  # resume
#>
    param([Parameter(Mandatory)][string]$PlanPath,$Config,[Parameter(Mandatory)][string]$AppRoot,[switch]$Force)
    try { $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json }
    catch { throw "Plan file could not be read: $($_.Exception.Message)" }

    # v2.1.1: the PlanId is used in the journal path - reject anything that is not the
    # documented format (blocks journal-name injection like 'plan-..\\evil').
    if("$($plan.PlanId)" -notmatch $script:PlanIdPattern){
        throw ("Plan id '{0}' is not valid (expected plan-<yyyyMMdd>-<HHmmss>[-<ms>] or migrate-...); refusing to execute." -f $plan.PlanId)
    }

    # v2.1.1: plan integrity - Save-SysOrgPlan stores a SHA256 over the canonical action
    # list. A mismatch means the plan was edited (or corrupted) after the save: refuse
    # loudly, or continue with -Force and a warning. Old plans without the hash are allowed.
    if($plan.PSObject.Properties['IntegrityHash'] -and "$($plan.IntegrityHash)"){
        $expected = "$($plan.IntegrityHash)"
        $actual = Get-SysOrgPlanIntegrityHash -Actions $plan.Actions
        if($actual -ne $expected){
            if(-not $Force){
                throw ("Plan integrity check FAILED: the actions in '{0}' do not match the hash stored at save time (edited or corrupted plan). Pass -Force to run it anyway." -f $PlanPath)
            }
            Write-Warning ("PLAN INTEGRITY MISMATCH: the actions in '{0}' were modified after the plan was saved. Executing anyway because -Force was passed." -f $PlanPath)
            Write-SysOrgLog ("PLAN INTEGRITY MISMATCH (executed with -Force): {0}" -f $PlanPath) -Level ERROR -LogFolder (Join-Path $AppRoot 'Logs')
        }
    }

    $logFolder  = Join-Path $AppRoot 'Logs'
    $undoFolder = Join-Path $AppRoot 'Undo'
    if(-not (Test-Path -LiteralPath $undoFolder)){ New-Item -ItemType Directory -Path $undoFolder -Force | Out-Null }
    $undoPath = Join-Path $undoFolder ('undo-{0}.csv' -f $plan.PlanId)

    # P1-3: re-execution guard with resume support
    $alreadyDone = @{}
    if(Test-Path -LiteralPath $undoPath){
        if(-not $Force){
            throw "Plan '$($plan.PlanId)' already has an undo journal. Undo it first, or pass -Force to resume (journaled actions are skipped)."
        }
        @(Import-Csv -LiteralPath $undoPath) | ForEach-Object { $alreadyDone[$_.OriginalSource] = $true }
    }

    $summary = @{ Moved=0; Copied=0; FolderMoves=0; Numbered=0; Quarantined=0; CollisionDuplicate=0
                  Resumed=0; Failed=0; Skipped=0; BytesMoved=[int64]0 }

    # ---- v2.1.1 executor-side re-validation -------------------------------------
    # A fresh drive profile per source drive. On the supported Windows runtime this
    # re-derives role/scope from the actual hardware; on hosts where no profile can be
    # built (portable test hosts) the plan-time profile from the JSON is used, which is
    # covered by the integrity hash, or a minimal default profile is synthesized.
    $execProfiles = @{}
    function Get-SysOrgExecutorProfile {
        param([string]$Letter,$PlanObj)
        # Key the profile off the plan's OWN drive letter: real plans carry the real letter,
        # so the fresh profile re-derives the true role/scope on Windows. Falling back to the
        # physical source-drive qualifier would misclassify test fixtures whose sources live
        # on the system drive while the plan names a virtual drive.
        $letter2 = "$($PlanObj.Drive)".TrimEnd(':').ToUpperInvariant()
        if([string]::IsNullOrWhiteSpace($letter2)){ $letter2 = "$Letter".TrimEnd(':').ToUpperInvariant() }
        if($execProfiles.ContainsKey($letter2)){ return $execProfiles[$letter2] }
        $prof = $null
        try {
            $fresh = @(Get-SysOrgDriveProfile -Config $Config -Letters $letter2)
            if($fresh.Count -gt 0){ $prof = $fresh[0] }
        } catch { Write-Verbose "Fresh drive profile unavailable for $letter2`: $($_.Exception.Message)" }
        if(-not $prof){
            if($PlanObj.PSObject.Properties['DriveProfile'] -and $PlanObj.DriveProfile -and
               ("$($PlanObj.DriveProfile.Letter)" -ieq $letter2)){
                # NOTE: scalar counters would be rebound in the child scope (classic PowerShell
                # trap), so the warn-once flag lives in the $execProfiles hashtable.
                if(-not $execProfiles.ContainsKey('__warnedPlanProfile')){
                    Write-Warning "No fresh drive profile could be built for $letter2`: using the plan-time profile from the plan file (covered by the plan integrity hash)."
                    $execProfiles['__warnedPlanProfile'] = $true
                }
                $prof = $PlanObj.DriveProfile
            } else {
                $sysLetter = 'C'
                try { if($env:SystemDrive){ $sysLetter = $env:SystemDrive.TrimEnd(':').ToUpperInvariant() } } catch { }
                $role = if($letter2 -ieq $sysLetter){ 'System' } else { 'Data' }
                $prof = [pscustomobject]@{ Letter=$letter2; Root=("{0}:\" -f $letter2); Role=$role; ProposedScope='FullDrive'
                                           KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
            }
        }
        $execProfiles[$letter2] = $prof
        return $prof
    }
    # Old plans predate the plan-time size/timestamp snapshot: warn once, skip drift checks.
    $driftCapable = $false
    foreach($probe in @($plan.Actions)){
        if($probe.PSObject.Properties['PlannedLastWriteTimeUtc'] -and "$($probe.PlannedLastWriteTimeUtc)"){ $driftCapable = $true; break }
    }
    if((-not $driftCapable) -and @($plan.Actions).Count -gt 0){
        Write-Warning 'This plan predates v2.1.1 (no plan-time size/timestamp snapshot); the changed-since-plan drift check is not available for it.'
    }
    # -----------------------------------------------------------------------------


    # P1-1: journal is appended and flushed after EVERY row, not written once at the end
    $journalExists = Test-Path -LiteralPath $undoPath
    $writer = New-Object System.IO.StreamWriter($undoPath, $true, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true

    try {
        if(-not $journalExists){
            $writer.WriteLine('Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash')
        }
        $allActions = @($plan.Actions)
        $i = 0; $total = $allActions.Count

        foreach($a in $allActions){
            $i++
            Write-Progress -Activity 'Executing plan' `
                -Status "$i / $total : $(Split-Path $a.Source -Leaf)" `
                -PercentComplete $(if($total -gt 0){ [int](100 * $i / $total) } else { 0 })

            if($alreadyDone.ContainsKey($a.Source)){
                $summary.Resumed++
                Write-SysOrgLog "Resume: skipping already-journaled source: $($a.Source)" -LogFolder $logFolder
                continue
            }

            $kind = 'File'
            if($a.PSObject.Properties['Kind'] -and "$($a.Kind)"){ $kind = "$($a.Kind)" }
            $isContainerAction = ($kind -eq 'Folder')

            # ---- v2.1.1: re-validate this action before anything moves. A failed
            # validation is recorded as Failed with a reason - never thrown wholesale.
            $refuse = $null
            $canonSrc = Get-SysOrgCanonicalPlanPath -Path "$($a.Source)"
            $canonDst = Get-SysOrgCanonicalPlanPath -Path "$($a.Destination)"
            if($canonSrc.Error){ $refuse = 'Unsafe source path: ' + $canonSrc.Error }
            elseif($canonDst.Error){ $refuse = 'Unsafe destination path: ' + $canonDst.Error }
            if(-not $refuse){
                if(Test-SysOrgExcludedPath -Path (Split-Path $canonSrc.Path -Parent) -Config $Config){
                    $refuse = 'Source is in a protected/excluded location'
                } elseif(Test-Path -LiteralPath $canonSrc.Path){
                    if(Test-SysOrgReparsePoint -Path $canonSrc.Path){
                        $refuse = 'Source is a reparse point (junction/symlink)'
                    } elseif(Test-SysOrgCloudPlaceholderAttributes -Attributes ([int](Get-Item -LiteralPath $canonSrc.Path -Force).Attributes)){
                        $refuse = 'Source is a cloud placeholder; opening it would hydrate the cloud library'
                    }
                }
            }
            if(-not $refuse){
                $srcQual = Split-Path $canonSrc.Path -Qualifier -ErrorAction SilentlyContinue
                $prof2 = Get-SysOrgExecutorProfile -Letter ("$srcQual".TrimEnd(':')) -PlanObj $plan
                if($isContainerAction){
                    $mut = Test-SysOrgFileMutable -Path $canonSrc.Path -Extension '' -DriveProfile $prof2 -Config $Config -Container
                } else {
                    $ext2 = [System.IO.Path]::GetExtension($canonSrc.Path).ToLowerInvariant()
                    $mut = Test-SysOrgFileMutable -Path $canonSrc.Path -Extension $ext2 -DriveProfile $prof2 -Config $Config
                }
                if(-not $mut.Allowed){ $refuse = 'Mutability denied at execution time: ' + $mut.Reason }
            }
            if(-not $refuse){
                $destCheck = Test-SysOrgPlanDestinationAllowed -Destination $canonDst.Path -Plan $plan -Config $Config
                if(-not $destCheck.Allowed){ $refuse = 'Unsafe destination: ' + $destCheck.Reason }
            }
            if(-not $refuse -and (-not $isContainerAction) -and $driftCapable -and (Test-Path -LiteralPath $canonSrc.Path)){
                $fiNow = Get-Item -LiteralPath $canonSrc.Path -Force
                if($a.PSObject.Properties['PlannedLength'] -and ($null -ne $a.PlannedLength) -and ([int64]$fiNow.Length -ne [int64]$a.PlannedLength)){
                    $summary.Skipped++
                    Write-SysOrgLog "Skipped (changed since plan - size differs): $($a.Source)" -Level WARN -LogFolder $logFolder
                    continue
                }
                if($a.PSObject.Properties['PlannedLastWriteTimeUtc'] -and "$($a.PlannedLastWriteTimeUtc)"){
                    try{
                        # After the JSON round trip this may arrive as a [datetime]
                        # (ConvertFrom-Json parses ISO strings) or as the stored string.
                        $pv = $a.PlannedLastWriteTimeUtc
                        $plannedUtc = $null
                        if($pv -is [datetime]){ $plannedUtc = $pv.ToUniversalTime() }
                        else { $plannedUtc = [datetime]::Parse("$pv", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
                        $deltaSec = [Math]::Abs(($fiNow.LastWriteTimeUtc - $plannedUtc).TotalSeconds)
                        if($deltaSec -gt 2){
                            $summary.Skipped++
                            Write-SysOrgLog "Skipped (changed since plan - last write time differs): $($a.Source)" -Level WARN -LogFolder $logFolder
                            continue
                        }
                    } catch { Write-Verbose "Drift check parse failed for '$($a.PlannedLastWriteTimeUtc)': $($_.Exception.Message)" }
                }
            }
            if($refuse){
                $summary.Failed++
                Write-SysOrgLog ("REFUSED ({0}): {1} -> {2}" -f $refuse, $a.Source, $a.Destination) -Level ERROR -LogFolder $logFolder
                continue
            }
            # validation passed: use the CANONICAL paths for the move, the logs and the journal
            $aSource = $canonSrc.Path
            $aDestination = $canonDst.Path

            # P2-1: hash only when the journal needs it (quarantine or cross-volume files);
            # reuse the scan-time hash when present. Folder moves are count/byte verified.
            $needsHash = ($kind -eq 'File') -and
                         (("$($a.Action)" -eq 'Quarantine') -or
                          ((Split-Path $aSource -Qualifier -ErrorAction SilentlyContinue) -ine (Split-Path $aDestination -Qualifier -ErrorAction SilentlyContinue)))
            $hashBefore = $null
            if($needsHash){
                if($a.PSObject.Properties['Hash'] -and $a.Hash){ $hashBefore = $a.Hash }
                else { $hashBefore = Get-SysOrgFileHash -Path $aSource }
            }

            if($kind -eq 'Folder'){
                $result = Invoke-SysOrgSafeMoveFolder -Source $aSource -Destination $aDestination -Config $Config
            } else {
                $result = Invoke-SysOrgSafeMove -Source $aSource -Destination $aDestination -Config $Config
            }

            switch($result.Status){
                'Moved' {
                    if("$($a.Action)" -eq 'Quarantine'){
                        $summary.Quarantined++
                        Write-SysOrgLog "Quarantined duplicate: $($a.Source) -> $($result.Destination)" -Level ACTION -LogFolder $logFolder
                    } else {
                        if($kind -eq 'Folder'){
                            $summary.FolderMoves++
                            Write-SysOrgLog "Moved folder: $($a.Source) -> $($result.Destination)" -Level ACTION -LogFolder $logFolder
                        } else {
                            $summary.Moved++
                            if($a.PSObject.Properties['CopyIndex'] -and $a.CopyIndex){ $summary.Numbered++ }
                            $summary.BytesMoved += [int64]$a.SizeBytes
                            Write-SysOrgLog "Moved: $($a.Source) -> $($result.Destination)" -Level ACTION -LogFolder $logFolder
                        }
                    }
                    # P0-fix: format into a variable FIRST, then write (the -f operator binds
                    # only to its immediate next expression inside a method-call argument list).
                    # v2.1.1: fields are CSV-escaped and the journal stores the CANONICAL source.
                    $journalLine = (ConvertTo-SysOrgCsvField (Get-Date -Format s)) + ',' + (ConvertTo-SysOrgCsvField $plan.PlanId) + ',' +
                                   (ConvertTo-SysOrgCsvField $kind) + ',' + (ConvertTo-SysOrgCsvField "$($a.Action)") + ',' +
                                   (ConvertTo-SysOrgCsvField $aSource) + ',' + (ConvertTo-SysOrgCsvField "$($result.Destination)") + ',' +
                                   (ConvertTo-SysOrgCsvField "$hashBefore")
                    $writer.WriteLine($journalLine)
                }
                'CopiedVerified' {
                    if($kind -eq 'Folder'){ $summary.FolderMoves++ } else { $summary.Copied++ }
                    $journalLine = (ConvertTo-SysOrgCsvField (Get-Date -Format s)) + ',' + (ConvertTo-SysOrgCsvField $plan.PlanId) + ',' +
                                   (ConvertTo-SysOrgCsvField $kind) + ',' + (ConvertTo-SysOrgCsvField "$($a.Action)") + ',' +
                                   (ConvertTo-SysOrgCsvField $aSource) + ',' + (ConvertTo-SysOrgCsvField "$($result.Destination)") + ',' +
                                   (ConvertTo-SysOrgCsvField "$hashBefore")
                    $writer.WriteLine($journalLine)
                    Write-SysOrgLog "Copied+verified: $($a.Source) -> $($result.Destination) ($($result.Message))" -Level WARN -LogFolder $logFolder
                }
                'CollisionDuplicate' {
                    $summary.CollisionDuplicate++
                    $letter = (Split-Path $aSource -Qualifier).TrimEnd(':')
                    $qFolderName = Get-SysOrgSetting $Config 'Copies.QuarantineFolderName' $null
                    if(-not $qFolderName){ $qFolderName = Get-SysOrgSetting $Config 'Duplicates.QuarantineFolderName' '_Duplicates' }
                    $qRoot = Join-Path (Get-SysOrgDestinationRoot -Letter $letter -Config $Config) "$qFolderName"
                    $qRoot = Join-Path $qRoot ('manual-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    $r2 = Invoke-SysOrgSafeMove -Source $aSource -Destination (Join-Path $qRoot (Split-Path $aSource -Leaf)) -Config $Config
                    if(($r2.Status -eq 'Moved') -or ($r2.Status -eq 'CopiedVerified')){
                        $summary.Quarantined++
                        $journalLine = (ConvertTo-SysOrgCsvField (Get-Date -Format s)) + ',' + (ConvertTo-SysOrgCsvField $plan.PlanId) + ',' +
                                       (ConvertTo-SysOrgCsvField 'File') + ',' + (ConvertTo-SysOrgCsvField 'Quarantine') + ',' +
                                       (ConvertTo-SysOrgCsvField $aSource) + ',' + (ConvertTo-SysOrgCsvField "$($r2.Destination)") + ',' +
                                       (ConvertTo-SysOrgCsvField "$hashBefore")
                        $writer.WriteLine($journalLine)
                        Write-SysOrgLog "Collision duplicate quarantined: $($a.Source) -> $($r2.Destination)" -Level ACTION -LogFolder $logFolder
                    } else {
                        $summary.Failed++
                        Write-SysOrgLog "FAILED (collision quarantine): $($a.Source): $($r2.Message)" -Level ERROR -LogFolder $logFolder
                    }
                }
                default {
                    $summary.Failed++
                    Write-SysOrgLog "FAILED: $($a.Source): $($result.Message)" -Level ERROR -LogFolder $logFolder
                }
            }
        }
    } finally {
        $writer.Dispose()
    }

    Write-Progress -Activity 'Executing plan' -Completed
    Write-SysOrgLog ("Plan {0} finished. Moved={1} Copied={2} Folders={3} Numbered={4} Quarantined={5} Resumed={6} Failed={7} Skipped={8}" -f `
        $plan.PlanId, $summary.Moved, $summary.Copied, $summary.FolderMoves, $summary.Numbered, $summary.Quarantined, $summary.Resumed, $summary.Failed, $summary.Skipped) -LogFolder $logFolder
    return [pscustomobject]@{ PlanId=$plan.PlanId; UndoFile=$undoPath; Summary=$summary }
}

function Undo-SysOrgPlan {
<#
.SYNOPSIS
    Reverses a plan using its undo journal, in reverse order. Never overwrites.
.DESCRIPTION
    Content verification (P1-4): rows carrying a ContentHash are re-hashed before
    restore; a file whose content changed since the move is skipped (SkippedChanged).
    Rows with an empty hash (same-volume moves after the P2-1 hash economy) fall back
    to path-only undo - a documented tradeoff. Folder rows (Kind='Folder') restore with
    the folder primitive. Numbered copies restore their ORIGINAL names because the
    journal's OriginalSource column carries the pre-move path. Restores into occupied
    slots get unique ' (2)' suffixed paths.
    v2.1.1: the journal is UNTRUSTED INPUT. The PlanId is validated (it indexes the
    journal path) and every row's CurrentLocation and OriginalSource are canonicalized
    and re-checked (exclusion, reparse point, cloud placeholder) BEFORE anything moves,
    so a tampered journal cannot move arbitrary files.
.EXAMPLE
    Undo-SysOrgPlan -PlanId plan-20260101-093000 -AppRoot C:\SysOrg -Config $cfg
#>
    param([Parameter(Mandatory)][string]$PlanId,[Parameter(Mandatory)][string]$AppRoot,$Config)
    if("$PlanId" -notmatch $script:PlanIdPattern){
        throw ("Plan id '{0}' is not valid (expected plan-<yyyyMMdd>-<HHmmss>[-<ms>] or migrate-...); refusing to touch a journal." -f $PlanId)
    }
    $undoPath = Join-Path (Join-Path $AppRoot 'Undo') ('undo-{0}.csv' -f $PlanId)
    if(-not (Test-Path -LiteralPath $undoPath)){ throw "No undo journal found for plan '$PlanId'." }
    $logFolder = Join-Path $AppRoot 'Logs'
    $rows = @(Import-Csv -LiteralPath $undoPath)
    $restored=0; $failed=0; $skippedMissing=0; $skippedChanged=0

    for($i=$rows.Count-1; $i -ge 0; $i--){
        $row = $rows[$i]
        $current  = $row.CurrentLocation
        $original = $row.OriginalSource
        # v2.1.1: tampered-journal protection - both endpoints must be canonical and
        # must not sit in protected locations. A refused row is counted as Failed.
        $canonCur = Get-SysOrgCanonicalPlanPath -Path "$current"
        $canonOrig = Get-SysOrgCanonicalPlanPath -Path "$original"
        if($canonCur.Error -or $canonOrig.Error){
            $failed++
            Write-SysOrgLog ("Undo REFUSED (unsafe journal row: {0} / {1}): {2} -> {3}" -f $canonCur.Error, $canonOrig.Error, $current, $original) -Level ERROR -LogFolder $logFolder
            continue
        }
        $current = $canonCur.Path
        $original = $canonOrig.Path
        if(Test-SysOrgExcludedPath -Path $current -Config $Config){
            $failed++
            Write-SysOrgLog "Undo REFUSED (CurrentLocation is a protected/excluded path): $current" -Level ERROR -LogFolder $logFolder
            continue
        }
        if(Test-SysOrgExcludedPath -Path $original -Config $Config){
            $failed++
            Write-SysOrgLog "Undo REFUSED (restore target is a protected/excluded path): $original" -Level ERROR -LogFolder $logFolder
            continue
        }
        if(Test-Path -LiteralPath $current){
            if(Test-SysOrgReparsePoint -Path $current){
                $failed++
                Write-SysOrgLog "Undo REFUSED (CurrentLocation is a reparse point): $current" -Level ERROR -LogFolder $logFolder
                continue
            }
            if(-not (Test-Path -LiteralPath $current -PathType Container) -and
               (Test-SysOrgCloudPlaceholderAttributes -Attributes ([int](Get-Item -LiteralPath $current -Force).Attributes))){
                $failed++
                Write-SysOrgLog "Undo REFUSED (CurrentLocation is a cloud placeholder): $current" -Level ERROR -LogFolder $logFolder
                continue
            }
        }
        if(-not (Test-Path -LiteralPath $current)){ $skippedMissing++; Write-SysOrgLog "Undo skip (missing): $current" -Level WARN -LogFolder $logFolder; continue }
        # P1-4: verify content has not changed since the move (file rows only)
        if($row.ContentHash -and (-not (Test-Path -LiteralPath $current -PathType Container))){
            $nowHash = Get-SysOrgFileHash -Path $current
            if($nowHash -and ($nowHash -ne $row.ContentHash)){
                $skippedChanged++
                Write-SysOrgLog "Undo skip (content changed since move): $current" -Level WARN -LogFolder $logFolder
                continue
            }
        }
        $origDir = Split-Path $original -Parent
        if(-not (Test-Path -LiteralPath $origDir)){ New-Item -ItemType Directory -Path $origDir -Force | Out-Null }
        if(Test-Path -LiteralPath $original){ $dest = Get-SysOrgUniquePath -Path $original }
        else { $dest = $original }
        if(Test-Path -LiteralPath $current -PathType Container){
            $r = Invoke-SysOrgSafeMoveFolder -Source $current -Destination $dest -Config $Config
        } else {
            $r = Invoke-SysOrgSafeMove -Source $current -Destination $dest -Config $Config
        }
        if(($r.Status -eq 'Moved') -or ($r.Status -eq 'CopiedVerified')){
            $restored++; Write-SysOrgLog "Undo: $current -> $($r.Destination)" -Level ACTION -LogFolder $logFolder
        } else {
            $failed++; Write-SysOrgLog "Undo FAILED: $current : $($r.Message)" -Level ERROR -LogFolder $logFolder
        }
    }
    return [pscustomobject]@{ Restored=$restored; Failed=$failed; SkippedMissing=$skippedMissing; SkippedChanged=$skippedChanged }
}

function New-SysOrgScanReport {
<#
.SYNOPSIS
    Report-only scan used by the weekly scheduled task. Writes a text report;
    moves nothing. Always uses the narrowed ScanRoots scope and never reads cache.
.EXAMPLE
    New-SysOrgScanReport -Letter C -Config $cfg -AppRoot C:\SysOrg
#>
    param([Parameter(Mandatory)][string]$Letter,$Config,[Parameter(Mandatory)][string]$AppRoot)
    $logFolder = Join-Path $AppRoot 'Logs'
    Write-SysOrgLog "Scheduled report scan starting for drive $Letter`:" -LogFolder $logFolder
    # @() wrapping: the inventory and duplicate functions stream their records
    # (an empty result emits nothing), so callers must collect with @().
    $inv = @(Get-SysOrgInventory -Letter $Letter -Config $Config -CacheFolder (Join-Path $AppRoot 'Cache') -DefaultScope -NoCache)
    $catCounts = $inv | Group-Object Category | Sort-Object Count -Descending
    $dupGroups = @(Find-SysOrgDuplicates -Inventory $inv -Config $Config)
    $folderMap = Get-SysOrgFolderMap -Config $Config
    $pk = @{}
    foreach($f in $inv){
        $c = "$($f.Category)"
        $rel = "$($folderMap['Other'])"
        if($folderMap.ContainsKey($c)){ $rel = "$($folderMap[$c])" }
        $pk["$($f.FullName)"] = $rel
    }
    $fam = Get-SysOrgNameFamilies -Inventory $inv -PartitionLookup $pk -Config $Config

    $reportsFolder = Join-Path (Get-SysOrgDestinationRoot -Letter $Letter -Config $Config) (Get-SysOrgSetting $Config 'ReportsFolderName' '_Reports')
    if(-not (Test-Path -LiteralPath $reportsFolder)){ New-Item -ItemType Directory -Path $reportsFolder -Force | Out-Null }
    $file = Join-Path $reportsFolder ('SysOrg-ScanReport-{0}-{1}.txt' -f $Letter, (Get-Date -Format 'yyyyMMdd-HHmm'))

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("SysOrg scan report - drive $Letter`: - $(Get-Date)")
    $lines.Add("Files scanned: $($inv.Count)   (REPORT ONLY - nothing was moved)")
    if($prof){ $lines.Add("Drive profile: role=$($prof.Role), scope=$($prof.ProposedScope), destination=$($prof.DestinationRoot)") }
    $longPaths = @($inv | Where-Object { $_.Category -eq 'SkippedLongPath' })
    if($longPaths.Count -gt 0){ $lines.Add("Paths >= 260 characters recorded but not planned: $($longPaths.Count)") }
    $lines.Add('')
    $lines.Add('By routing category:')
    foreach($c in $catCounts){ $lines.Add(('  {0,-15} {1}' -f $c.Name, $c.Count)) }
    $lines.Add('')
    $lines.Add("Duplicate groups: $(@($dupGroups).Count)")
    foreach($dg in (@($dupGroups) | Select-Object -First 20)){
        $lines.Add(('  Keep: ' + $dg.KeepPath + '  (' + $dg.KeepReason + ')'))
        foreach($d in $dg.Duplicates){ $lines.Add(('    copy: ' + $d)) }
    }
    $lines.Add('')
    $lines.Add("Detected families: $(@($fam.Families).Count)")
    foreach($fl in (@($fam.Families) | Select-Object -First 20)){
        $lines.Add(('  {0}  [{1}]  {2} file(s)  ({3})' -f $fl.Name, $fl.Partition, $fl.Members, $fl.Basis))
    }
    $lines | Set-Content -LiteralPath $file -Encoding UTF8
    Write-SysOrgLog "Report written: $file" -LogFolder $logFolder
    return $file
}

Export-ModuleMember -Function *-SysOrg*
