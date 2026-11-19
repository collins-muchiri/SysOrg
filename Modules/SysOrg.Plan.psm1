#Requires -Version 5.1
# SysOrg.Plan.psm1 - plan generation, preview, execution with undo journal, undo, reports.

function New-SysOrgPlan {
<#
.SYNOPSIS
    Builds a move/quarantine plan from an inventory, clusters and duplicate groups.
.DESCRIPTION
    Destination layout: <root>\<Category>\[Projects\<key>|<date>]\file. Duplicate
    quarantine actions carry the scan-time SHA256 (P2-1 hash economy). Files with
    Category 'SkippedLongPath' are never planned (P2-5).
.EXAMPLE
    $plan = New-SysOrgPlan -Letter C -Inventory $inv -ClusterResult $cl -DupGroups $dups -Config $cfg
#>
    param([Parameter(Mandatory)][string]$Letter,$Inventory,$ClusterResult,$DupGroups,$Config)
    $root             = Get-SysOrgDestinationRoot -Letter $Letter -Config $Config
    $planId           = 'plan-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $maxActions       = Get-SysOrgSetting $Config 'MaxPlanActions' 5000
    $dateMode         = Get-SysOrgSetting $Config 'DateFolders' 'Year'
    $quarantinePolicy = Get-SysOrgSetting $Config 'Duplicates.Policy' 'Quarantine'
    $qFolder          = Get-SysOrgSetting $Config 'Duplicates.QuarantineFolderName' '_Duplicates'

    $organizedSet = Get-SysOrgOrganizedDirSet -Inventory $Inventory -Config $Config

    $dupSet = @{}
    foreach($dg in $DupGroups){ foreach($p in $dg.Duplicates){ $dupSet[$p] = $dg.Hash } }

    $actions = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]

    foreach($f in $Inventory){
        if($actions.Count -ge $maxActions){ Write-Warning "Plan capped at $maxActions actions; rest skipped this run."; break }
        try{
            $src = $f.FullName
            if($f.Category -eq 'SkippedLongPath'){
                $skipped.Add([pscustomobject]@{ Source=$src; Reason='Path >= 260 characters (recorded; PowerShell 5.1 cannot address it)' })
                continue
            }
            if(Test-SysOrgDestinationPath -Path $src -Config $Config){ continue }

            if($dupSet.ContainsKey($src)){
                if($quarantinePolicy -eq 'Quarantine'){
                    $h = $dupSet[$src]
                    $hash8 = if($h -and ($h.Length -ge 8)){ $h.Substring(0,8) } else { 'dup' }
                    $qName = '{0}_{1}{2}' -f $f.Stem, $hash8, $f.Extension
                    $dest  = Join-Path (Join-Path $root $qFolder) (Join-Path $planId $qName)
                    $actions.Add([pscustomobject]@{ Action='Quarantine'; Source=$src; Destination=$dest; Reason='Exact duplicate (keeper identified during scan)'; SizeBytes=$f.Length; Hash=$h })
                }
                continue
            }

            if((Get-SysOrgSetting $Config 'PreserveExistingFolders' $true) -and
               (Test-SysOrgInOrganizedDir -Directory $f.Directory -OrganizedSet $organizedSet)){
                $skipped.Add([pscustomobject]@{ Source=$src; Reason='Inside a folder that already looks organized (preserved)' })
                continue
            }

            $cat = $f.Category
            $projectKey = $null
            if($ClusterResult.Lookup.ContainsKey($src)){ $projectKey = $ClusterResult.Lookup[$src] }

            $rel = $cat
            if($projectKey){
                $rel = Join-Path (Join-Path $cat 'Projects') $projectKey
            } elseif($dateMode -eq 'Year'){
                $rel = Join-Path $cat ([datetime]$f.LastWriteTime).ToString('yyyy')
            } elseif($dateMode -eq 'YearMonth'){
                $rel = Join-Path $cat ([datetime]$f.LastWriteTime).ToString('yyyy-MM')
            }
            $dest = Join-Path (Join-Path $root $rel) $f.Name

            $dt = [datetime]$f.LastWriteTime
            $reasonParts = @("Category=$cat")
            if($projectKey){ $reasonParts += "Project=$projectKey" }
            else { $reasonParts += 'Date=' + $dt.ToString('yyyy-MM') }

            $actions.Add([pscustomobject]@{ Action='Move'; Source=$src; Destination=$dest; Reason=($reasonParts -join '; '); SizeBytes=$f.Length })
        } catch {
            $skipped.Add([pscustomobject]@{ Source=$f.FullName; Reason="Analysis error: $($_.Exception.Message)" })
        }
    }

    return [pscustomobject]@{
        PlanId          = $planId
        Created         = (Get-Date).ToString('s')
        Computer        = $env:COMPUTERNAME
        Drive           = "$Letter`:"
        DestinationRoot = $root
        Mode            = "Type-first; date subfolders=$dateMode; duplicates=$quarantinePolicy; projects=" + (Get-SysOrgSetting $Config 'ProjectDetection.Enabled' $true)
        Actions         = $actions.ToArray()
        Skipped         = $skipped.ToArray()
    }
}

