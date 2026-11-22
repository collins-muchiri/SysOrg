#Requires -Version 5.1
# SysOrg.Score.psm1 - the findability score (v3.0 Phase 0.3 / Phase 5).
#
# Measures how easy an organized tree is to browse and search:
#   - folder depth (average and max, below the tree root)
#   - fan-out percentiles (files per folder, subfolders per folder)
#   - % of files in over-cap folders (more than Layout.MaxFilesPerFolder)
#   - % of files in near-empty folders (fewer than Layout.MinFilesPerFolder)
#   - % classified with confidence >= 0.70, % left in place, % review-flagged
#   - browse-distance: average number of folder opens from the root to a file
#   - duplicate share of total bytes
# Every metric has a target in config (Score.Targets); Show- prints pass/fail.
# The score is deterministic: identical inputs produce identical numbers.

function Get-SysOrgPercentile {
<#
.SYNOPSIS
    Deterministic percentile of a numeric list (index floor(p*(n-1)) on the sorted list).
.DESCRIPTION
    Nearest-rank style; for an empty list returns 0. Used for fan-out percentiles so
    identical inputs always produce identical numbers.
.EXAMPLE
    Get-SysOrgPercentile -Values @(1,2,3,4) -Percentile 0.5   # -> 2
#>
    param([int[]]$Values,[double]$Percentile)
    if($null -eq $Values -or @($Values).Count -eq 0){ return 0 }
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    $idx = [int][Math]::Floor($Percentile * ($n - 1))
    if($idx -lt 0){ $idx = 0 }
    if($idx -ge $n){ $idx = $n - 1 }
    return [int]$sorted[$idx]
}

function Get-SysOrgScoreTargets {
<#
.SYNOPSIS
    Reads the Score.Targets block from config with the built-in defaults.
.EXAMPLE
    Get-SysOrgScoreTargets -Config $cfg   # -> hashtable of target metrics
#>
    param($Config)
    $t = @{
        MaxDepth      = 4      # no file sits deeper than this below the root
        AvgDepth      = 3.0    # average folder opens to a file
        OverCapShare  = 0.05   # at most 5% of files in over-cap folders
        NearEmptyShare= 0.10   # at most 10% of files in near-empty folders
        ConfidentShare= 0.80   # at least 80% of planned files at confidence >= 0.70
        DupByteShare  = 0.10   # at most 10% of bytes are duplicates
    }
    $cfg = Get-SysOrgSetting $Config 'Score.Targets' $null
    if($cfg -is [hashtable]){
        foreach($k in @($cfg.Keys)){ $t["$k"] = $cfg[$k] }
    }
    return $t
}

