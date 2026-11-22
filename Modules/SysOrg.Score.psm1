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
        [int]$MinPerFolder = 8
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
.EXAMPLE
    Show-SysOrgFindabilityScore -Score $s -Config $cfg -Label 'After plan'
#>
    param([Parameter(Mandatory)]$Score,[string]$Label,$Config,[switch]$WithTargets)
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

Export-ModuleMember -Function *-SysOrg*