function Save-SysOrgPlan {
<#
.SYNOPSIS
    Serializes a plan to <PlansFolder>\<PlanId>.json and returns the path.
.EXAMPLE
    $p = Save-SysOrgPlan -Plan $plan -PlansFolder C:\SysOrg\Plans
#>
    param($Plan,[string]$PlansFolder)
    if(-not (Test-Path -LiteralPath $PlansFolder)){ New-Item -ItemType Directory -Path $PlansFolder -Force | Out-Null }
    $path = Join-Path $PlansFolder ('{0}.json' -f $Plan.PlanId)
    $Plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Show-SysOrgPlan {
<#
.SYNOPSIS
    Prints a full plan preview: totals, reasons, duplicate quarantines, sample moves,
    affected top-level folders (P1-6 blast radius) and the long-path skip count (P2-5).
.EXAMPLE
    Show-SysOrgPlan -Plan $plan
#>
    param($Plan,[int]$SampleSize=20)
    Write-Host ''
    Write-Host ("PLAN {0}  (drive {1} -> {2})" -f $Plan.PlanId, $Plan.Drive, $Plan.DestinationRoot) -ForegroundColor White
    Write-Host ("Mode: {0}" -f $Plan.Mode)
    $moves = @($Plan.Actions | Where-Object { $_.Action -eq 'Move' })
    $quars = @($Plan.Actions | Where-Object { $_.Action -eq 'Quarantine' })
    $totalBytes = [int64](($moves | Measure-Object -Property SizeBytes -Sum).Sum)
    Write-Host ("Moves: {0} ({1})   Quarantines (duplicates): {2}   Skipped: {3}" -f $moves.Count, (Format-SysOrgFileSize $totalBytes), $quars.Count, @($Plan.Skipped).Count)
    $longPaths = @(@($Plan.Skipped) | Where-Object { $_.Reason -like 'Path >= 260*' })
    if($longPaths.Count -gt 0){
        Write-Host ("Paths >= 260 characters recorded but not planned (PowerShell 5.1 limit): {0}" -f $longPaths.Count) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Affected top-level folders:' -ForegroundColor White
    $Plan.Actions | Group-Object {
        $p = $_.Source.Split('\')
        $n = [Math]::Min(1, $p.Count - 1)
        if($p.Count -ge 3 -and $p[1] -ieq 'Users'){ $n = 2 }   # show the user folder, not just 'C:\Users'
        $p[0..$n] -join '\'
    } | Sort-Object Count -Descending | Select-Object -First 15 |
        ForEach-Object { Write-Host ('  {0}  ({1} files)' -f $_.Name, $_.Count) }
    Write-Host ''
    Write-Host 'Actions by reason:' -ForegroundColor White
    $Plan.Actions | Group-Object { $_.Reason.Split(';')[0] } | Sort-Object Count -Descending |
        Format-Table @{l='Reason';e={$_.Name}}, Count -AutoSize | Out-Host
    if($quars.Count -gt 0){
        Write-Host 'Duplicate quarantines (first 5):' -ForegroundColor White
        $quars | Select-Object -First 5 | ForEach-Object { Write-Host ('  ' + $_.Source) }
        if($quars.Count -gt 5){ Write-Host ('  ... and {0} more' -f ($quars.Count-5)) }
        Write-Host ''
    }
    Write-Host 'Sample moves:' -ForegroundColor White
    $moves | Select-Object -First $SampleSize | ForEach-Object {
        Write-Host ('  ' + $_.Source) -ForegroundColor DarkGray
        Write-Host ('    -> {0}   [{1}]' -f $_.Destination, $_.Reason) -ForegroundColor Gray
    }
    if($moves.Count -gt $SampleSize){ Write-Host ('  ... and {0} more moves' -f ($moves.Count - $SampleSize)) }
    Write-Host ''
}

function Invoke-SysOrgPlan {
<#
.SYNOPSIS
    Executes a saved plan; every completed action is appended to Undo\<PlanId>.csv
    immediately (P1-1), so a crash leaves a complete journal of what has been done.
.DESCRIPTION
    - Re-execution guard (P1-3): a plan with an existing undo journal is refused
      unless -Force is passed, in which case journaled sources are skipped (resume).
    - Hash economy (P2-1): same-volume Move actions are not hashed; cross-volume
      and quarantine actions are, using the scan-time hash when available.
    - Collision duplicates found at execution time are quarantined, never deleted.
    - 'CopiedVerified' results are counted as Copied, not Moved (P1-10).
.EXAMPLE
    $res = Invoke-SysOrgPlan -PlanPath .\Plans\plan.json -Config $cfg -AppRoot C:\SysOrg
.EXAMPLE
    Invoke-SysOrgPlan -PlanPath .\Plans\plan.json -Config $cfg -AppRoot C:\SysOrg -Force  # resume
#>
    param([Parameter(Mandatory)][string]$PlanPath,$Config,[Parameter(Mandatory)][string]$AppRoot,[switch]$Force)
    try { $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json }
    catch { throw "Plan file could not be read: $($_.Exception.Message)" }

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
        Import-Csv -LiteralPath $undoPath | ForEach-Object { $alreadyDone[$_.OriginalSource] = $true }
    }

    $summary = @{ Moved=0; Copied=0; Quarantined=0; CollisionDuplicate=0; Resumed=0; Failed=0; BytesMoved=[int64]0 }

    # P1-1: journal is appended and flushed after EVERY row, not written once at the end
    $journalExists = Test-Path -LiteralPath $undoPath
    $writer = New-Object System.IO.StreamWriter($undoPath, $true, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true

    try {
        if(-not $journalExists){
            $writer.WriteLine('Timestamp,PlanId,Action,OriginalSource,CurrentLocation,ContentHash')
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

            # P2-1: hash only when the journal needs it (quarantine or cross-volume);
            # reuse the scan-time hash for quarantines when present
            $needsHash = ($a.Action -eq 'Quarantine') -or
                         ((Split-Path $a.Source -Qualifier) -ine (Split-Path $a.Destination -Qualifier))
            $hashBefore = $null
            if($needsHash){
                if($a.PSObject.Properties['Hash'] -and $a.Hash){ $hashBefore = $a.Hash }
                else { $hashBefore = Get-SysOrgFileHash -Path $a.Source }
            }

            $result = Invoke-SysOrgSafeMove -Source $a.Source -Destination $a.Destination -Config $Config

            switch($result.Status){
                'Moved' {
                    if($a.Action -eq 'Quarantine'){
                        $summary.Quarantined++
                        Write-SysOrgLog "Quarantined duplicate: $($a.Source) -> $($result.Destination)" -Level ACTION -LogFolder $logFolder
                    } else {
                        $summary.Moved++
                        $summary.BytesMoved += [int64]$a.SizeBytes
                        Write-SysOrgLog "Moved: $($a.Source) -> $($result.Destination)" -Level ACTION -LogFolder $logFolder
                    }
                    $writer.WriteLine('"{0}","{1}","{2}","{3}","{4}","{5}"' -f (Get-Date -Format s), $plan.PlanId, $a.Action, $a.Source, $result.Destination, $hashBefore)
                }
                'CopiedVerified' {
                    $summary.Copied++
                    $writer.WriteLine('"{0}","{1}","{2}","{3}","{4}","{5}"' -f (Get-Date -Format s), $plan.PlanId, $a.Action, $a.Source, $result.Destination, $hashBefore)
                    Write-SysOrgLog "Copied+verified: $($a.Source) -> $($result.Destination) ($($result.Message))" -Level WARN -LogFolder $logFolder
                }
                'CollisionDuplicate' {
                    $summary.CollisionDuplicate++
                    $letter = (Split-Path $a.Source -Qualifier).TrimEnd(':')
                    $qRoot = Join-Path (Get-SysOrgDestinationRoot -Letter $letter -Config $Config) (Get-SysOrgSetting $Config 'Duplicates.QuarantineFolderName' '_Duplicates')
                    $qRoot = Join-Path $qRoot ('manual-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    $r2 = Invoke-SysOrgSafeMove -Source $a.Source -Destination (Join-Path $qRoot (Split-Path $a.Source -Leaf)) -Config $Config
                    if(($r2.Status -eq 'Moved') -or ($r2.Status -eq 'CopiedVerified')){
                        $summary.Quarantined++
                        $writer.WriteLine('"{0}","{1}","{2}","{3}","{4}","{5}"' -f (Get-Date -Format s), $plan.PlanId, 'Quarantine', $a.Source, $r2.Destination, $hashBefore)
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
    Write-SysOrgLog ("Plan {0} finished. Moved={1} Copied={2} Quarantined={3} Resumed={4} Failed={5}" -f $plan.PlanId, $summary.Moved, $summary.Copied, $summary.Quarantined, $summary.Resumed, $summary.Failed) -LogFolder $logFolder
    return [pscustomobject]@{ PlanId=$plan.PlanId; UndoFile=$undoPath; Summary=$summary }
}

function Undo-SysOrgPlan {
<#
.SYNOPSIS
    Reverses a plan using its undo journal, in reverse order. Never overwrites.
.DESCRIPTION
    Content verification (P1-4): rows carrying a ContentHash are re-hashed before
    restore; a file whose content changed since the move is skipped (SkippedChanged)
    so the undo never clobbers newer intent. Rows with an empty hash (same-volume
    moves after the P2-1 hash economy) fall back to path-only undo - a documented
    tradeoff. Restores into occupied slots get unique ' (2)' suffixed paths.
.EXAMPLE
    Undo-SysOrgPlan -PlanId plan-20260101-093000 -AppRoot C:\SysOrg -Config $cfg
#>
    param([Parameter(Mandatory)][string]$PlanId,[Parameter(Mandatory)][string]$AppRoot,$Config)
    $undoPath = Join-Path (Join-Path $AppRoot 'Undo') ('undo-{0}.csv' -f $PlanId)
    if(-not (Test-Path -LiteralPath $undoPath)){ throw "No undo journal found for plan '$PlanId'." }
    $logFolder = Join-Path $AppRoot 'Logs'
    $rows = @(Import-Csv -LiteralPath $undoPath)
    $restored=0; $failed=0; $skippedMissing=0; $skippedChanged=0

    for($i=$rows.Count-1; $i -ge 0; $i--){
        $row = $rows[$i]
        $current  = $row.CurrentLocation
        $original = $row.OriginalSource
        if(-not (Test-Path -LiteralPath $current)){ $skippedMissing++; Write-SysOrgLog "Undo skip (missing): $current" -Level WARN -LogFolder $logFolder; continue }
        # P1-4: verify content has not changed since the move
        if($row.ContentHash){
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
        $r = Invoke-SysOrgSafeMove -Source $current -Destination $dest -Config $Config
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
    $inv = Get-SysOrgInventory -Letter $Letter -Config $Config -CacheFolder (Join-Path $AppRoot 'Cache') -DefaultScope -NoCache
    $catCounts = $inv | Group-Object Category | Sort-Object Count -Descending
    $dupGroups = Find-SysOrgDuplicates -Inventory $inv -Config $Config
    $clusters  = Get-SysOrgProjectClusters -Inventory $inv -Config $Config

    $reportsFolder = Join-Path (Get-SysOrgDestinationRoot -Letter $Letter -Config $Config) (Get-SysOrgSetting $Config 'ReportsFolderName' '_Reports')
    if(-not (Test-Path -LiteralPath $reportsFolder)){ New-Item -ItemType Directory -Path $reportsFolder -Force | Out-Null }
    $file = Join-Path $reportsFolder ('SysOrg-ScanReport-{0}-{1}.txt' -f $Letter, (Get-Date -Format 'yyyyMMdd-HHmm'))

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("SysOrg scan report - drive $Letter`: - $(Get-Date)")
    $lines.Add("Files scanned: $($inv.Count)   (REPORT ONLY - nothing was moved)")
    $longPaths = @($inv | Where-Object { $_.Category -eq 'SkippedLongPath' })
    if($longPaths.Count -gt 0){ $lines.Add("Paths >= 260 characters recorded but not planned: $($longPaths.Count)") }
    $lines.Add('')
    $lines.Add('By category:')
    foreach($c in $catCounts){ $lines.Add(('  {0,-15} {1}' -f $c.Name, $c.Count)) }
    $lines.Add('')
    $lines.Add("Duplicate groups: $(@($dupGroups).Count)")
    foreach($dg in (@($dupGroups) | Select-Object -First 20)){
        $lines.Add(('  Keep: ' + $dg.KeepPath))
        foreach($d in $dg.Duplicates){ $lines.Add(('    dup: ' + $d)) }
    }
    $lines.Add('')
    $lines.Add("Detected project clusters: $(@($clusters.Clusters).Count)")
    foreach($cl in (@($clusters.Clusters) | Select-Object -First 20)){
        $lines.Add(('  {0}  ({1} files, {2})' -f $cl.Key, $cl.FileCount, $cl.Basis))
    }
    $lines | Set-Content -LiteralPath $file -Encoding UTF8
    Write-SysOrgLog "Report written: $file" -LogFolder $logFolder
    return $file
}

Export-ModuleMember -Function *-SysOrg*