function Get-SysOrgFindabilityScore {
<#
.SYNOPSIS
    Computes the findability score for a set of files under a root.
.DESCRIPTION
    -FilePaths are the files being scored (full paths; anything outside -Root is
    counted as left in place). -Confidences optionally maps path -> 0..1 confidence
    (from the v3.0 Decision records). -DuplicateBytes is the redundant byte total
    measured by the duplicate pipeline; -TotalBytes defaults to the sum of file sizes
    when -FileSizes is supplied. Deterministic: folders are aggregated in one pass and
    percentiles use the nearest-rank rule.
    v3.0.1 A2: -MinFilesForScore (caller-supplied; the CLI uses 20) makes the composite
    score an honest 'n/a' (-1) on tiny trees instead of a meaningless 100. All raw
    metrics are still computed, so callers can inspect them.
.EXAMPLE
    $s = Get-SysOrgFindabilityScore -Root 'C:\_Organized' -FilePaths $paths -FileSizes $sizes
    $s.Score   # -> 0..100
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$FilePaths,
        [hashtable]$FileSizes,
        [hashtable]$Confidences,
        [long]$DuplicateBytes = 0,
        [int]$Cap = 150,
        [int]$MinPerFolder = 8,
        [int]$MinFilesForScore = 0
    )
    $rootN = ("$Root").Replace('/','\').TrimEnd('\')
    if([string]::IsNullOrWhiteSpace($rootN)){ $rootN = '\' }

    $folderFiles = @{}          # folder -> file count
    $folderSubs  = @{}          # folder -> subfolder count (derived from every folder seen)
    $depths      = New-Object System.Collections.Generic.List[int]
    $totalBytes  = [long]0
    $confident   = 0
    $review      = 0
    $lowConf     = 0
    $withConf    = 0
    $leftInPlace = 0
    $rootPrefix = $rootN + '\'

    foreach($p in @($FilePaths)){
        $pn = ("$p").Replace('/','\').TrimEnd('\')
        if([string]::IsNullOrWhiteSpace($pn)){ continue }
        $dir = $pn
        if($pn -notlike "$rootPrefix*"){
            $leftInPlace++
            continue
        }
        $dir = $pn.Substring($rootPrefix.Length)
        $dir = $dir.Substring(0, [Math]::Max(0, $dir.LastIndexOf('\')))
        if($dir -eq ''){ $dir = '(root)' }
        $dirKey = $dir.ToLowerInvariant()
        if(-not $folderFiles.ContainsKey($dirKey)){ $folderFiles[$dirKey] = 0 }
        $folderFiles[$dirKey]++
        # depth = number of folder opens from the root to the file (root level = 0)
        if($dir -eq '(root)'){ [void]$depths.Add(0) }
        else {
            $segs = @($dir.Split('\') | Where-Object { "$_" -ne '' })
            [void]$depths.Add($segs.Count)
        }
        if($FileSizes -and $FileSizes.ContainsKey($pn)){ $totalBytes += [long]$FileSizes[$pn] }
        if($Confidences -and $Confidences.ContainsKey($pn)){
            $c = [double]$Confidences[$pn]
            $withConf++
            if($c -ge 0.70){ $confident++ }
            elseif($c -ge 0.40){ $review++ }
            else { $lowConf++ }
        }
    }

    # subfolders per folder: every folder key is a child of its parent folder
    foreach($f in @($folderFiles.Keys)){
        if($f -eq '(root)'){ continue }
        $parent = ''
        $idx = $f.LastIndexOf('\')
        if($idx -gt 0){ $parent = $f.Substring(0, $idx) } else { $parent = '(root)' }
        if(-not $folderSubs.ContainsKey($parent)){ $folderSubs[$parent] = 0 }
        $folderSubs[$parent]++
    }

    $filesPerFolder = New-Object System.Collections.Generic.List[int]
    foreach($f in @($folderFiles.Keys)){ [void]$filesPerFolder.Add([int]$folderFiles[$f]) }
    $subsPerFolder = New-Object System.Collections.Generic.List[int]
    foreach($s in @($folderSubs.Keys)){ [void]$subsPerFolder.Add([int]$folderSubs[$s]) }

    $overCapFiles = 0
    $nearEmptyFiles = 0
    foreach($f in @($folderFiles.Keys)){
        $c = [int]$folderFiles[$f]
        if($c -gt $Cap){ $overCapFiles += $c }
        if($c -lt $MinPerFolder){ $nearEmptyFiles += $c }
    }
    $totalFiles = @($FilePaths | Where-Object { "$_" -ne '' }).Count
    $scoredFiles = [Math]::Max(1, $totalFiles)

    $avgDepth = 0.0
    $maxDepth = 0
    if($depths.Count -gt 0){
        $avgDepth = [Math]::Round((($depths | Measure-Object -Average).Average), 2)
        $maxDepth = ($depths | Measure-Object -Maximum).Maximum
    }
    $overCapShare = [Math]::Round($overCapFiles / $scoredFiles, 4)
    $nearEmptyShare = [Math]::Round($nearEmptyFiles / $scoredFiles, 4)
    $leftShare = [Math]::Round($leftInPlace / $scoredFiles, 4)
    $confidentShare = -1.0
    $reviewShare = -1.0
    if($withConf -gt 0){
        $confidentShare = [Math]::Round($confident / $withConf, 4)
        $reviewShare = [Math]::Round($review / $withConf, 4)
    }
    $dupShare = -1.0
    if($totalBytes -gt 0){ $dupShare = [Math]::Round($DuplicateBytes / $totalBytes, 4) }

    # composite 0..100: start at 100 and subtract weighted shares/depth violations.
    $score = 100.0
    $score -= 30.0 * $overCapShare
    $score -= 20.0 * $nearEmptyShare
    $score -= 15.0 * $leftShare
    if($withConf -gt 0){ $score -= 20.0 * (1.0 - $confidentShare) }
    if($dupShare -ge 0){ $score -= 10.0 * $dupShare }
    if($maxDepth -gt 4){ $score -= [Math]::Min(20.0, 5.0 * ($maxDepth - 4)) }
    if($score -lt 0){ $score = 0.0 }
    if($score -gt 100){ $score = 100.0 }
    # v3.0.1 A2: an honest 'n/a' on a tiny population - 4 files can never mean 100.
    if($MinFilesForScore -gt 0 -and $totalFiles -lt $MinFilesForScore){ $score = -1.0 }

    return [pscustomobject]@{
        Root            = $rootN
        Files           = $totalFiles
        Folders         = @($folderFiles.Keys).Count
        AvgDepth        = $avgDepth
        MaxDepth        = $maxDepth
        FilesPerFolder  = [pscustomobject]@{ P50=(Get-SysOrgPercentile -Values $filesPerFolder.ToArray() -Percentile 0.5); P90=(Get-SysOrgPercentile -Values $filesPerFolder.ToArray() -Percentile 0.9); P99=(Get-SysOrgPercentile -Values $filesPerFolder.ToArray() -Percentile 0.99) }
        SubsPerFolder   = [pscustomobject]@{ P50=(Get-SysOrgPercentile -Values $subsPerFolder.ToArray() -Percentile 0.5); P90=(Get-SysOrgPercentile -Values $subsPerFolder.ToArray() -Percentile 0.9) }
        OverCapShare    = $overCapShare
        NearEmptyShare  = $nearEmptyShare
        LeftInPlaceShare= $leftShare
        ConfidentShare  = $confidentShare     # -1 when no confidences were supplied
        ReviewShare     = $reviewShare
        LowConfShare    = $(if($withConf -gt 0){ [Math]::Round($lowConf / $withConf, 4) } else { -1.0 })
        DuplicateByteShare = $dupShare        # -1 when total bytes unknown
        Score           = [Math]::Round($score, 1)
        MinFilesForScore= $MinFilesForScore   # the threshold that made Score -1 (n/a), if any
    }
}

function Test-SysOrgScoreTargets {
<#
.SYNOPSIS
    Compares a score result against the configured targets.
.DESCRIPTION
    Returns one row per metric with Pass true/false. Metrics whose value is -1
    (not measurable in this run) are reported as 'n/a' and never fail.
.EXAMPLE
    Test-SysOrgScoreTargets -Score $s -Config $cfg
#>
    param([Parameter(Mandatory)]$Score,$Config)
    $t = Get-SysOrgScoreTargets -Config $Config
    $rows = @()
    $rows += [pscustomobject]@{ Metric='MaxDepth'; Value=$Score.MaxDepth; Target=$t.MaxDepth; Pass=($Score.MaxDepth -le [double]$t.MaxDepth) }
    $rows += [pscustomobject]@{ Metric='AvgDepth'; Value=$Score.AvgDepth; Target=$t.AvgDepth; Pass=($Score.AvgDepth -le [double]$t.AvgDepth) }
    $rows += [pscustomobject]@{ Metric='OverCapShare'; Value=$Score.OverCapShare; Target=$t.OverCapShare; Pass=($Score.OverCapShare -le [double]$t.OverCapShare) }
    $rows += [pscustomobject]@{ Metric='NearEmptyShare'; Value=$Score.NearEmptyShare; Target=$t.NearEmptyShare; Pass=($Score.NearEmptyShare -le [double]$t.NearEmptyShare) }
    $rows += [pscustomobject]@{ Metric='ConfidentShare'; Value=$Score.ConfidentShare; Target=$t.ConfidentShare; Pass=(($Score.ConfidentShare -lt 0) -or ($Score.ConfidentShare -ge [double]$t.ConfidentShare)) }
    $rows += [pscustomobject]@{ Metric='DupByteShare'; Value=$Score.DuplicateByteShare; Target=$t.DupByteShare; Pass=(($Score.DuplicateByteShare -lt 0) -or ($Score.DuplicateByteShare -le [double]$t.DupByteShare)) }
    # stream the rows: callers collect with @() (the ',array' wrapper would make
    # @(Test-...) a ONE-element array holding the whole inner array)
    return $rows
}

function Show-SysOrgFindabilityScore {
<#
.SYNOPSIS
    Prints a findability score result (and optionally the target table).
.DESCRIPTION
    v3.0.1 A2: an empty tree (or one below the population floor) prints an honest
    'n/a', never a fake 100.
.EXAMPLE
    Show-SysOrgFindabilityScore -Score $s -Config $cfg -Label 'After plan'
#>
    param([Parameter(Mandatory)]$Score,[string]$Label,$Config,[switch]$WithTargets)
    if($Score.Score -lt 0){
        if($Label){ Write-Host ('Findability score - {0}: n/a' -f $Label) -ForegroundColor Gray }
        else { Write-Host 'Findability score: n/a' -ForegroundColor Gray }
        Write-Host ('  {0} file(s) in this tree - fewer than {1}; there is nothing meaningful to score yet.' -f $Score.Files, $Score.MinFilesForScore) -ForegroundColor Gray
        return
    }
    if($Label){ Write-Host '' ; Write-Host ("Findability score - {0}: {1}/100" -f $Label, $Score.Score) -ForegroundColor White }
    else { Write-Host ("Findability score: {0}/100" -f $Score.Score) -ForegroundColor White }
    Write-Host ("  files={0} folders={1}  depth avg={2} max={3}  browse-distance(avg folder opens)={4}" -f $Score.Files, $Score.Folders, $Score.AvgDepth, $Score.MaxDepth, $Score.AvgDepth)
    Write-Host ("  files/folder p50={0} p90={1} p99={2}   subfolders/folder p50={3} p90={4}" -f $Score.FilesPerFolder.P50, $Score.FilesPerFolder.P90, $Score.FilesPerFolder.P99, $Score.SubsPerFolder.P50, $Score.SubsPerFolder.P90)
    Write-Host ("  over-cap files: {0}%   near-empty-folder files: {1}%   left in place: {2}%" -f ($Score.OverCapShare*100), ($Score.NearEmptyShare*100), ($Score.LeftInPlaceShare*100))
    if($Score.ConfidentShare -ge 0){ Write-Host ("  confidence >= 0.70: {0}%   review-flagged: {1}%   below 0.40: {2}%" -f ($Score.ConfidentShare*100), ($Score.ReviewShare*100), ($Score.LowConfShare*100)) }
    if($Score.DuplicateByteShare -ge 0){ Write-Host ("  duplicate bytes: {0}% of total" -f ($Score.DuplicateByteShare*100)) }
    if($WithTargets -and $Config){
        foreach($row in (Test-SysOrgScoreTargets -Score $Score -Config $Config)){
            $mark = 'PASS'
            if($row.Value -lt 0){ $mark = 'n/a ' }
            elseif(-not $row.Pass){ $mark = 'FAIL' }
            $color = 'Gray'
            if($mark -eq 'FAIL'){ $color = 'Yellow' }
            Write-Host ("  [{0}] {1}: {2} (target {3})" -f $mark, $row.Metric, $row.Value, $row.Target) -ForegroundColor $color
        }
    }
}

function Get-SysOrgPlanScoreDelta {
<#
.SYNOPSIS
    Before/after findability scores for a plan (v3.0 Phase 5; corrected in v3.0.1 A2).
.DESCRIPTION
    v3.0.1 A2 - the BEFORE and AFTER trees are scored over the SAME population:
    EVERY file in scope (the untouched files plus the planned moves) appears on both
    sides, at its before and after location. The old code compared a moved-files-only
    'after' against it, which could make an 11-file plan over 9,579 files read as
    'worsens'. Pass -Inventory (the scan records) to include the untouched files;
    without it the population falls back to the plan's own actions + needs-a-decision
    files (still the same population on both sides).
    Population below Score.MinPopulation (default 20) or an empty tree returns the
    honest Verdict 'n/a' - never a fake 100.
    Verdict wording is honest about scale: when fewer than
    Score.MeaningfulChangeShare (default 5%) of the population is affected, the
    verdict is 'no meaningful change' - never 'improves'/'worsens'.
    Deterministic.
.EXAMPLE
    $delta = Get-SysOrgPlanScoreDelta -Plan $plan -Config $cfg -Root $root -Inventory $inv
    $delta.Verdict   # -> 'improves' | 'worsens' | 'unchanged' | 'no meaningful change' | 'n/a'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$Root,
          [AllowEmptyCollection()]$Inventory)
    $cap = [int](Get-SysOrgSetting $Config 'Layout.MaxFilesPerFolder' 150)
    $min = [int](Get-SysOrgSetting $Config 'Layout.MinFilesPerFolder' 8)
    $minPopulation = [int](Get-SysOrgSetting $Config 'Score.MinPopulation' 20)
    $meaningfulShare = [double](Get-SysOrgSetting $Config 'Score.MeaningfulChangeShare' 0.05)
    $rootN = ("$Root").Replace('/','\').TrimEnd('\')

    # ---- build the population: same set of files, before AND after locations ----
    $plannedDestBySrc = @{}
    $plannedSizeBySrc = @{}
    $plannedConfBySrc = @{}
    foreach($a in @($Plan.Actions)){
        if("$($a.Action)" -ne 'Move'){ continue }
        if($a.PSObject.Properties['Kind'] -and "$($a.Kind)" -eq 'Folder'){ continue }   # folder units are not scored per-file
        $src = "$($a.Source)"
        $dst = "$($a.Destination)"
        $sz = [long]0
        if($a.PSObject.Properties['SizeBytes'] -and $a.SizeBytes){ $sz = [long]$a.SizeBytes }
        $plannedDestBySrc[$src] = $dst
        $plannedSizeBySrc[$src] = $sz
        if($a.PSObject.Properties['Confidence'] -and ($null -ne $a.Confidence)){ $plannedConfBySrc[$src] = [double]$a.Confidence }
    }

    $population = New-Object System.Collections.Generic.List[object]
    $inventorySet = @{}
    if($Inventory -and @($Inventory).Count -gt 0){
        foreach($f in @($Inventory)){
            $src = "$($f.FullName)"
            if([string]::IsNullOrWhiteSpace($src)){ continue }
            if("$($f.Category)" -eq 'SkippedLongPath'){ continue }   # recorded, never planned
            $inventorySet[$src] = $true
            $after = $src
            if($plannedDestBySrc.ContainsKey($src)){ $after = [string]$plannedDestBySrc[$src] }
            $sz = [long]0
            if($f.PSObject.Properties['Length'] -and $f.Length){ $sz = [long]$f.Length }
            elseif($plannedSizeBySrc.ContainsKey($src)){ $sz = [long]$plannedSizeBySrc[$src] }
            $conf = $null
            if($plannedConfBySrc.ContainsKey($src)){ $conf = $plannedConfBySrc[$src] }
            [void]$population.Add([pscustomobject]@{ Before=$src; After=$after; Size=$sz; Conf=$conf })
        }
        # plan actions whose source is not in the inventory (folder members, cross-scope copies)
        foreach($a in @($Plan.Actions)){
            if("$($a.Action)" -ne 'Move'){ continue }
            if($a.PSObject.Properties['Kind'] -and "$($a.Kind)" -eq 'Folder'){ continue }
            $src = "$($a.Source)"
            if($inventorySet.ContainsKey($src)){ continue }
            $sz = [long]0
            if($a.PSObject.Properties['SizeBytes'] -and $a.SizeBytes){ $sz = [long]$a.SizeBytes }
            $conf = $null
            if($a.PSObject.Properties['Confidence'] -and ($null -ne $a.Confidence)){ $conf = [double]$a.Confidence }
            [void]$population.Add([pscustomobject]@{ Before=$src; After="$($a.Destination)"; Size=$sz; Conf=$conf })
        }
    }
    else {
        # no inventory supplied: the plan's own files (moves + needs-a-decision) form the
        # population - the SAME set on both sides
        foreach($a in @($Plan.Actions)){
            if("$($a.Action)" -ne 'Move'){ continue }
            if($a.PSObject.Properties['Kind'] -and "$($a.Kind)" -eq 'Folder'){ continue }
            $src = "$($a.Source)"
            $sz = [long]0
            if($a.PSObject.Properties['SizeBytes'] -and $a.SizeBytes){ $sz = [long]$a.SizeBytes }
            $conf = $null
            if($a.PSObject.Properties['Confidence'] -and ($null -ne $a.Confidence)){ $conf = [double]$a.Confidence }
            [void]$population.Add([pscustomobject]@{ Before=$src; After="$($a.Destination)"; Size=$sz; Conf=$conf })
        }
        if($Plan.PSObject.Properties['NeedsDecision']){
            $seenBefore = @{}
            foreach($p in $population){ $seenBefore["$($p.Before)"] = $true }
            foreach($nd in @($Plan.NeedsDecision)){
                $src = "$($nd.Source)"
                if([string]::IsNullOrWhiteSpace($src)){ continue }
                if($seenBefore.ContainsKey($src)){ continue }
                $seenBefore[$src] = $true
                [void]$population.Add([pscustomobject]@{ Before=$src; After=$src; Size=[long]0; Conf=$null })
            }
        }
    }

    $total = $population.Count
    $affected = 0
    foreach($p in $population){ if("$($p.Before)" -ine "$($p.After)"){ $affected++ } }

    if($total -lt $minPopulation){
        return [pscustomobject]@{
            Before=$null; After=$null; Verdict='n/a'
            Why=('population too small to score honestly ({0} file(s) in scope; {1} required)' -f $total, $minPopulation)
            Moved=$affected; Affected=$affected; Population=$total; CommonRoot=$rootN; Measured=$false
        }
    }

    $beforePaths = New-Object System.Collections.Generic.List[string]
    $beforeSizes = @{}
    $beforeConf = @{}
    $afterPaths = New-Object System.Collections.Generic.List[string]
    $afterSizes = @{}
    $afterConf = @{}
    foreach($p in $population){
        [void]$beforePaths.Add([string]$p.Before)
        [void]$afterPaths.Add([string]$p.After)
        $beforeSizes[[string]$p.Before] = [long]$p.Size
        $afterSizes[[string]$p.After] = [long]$p.Size
        if($null -ne $p.Conf){ $beforeConf[[string]$p.Before] = [double]$p.Conf; $afterConf[[string]$p.After] = [double]$p.Conf }
    }
    # The BEFORE tree must be measured on its own structure: sources live OUTSIDE the
    # destination root (and possibly on another drive), so each tree is scored relative
    # to its own deepest common ancestor - that keeps depth/fan-out comparable between
    # the current layout and the planned one. SAME population on both sides.
    function Get-SysOrgCommonAncestor {
        param([AllowEmptyCollection()][string[]]$Paths)
        $root2 = $null
        foreach($p in $Paths){
            $pn = ("$p").Replace('/','\')
            $dir = $pn.Substring(0, [Math]::Max(0, $pn.LastIndexOf('\')))
            if($null -eq $root2){ $root2 = $dir; continue }
            $a = $root2.ToLowerInvariant()
            $b = $dir.ToLowerInvariant()
            $n = [Math]::Min($a.Length, $b.Length)
            $i = 0
            while($i -lt $n -and $a[$i] -eq $b[$i]){ $i++ }
            $root2 = $root2.Substring(0, $i)
        }
        if([string]::IsNullOrWhiteSpace($root2)){ return $null }
        return $root2.TrimEnd('\')
    }
    $beforeRoot = Get-SysOrgCommonAncestor -Paths $beforePaths.ToArray()
    $afterRoot = Get-SysOrgCommonAncestor -Paths $afterPaths.ToArray()
    if([string]::IsNullOrWhiteSpace($beforeRoot)){ $beforeRoot = $rootN }
    if([string]::IsNullOrWhiteSpace($afterRoot)){ $afterRoot = $rootN }
    $before = Get-SysOrgFindabilityScore -Root $beforeRoot -FilePaths $beforePaths.ToArray() -FileSizes $beforeSizes -Confidences $beforeConf -Cap $cap -MinPerFolder $min
    $after  = Get-SysOrgFindabilityScore -Root $afterRoot  -FilePaths $afterPaths.ToArray()  -FileSizes $afterSizes  -Confidences $afterConf  -Cap $cap -MinPerFolder $min
    $verdict = 'unchanged'
    if($after.Score -gt $before.Score){ $verdict = 'improves' }
    elseif($after.Score -lt $before.Score){ $verdict = 'worsens' }
    # v3.0.1 A2: honest scale. An 11-file plan over 9,579 files is noise, not a verdict.
    $affectedPct = [Math]::Round(100.0 * $affected / $total, 1)
    if(($affected / $total) -lt $meaningfulShare){ $verdict = 'no meaningful change' }
    $why = ('{0} of {1} files affected ({2}%); depth {3} -> {4}; over-cap {5}% -> {6}%{7}' -f `
        $affected, ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $total)), $affectedPct, $before.AvgDepth, $after.AvgDepth,
        [Math]::Round($before.OverCapShare*100), [Math]::Round($after.OverCapShare*100),
        $(if($before.ConfidentShare -ge 0){ ('; confident {0}% -> {1}%' -f [Math]::Round($before.ConfidentShare*100), [Math]::Round($after.ConfidentShare*100)) } else { '' }))
    return [pscustomobject]@{
        Before=$before; After=$after; Verdict=$verdict; Why=$why
        Moved=$affected; Affected=$affected; Population=$total; CommonRoot=$beforeRoot
        Measured=$true
    }
}

function Show-SysOrgScoreDelta {
<#
.SYNOPSIS
    Prints the before/after score and the plain-language verdict.
.DESCRIPTION
    v3.0.1 A2: verdict wording is honest about scale - a tiny affected share reads
    'no meaningful change (X of Y files affected)' and can never read 'worsens';
    a too-small population reads 'n/a'.
.EXAMPLE
    Show-SysOrgScoreDelta -Delta $delta
#>
    param([Parameter(Mandatory)]$Delta)
    if("$($Delta.Verdict)" -eq 'n/a'){
        Write-Host ''
        Write-Host ('Findability score: n/a  ({0})' -f $Delta.Why) -ForegroundColor Gray
        return
    }
    if("$($Delta.Verdict)" -eq 'no meaningful change'){
        Write-Host ''
        Write-Host ('Findability score: {0} -> {1}  (no meaningful change: {2} of {3} files affected)' -f `
            $Delta.Before.Score, $Delta.After.Score, $Delta.Affected,
            ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $Delta.Population))) -ForegroundColor Gray
        Write-Host ('  ' + $Delta.Why) -ForegroundColor Gray
        return
    }
    $color = 'Gray'
    if($Delta.Verdict -eq 'improves'){ $color = 'Green' }
    elseif($Delta.Verdict -eq 'worsens'){ $color = 'Yellow' }
    Write-Host ''
    Write-Host ('Findability score: {0} -> {1}  (this plan {2} it)' -f $Delta.Before.Score, $Delta.After.Score, $Delta.Verdict) -ForegroundColor $color
    Write-Host ('  ' + $Delta.Why) -ForegroundColor Gray
    if($Delta.Verdict -eq 'worsens'){ Write-Host '  The plan makes the tree harder to browse - review the destination settings before executing.' -ForegroundColor Yellow }
}

function Get-SysOrgTreeScore {
<#
.SYNOPSIS
    Scores an existing tree live (the -Score CLI path).
.DESCRIPTION
    v3.0.1 A2: the composite score is 'n/a' (-1) for a tree with fewer than
    Score.MinPopulation (default 20) files - an empty or near-empty tree never
    prints a fake 100.
.EXAMPLE
    Get-SysOrgTreeScore -Root 'C:\_Organized' -Config $cfg
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,$Config)
    $cap = [int](Get-SysOrgSetting $Config 'Layout.MaxFilesPerFolder' 150)
    $min = [int](Get-SysOrgSetting $Config 'Layout.MinFilesPerFolder' 8)
    $minPop = [int](Get-SysOrgSetting $Config 'Score.MinPopulation' 20)
    $paths = New-Object System.Collections.Generic.List[string]
    $sizes = @{}
    try{
        foreach($f in [System.IO.Directory]::EnumerateFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)){
            $paths.Add([string]$f)
            try { $sizes[[string]$f] = (Get-Item -LiteralPath $f -Force).Length } catch { }
        }
    } catch { }
    return (Get-SysOrgFindabilityScore -Root $Root -FilePaths $paths.ToArray() -FileSizes $sizes -Cap $cap -MinPerFolder $min -MinFilesForScore $minPop)
}

Export-ModuleMember -Function *-SysOrg*
