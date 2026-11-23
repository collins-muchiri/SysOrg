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
          $ProjectFolders,
          $UserCollections,
          $VersionPairs,
          $FileCache,
          [hashtable]$NewCacheEntries,
          [AllowEmptyCollection()]$SkippedScanRoots)

    if(-not $Config){ throw 'New-SysOrgPlan requires -Config.' }
    if(-not $DriveProfile){ throw 'No drive profile was provided. A plan cannot be built without one (run -ProfileDrives first).' }
    if(-not $Inventory){ throw 'New-SysOrgPlan requires an inventory (run a scan first).' }
    if(-not $KnownFolders -or @($KnownFolders).Count -eq 0){ $KnownFolders = @(Get-SysOrgKnownFolders) }
    if(-not $ProjectFolders){ $ProjectFolders = @() }
    # v3.0.2 A1: test hook - SYSORG_FAULT_PLANBUILD forces a synthetic plan-build
    # failure through the REAL code path so the diagnostics fixtures (log carries a
    # stack trace, the user sees "Nothing was modified.") run on any machine, any host.
    if($env:SYSORG_FAULT_PLANBUILD){
        throw ("Synthetic plan-build fault (SYSORG_FAULT_PLANBUILD={0})." -f $env:SYSORG_FAULT_PLANBUILD)
    }

    # v2.1.1: millisecond suffix - two plans planned within the same second no longer collide
    $stamp = Get-Date
    $planId = 'plan-' + $stamp.ToString('yyyyMMdd-HHmmss') + '-' + $stamp.ToString('fff')
    $root      = Get-SysOrgDestinationRoot -Letter $Letter -Config $Config
    $style     = "$(Get-SysOrgSetting $Config 'DestinationStyle' 'OrganizedRoot')"
    $maxActions = [int](Get-SysOrgSetting $Config 'MaxPlanActions' 5000)
    $dateMode  = Get-SysOrgSetting $Config 'DateFolders' 'Year'
    $dlDateMode = Get-SysOrgSetting $Config 'Downloads.DateFolders' "$(Get-SysOrgSetting $Config 'DateFolders' 'Year')"
    $folderMap = Get-SysOrgFolderMap -Config $Config
    # v3.0: the Findable layout profile (Windows/Compact4 keep the legacy routing below)
    $layoutProfile = 'Windows'
    try { $layoutProfile = Get-SysOrgLayoutProfile -Config $Config } catch { $layoutProfile = 'Windows' }
    $findable = ($layoutProfile -eq 'Findable')
    $layoutCap = [int](Get-SysOrgSetting $Config 'Layout.MaxFilesPerFolder' 150)
    $layoutMin = [int](Get-SysOrgSetting $Config 'Layout.MinFilesPerFolder' 8)
    $layoutPathBudget = [int](Get-SysOrgSetting $Config 'Layout.MaxPathChars' 200)
    $relBaseOf = @{}
    $noDateOf = @{}   # rule-matched leaves carry their own date tokens - never add another
    # v3.0 Phase 2.9: decision records per source + rule sets loaded ONCE (fail closed:
    # an invalid user-rules file refuses the whole plan)
    $decOf = @{}
    $needsDecision = New-Object System.Collections.Generic.List[object]
    $minConfidence = [double](Get-SysOrgSetting $Config 'Classify.MinConfidence' 0.40)
    $reviewMode = "$(Get-SysOrgSetting $Config 'Review.Mode' 'Report')"
    $reviewFolder = "$(Get-SysOrgSetting $Config 'Review.FolderName' '_Review')"
    $planAppRoot = "$(Get-SysOrgSetting $Config 'AppRoot' '')"
    $userRules = @()
    $learnedRules = @()
    if($findable){
        $userRules = @(Get-SysOrgUserRules -Config $Config -AppRoot $planAppRoot)
        $learnedPath = "$(Get-SysOrgSetting $Config 'Rules.LearnedRulesPath' '')"
        if([string]::IsNullOrWhiteSpace($learnedPath)){
            try { $learnedPath = ((Get-SysOrgDestinationRoot -Letter $Letter -Config $Config) + '\_Index\LearnedRules.psd1') } catch { $learnedPath = '' }
        }
        $learnedRules = @(Get-SysOrgLearnedRules -Config $Config -Path $learnedPath)
        # v3.0.1 B3: the self-supervised model built from the user's OWN curated folders
        # (existing subfolders of the known folders in scope). Loaded once per plan;
        # rebuilt only when its input fingerprint changed. Never required: when the
        # model cannot be built the pipeline simply runs without it.
        $learnModel = $null
        if(Get-SysOrgSetting $Config 'Learn.Enabled' $true){
            try{
                # v3.0.1: the model trains ONLY on the drive profile's known folders -
                # the folders IN SCOPE for this scan. New-SysOrgPlan defaults the
                # routing $KnownFolders to the registry-resolved real folders when the
                # caller passes none; feeding those to the learner would train on the
                # machine's real profile even when the scan has nothing to do with it.
                $lm = New-SysOrgLearnModel -Config $Config -DestinationRoot $root -KnownFolders @($DriveProfile.KnownFolders)
                if($lm -and $lm.Model){ $learnModel = $lm.Model }
            } catch { Write-Verbose ("Learn model unavailable (continuing without it): {0}" -f $_.Exception.Message) }
        }
    }
    # v3.0.1 C1: the lexicon is loaded ONCE per plan and passed into every pipeline
    # call (it used to be re-parsed from disk per file - the #1 plan-build hotspot
    # when a lexicon file exists).
    $planLexicon = $null
    try { $planLexicon = Get-SysOrgLexicon -Config $Config -AppRoot $planAppRoot } catch { throw }
    # v3.0 Phase 3.1: metadata through the persistent file-state cache - a fresh hit
    # returns the stored EXIF/ID3/MP4/Office/PDF/text result WITHOUT re-reading the file
    $cachedExtractors = $null
    if($FileCache){
        $cachedExtractors = @{
            exif   = { param($Path) Get-SysOrgCachedMetadata -Path $Path -Family 'exif'   -FileCache $FileCache -NewEntries $NewCacheEntries }
            id3    = { param($Path) Get-SysOrgCachedMetadata -Path $Path -Family 'id3'    -FileCache $FileCache -NewEntries $NewCacheEntries }
            mp4    = { param($Path) Get-SysOrgCachedMetadata -Path $Path -Family 'mp4'    -FileCache $FileCache -NewEntries $NewCacheEntries }
            office = { param($Path) Get-SysOrgCachedMetadata -Path $Path -Family 'office' -FileCache $FileCache -NewEntries $NewCacheEntries }
            pdf    = { param($Path) Get-SysOrgCachedMetadata -Path $Path -Family 'pdf'    -FileCache $FileCache -NewEntries $NewCacheEntries }
            text   = { param($Path) Get-SysOrgCachedMetadata -Path $Path -Family 'text'   -FileCache $FileCache -NewEntries $NewCacheEntries }
        }
    }

    $copiesPolicy = "$(Get-SysOrgSetting $Config 'Copies.Policy' 'NumberCopies')"
    $qFolder      = "$(Get-SysOrgSetting $Config 'Copies.QuarantineFolderName' '_Duplicates')"
    $startIndex   = [int](Get-SysOrgSetting $Config 'Copies.StartIndex' 2)
    $suffixStyle  = "$(Get-SysOrgSetting $Config 'Copies.SuffixStyle' 'Parentheses')"
    $unknownSrc   = "$(Get-SysOrgSetting $Config 'Downloads.UnknownSourceFolder' '_NoSource')"
    $groupBy      = "$(Get-SysOrgSetting $Config 'Downloads.GroupBy' 'SourceFirst')"
    $useZone      = [bool](Get-SysOrgSetting $Config 'Downloads.UseZoneIdentifier' $true)
    $storeUrls    = [bool](Get-SysOrgSetting $Config 'Privacy.StoreFullUrlsInJournal' $true)

    # v3.0.1 C1/C4: ONE mutability-policy cache and ONE compiled exclusion matcher
    # per plan build - Test-SysOrgFileMutable was re-resolving 4 dotted-path settings
    # and looping every exclusion pattern for EVERY file (the #1 plan-build hotspot).
    $mutPolicyCache = @{}
    $planExMatcher = $null
    try { $planExMatcher = New-SysOrgExclusionMatcher -Config $Config } catch { $planExMatcher = $null }

    $organizedSet = Get-SysOrgOrganizedDirSet -Inventory $Inventory -Config $Config
    $categoryNames = Get-SysOrgCategoryNames -KnownFolders $KnownFolders
    $kfPathSet = @{}
    foreach($k in @($KnownFolders)){ if($k.Path){ $kfPathSet[(("$($k.Path)").Replace('/','\').TrimEnd('\')).ToLowerInvariant()] = $true } }
    # v2.1.1: OneDrive roots come from the central helper (env vars + registry accounts)
    # instead of $env:OneDrive only.

    # project-folder coverage: files under a detected project move as one unit
    $projectDirSet = @{}
    foreach($pf in @($ProjectFolders)){ $projectDirSet[(("$($pf.Path)").Replace('/','\').TrimEnd('\')).ToLowerInvariant()] = $true }

    # v3.0.1 B2: user collections move as ONE unit - their files are never planned
    # individually and never flattened. Deterministic processing order (path-sorted).
    # Keys are the NATIVE path lowercased (no separator rewriting) so matching works
    # identically on Windows and portable hosts.
    $collectionDirSet = @{}   # lowercase native dir -> @{ Move=<bool>; Reason=<string> }
    $collectionList = New-Object System.Collections.Generic.List[object]
    $colMinRatioEarly = [double](Get-SysOrgSetting $Config 'Folders.MinMajorityRatio' 0.6)
    foreach($uc in (@($UserCollections) | Sort-Object { ("$($_.Path)").ToLowerInvariant() })){
        if(-not $uc){ continue }
        if(-not "$($uc.Path)"){ continue }
        $cp = ("$($uc.Path)").TrimEnd('\').TrimEnd('/')
        $ck = $cp.ToLowerInvariant()
        $moves = ([double]$uc.MajorityRatio -ge $colMinRatioEarly)
        $collectionDirSet[$ck] = @{ Move=$moves }
        $collectionList.Add([pscustomobject]@{ Path=$cp; Name="$($uc.Name)"; SafeName="$($uc.SafeName)";
            MajorityCategory="$($uc.MajorityCategory)"; MajoritySubtype="$($uc.MajoritySubtype)";
            MajorityRatio=[double]$uc.MajorityRatio; Files=[int]$uc.Files; Moves=$moves })
    }

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

    # v3.0.2 B2: scan roots that were dropped carry into the plan (header + warnings)
    if(-not $SkippedScanRoots){ $SkippedScanRoots = @() }
    $SkippedScanRoots = @($SkippedScanRoots)
    if($SkippedScanRoots.Count -gt 0){
        [void]$warnings.Add(("{0} scan root(s) were NOT scanned and are NOT part of this plan: {1}" -f $SkippedScanRoots.Count, (($SkippedScanRoots | ForEach-Object { '{0} ({1})' -f (Split-Path "$($_.Path)" -Leaf), "$($_.Reason)" }) -join ', ')))
    }

    # NOTE: this nested helper only MUTATES objects ($skipped list, $mutDenied h[hashtable) -
    # scalar counters would be rebound in the child scope, a classic PowerShell trap.
    # v3.0.1 A3: every skip carries an honest group tag:
    #   Protected = the mutability engine refused (provably never touched)
    #   Preserved = intentionally left alone (organized folders, project units, user
    #               collections, idempotent re-plans)
    #   Decision  = below the confidence floor - needs a human decision
    #   Other     = recorded but not planned (long paths, system types, analysis errors)
    # Only Protected rows count into Mutability.Denied - preserved and needs-a-decision
    # files were never 'denied by mutability'.
    function Add-SysOrgPlanSkip {
        param([string]$Source,[string]$Reason,[string]$Group='Other')
        $skipped.Add([pscustomobject]@{ Source=$Source; Reason=$Reason; Group=$Group })
        if($Group -eq 'Protected'){
            if($mutDenied.ContainsKey($Reason)){ $mutDenied[$Reason]++ } else { $mutDenied[$Reason] = 1 }
        }
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
                Add-SysOrgPlanSkip -Source $src -Reason 'Path >= 260 characters (recorded; PowerShell 5.1 cannot address it)' -Group 'Other'
                continue
            }
            if(Test-SysOrgDestinationPath -Path $src -Config $Config){ continue }
            # protected path (mutability engine, row 1 of the policy matrix)
            $parentDir = Split-Path $src -Parent
            if(Test-SysOrgExcludedPath -Path $parentDir -Config $Config){
                Add-SysOrgPlanSkip -Source $src -Reason 'Protected path' -Group 'Protected'
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
                Add-SysOrgPlanSkip -Source $src -Reason 'Inside a detected code project folder (moved as one unit)' -Group 'Preserved'
                continue
            }
            # v3.0.1 B2: a user collection moves as ONE unit - files inside are never
            # planned individually. Collections deliberately come BEFORE the organized-
            # heuristic preservation: the point of B2 is that a bounded, user-named
            # folder (often single-category, which the heuristic would silently
            # 'preserve') is treated as one intentional unit. Mutability still gates
            # the collection move itself.
            $cur = $parentDir.ToLowerInvariant()
            $inCollection = $null
            while($cur -and ($cur.Length -gt 3)){
                if($collectionDirSet.ContainsKey($cur)){ $inCollection = $cur; break }
                $cur2 = $null
                try { $cur2 = Split-Path $cur -Parent } catch { $cur2 = $null }
                if(-not $cur2 -or ("$cur2").Length -ge $cur.Length){ break }
                $cur = ("$cur2")
            }
            if($inCollection){
                # never flattened: the whole unit moves (or waits for a decision) together
                if($collectionDirSet[$inCollection]['Move']){
                    Add-SysOrgPlanSkip -Source $src -Reason 'Inside a user collection folder (moved as one unit)' -Group 'Preserved'
                } else {
                    Add-SysOrgPlanSkip -Source $src -Reason 'Inside a user collection folder (left in place, below confidence - never flattened)' -Group 'Decision'
                }
                continue
            }
            # preservation: organized heuristic + localized category recognition (W2)
            $pres = Test-SysOrgPlanPreservedDir -Directory $parentDir
            if($pres){ Add-SysOrgPlanSkip -Source $src -Reason $pres -Group 'Preserved'; continue }
            # 1) mutability engine (W3)
            $mut = Test-SysOrgFileMutable -Path $src -Extension "$($f.Extension)" -DriveProfile $DriveProfile -Config $Config -PolicyCache $mutPolicyCache -ExMatcher $planExMatcher
            if(-not $mut.Allowed){
                Add-SysOrgPlanSkip -Source $src -Reason "$($mut.Reason)" -Group 'Protected'
                continue
            }
            if("$($f.Category)" -eq 'SKIP'){
                Add-SysOrgPlanSkip -Source $src -Reason 'Non-organizable type (system PerceivedType)' -Group 'Other'
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
            if($prov){ $bucket = Get-SysOrgSourceBucket -HostUrl "$($prov['HostUrl'])" -ReferrerUrl "$($prov['ReferrerUrl'])" -FileName "$($f.Name)" -Config $Config -AppRoot "$planAppRoot" }
            $downloadContext = $inDownloads -or ($null -ne $prov) -or ($category -eq 'Installers')
            $sourceName = $null
            if($downloadContext){
                if((-not $bucket) -and ($inDownloads -or $prov)){
                    $bucket = Get-SysOrgSourceBucket -HostUrl '' -ReferrerUrl '' -FileName "$($f.Name)" -Config $Config -AppRoot "$planAppRoot"
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
            # v3.0 Findable: the FULL Decision pipeline runs here (context, true type,
            # metadata extractors, date resolution, lexicon, user/learned rules,
            # confidence gating). Safety gates already passed above - the pipeline's
            # gate stage is unused in the plan path.
            if($findable){
                $dec = Invoke-SysOrgClassifyPipeline -Path $src -Extension "$($f.Extension)" -Category "$category" `
                    -Config $Config -DriveProfile $DriveProfile -UrlBucket "$bucket" `
                    -IncludeMetadata -UserRules $userRules -LearnedRules $learnedRules -AppRoot "$planAppRoot" `
                    -Extractors $cachedExtractors -LearnModel $learnModel -Lexicon $planLexicon
                $decOf[$src] = $dec
                $inReviewMove = $false
                if($dec.NeedsDecision){
                    # below MinConfidence: never moved silently. Review.Mode='Report'
                    # leaves the file in place; Mode='Move' files it under _Review\<Year>.
                    if("$reviewMode" -ieq 'Move'){
                        $inReviewMove = $true
                        $reviewLeaf = ('{0}\{1}' -f "$reviewFolder", $((Get-Date).ToString('yyyy')))
                        $pk = $reviewLeaf
                        [void]$needsDecision.Add([pscustomobject]@{ Source=$src; Confidence=$dec.Confidence; Disposition='moved to review folder' })
                    } else {
                        [void]$needsDecision.Add([pscustomobject]@{ Source=$src; Confidence=$dec.Confidence; Disposition='left in place' })
                        Add-SysOrgPlanSkip -Source $src -Reason ('Needs a decision: confidence {0} below {1} ({2})' -f $dec.Confidence, $minConfidence, $dec.RuleId) -Group 'Decision'
                        continue
                    }
                }
                if(-not $inReviewMove){
                    if($dec.RuleId -like 'user:*' -or $dec.RuleId -like 'learned:*'){
                        # rule destination templates expand with the decision context; the
                        # template IS the leaf base (no additional date segment)
                        $ctxTok = @{ Stem=[System.IO.Path]::GetFileNameWithoutExtension("$($f.Name)"); Source="$sourceName" }
                        $decDate = $dec.Date
                        if($null -eq $decDate){ $decDate = $f.LastWriteTime }
                        $ctxTok.Year = ([datetime]$decDate).ToString('yyyy')
                        $ctxTok.Month = ([datetime]$decDate).ToString('MM')
                        $ctxTok.Day = ([datetime]$decDate).ToString('dd')
                        $ctxTok.Date = ([datetime]$decDate).ToString('yyyy-MM-dd')
                        if($dec.Meta){
                            if($dec.Meta.Artist){ $ctxTok.Artist = "$($dec.Meta.Artist)" }
                            if($dec.Meta.Album){ $ctxTok.Album = "$($dec.Meta.Album)" }
                        }
                        $pk = (Expand-SysOrgRuleTemplate -Template $dec.Destination -Context $ctxTok)
                        $noDateOf[$src] = $true
                    } else {
                        $pk = "$($dec.Destination)"
                    }
                    if([string]::IsNullOrWhiteSpace($pk)){ $pk = "$($folderMap['Other'])" }
                }
                $relBaseOf[$src] = $pk
                # v3.0.1 B1: families must cluster inside the CONTENT leaf too - a file
                # downloaded from Z-AI belongs to Documents\Work\<...> like every other
                # document, not to a Downloads\<Source> partition.
                $partitionLookup[$src] = $pk
            }
            $context[$src] = @{ Rel=$pk; Category=$category; Source=$sourceName; InDownloads=$inDownloads }
            $partitionLookup[$src] = $pk
            [void]$routed.Add($f)
        } catch {
            Add-SysOrgPlanSkip -Source $src -Reason ("Analysis error: {0}" -f $_.Exception.Message) -Group 'Other'
        }
    }
    if($capped){ [void]$warnings.Add(("Plan capped at {0} actions; the remaining files were skipped this run." -f $maxActions)) }

    # 5) families within the context leaf (W5)
    # @() cannot collect a generic List[object] (Argument types do not match) - use ToArray
    $fam = Get-SysOrgNameFamilies -Inventory $routed.ToArray() -PartitionLookup $partitionLookup -Config $Config

    # v3.0 Findable: adaptive date granularity is computed over the WHOLE routed set
    # (per leaf), so a leaf only splits when it really exceeds the cap. Family leaves
    # stay date-free unless they themselves exceed the cap. Dates come from the
    # Decision records (metadata > filename > filesystem), and photo/video events
    # (Phase 2.7) override the date segment with their 'Events\<range>' leaf.
    $destRelOf = @{}
    $eventMap = @{}
    if($findable){
        $routedArr = $routed.ToArray()
        $mediaRecs = New-Object System.Collections.Generic.List[object]
        foreach($f in $routedArr){
            $src2 = "$($f.FullName)"
            $dec = $null
            if($decOf.ContainsKey($src2)){ $dec = $decOf[$src2] }
            if(-not $dec){ continue }
            if($dec.Category -in @('Pictures','Videos')){
                $decDate = $dec.Date
                if($null -eq $decDate){ $decDate = $f.LastWriteTime }
                $lat = $null; $lon = $null
                if($dec.Meta){
                    if($dec.Meta.ContainsKey('GpsLat')){ $lat = $dec.Meta['GpsLat'] }
                    if($dec.Meta.ContainsKey('GpsLon')){ $lon = $dec.Meta['GpsLon'] }
                }
                [void]$mediaRecs.Add([pscustomobject]@{ Path=$src2; Date=$decDate; GpsLat=$lat; GpsLon=$lon })
            }
        }
        try { $events = Get-SysOrgEventClusters -Records $mediaRecs.ToArray() -Config $Config; $eventMap = $events.Map } catch { $eventMap = @{} }

        $recs = New-Object System.Collections.Generic.List[object]
        foreach($f in $routedArr){
            $src2 = "$($f.FullName)"
            $rb = ''
            if($relBaseOf.ContainsKey($src2)){ $rb = [string]$relBaseOf[$src2] }
            if(-not $rb){
                if($folderMap.ContainsKey("$($f.Category)")){ $rb = "$($folderMap[$($f.Category)])" } else { $rb = "$($folderMap['Other'])" }
            }
            $isFam = $fam.Lookup.ContainsKey($src2)
            $decDate = $f.LastWriteTime
            $takesDate = $true
            if($noDateOf.ContainsKey($src2)){ $takesDate = $false }
            if($decOf.ContainsKey($src2)){
                $dec = $decOf[$src2]
                if($dec.Date){ $decDate = $dec.Date }
                if(-not $noDateOf.ContainsKey($src2)){ $takesDate = [bool]$dec.TakesDate }
            }
            [void]$recs.Add([pscustomobject]@{ Key=$rb; FileKey=$src2; Date=$decDate; Family=$isFam; TakesDate=$takesDate })
        }
        $segs = Add-SysOrgFindableDateSegments -Records $recs.ToArray() -Cap $layoutCap -MinPerFolder $layoutMin
        foreach($f in $routedArr){
            $src2 = "$($f.FullName)"
            $famInfo2 = $null
            if($fam.Lookup.ContainsKey($src2)){ $famInfo2 = $fam.Lookup[$src2] }
            if($famInfo2 -and $famInfo2.Partition){
                $destRelOf[$src2] = [string]$famInfo2.Partition
            } elseif($eventMap.ContainsKey($src2)){
                $destRelOf[$src2] = [string]$eventMap[$src2]   # Pictures\Events\<range>: the range IS the leaf
            } else {
                $rb = ''
                if($relBaseOf.ContainsKey($src2)){ $rb = [string]$relBaseOf[$src2] }
                if(-not $rb){
                    if($folderMap.ContainsKey("$($f.Category)")){ $rb = "$($folderMap[$($f.Category)])" } else { $rb = "$($folderMap['Other'])" }
                }
                $takesDate = $true
                if($noDateOf.ContainsKey($src2)){ $takesDate = $false }
                elseif($decOf.ContainsKey($src2)){ $takesDate = [bool]$decOf[$src2].TakesDate }
                $seg = ''
                if($takesDate -and $segs.ContainsKey($rb.ToLowerInvariant()) -and $segs[$rb.ToLowerInvariant()].ContainsKey($src2)){ $seg = [string]$segs[$rb.ToLowerInvariant()][$src2] }
                if($seg){ $destRelOf[$src2] = ($rb + '\' + $seg) } else { $destRelOf[$src2] = $rb }
            }
        }
    }

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
            # v3.0 Findable: the destination leaf (incl. adaptive date segment) was
            # computed over the whole routed set; families override with their leaf base.
            if($findable -and $destRelOf.ContainsKey($src)){
                $relForDest = [string]$destRelOf[$src]
            }
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
                if(-not $findable){
                    $dMode = $dateMode
                    if($cx.InDownloads){ $dMode = $dlDateMode }
                    if("$dMode" -eq 'Year'){ $relDate = ([datetime]$f.LastWriteTime).ToString('yyyy'); $destFolder = $db.Base + '\' + $relDate }
                    elseif("$dMode" -eq 'YearMonth'){ $relDate = ([datetime]$f.LastWriteTime).ToString('yyyy-MM'); $destFolder = $db.Base + '\' + $relDate }
                }
                $reason = ('Category={0}' -f $cx.Category)
                if($cx.Source){ $reason = ('Source={0}; Category={1}' -f $cx.Source, $cx.Category) }
                if($findable){ $reason = ('Findable={0}' -f $relForDest) }
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
            # v3.0 idempotence (Phase property test): a file that is ALREADY at its
            # planned destination is never re-planned - moving X to X is not an action.
            # (On Windows the destination root is excluded at scan time; on portable
            # hosts and after layout migrations this check is the second line of defence.)
            $srcN = ("$src").Replace('/','\').TrimEnd('\')
            $destN = ("$dest").Replace('/','\').TrimEnd('\')
            if($srcN -ieq $destN){
                Add-SysOrgPlanSkip -Source $src -Reason 'Already in its destination (idempotent re-plan)' -Group 'Preserved'
                continue
            }
            # v3.0 Findable: keep every destination inside the character budget with
            # deterministic hash-suffixed shortening (folder segments first, name last).
            if($findable){
                $dest = Compress-SysOrgFindablePath -Path $dest -Budget $layoutPathBudget
                $destFolder = Split-Path $dest -Parent
            }
            $nameKey = $destFolder.ToLowerInvariant() + '|' + ("$($f.Name)").ToLowerInvariant()
            $usedNames[$nameKey] = $true

            $syncOut = $false; $intoCloud = $false
            if(Test-SysOrgUnderOneDrive -Path $src){
                if(-not (Test-SysOrgUnderOneDrive -Path $dest)){ $syncOut = $true; [void]$odSyncOut.Add($src) }
            } elseif(Test-SysOrgUnderOneDrive -Path $dest){
                $intoCloud = $true; [void]$odIntoCloud.Add($dest)
            }
            # v2.1.1: capture plan-time metadata so the executor can detect a source that
            # changed between planning and execution. Stored as a round-trip-safe UTC string.
            # v3.0: Decision provenance rides along (confidence, rule, review flag).
            $decConf = $null; $decRule = $null; $decReview = $false; $decReason = ''
            if($decOf.ContainsKey($src)){
                $decConf = $decOf[$src].Confidence
                $decRule = $decOf[$src].RuleId
                $decReview = (@($decOf[$src].Flags) -contains 'review')
                # v3.0.1 B6: the honest REASON for the score, not just the number
                try { $decReason = Get-SysOrgDecisionReason -Decision $decOf[$src] } catch { $decReason = '' }
            }
            $actions.Add([pscustomobject]@{
                Action='Move'; Kind='File'; Source=$src; Destination=$dest; DestRoot=$destRoot
                SizeBytes=[int64]$f.Length; Family=$famName; CopyIndex=$null
                SourceBucket=$cx.Source; Reason=$reason; DifferentContent=$false
                PlannedLength=[int64]$f.Length
                PlannedLastWriteTimeUtc=([datetime]$f.LastWriteTime).ToUniversalTime().ToString('o')
                OneDriveSyncOut=$syncOut; OneDriveIntoCloud=$intoCloud
                Confidence=$decConf; RuleId=$decRule; ReviewFlag=$decReview
                ConfidenceReason=$decReason
            })
            $actionFolderBySrc[$src] = $destFolder
        } catch {
            Add-SysOrgPlanSkip -Source $src -Reason ("Routing error: {0}" -f $_.Exception.Message) -Group 'Other'
        }
    }

    # v3.0 Phase 3.6: ONE directory listing per destination folder, cached in memory.
    # Copy-numbering consults these name sets instead of Test-Path per candidate.
    # NOTE: the sets are built and stored INLINE - an empty HashSet returned through a
    # function's output stream unwraps to $null (pipeline enumeration), so the pattern
    # 'build -> store in the hashtable -> read it back' is used instead of a helper.
    $destDirNames = @{}

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
                    if(Test-SysOrgUnderOneDrive -Path "$($m.FullName)"){
                        if(-not (Test-SysOrgUnderOneDrive -Path $dest)){ $syncOut = $true; [void]$odSyncOut.Add("$($m.FullName)") }
                    } elseif(Test-SysOrgUnderOneDrive -Path $dest){
                        $intoCloud = $true; [void]$odIntoCloud.Add($dest)
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
                            if(-not $destDirNames.ContainsKey($folderKey)){
                                $set2 = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                                try { foreach($n2 in [System.IO.Directory]::GetFiles([string]$keeperFolder)){ [void]$set2.Add([System.IO.Path]::GetFileName($n2)) } } catch { }
                                $destDirNames[$folderKey] = $set2
                            }
                            $nameSet = $destDirNames[$folderKey]
                            # v3.0 Phase 3.6: the in-memory name set replaces per-candidate Test-Path
                            while($usedNames.ContainsKey($folderKey + '|' + $candidate.ToLowerInvariant()) -or $nameSet.Contains($candidate)){
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
                            if(-not $destDirNames.ContainsKey($folderKey)){
                                $set3 = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                                try { foreach($n3 in [System.IO.Directory]::GetFiles([string]$keeperFolder)){ [void]$set3.Add([System.IO.Path]::GetFileName($n3)) } } catch { }
                                $destDirNames[$folderKey] = $set3
                            }
                            $nameSet = $destDirNames[$folderKey]
                            if($usedNames.ContainsKey($folderKey + '|' + $candidate.ToLowerInvariant()) -or $nameSet.Contains($candidate)){
                                $i = $startIndex - 1
                                while($true){
                                    $i++
                                    if($i -gt 999){ $candidate = ([guid]::NewGuid().ToString('N').Substring(0,8)) + $ext; $copyIndex = $i; break }
                                    $candidate = Get-SysOrgCopyName -Stem $stem -Extension $ext -Index $i -Style $suffixStyle
                                    if((-not $usedNames.ContainsKey($folderKey + '|' + $candidate.ToLowerInvariant())) -and (-not $nameSet.Contains($candidate))){
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
                        if(Test-SysOrgUnderOneDrive -Path "$($m.FullName)"){
                            if(-not (Test-SysOrgUnderOneDrive -Path $dest)){ $syncOut = $true; [void]$odSyncOut.Add("$($m.FullName)") }
                        } elseif(Test-SysOrgUnderOneDrive -Path $dest){
                            $intoCloud = $true; [void]$odIntoCloud.Add($dest)
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

    # v3.0.1 B2: user collections - ONE MoveFolder unit each (mutability checked at the
    # folder itself; low-confidence collections are left in place and reported).
    foreach($uc in $collectionList){
        if($actions.Count -ge $maxActions){ $capped = $true; break }
        try{
            $cp = "$($uc.Path)"
            # majority category -> routing leaf; an informative subtype rides along
            $cat2 = "$($uc.MajorityCategory)"
            $rel2 = ''
            if($folderMap.ContainsKey($cat2)){ $rel2 = "$($folderMap[$cat2])" } else { $rel2 = "$($folderMap['Other'])" }
            $sub2 = "$($uc.MajoritySubtype)"
            if($sub2 -and (@('General','Unsorted') -notcontains $sub2)){ $rel2 = ($rel2 + '\' + $sub2) }
            $db2 = Get-SysOrgDestinationBase -RelBase $rel2 -DriveProfile $DriveProfile -Config $Config -KnownFolders $KnownFolders
            $destFolder2 = $db2.Base + '\' + "$($uc.SafeName)"
            if($cp -ieq $destFolder2){
                Add-SysOrgPlanSkip -Source $cp -Reason 'User collection already in its place (idempotent re-plan)' -Group 'Preserved'
                continue
            }
            if(-not [bool]$uc.Moves){
                Add-SysOrgPlanSkip -Source $cp -Reason ('User collection left for a decision: majority confidence {0} below {1}' -f $uc.MajorityRatio, $colMinRatioEarly) -Group 'Decision'
                [void]$needsDecision.Add([pscustomobject]@{ Source=$cp; Confidence=$uc.MajorityRatio; Disposition='collection left in place (low confidence)' })
                continue
            }
            $mut2 = Test-SysOrgFileMutable -Path $cp -Extension '' -DriveProfile $DriveProfile -Config $Config -Container -PolicyCache $mutPolicyCache -ExMatcher $planExMatcher
            if(-not $mut2.Allowed){
                Add-SysOrgPlanSkip -Source $cp -Reason ("User collection not moved: {0}" -f $mut2.Reason) -Group 'Protected'
                continue
            }
            $stats2 = Get-SysOrgFolderMoveStats -Path $cp -Config $Config -DriveProfile $DriveProfile
            $syncOut2 = $false; $intoCloud2 = $false
            if(Test-SysOrgUnderOneDrive -Path $cp){
                if(-not (Test-SysOrgUnderOneDrive -Path $destFolder2)){ $syncOut2 = $true; [void]$odSyncOut.Add($cp) }
            } elseif(Test-SysOrgUnderOneDrive -Path $destFolder2){
                $intoCloud2 = $true; [void]$odIntoCloud.Add($destFolder2)
            }
            $actions.Add([pscustomobject]@{
                Action='Move'; Kind='Folder'; Source=$cp; Destination=$destFolder2; DestRoot=$db2.DisplayRoot
                SizeBytes=[int64]0; Family=$null; CopyIndex=$null; SourceBucket=$null
                Reason=('User collection: majority {0} ({1}% of {2} files); moved whole, structure intact' -f $cat2, [Math]::Round(100 * [double]$uc.MajorityRatio), $uc.Files)
                FilesInside=$uc.Files; NonCodeFilesInside=$stats2.NonCode
                BlockedFilesCount=$stats2.BlockedCount; BlockedFileSamples=$stats2.BlockedSamples
                DifferentContent=$false; OneDriveSyncOut=$syncOut2; OneDriveIntoCloud=$intoCloud2
                Confidence=$uc.MajorityRatio; RuleId='collection'; ReviewFlag=$false; Collection=$true
            })
        } catch {
            Add-SysOrgPlanSkip -Source "$($uc.Path)" -Reason ("User collection error: {0}" -f $_.Exception.Message) -Group 'Other'
        }
    }

    # code project folders: one MoveFolder unit each (mutability checked at the folder itself)
    $projCfgDest = "$(Get-SysOrgSetting $Config 'Projects.Destination' 'Documents\Projects\Code')"
    # v3.0 Findable: projects live under Code\Projects (the tree's Code branch) unless the
    # user customized Projects.Destination away from the legacy default.
    if($findable -and ($projCfgDest -ieq 'Documents\Projects\Code')){ $projCfgDest = 'Code\Projects' }
    $docMap = "$($folderMap['Documents'])"
    foreach($pf in @($ProjectFolders)){
        if($actions.Count -ge $maxActions){ $capped = $true; break }
        try{
            $mut = Test-SysOrgFileMutable -Path "$($pf.Path)" -Extension '' -DriveProfile $DriveProfile -Config $Config -Container -PolicyCache $mutPolicyCache -ExMatcher $planExMatcher
            if(-not $mut.Allowed){
                Add-SysOrgPlanSkip -Source "$($pf.Path)" -Reason ("Project folder not moved: {0}" -f $mut.Reason) -Group 'Protected'
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
            if(Test-SysOrgUnderOneDrive -Path "$($pf.Path)"){
                if(-not (Test-SysOrgUnderOneDrive -Path $dest)){ $syncOut = $true; [void]$odSyncOut.Add("$($pf.Path)") }
            } elseif(Test-SysOrgUnderOneDrive -Path $dest){
                $intoCloud = $true; [void]$odIntoCloud.Add($dest)
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
            Add-SysOrgPlanSkip -Source "$($pf.Path)" -Reason ("Project folder error: {0}" -f $_.Exception.Message) -Group 'Other'
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

    # v3.0: Mode line reflects the active layout (precomputed for PS 5.1 compatibility)
    if($findable){
        $modeLine = ('Findable layout; copies={0}; style={1}' -f $copiesPolicy, $style)
    } else {
        $modeLine = ('Type-first families; preset={0}; copies={1}; style={2}' -f (Get-SysOrgSetting $Config 'NamingPreset' 'Windows'), $copiesPolicy, $style)
    }

    return [pscustomobject]@{
        PlanId          = $planId
        Created         = (Get-Date).ToString('s')
        Computer        = $env:COMPUTERNAME
        Drive           = "$Letter`:"
        DestinationRoot = $root
        DestinationStyle= $style
        Mode            = $modeLine
        DriveProfile    = $profileSummary
        Actions         = $actions.ToArray()
        Skipped         = $skipped.ToArray()
        Families        = $familiesAudit
        Copies          = [pscustomobject]$copiesAudit
        Mutability      = [pscustomobject]@{ Allowed=$mutAllowed; DeniedTotal=$deniedTotal; Denied=$deniedList }
        OneDrive        = [pscustomobject]@{ SyncOut=@($odSyncOut.ToArray()); IntoCloud=@($odIntoCloud.ToArray()) }
        NeedsDecision   = $needsDecision.ToArray()
        Warnings        = @($warnings.ToArray())
        # v3.0.2 B2: scan roots that were dropped - reported in the plan header
        SkippedRoots    = $SkippedScanRoots
        Provenance      = @($provRows.ToArray())
        ProvenanceFile  = ''
        # v3.0.1 B5: re-download version pairs - REPORT ONLY (nothing moves)
        VersionPairs    = $(if($VersionPairs){ $VersionPairs } else { [pscustomobject]@{ Identical=0; Versions=@() } })
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
    # v2.1.1: millisecond suffix (item 10) - see New-SysOrgPlan
    $stamp = Get-Date
    $planId = 'migrate-' + $stamp.ToString('yyyyMMdd-HHmmss') + '-' + $stamp.ToString('fff')
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
    if(-not $Plan.PSObject.Properties['ProvenanceFile']){
        [void]($Plan | Add-Member -NotePropertyName ProvenanceFile -NotePropertyValue '')
    }
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

function Get-SysOrgSkipGroupFromReason {
<#
.SYNOPSIS
    Legacy-plan fallback: classifies a skip reason into the A3 taxonomy group.
.DESCRIPTION
    Plans saved before v3.0.1 carry no Group tag on their skipped rows; this maps
    the documented reason strings of those plans onto the honest taxonomy:
    Protected (mutability engine) / Preserved (by design) / Decision / Other.
.EXAMPLE
    Get-SysOrgSkipGroupFromReason -Reason 'Outside writable scope on system drive'   # -> 'Protected'
#>
    param([string]$Reason)
    $r = "$Reason"
    if([string]::IsNullOrWhiteSpace($r)){ return 'Other' }
    if($r.StartsWith('Needs a decision', [StringComparison]::OrdinalIgnoreCase)){ return 'Decision' }
    foreach($p in @('Protected path','Blocked extension','Installer outside download roots','Outside writable scope')){
        if($r.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)){ return 'Protected' }
    }
    if($r.StartsWith('Project folder not moved', [StringComparison]::OrdinalIgnoreCase)){ return 'Protected' }
    foreach($p in @('Inside a detected code project folder','Inside a folder that already looks organized','Existing ','Already in its destination','Inside a user collection')){
        if($r.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)){ return 'Preserved' }
    }
    return 'Other'
}

function Get-SysOrgSkipTaxonomy {
<#
.SYNOPSIS
    The honest skip taxonomy of a plan (v3.0.1 A3).
.DESCRIPTION
    Replaces the old 'Mutability: N denied (provably never touched)' line, which
    folded preserved and needs-a-decision files into 'denied'. Returns:
      - Scanned      : every file the scan saw (plan.Stats.Scanned)
      - Planned      : file moves in the plan
      - Protected    : count + per-reason counts + one example each - the mutability
                       engine refused (system paths, blocked extensions, scope)
      - Preserved    : count + reasons - left alone BY DESIGN (organized-folder
                       heuristic, project units, user collections, already in place)
      - Decision     : count - below the confidence floor, needs a human decision
                       (authoritative: the plan's NeedsDecision list)
      - Other        : count + reasons - recorded but not planned (long paths,
                       system PerceivedType, analysis errors)
      - UntouchedPct : percentage of scanned files that stay untouched
    Deterministic: reasons sorted by count descending, then natural order.
.EXAMPLE
    $tax = Get-SysOrgSkipTaxonomy -Plan $plan
    $tax.Headline   # -> '9,579 scanned: 11 planned, 9,518 preserved, 50 protected, 0 need a decision.'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $scanned = 0
    if($Plan.PSObject.Properties['Stats'] -and $Plan.Stats -and $Plan.Stats.PSObject.Properties['Scanned']){ $scanned = [int]$Plan.Stats.Scanned }
    $planned = 0
    foreach($a in @($Plan.Actions)){
        if("$($a.Action)" -ne 'Move'){ continue }
        if($a.PSObject.Properties['Kind'] -and "$($a.Kind)" -eq 'Folder'){ continue }
        $planned++
    }

    # reason -> count per group, plus one deterministic example per reason
    $byGroup = @{ Protected=@{}; Preserved=@{}; Decision=@{}; Other=@{} }
    $examples = @{}
    foreach($s in @($Plan.Skipped)){
        $g = ''
        if($s.PSObject.Properties['Group'] -and "$($s.Group)"){ $g = "$($s.Group)" }
        else { $g = Get-SysOrgSkipGroupFromReason -Reason "$($s.Reason)" }
        if(-not $byGroup.ContainsKey($g)){ $g = 'Other' }
        $r = "$($s.Reason)"
        if(-not $byGroup[$g].ContainsKey($r)){ $byGroup[$g][$r] = 0 }
        $byGroup[$g][$r]++
        if(-not $examples.ContainsKey($r)){ $examples[$r] = "$($s.Source)" }
    }

    function ConvertTo-SysOrgGroupRows {
        param([hashtable]$ReasonMap,[hashtable]$Examples)
        $rows = @()
        foreach($r in ($ReasonMap.Keys | Sort-Object)){ $rows += [pscustomobject]@{ Reason=$r; Count=[int]$ReasonMap[$r]; Example=[string]$Examples[$r] } }
        return @($rows | Sort-Object -Property @{e={$_.Count}}, @{e={$_.Reason}} -Descending:$false)
    }
    # deterministic: highest count first, ties by natural reason order
    function Sort-SysOrgTaxonomyRows {
        param($Rows)
        return @($Rows | Sort-Object -Property @{e={ -$_.Count }}, @{e={ "$($_.Reason)" }})
    }

    # needs-a-decision: the authoritative source is the plan's NeedsDecision list
    # (Review.Mode='Move' files them under _Review - planned, NOT skipped)
    $decisionCount = 0
    if($Plan.PSObject.Properties['NeedsDecision']){ $decisionCount = @($plan.NeedsDecision).Count }
    $decisionRows = @(ConvertTo-SysOrgGroupRows -ReasonMap $byGroup['Decision'] -Examples $examples)
    $decisionExamples = @()
    if($Plan.PSObject.Properties['NeedsDecision'] -and @($Plan.NeedsDecision).Count -gt 0){
        $decisionExamples = @(@($Plan.NeedsDecision) | Select-Object -First 3 | ForEach-Object { "$($_.Source)" })
    }
    elseif($decisionRows.Count -gt 0){ $decisionExamples = @($decisionRows[0].Example) }

    $protectedRows = @(Sort-SysOrgTaxonomyRows -Rows (ConvertTo-SysOrgGroupRows -ReasonMap $byGroup['Protected'] -Examples $examples))
    $preservedRows = @(Sort-SysOrgTaxonomyRows -Rows (ConvertTo-SysOrgGroupRows -ReasonMap $byGroup['Preserved'] -Examples $examples))
    $otherRows     = @(Sort-SysOrgTaxonomyRows -Rows (ConvertTo-SysOrgGroupRows -ReasonMap $byGroup['Other'] -Examples $examples))
    $protectedCount = 0; foreach($r in $protectedRows){ $protectedCount += $r.Count }
    $preservedCount = 0; foreach($r in $preservedRows){ $preservedCount += $r.Count }
    $otherCount = 0; foreach($r in $otherRows){ $otherCount += $r.Count }

    $untouched = $scanned - $planned
    $untouchedPct = 0.0
    if($scanned -gt 0){ $untouchedPct = [Math]::Round(100.0 * $untouched / $scanned, 1) }
    $fmt = [System.Globalization.CultureInfo]::InvariantCulture
    $headline = ('{0} scanned: {1} planned, {2} preserved, {3} protected, {4} need a decision.' -f `
        ([string]::Format($fmt, '{0:N0}', $scanned)), ([string]::Format($fmt, '{0:N0}', $planned)),
        ([string]::Format($fmt, '{0:N0}', $preservedCount)), ([string]::Format($fmt, '{0:N0}', $protectedCount)),
        ([string]::Format($fmt, '{0:N0}', $decisionCount)))

    return [pscustomobject]@{
        Scanned=$scanned; Planned=$planned
        ProtectedCount=$protectedCount; ProtectedRows=$protectedRows
        PreservedCount=$preservedCount; PreservedRows=$preservedRows
        DecisionCount=$decisionCount;   DecisionRows=$decisionRows; DecisionExamples=$decisionExamples
        OtherCount=$otherCount;         OtherRows=$otherRows
        Untouched=$untouched; UntouchedPct=$untouchedPct
        Headline=$headline
    }
}

# ---------------------------------------------------------------------------
# v3.0.2 D3: duplicate and version-pair REPORTS are grouped by folder pair and
# the FULL lists go to a report file - the preview never prints 41 raw pairs.
# ---------------------------------------------------------------------------
function Get-SysOrgFolderPairGroups {
<#
.SYNOPSIS
    Groups items by an (A-folder, B-folder) pair and returns the largest groups.
.EXAMPLE
    Get-SysOrgFolderPairGroups -Items $pairs -KeyA { param($v) Split-Path $v.Original -Parent } -KeyB { param($v) Split-Path $v.Copy -Parent } -Top 5
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Items,
          [Parameter(Mandatory)][scriptblock]$KeyA,[Parameter(Mandatory)][scriptblock]$KeyB,
          [int]$Top=5)
    $groups = @{}
    foreach($it in @($Items)){
        if(-not $it){ continue }
        $a = (& $KeyA $it); $b = (& $KeyB $it)
        $k = ("$a") + '|' + ("$b")
        if(-not $groups.ContainsKey($k)){ $groups[$k] = @{ A="$a"; B="$b"; Count=0; Items=@() } }
        $groups[$k].Count++
        $groups[$k].Items += $it
    }
    return @($groups.Values | Sort-Object { $_.Count } -Descending | Select-Object -First $Top)
}

function Write-SysOrgDuplicateReportFile {
<#
.SYNOPSIS
    Writes the FULL duplicate-group and version-pair list to Reports\ (v3.0.2 D3).
.DESCRIPTION
    The preview prints grouped summaries only; this file carries every row.
    Best effort: returns '' when the file could not be written. Report-only.
.EXAMPLE
    Write-SysOrgDuplicateReportFile -ReportFolder C:\SysOrg\Reports -PlanId $p.PlanId -CopiesGroups $p.Copies.Groups -VersionPairs $p.VersionPairs.Versions
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReportFolder,[Parameter(Mandatory)][string]$PlanId,
          [AllowEmptyCollection()]$CopiesGroups,[AllowEmptyCollection()]$VersionPairs)
    try{
        if(-not (Test-Path -LiteralPath $ReportFolder)){ New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
        $file = Join-Path $ReportFolder ('SysOrg-DuplicateReport-{0}.txt' -f $PlanId)
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add("SysOrg duplicate report - plan $PlanId - $(Get-Date)")
        [void]$lines.Add('Report only: nothing is ever moved, renamed or deleted by this file.')
        if($CopiesGroups -and @($CopiesGroups).Count -gt 0){
            [void]$lines.Add('')
            [void]$lines.Add('--- duplicate groups (keeper + numbered/quarantined/reported copies) ---')
            foreach($g in @($CopiesGroups)){
                [void]$lines.Add(('GROUP keeper={0} hash={1}' -f "$($g.Keeper)", "$($g.Hash)"))
                foreach($cp in @($g.Copies)){ [void]$lines.Add("  copy: $($cp.Source) -> $($cp.Assigned)") }
                foreach($q in @($g.Quarantined)){ [void]$lines.Add("  quarantined: $q") }
                foreach($r in @($g.Reported)){ [void]$lines.Add("  reported: $r") }
            }
        }
        if($VersionPairs -and @($VersionPairs).Count -gt 0){
            [void]$lines.Add('')
            [void]$lines.Add('--- possible newer-version pairs (browser re-download signal; report only) ---')
            foreach($v in @($VersionPairs)){
                $newer = ''
                if($v.PSObject.Properties['CopyLooksNewer'] -and $v.CopyLooksNewer){ $newer = '  [copy looks newer]' }
                [void]$lines.Add(('{0}  ({1} bytes, modified {2})' -f $v.Original, $v.OriginalSize, $v.OriginalLastWrite))
                [void]$lines.Add(('  vs {0}  ({1} bytes, modified {2}){3}' -f $v.Copy, $v.CopySize, $v.CopyLastWrite, $newer))
            }
        }
        [System.IO.File]::WriteAllLines($file, $lines)
        return $file
    } catch { return '' }
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

    # 12.2 mutability summary - v3.0.1 A3: the honest skip taxonomy. The old
    # 'Mutability: N denied (provably never touched)' line folded preserved files
    # (organized folders, project units) and needs-a-decision files into 'denied'.
    $tax = Get-SysOrgSkipTaxonomy -Plan $Plan
    Write-Host ''
    Write-Host $tax.Headline -ForegroundColor White
    Write-Host ('  {0}% of scanned files stay untouched.' -f $tax.UntouchedPct) -ForegroundColor Gray
    if($showDenied){
        if($tax.ProtectedCount -gt 0){
            Write-Host ('  Protected/denied (mutability engine): {0}' -f $tax.ProtectedCount) -ForegroundColor Yellow
            foreach($d in $tax.ProtectedRows){
                Write-Host ('    x{0}  {1}' -f $d.Count, $d.Reason) -ForegroundColor Yellow
                Write-Host ('      e.g. {0}' -f $d.Example) -ForegroundColor DarkYellow
            }
        }
        if($tax.PreservedCount -gt 0){
            Write-Host ('  Preserved by design (organized folders, project units, user collections): {0}' -f $tax.PreservedCount) -ForegroundColor Green
            foreach($d in $tax.PreservedRows){
                Write-Host ('    x{0}  {1}' -f $d.Count, $d.Reason) -ForegroundColor DarkGreen
                Write-Host ('      e.g. {0}' -f $d.Example) -ForegroundColor DarkYellow
            }
        }
        if($tax.DecisionCount -gt 0){
            Write-Host ('  Left for a decision (low confidence): {0}' -f $tax.DecisionCount) -ForegroundColor Yellow
            foreach($ex in (@($tax.DecisionExamples) | Select-Object -First 3)){ Write-Host ('      e.g. {0}' -f $ex) -ForegroundColor DarkYellow }
        }
        if($tax.OtherCount -gt 0){
            Write-Host ('  Recorded, not planned (other): {0}' -f $tax.OtherCount) -ForegroundColor Gray
            foreach($d in $tax.OtherRows){
                Write-Host ('    x{0}  {1}' -f $d.Count, $d.Reason) -ForegroundColor DarkGray
                Write-Host ('      e.g. {0}' -f $d.Example) -ForegroundColor DarkGray
            }
        }
        # v3.0.2 B2: dropped scan roots are part of the skip taxonomy - the count is
        # stated explicitly, never silently folded into 'preserved'
        if($Plan.PSObject.Properties['SkippedRoots'] -and @($Plan.SkippedRoots).Count -gt 0){
            Write-Host ('  Scan roots NOT scanned: {0}' -f @($Plan.SkippedRoots).Count) -ForegroundColor Yellow
            foreach($sr in @($Plan.SkippedRoots)){
                Write-Host ('    {0} was NOT scanned: {1}' -f (Split-Path "$($sr.Path)" -Leaf), "$($sr.Reason)") -ForegroundColor Yellow
            }
        }
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
            # v3.0.2 D3: grouped by folder pair (keeper folder vs copy folder) - the
            # top 5 pairs are printed, the full list lands in the duplicate report file
            $flatCopies = @()
            foreach($g in @($c.Groups)){ foreach($cp in @($g.Copies)){ $flatCopies += [pscustomobject]@{ Keeper="$($g.Keeper)"; Source="$($cp.Source)"; Assigned="$($cp.Assigned)" } } }
            foreach($p in (Get-SysOrgFolderPairGroups -Items $flatCopies -KeyA { param($x) Split-Path "$($x.Keeper)" -Parent } -KeyB { param($x) Split-Path "$($x.Source)" -Parent } -Top 5)){
                Write-Host ('  {0}  vs  {1}: {2} numbered copy(ies)' -f $p.A, $p.B, $p.Count) -ForegroundColor Gray
            }
            if(@($flatCopies).Count -gt 5){ Write-Host '  ... (full list in the duplicate report file)' -ForegroundColor DarkGray }
        }
        if("$($c.Policy)" -eq 'Quarantine' -and ([int]$c.Quarantined -gt 0)){
            Write-Host ("  Quarantined duplicates: {0}" -f $c.Quarantined)
        }
        if("$($c.Policy)" -eq 'ReportOnly' -and ([int]$c.Reported -gt 0)){
            Write-Host ("  Copies reported (nothing moves): {0}" -f $c.Reported)
        }
    }

    # v3.0.1 B5: possible newer versions (browser re-download signal) - report only
    if($Plan.PSObject.Properties['VersionPairs'] -and $Plan.VersionPairs){
        $vpVersions = @($Plan.VersionPairs.Versions)
        if($vpVersions.Count -gt 0){
            Write-Host ''
            Write-Host ("Possible newer versions (report-only, nothing moves): {0}" -f $vpVersions.Count) -ForegroundColor Yellow
            # v3.0.2 D3: grouped by folder pair (original folder vs copy folder) - the
            # top 5 pairs are printed ('A(1)\x vs A\x: 38 files'), the full list goes
            # to the duplicate report file. Never 41 raw pairs in the console.
            foreach($p in (Get-SysOrgFolderPairGroups -Items $vpVersions -KeyA { param($v) Split-Path "$($v.Original)" -Parent } -KeyB { param($v) Split-Path "$($v.Copy)" -Parent } -Top 5)){
                Write-Host ('  {0}  vs  {1}: {2} file(s)' -f $p.A, $p.B, $p.Count) -ForegroundColor Yellow
            }
            if($vpVersions.Count -gt 5){ Write-Host '  ... (full list in the duplicate report file)' -ForegroundColor DarkGray }
            Write-Host '  Decide which version to keep yourself - SysOrg never deletes either file.' -ForegroundColor DarkGray
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

    # v3.0 Phase 2.9: needs-a-decision files (below MinConfidence) + review-flagged moves
    $reviewMoves = @($fileMoves | Where-Object { $_.PSObject.Properties['ReviewFlag'] -and $_.ReviewFlag })
    if($reviewMoves.Count -gt 0){
        Write-Host ''
        Write-Host ("Review-flagged moves (confidence below {0}): {1} - planned, but worth a look" -f 0.70, $reviewMoves.Count) -ForegroundColor Yellow
        # v3.0.1 B6: show the REASON for each low score, not just the number
        foreach($rm in ($reviewMoves | Select-Object -First 8)){
            $reasonTxt = ''
            if($rm.PSObject.Properties['ConfidenceReason'] -and "$($rm.ConfidenceReason)"){ $reasonTxt = ('  - ' + $rm.ConfidenceReason) }
            Write-Host ('  conf {0}  {1}{2}' -f $rm.Confidence, $rm.Source, $reasonTxt) -ForegroundColor DarkYellow
        }
        if($reviewMoves.Count -gt 8){ Write-Host ('  ... and {0} more review-flagged moves' -f ($reviewMoves.Count - 8)) -ForegroundColor DarkGray }
    }
    if($Plan.PSObject.Properties['NeedsDecision'] -and @($Plan.NeedsDecision).Count -gt 0){
        Write-Host ''
        Write-Host ("NEEDS A DECISION ({0} file(s) - not moved automatically):" -f @($Plan.NeedsDecision).Count) -ForegroundColor Yellow
        foreach($nd in (@($Plan.NeedsDecision) | Select-Object -First 10)){
            Write-Host ('  ' + $nd.Source + '  [confidence ' + $nd.Confidence + ' - ' + $nd.Disposition + ']') -ForegroundColor DarkYellow
        }
        if(@($Plan.NeedsDecision).Count -gt 10){ Write-Host ('  ... and {0} more' -f (@($Plan.NeedsDecision).Count - 10)) -ForegroundColor DarkGray }
        Write-Host '  These files are listed, never dumped into a junk folder. Use -Explain <path> to see why.' -ForegroundColor Gray
    }

    # v3.0.1 B2: user collections are listed SEPARATELY in the preview
    $collectionMoves = @($folderMoves | Where-Object { $_.PSObject.Properties['Collection'] -and $_.Collection })
    if($collectionMoves.Count -gt 0){
        Write-Host ''
        Write-Host ('User collections (moved whole, structure intact): {0}' -f $collectionMoves.Count) -ForegroundColor White
        foreach($cm in $collectionMoves){
            $confTxt = ''
            if($cm.PSObject.Properties['Confidence'] -and ($null -ne $cm.Confidence)){ $confTxt = ('  [confidence {0}]' -f $cm.Confidence) }
            Write-Host ('  ' + $cm.Source + ' -> ' + $cm.Destination + ('  ({0} file(s))' -f $cm.FilesInside) + $confTxt) -ForegroundColor Gray
        }
        Write-Host '  Collections are never flattened - every nested folder moves as it is.' -ForegroundColor DarkGray
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
        $confTag = ''
        if($_.PSObject.Properties['Confidence'] -and ($null -ne $_.Confidence)){ $confTag = ('  [conf {0}]' -f $_.Confidence) }
        Write-Host ('    -> {0}   [{1}]{2}' -f $_.Destination, $_.Reason, $confTag) -ForegroundColor Gray
    }
    if($moves.Count -gt $SampleSize){ Write-Host ('  ... and {0} more moves' -f ($moves.Count - $SampleSize)) }
    Write-Host ''

    $deniedTotal = 0
    if($Plan.PSObject.Properties['Mutability'] -and $Plan.Mutability){ $deniedTotal = [int]$Plan.Mutability.DeniedTotal }

    # v3.0.2 D3: the FULL duplicate/version-pair list always lands in the report file
    $dupHasContent = $false
    try {
        $dupHasContent = (($Plan.PSObject.Properties['VersionPairs'] -and $Plan.VersionPairs -and @($Plan.VersionPairs.Versions).Count -gt 0) -or
                          ($Plan.PSObject.Properties['Copies'] -and $Plan.Copies -and (([int]$Plan.Copies.Numbered -gt 0) -or ([int]$Plan.Copies.Quarantined -gt 0) -or ([int]$Plan.Copies.Reported -gt 0))))
    } catch { $dupHasContent = $false }
    if($dupHasContent){
        $dupReportFolder = ''
        try {
            $dupAppRoot = "$(Get-SysOrgSetting $Config 'AppRoot' '')"
            if(-not [string]::IsNullOrWhiteSpace($dupAppRoot)){ $dupReportFolder = Join-Path $dupAppRoot 'Reports' }
        } catch { }
        if(-not [string]::IsNullOrWhiteSpace($dupReportFolder)){
            # the report writer creates the Reports folder on demand; a preview without
            # an app root (unit tests) gets the grouped summary without the file
            $cg = @(); $vp = @()
            try { if($Plan.PSObject.Properties['Copies'] -and $Plan.Copies){ $cg = @($Plan.Copies.Groups) } } catch { }
            try { if($Plan.PSObject.Properties['VersionPairs'] -and $Plan.VersionPairs){ $vp = @($Plan.VersionPairs.Versions) } } catch { }
            $dupReportPath = Write-SysOrgDuplicateReportFile -ReportFolder $dupReportFolder -PlanId "$($Plan.PlanId)" -CopiesGroups $cg -VersionPairs $vp
            if("$dupReportPath"){ Write-Host ("Duplicate report (full list): {0}" -f $dupReportPath) -ForegroundColor DarkGray }
        }
    }

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
    $alreadyDone = @{}

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
    # v2.1.1: journals carry a Status column (appended at the END, so old 7-column journals
    # remain readable and undoable). Done rows (and all rows of legacy journals) mark a
    # source as already handled; orphaned Pending rows are resolved against the actual
    # filesystem state after the writer is open.
    $journalExists = Test-Path -LiteralPath $undoPath
    $journalRows = @()
    $journalHasStatus = $false
    if($journalExists){
        if(-not $Force){
            throw "Plan '$($plan.PlanId)' already has an undo journal. Undo it first, or pass -Force to resume (journaled actions are skipped)."
        }
        $journalRows = @(Import-Csv -LiteralPath $undoPath)
        $headerLine = ''
        try { $headerLine = (Get-Content -LiteralPath $undoPath -TotalCount 1) } catch { }
        $journalHasStatus = ("$headerLine" -match ',Status\s*$')
        foreach($r in $journalRows){
            $st = ''
            if($r.PSObject.Properties['Status']){ $st = "$($r.Status)" }
            if(($st -eq '') -or ($st -ieq 'Done')){ $alreadyDone[$r.OriginalSource] = $true }
        }
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
    # v3.0.1 C1: one mutability-policy cache + one compiled exclusion matcher per run
    $execPolicyCache = @{}
    $execExMatcher = $null
    try { $execExMatcher = New-SysOrgExclusionMatcher -Config $Config } catch { $execExMatcher = $null }


    # P1-1: journal is appended and flushed after EVERY row, not written once at the end.
    # v2.1.1: the stream opens with WriteThrough and every row is flushed to disk
    # (Flush($true)) so a crash cannot lose rows the OS still held in cache - the journal
    # must survive a power cut, not just a process kill.
    $writer = $null
    try {
        $fs = New-Object System.IO.FileStream($undoPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 1, [System.IO.FileOptions]::WriteThrough)
        $writer = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        $writer.AutoFlush = $true
    } catch { throw "Undo journal could not be opened: $($_.Exception.Message)" }

    function Add-SysOrgJournalRow {
        # NOTE: reads the enclosing function's locals via dynamic scoping (same pattern as
        # Add-SysOrgPlanSkip) - $script: qualifiers here would miss those locals entirely.
        param([string]$Kind,[string]$Action,[string]$OriginalSource,[string]$CurrentLocation,[string]$Hash,[string]$Status)
        # Legacy 7-column journals keep their layout: no Pending/Retried markers are written
        # for them (the orphan logic does not apply), but normal Done rows still are.
        if((-not $journalHasStatus) -and $Status -and ($Status -ne 'Done')){ return }
        $line = (ConvertTo-SysOrgCsvField (Get-Date -Format s)) + ',' + (ConvertTo-SysOrgCsvField $plan.PlanId) + ',' +
                (ConvertTo-SysOrgCsvField $Kind) + ',' + (ConvertTo-SysOrgCsvField $Action) + ',' +
                (ConvertTo-SysOrgCsvField $OriginalSource) + ',' + (ConvertTo-SysOrgCsvField $CurrentLocation) + ',' +
                (ConvertTo-SysOrgCsvField $Hash)
        if($journalHasStatus){ $line += ',' + (ConvertTo-SysOrgCsvField $Status) }
        $writer.WriteLine($line)
        # crash-safe: push the row past every buffer, down to the disk
        $writer.Flush()
        $fs.Flush($true)
    }

    try {
        if(-not $journalExists){
            $writer.WriteLine('Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash,Status')
            $writer.Flush(); $fs.Flush($true)
            $journalHasStatus = $true   # the journal we just created has the Status column
        }

        # v2.1.1: resolve orphaned Pending rows (a crash between the Pending row and the
        # Done row) against the ACTUAL filesystem state before deciding to skip or retry.
        if($journalHasStatus -and $journalRows.Count -gt 0){
            $doneSet = @{}
            foreach($r in $journalRows){
                $st = ''; if($r.PSObject.Properties['Status']){ $st = "$($r.Status)" }
                if(($st -eq '') -or ($st -ieq 'Done')){ $doneSet[$r.OriginalSource] = $true }
            }
            $planActionBySource = @{}
            foreach($pa in @($plan.Actions)){ $planActionBySource["$($pa.Source)"] = $pa }
            foreach($r in $journalRows){
                $st = ''; if($r.PSObject.Properties['Status']){ $st = "$($r.Status)" }
                if($st -ine 'Pending'){ continue }
                if($doneSet.ContainsKey($r.OriginalSource)){ continue }   # a later Done row exists
                $plannedDest = ''
                if($planActionBySource.ContainsKey($r.OriginalSource)){ $plannedDest = "$($planActionBySource[$r.OriginalSource].Destination)" }
                if(-not (Test-Path -LiteralPath $r.OriginalSource)){
                    # the move happened but the process died before the Done row: mark it done
                    # so the source is skipped and remains undoable (planned destination used).
                    # The Resumed counter is incremented by the main loop's alreadyDone skip.
                    Add-SysOrgJournalRow -Kind "$($r.Kind)" -Action "$($r.Action)" -OriginalSource $r.OriginalSource `
                        -CurrentLocation $plannedDest -Hash "$($r.ContentHash)" -Status 'Done'
                    $alreadyDone[$r.OriginalSource] = $true
                    Write-SysOrgLog "Resume: orphaned Pending row resolved as done (source is gone): $($r.OriginalSource)" -LogFolder $logFolder
                } else {
                    # the move never happened: mark retried so the row is no longer orphaned
                    Add-SysOrgJournalRow -Kind "$($r.Kind)" -Action "$($r.Action)" -OriginalSource $r.OriginalSource `
                        -CurrentLocation '' -Hash '' -Status 'Retried'
                    Write-SysOrgLog "Resume: orphaned Pending row retried (source still present): $($r.OriginalSource)" -LogFolder $logFolder
                }
            }
        }

        $allActions = @($plan.Actions)
        $i = 0; $total = $allActions.Count

        # v3.0 Phase 3.7: batched directory creation - every destination parent is
        # created ONCE up front (tracked set), so per-move Test-Path/New-Item storms go
        # away. The per-move primitive still verifies before writing (never overwrites).
        $createdDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach($a in $allActions){
            $pd = $null
            try { $pd = Split-Path ([string]$a.Destination) -Parent } catch { $pd = $null }
            if([string]::IsNullOrWhiteSpace("$pd")){ continue }
            $pdKey = ("$pd").TrimEnd('\')
            if($createdDirs.Contains($pdKey)){ continue }
            $createdDirs.Add($pdKey)
            if(-not (Test-Path -LiteralPath $pdKey)){
                try { New-Item -ItemType Directory -Path $pdKey -Force | Out-Null } catch { }
            }
        }

        # v3.0 Phase 3.7: buffered file logging + throttled progress. The undo journal
        # STAYS flushed-per-row (crash safety is untouched); only the human log and the
        # console are batched, since losing a few log lines in a crash is acceptable.
        $logBuffer = New-Object System.Collections.Generic.List[string]
        function Add-SysOrgRunLog {
            param([string]$Message,[string]$Level='INFO')
            $logBuffer.Add(('{0} [{1,-6}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message))
            if($logBuffer.Count -ge 64){ Flush-SysOrgRunLog }
        }
        function Flush-SysOrgRunLog {
            if($logBuffer.Count -eq 0){ return }
            try {
                $logFile = Join-Path $logFolder ('sysorg-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
                if(-not (Test-Path -LiteralPath $logFolder)){ New-Item -ItemType Directory -Path $logFolder -Force | Out-Null }
                Add-Content -LiteralPath $logFile -Value ($logBuffer.ToArray() -join "`r`n") -Encoding UTF8
            } catch { }
            $logBuffer.Clear()
        }

        foreach($a in $allActions){
            $i++
            if(($i -eq 1) -or ($i -eq $total) -or (($i % 25) -eq 0)){
                Write-Progress -Activity 'Executing plan' `
                    -Status "$i / $total : $(Split-Path $a.Source -Leaf)" `
                    -PercentComplete $(if($total -gt 0){ [int](100 * $i / $total) } else { 0 })
            }

            if($alreadyDone.ContainsKey($a.Source)){
                $summary.Resumed++
                Add-SysOrgRunLog "Resume: skipping already-journaled source: $($a.Source)"
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
                if($execExMatcher){
                    if(Test-SysOrgExcludedPathFast -Path (Split-Path $canonSrc.Path -Parent) -Matcher $execExMatcher){ $refuse = 'Source is in a protected/excluded location' }
                } elseif(Test-SysOrgExcludedPath -Path (Split-Path $canonSrc.Path -Parent) -Config $Config){
                    $refuse = 'Source is in a protected/excluded location'
                }
                if(-not $refuse -and (Test-Path -LiteralPath $canonSrc.Path)){
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
                    $mut = Test-SysOrgFileMutable -Path $canonSrc.Path -Extension '' -DriveProfile $prof2 -Config $Config -Container -PolicyCache $execPolicyCache -ExMatcher $execExMatcher
                } else {
                    $ext2 = [System.IO.Path]::GetExtension($canonSrc.Path).ToLowerInvariant()
                    $mut = Test-SysOrgFileMutable -Path $canonSrc.Path -Extension $ext2 -DriveProfile $prof2 -Config $Config -PolicyCache $execPolicyCache -ExMatcher $execExMatcher
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
                    Add-SysOrgRunLog "Skipped (changed since plan - size differs): $($a.Source)" -Level WARN
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
                            Add-SysOrgRunLog "Skipped (changed since plan - last write time differs): $($a.Source)" -Level WARN
                            continue
                        }
                    } catch { Write-Verbose "Drift check parse failed for '$($a.PlannedLastWriteTimeUtc)': $($_.Exception.Message)" }
                }
            }
            if($refuse){
                $summary.Failed++
                Add-SysOrgRunLog ("REFUSED ({0}): {1} -> {2}" -f $refuse, $a.Source, $a.Destination) -Level ERROR
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

            # v2.1.1: Pending row BEFORE the move - a crash between Pending and Done leaves
            # an orphan that resume resolves against the actual filesystem state.
            if($journalHasStatus){
                Add-SysOrgJournalRow -Kind $kind -Action "$($a.Action)" -OriginalSource $aSource `
                    -CurrentLocation $aDestination -Hash "$hashBefore" -Status 'Pending'
            }

            if($kind -eq 'Folder'){
                $result = Invoke-SysOrgSafeMoveFolder -Source $aSource -Destination $aDestination -Config $Config
            } else {
                # v2.1.1 (item 10): pass the pre-move hash through so cross-volume moves do
                # not hash the source a second time.
                $result = Invoke-SysOrgSafeMove -Source $aSource -Destination $aDestination -Config $Config -ExpectedHash "$hashBefore"
            }

            switch($result.Status){
                'Moved' {
                    if("$($a.Action)" -eq 'Quarantine'){
                        $summary.Quarantined++
                        Add-SysOrgRunLog "Quarantined duplicate: $($a.Source) -> $($result.Destination)" -Level ACTION
                    } else {
                        if($kind -eq 'Folder'){
                            $summary.FolderMoves++
                            Add-SysOrgRunLog "Moved folder: $($a.Source) -> $($result.Destination)" -Level ACTION
                        } else {
                            $summary.Moved++
                            if($a.PSObject.Properties['CopyIndex'] -and $a.CopyIndex){ $summary.Numbered++ }
                            $summary.BytesMoved += [int64]$a.SizeBytes
                            Add-SysOrgRunLog "Moved: $($a.Source) -> $($result.Destination)" -Level ACTION
                        }
                    }
                    # P0-fix note: the row is built by the journal helper, then flushed to
                    # disk (WriteThrough + Flush($true)) so a crash cannot lose it.
                    # v2.1.1: fields are CSV-escaped and the journal stores the CANONICAL source.
                    Add-SysOrgJournalRow -Kind $kind -Action "$($a.Action)" -OriginalSource $aSource `
                        -CurrentLocation "$($result.Destination)" -Hash "$hashBefore" -Status 'Done'
                }
                'CopiedVerified' {
                    if($kind -eq 'Folder'){ $summary.FolderMoves++ } else { $summary.Copied++ }
                    Add-SysOrgJournalRow -Kind $kind -Action "$($a.Action)" -OriginalSource $aSource `
                        -CurrentLocation "$($result.Destination)" -Hash "$hashBefore" -Status 'Done'
                    Add-SysOrgRunLog "Copied+verified: $($a.Source) -> $($result.Destination) ($($result.Message))" -Level WARN
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
                        # Done row for the ORIGINAL pending action: the quarantine move is this
                        # action's resolution, so resume skips the source and undo restores
                        # Source -> quarantine location.
                        Add-SysOrgJournalRow -Kind $kind -Action "$($a.Action)" -OriginalSource $aSource `
                            -CurrentLocation "$($r2.Destination)" -Hash "$hashBefore" -Status 'Done'
                        Add-SysOrgRunLog "Collision duplicate quarantined: $($a.Source) -> $($r2.Destination)" -Level ACTION
                    } else {
                        $summary.Failed++
                        Add-SysOrgRunLog "FAILED (collision quarantine): $($a.Source): $($r2.Message)" -Level ERROR
                    }
                }
                default {
                    $summary.Failed++
                    Add-SysOrgRunLog "FAILED: $($a.Source): $($result.Message)" -Level ERROR
                    # v2.1.1: nothing moved - neutralize the Pending row so it is not
                    # treated as an orphan on the next resume.
                    if($journalHasStatus){
                        Add-SysOrgJournalRow -Kind $kind -Action "$($a.Action)" -OriginalSource $aSource `
                            -CurrentLocation '' -Hash '' -Status 'Retried'
                    }
                }
            }
        }
    } finally {
        $writer.Dispose()
        try { Flush-SysOrgRunLog } catch { }
    }

    Flush-SysOrgRunLog
    Write-Progress -Activity 'Executing plan' -Completed
    Write-SysOrgLog ("Plan {0} finished. Moved={1} Copied={2} Folders={3} Numbered={4} Quarantined={5} Resumed={6} Failed={7} Skipped={8}" -f `
        $plan.PlanId, $summary.Moved, $summary.Copied, $summary.FolderMoves, $summary.Numbered, $summary.Quarantined, $summary.Resumed, $summary.Failed, $summary.Skipped) -LogFolder $logFolder
    return [pscustomobject]@{ PlanId=$plan.PlanId; UndoFile=$undoPath; Summary=$summary }
}

function New-SysOrgLayoutMigrationPlan {
<#
.SYNOPSIS
    Builds a previewable, journaled, undoable plan that migrates an existing v2.1
    organized tree to the Findable layout (v3.0 Phase 6).
.DESCRIPTION
    Walks the destination root (skipping the app-managed runtime folders _Index,
    _Reports, _Duplicates, _Review and the Downloads provenance branch),
    re-classifies every file with the v3.0 routing table and re-buckets dates
    adaptively. Whole folders move as ONE MoveFolder unit when every file inside
    them maps to the same destination folder; files that are ALREADY in their
    Findable place are skipped (running the migration twice is a no-op). The plan
    runs through the same executor as everything else: preview first, never
    overwrites, crash-safe journal, full undo.
.EXAMPLE
    New-SysOrgLayoutMigrationPlan -Letter D -Config $cfg -TargetProfile Findable
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter,$Config,[string]$TargetProfile='Findable')
    if(-not $Config){ throw 'New-SysOrgLayoutMigrationPlan requires -Config.' }
    $stamp = Get-Date
    $planId = 'migrate-' + $stamp.ToString('yyyyMMdd-HHmmss') + '-' + $stamp.ToString('fff')
    $root = Get-SysOrgDestinationRoot -Letter $Letter -Config $Config
    if(-not (Test-Path -LiteralPath $root)){ throw ("Nothing to migrate: destination root '{0}' does not exist." -f $root) }
    $layoutCap = [int](Get-SysOrgSetting $Config 'Layout.MaxFilesPerFolder' 150)
    $layoutMin = [int](Get-SysOrgSetting $Config 'Layout.MinFilesPerFolder' 8)
    $runtimeFolders = @('_index','_reports','_duplicates','_review','_sysorg')

    $files = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    try{
        foreach($f in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)){
            $fn = [string]$f                                    # NATIVE separators (the executor needs them)
            $rel = $fn.Substring($root.Length).TrimStart('\','/').Replace('/','\')   # logic runs on '\'
            $segs = @($rel.Split('\'))
            if($runtimeFolders -contains $segs[0].ToLowerInvariant()){ continue }
            if($segs[0] -ieq 'Downloads'){ continue }   # provenance branch already Findable-shaped
            try { $fi = Get-Item -LiteralPath $fn -Force; [void]$files.Add([pscustomobject]@{ Path=$fn; Rel=$rel; Segs=$segs; Length=[long]$fi.Length; LastWriteTime=$fi.LastWriteTime; CreationTime=$fi.CreationTime }) } catch { }
        }
    } catch { }
    if($files.Count -eq 0){
        [void]$skipped.Add([pscustomobject]@{ Source=$root; Reason='No organized files found under the destination root.' })
    }

    # route every file to its Findable leaf + adaptive date segment
    $recs = New-Object System.Collections.Generic.List[object]
    $leafOf = @{}
    foreach($f in $files.ToArray()){
        $ext = [System.IO.Path]::GetExtension($f.Path).ToLowerInvariant()
        $category = Get-SysOrgCategory -Extension $ext -Config $Config
        if($category -eq 'SKIP'){ $category = 'Other' }
        $subtype = Get-SysOrgFindableSubtype -Category $category -Name ([System.IO.Path]::GetFileName($f.Path)) -Source ''
        $rb = Get-SysOrgFindableRelBase -Category $category -Subtype $subtype -Name ([System.IO.Path]::GetFileName($f.Path))
        # date: prefer the date already embedded in the current path, then filename, then filesystem
        $d = $null
        foreach($seg in $f.Segs){
            if($seg -match '^(19|20)\d{2}(-\d{2}){0,2}$'){
                try { $d = [datetime]::ParseExact($seg, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture); break } catch { }
                try { $d = [datetime]::ParseExact($seg, 'yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture); break } catch { }
                try { $d = [datetime]::ParseExact($seg, 'yyyy', [System.Globalization.CultureInfo]::InvariantCulture); break } catch { }
            }
        }
        if($null -eq $d){
            try { $r = Resolve-SysOrgFileDate -Path $f.Path; $d = $r.Date } catch { $d = $f.LastWriteTime }
        }
        $leafOf[$f.Path] = $rb.RelBase
        [void]$recs.Add([pscustomobject]@{ Key=$rb.RelBase; FileKey=$f.Path; Date=$d; Family=$false; TakesDate=$true })
    }
    $dateSegs = Add-SysOrgFindableDateSegments -Records $recs.ToArray() -Cap $layoutCap -MinPerFolder $layoutMin

    # group by source directory: a whole folder moves when all files share one target
    $byDir = @{}
    foreach($f in $files.ToArray()){
        $dir = Split-Path $f.Path -Parent
        $k = $dir.ToLowerInvariant()
        if(-not $byDir.ContainsKey($k)){ $byDir[$k] = New-Object System.Collections.Generic.List[object] }
        [void]$byDir[$k].Add($f)
    }
    $actions = New-Object System.Collections.Generic.List[object]
    $dirKeys = @($byDir.Keys | Sort-Object)
    foreach($k in $dirKeys){
        $members = @($byDir[$k].ToArray())
        $srcDir = Split-Path $members[0].Path -Parent
        $dirName = Split-Path $srcDir -Leaf
        $targets = New-Object System.Collections.Generic.HashSet[string]
        foreach($m in $members){
            $rb = $leafOf[$m.Path]
            $seg = ''
            $lk = $rb.ToLowerInvariant()
            if($dateSegs.ContainsKey($lk) -and $dateSegs[$lk].ContainsKey($m.Path)){ $seg = [string]$dateSegs[$lk][$m.Path] }
            if($seg){ [void]$targets.Add($rb + '\' + $seg) } else { [void]$targets.Add($rb) }
        }
        if($targets.Count -eq 1){
            $destFolder = $root + '\' + (@($targets)[0])
            $relNow = $members[0].Rel
            $idx = $relNow.LastIndexOf('\')
            $relNow = $(if($idx -ge 0){ $relNow.Substring(0, $idx) } else { '' })
            $already = ($destFolder.Substring($root.Length).TrimStart('\')).ToLowerInvariant()
            if($relNow.ToLowerInvariant() -eq $already){
                [void]$skipped.Add([pscustomobject]@{ Source=$srcDir; Reason='Already in its Findable place (idempotent migration)' })
                continue
            }
            [void]$actions.Add([pscustomobject]@{
                Action='Move'; Kind='Folder'; Source=$srcDir; Destination=$destFolder; DestRoot=$root
                SizeBytes=[int64]0; Family=$null; CopyIndex=$null; SourceBucket=$null
                Reason=('Migrate to Findable: whole folder re-bucketed to ' + (@($targets)[0]))
                DifferentContent=$false; OneDriveSyncOut=$false; OneDriveIntoCloud=$false
                Confidence=$null; RuleId='migration'; ReviewFlag=$false
            })
        } else {
            foreach($m in $members){
                $rb = $leafOf[$m.Path]
                $seg = ''
                $lk = $rb.ToLowerInvariant()
                if($dateSegs.ContainsKey($lk) -and $dateSegs[$lk].ContainsKey($m.Path)){ $seg = [string]$dateSegs[$lk][$m.Path] }
                $destFolder = if($seg){ $root + '\' + $rb + '\' + $seg } else { $root + '\' + $rb }
                $dest = $destFolder + '\' + [System.IO.Path]::GetFileName($m.Path)
                if($dest.Substring($root.Length).TrimStart('\').ToLowerInvariant() -eq $m.Rel.ToLowerInvariant()){
                    [void]$skipped.Add([pscustomobject]@{ Source=$m.Path; Reason='Already in its Findable place (idempotent migration)' })
                    continue
                }
                [void]$actions.Add([pscustomobject]@{
                    Action='Move'; Kind='File'; Source=$m.Path; Destination=$dest; DestRoot=$root
                    SizeBytes=[int64]$m.Length; Family=$null; CopyIndex=$null; SourceBucket=$null
                    Reason=('Migrate to Findable: ' + $rb + $(if($seg){ '\' + $seg }))
                    DifferentContent=$false; OneDriveSyncOut=$false; OneDriveIntoCloud=$false
                    PlannedLength=[int64]$m.Length
                    PlannedLastWriteTimeUtc=([datetime]$m.LastWriteTime).ToUniversalTime().ToString('o')
                    Confidence=$null; RuleId='migration'; ReviewFlag=$false
                })
            }
        }
    }

    return [pscustomobject]@{
        PlanId          = $planId
        Created         = (Get-Date).ToString('s')
        Computer        = $env:COMPUTERNAME
        Drive           = "$Letter`:"
        DestinationRoot = $root
        DestinationStyle= 'OrganizedRoot'
        Mode            = ('Layout migration ({0} -> Findable); _Index/_Reports/_Duplicates untouched' -f $TargetProfile)
        DriveProfile    = $null
        Actions         = $actions.ToArray()
        Skipped         = $skipped.ToArray()
        Families        = @()
        Copies          = [pscustomobject]@{ Policy='n/a'; Numbered=0; Quarantined=0; Reported=0; Groups=@() }
        Mutability      = [pscustomobject]@{ Allowed=$actions.Count; DeniedTotal=0; Denied=@() }
        OneDrive        = [pscustomobject]@{ SyncOut=@(); IntoCloud=@() }
        NeedsDecision   = @()
        Warnings        = @()
        Provenance      = @()
        ProvenanceFile  = ''
        Stats           = [pscustomobject]@{ Scanned=$files.Count; Routed=$actions.Count }
    }
}

function Get-SysOrgPlanInputFingerprint {
<#
.SYNOPSIS
    A stable fingerprint of a plan's INPUTS (v3.0.1 D1).
.DESCRIPTION
    SHA256 over: drive letter, destination root, layout profile, copies policy and
    the sorted 'path|size|mtimeUtcTicks' of the inventory (long-path records
    excluded). Two scans of the same tree in the same state produce the same
    fingerprint - so re-running an identical scan can REUSE the existing plan
    instead of building a duplicate. Deterministic.
.EXAMPLE
    Get-SysOrgPlanInputFingerprint -Letter C -Inventory $inv -Config $cfg -DriveProfile $prof
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter,[AllowEmptyCollection()]$Inventory,
          [Parameter(Mandatory)]$Config,[Parameter(Mandatory)]$DriveProfile)
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add(('letter={0}' -f $Letter))
    try { [void]$parts.Add(('root={0}' -f (Get-SysOrgDestinationRoot -Letter $Letter -Config $Config))) } catch { }
    try { [void]$parts.Add(('layout={0}' -f (Get-SysOrgLayoutProfile -Config $Config))) } catch { }
    [void]$parts.Add(('copies={0}' -f "$(Get-SysOrgSetting $Config 'Copies.Policy' 'NumberCopies')"))
    [void]$parts.Add(('deststyle={0}' -f "$(Get-SysOrgSetting $Config 'DestinationStyle' 'OrganizedRoot')"))
    foreach($f in (@($Inventory) | Where-Object { "$($_.Category)" -ne 'SkippedLongPath' } | Sort-Object { "$($_.FullName)" })){
        $ticks = 0
        try { $ticks = ([datetime]$f.LastWriteTime).ToUniversalTime().Ticks } catch { $ticks = 0 }
        [void]$parts.Add(('{0}|{1}|{2}' -f "$($f.FullName)", [long]$f.Length, $ticks))
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try{
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join ";"))
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
    } finally { $sha.Dispose() }
}

function Get-SysOrgPlanList {
<#
.SYNOPSIS
    The newest saved plans with their status (v3.0.1 D1).
.DESCRIPTION
    Returns up to -Top plans, newest first, each with PlanId, Drive, MoveCount,
    Age (human), Executed (an undo journal exists) and Path. Best effort: unreadable
    plan files are skipped.
.EXAMPLE
    Get-SysOrgPlanList -PlansFolder C:\SysOrg\Plans -Top 10
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlansFolder,[int]$Top=10)
    $rows = New-Object System.Collections.Generic.List[object]
    if(-not (Test-Path -LiteralPath $PlansFolder)){ return $rows.ToArray() }
    $files = @(Get-ChildItem -LiteralPath $PlansFolder -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $shown = 0
    foreach($f in $files){
        if($shown -ge $Top){ break }
        try{
            $p = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            if(-not ($p.PSObject.Properties['PlanId'])){ continue }
            $moveCount = 0
            try { $moveCount = @(@($p.Actions) | Where-Object { "$($_.Action)" -eq 'Move' -and -not ($_.PSObject.Properties['Kind'] -and "$($_.Kind)" -eq 'Folder') }).Count } catch { }
            $executed = (Test-Path -LiteralPath (Join-Path (Join-Path (Split-Path $PlansFolder -Parent) 'Undo') ("undo-{0}.csv" -f $p.PlanId)))
            $age = (New-TimeSpan -Start $f.LastWriteTime -End (Get-Date))
            $ageTxt = if($age.TotalDays -ge 1){ ('{0:N0}d {1}h ago' -f $age.TotalDays, $age.Hours) }
                      elseif($age.TotalHours -ge 1){ ('{0}h {1}m ago' -f $age.Hours, $age.Minutes) }
                      else { ('{0}m ago' -f [Math]::Max(1, $age.Minutes)) }
            [void]$rows.Add([pscustomobject]@{
                PlanId="$($p.PlanId)"; Drive="$($p.Drive)"; MoveCount=$moveCount
                Age=$ageTxt; Executed=[bool]$executed; Path=$f.FullName
            })
            $shown++
        } catch { continue }
    }
    return $rows.ToArray()
}

function Resolve-SysOrgPlanChoice {
<#
.SYNOPSIS
    Resolves a plan-picker input: a list NUMBER, a plan id, a full path, or a FOLDER (v3.0.1 D1).
.DESCRIPTION
    - '1'..'9' selects the Nth entry of the newest-plan list
    - a plan id ('plan-20260101-093000-123') matches the saved plan JSON
    - a full path to a plan JSON is used as-is
    - a FOLDER resolves to its newest plan JSON (recursive)
    Returns the plan JSON path, or $null when nothing matched.
.EXAMPLE
    Resolve-SysOrgPlanChoice -Input '2' -PlansFolder C:\SysOrg\Plans
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Choice,[Parameter(Mandatory)][string]$PlansFolder)
    $v = "$Choice".Trim()
    if([string]::IsNullOrWhiteSpace($v)){ return $null }
    # 1) a list number
    if($v -match '^\d+$'){
        $list = @(Get-SysOrgPlanList -PlansFolder $PlansFolder -Top 10)
        $idx = [int]$v
        if($idx -ge 1 -and $idx -le $list.Count){ return [string]$list[$idx-1].Path }
        return $null
    }
    # 2) a full path to a plan JSON
    if(($v -match '\\') -or ("$v".Contains('/'))){
        if(Test-Path -LiteralPath $v -PathType Leaf){ return $v }
        if(Test-Path -LiteralPath $v -PathType Container){
            $newest = @(Get-ChildItem -LiteralPath $v -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if($newest.Count -gt 0){ return [string]$newest[0].FullName }
        }
        return $null
    }
    # 3) a plan id
    $candidate = Join-Path $PlansFolder ("{0}.json" -f $v)
    if($v -match '^(plan|migrate)-\d{8}-\d{6}(-\d{3})?$' -and (Test-Path -LiteralPath $candidate)){ return $candidate }
    return $null
}

function Test-SysOrgPlanNeedsReview {
<#
.SYNOPSIS
    True when MORE THAN HALF of the planned moves are below the review threshold (v3.0.1 B6).
.DESCRIPTION
    Denominator: planned FILE moves that carry a confidence (the classification
    decisions). Folder units, quarantines and numbered copies are excluded - they
    are not confidence decisions. Threshold: Classify.ReviewConfidence (0.70);
    share: Review.InteractiveThreshold (0.5). When this returns $true the plan must
    NOT be presented as a ready-to-execute default - the interactive review offers
    [A]/[R]/[S]/[N] instead.
.EXAMPLE
    Test-SysOrgPlanNeedsReview -Plan $plan -Config $cfg   # -> $true
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,$Config)
    $revConf = [double](Get-SysOrgSetting $Config 'Classify.ReviewConfidence' 0.70)
    $share = [double](Get-SysOrgSetting $Config 'Review.InteractiveThreshold' 0.5)
    $decided = New-Object System.Collections.Generic.List[object]
    foreach($a in @($Plan.Actions)){
        if("$($a.Action)" -ne 'Move'){ continue }
        if($a.PSObject.Properties['Kind'] -and "$($a.Kind)" -eq 'Folder'){ continue }
        if(-not ($a.PSObject.Properties['Confidence']) -or ($null -eq $a.Confidence)){ continue }
        [void]$decided.Add($a)
    }
    if($decided.Count -eq 0){ return $false }
    $low = 0
    foreach($a in $decided){ if([double]$a.Confidence -lt $revConf){ $low++ } }
    return (($low / $decided.Count) -gt $share)
}

function Get-SysOrgPlanFiltered {
<#
.SYNOPSIS
    A copy of the plan with only the actions at/above a confidence floor (v3.0.1 B6).
.DESCRIPTION
    Used by the review options [A] (approve only confident moves) and [S] (skip all
    uncertain files). Folder moves, quarantines and actions WITHOUT a confidence
    (legacy plans, collection units) are always kept - the floor filters confidence
    decisions only. The returned plan carries the same metadata; re-saving it
    recomputes the integrity hash, so the executor accepts it.
.EXAMPLE
    $filtered = Get-SysOrgPlanFiltered -Plan $plan -ConfidenceFloor 0.70
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][double]$ConfidenceFloor)
    $kept = New-Object System.Collections.Generic.List[object]
    foreach($a in @($Plan.Actions)){
        $isFolder = ($a.PSObject.Properties['Kind'] -and "$($a.Kind)" -eq 'Folder')
        $isQuarantine = ("$($a.Action)" -eq 'Quarantine')
        $hasConf = ($a.PSObject.Properties['Confidence'] -and ($null -ne $a.Confidence))
        if($isFolder -or $isQuarantine -or (-not $hasConf) -or ([double]$a.Confidence -ge $ConfidenceFloor)){
            [void]$kept.Add($a)
        }
    }
    $copy = New-Object System.Collections.Specialized.OrderedDictionary
    foreach($prop in $Plan.PSObject.Properties){
        if($prop.Name -eq 'Actions'){ continue }
        $copy[$prop.Name] = $prop.Value
    }
    $copy['Actions'] = $kept.ToArray()
    return [pscustomobject]$copy
}

function Test-SysOrgReviewDestinationPath {
<#
.SYNOPSIS
    Validates a user-typed destination LEAF for the review flow (v3.0.1 B6).
.DESCRIPTION
    The leaf is RELATIVE to the plan's destination root: non-empty, no '.'/'..'
    segments, no drive qualifier, no leading/trailing separators, no empty segments.
.EXAMPLE
    Test-SysOrgReviewDestinationPath -Leaf 'Documents\Work'   # -> $true
#>
    [CmdletBinding()]
    param([string]$Leaf)
    if([string]::IsNullOrWhiteSpace("$Leaf")){ return $false }
    $l = ("$Leaf").Replace('/','\').Trim('\')
    if([string]::IsNullOrWhiteSpace($l)){ return $false }
    if($l -match '(^|\\)\.{1,2}(\\|$)'){ return $false }
    if($l -match '^[A-Za-z]:'){ return $false }
    foreach($seg in @($l.Split('\'))){ if([string]::IsNullOrWhiteSpace($seg)){ return $false } }
    return $true
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
    Undo-SysOrgPlan -PlanId plan-20260101-093000-123 -AppRoot C:\SysOrg -Config $cfg
#>
    param([Parameter(Mandatory)][string]$PlanId,[Parameter(Mandatory)][string]$AppRoot,$Config)
    if("$PlanId" -notmatch $script:PlanIdPattern){
        throw ("Plan id '{0}' is not valid (expected plan-<yyyyMMdd>-<HHmmss>[-<ms>] or migrate-...); refusing to touch a journal." -f $PlanId)
    }
    $undoPath = Join-Path (Join-Path $AppRoot 'Undo') ('undo-{0}.csv' -f $PlanId)
    if(-not (Test-Path -LiteralPath $undoPath)){ throw "No undo journal found for plan '$PlanId'." }
    $logFolder = Join-Path $AppRoot 'Logs'
    $allRows = @(Import-Csv -LiteralPath $undoPath)
    # v2.1.1: only Done rows (and rows of legacy journals, which carry no Status) are
    # undoable. Orphaned Pending rows and Retried markers describe moves that did NOT
    # complete and are deliberately ignored here.
    $rows = @($allRows | Where-Object {
        $st = ''
        if($_.PSObject.Properties['Status']){ $st = "$($_.Status)" }
        ($st -eq '') -or ($st -ieq 'Done')
    })
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
    # v2.1.1: after a FULLY successful undo the journal is renamed to
    # undo-<PlanId>.undone.csv, which lifts the re-execution guard - the plan can be
    # re-executed deliberately. A partial undo keeps the journal in place.
    if(($restored -gt 0) -and ($failed -eq 0) -and ($skippedMissing -eq 0) -and ($skippedChanged -eq 0) -and ($restored -eq $rows.Count)){
        $undoFolder = Join-Path $AppRoot 'Undo'
        $undonePath = Join-Path $undoFolder ('undo-{0}.undone.csv' -f $PlanId)
        if(Test-Path -LiteralPath $undonePath){
            $undonePath = Join-Path $undoFolder ('undo-{0}.undone-{1}.csv' -f $PlanId, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        }
        try{
            Rename-Item -LiteralPath $undoPath -NewName (Split-Path $undonePath -Leaf) -ErrorAction Stop
            Write-SysOrgLog "Journal archived to '$undonePath' - the plan can be re-executed deliberately now." -LogFolder $logFolder
        } catch { Write-Verbose "Journal rename failed: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Restored=$restored; Failed=$failed; SkippedMissing=$skippedMissing; SkippedChanged=$skippedChanged }
}

function New-SysOrgScanReport {
<#
.SYNOPSIS
    Report-only scan used by the weekly scheduled task. Writes a text report;
    moves nothing. Always uses the narrowed ScanRoots scope and never reads cache.
.DESCRIPTION
    v2.1.1: the report is written under <AppRoot>\Reports\ (never at a drive root),
    the drive profile is built fresh inside the function (or accepted via the optional
    -DriveProfile parameter) so the "Drive profile" line actually prints, and a drive
    whose scan roots contain no files is SKIPPED instead of producing an empty report
    (returns $null).
.EXAMPLE
    New-SysOrgScanReport -Letter C -Config $cfg -AppRoot C:\SysOrg
#>
    param([Parameter(Mandatory)][string]$Letter,$Config,[Parameter(Mandatory)][string]$AppRoot,$DriveProfile,[string[]]$ScanRoots)
    $logFolder = Join-Path $AppRoot 'Logs'
    Write-SysOrgLog "Scheduled report scan starting for drive $Letter`:" -LogFolder $logFolder
    # v2.1.1: build the drive profile fresh (or take the caller's) - the 'Drive profile'
    # line referenced an undefined $prof before this fix.
    $prof = $DriveProfile
    if(-not $prof){
        try{
            $profiles = @(Get-SysOrgDriveProfile -Config $Config -Letters $Letter)
            if($profiles.Count -gt 0){ $prof = $profiles[0] }
        } catch { Write-Verbose "Drive profile unavailable for $Letter`: $($_.Exception.Message)" }
    }
    $invParams = @{ Letter=$Letter; Config=$Config; CacheFolder=(Join-Path $AppRoot 'Cache'); NoCache=$true }
    if($ScanRoots -and @($ScanRoots).Count -gt 0){ $invParams.Roots = $ScanRoots } else { $invParams.DefaultScope = $true }
    # @() wrapping: the inventory and duplicate functions stream their records
    # (an empty result emits nothing), so callers must collect with @().
    $inv = @(Get-SysOrgInventory @invParams)
    if($inv.Count -eq 0){
        # v2.1.1: skip drives with empty scan roots instead of writing an empty report.
        Write-SysOrgLog "Scheduled report skipped for drive $Letter`: no files found in the scan roots." -Level WARN -LogFolder $logFolder
        return $null
    }
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

    # v2.1.1: reports live under the app folder, never at a drive root.
    $reportsFolder = Join-Path $AppRoot 'Reports'
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
