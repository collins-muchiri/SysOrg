#Requires -Version 5.1
# SysOrg.Plan.psm1 - plan generation, preview, execution with undo journal, undo, reports.

function New-SysOrgPlan {
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
            if(Test-SysOrgDestinationPath -Path $src -Config $Config){ continue }

            if($dupSet.ContainsKey($src)){
                if($quarantinePolicy -eq 'Quarantine'){
                    $h = $dupSet[$src]
                    $hash8 = if($h -and ($h.Length -ge 8)){ $h.Substring(0,8) } else { 'dup' }
                    $qName = '{0}_{1}{2}' -f $f.Stem, $hash8, $f.Extension
                    $dest  = Join-Path (Join-Path $root $qFolder) (Join-Path $planId $qName)
                    $actions.Add([pscustomobject]@{ Action='Quarantine'; Source=$src; Destination=$dest; Reason='Exact duplicate (keeper identified during scan)'; SizeBytes=$f.Length })
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
        Actions         = $actions
        Skipped         = $skipped
    }
}

function Save-SysOrgPlan {
    param($Plan,[string]$PlansFolder)
    if(-not (Test-Path -LiteralPath $PlansFolder)){ New-Item -ItemType Directory -Path $PlansFolder -Force | Out-Null }
    $path = Join-Path $PlansFolder ('{0}.json' -f $Plan.PlanId)
    $Plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Show-SysOrgPlan {
    param($Plan,[int]$SampleSize=20)
    Write-Host ''
    Write-Host ("PLAN {0}  (drive {1} -> {2})" -f $Plan.PlanId, $Plan.Drive, $Plan.DestinationRoot) -ForegroundColor White
    Write-Host ("Mode: {0}" -f $Plan.Mode)
    $moves = @($Plan.Actions | Where-Object { $_.Action -eq 'Move' })
    $quars = @($Plan.Actions | Where-Object { $_.Action -eq 'Quarantine' })
    $totalBytes = [int64]($moves | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host ("Moves: {0} ({1})   Quarantines (duplicates): {2}   Skipped: {3}" -f $moves.Count, (Format-SysOrgFileSize $totalBytes), $quars.Count, @($Plan.Skipped).Count)
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
    <# Executes a saved plan. Every completed action is appended to Undo\<planId>.csv.
       Collision duplicates found at execution time are quarantined, never deleted. #>
    param([Parameter(Mandatory)][string]$PlanPath,$Config,[Parameter(Mandatory)][string]$AppRoot)
    try { $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json }
    catch { throw "Plan file could not be read: $($_.Exception.Message)" }

    $logFolder  = Join-Path $AppRoot 'Logs'
    $undoFolder = Join-Path $AppRoot 'Undo'
    if(-not (Test-Path -LiteralPath $undoFolder)){ New-Item -ItemType Directory -Path $undoFolder -Force | Out-Null }
    $undoPath = Join-Path $undoFolder ('undo-{0}.csv' -f $plan.PlanId)

    $summary = @{ Moved=0; Quarantined=0; CollisionDuplicate=0; Failed=0; BytesMoved=[int64]0 }
    $undoRows = New-Object System.Collections.Generic.List[string]
    $undoRows.Add('Timestamp,PlanId,Action,OriginalSource,CurrentLocation,ContentHash')

    $allActions = @($plan.Actions)
    $i = 0; $total = $allActions.Count

    foreach($a in $allActions){
        $i++
        Write-Progress -Activity 'Executing plan' -Status "$i / $total : $(Split-Path $a.Source -Leaf)" -PercentComplete ([int](100*$i/[math]::Max($total,1)))
        $hashBefore = Get-SysOrgFileHash -Path $a.Source
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
                $undoRows.Add('"{0}","{1}","{2}","{3}","{4}","{5}"' -f (Get-Date -Format s), $plan.PlanId, $a.Action, $a.Source, $result.Destination, $hashBefore)
            }
            'CopiedVerified' {
                $summary.Moved++
                $undoRows.Add('"{0}","{1}","{2}","{3}","{4}","{5}"' -f (Get-Date -Format s), $plan.PlanId, $a.Action, $a.Source, $result.Destination, $hashBefore)
                Write-SysOrgLog "Copied+verified (source locked, kept): $($a.Source) -> $($result.Destination)" -Level WARN -LogFolder $logFolder
            }
            'CollisionDuplicate' {
                $summary.CollisionDuplicate++
                $letter = (Split-Path $a.Source -Qualifier).TrimEnd(':')
                $qRoot = Join-Path (Get-SysOrgDestinationRoot -Letter $letter -Config $Config) (Get-SysOrgSetting $Config 'Duplicates.QuarantineFolderName' '_Duplicates')
                $qRoot = Join-Path $qRoot ('manual-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $r2 = Invoke-SysOrgSafeMove -Source $a.Source -Destination (Join-Path $qRoot (Split-Path $a.Source -Leaf)) -Config $Config
                if(($r2.Status -eq 'Moved') -or ($r2.Status -eq 'CopiedVerified')){
                    $summary.Quarantined++
                    $undoRows.Add('"{0}","{1}","{2}","{3}","{4}","{5}"' -f (Get-Date -Format s), $plan.PlanId, 'Quarantine', $a.Source, $r2.Destination, $hashBefore)
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
    Set-Content -LiteralPath $undoPath -Value $undoRows -Encoding UTF8
    Write-Progress -Activity 'Executing plan' -Completed
    Write-SysOrgLog ("Plan {0} finished. Moved={1} Quarantined={2} Failed={3}" -f $plan.PlanId, $summary.Moved, $summary.Quarantined, $summary.Failed) -LogFolder $logFolder
    return [pscustomobject]@{ PlanId=$plan.PlanId; UndoFile=$undoPath; Summary=$summary }
}

function Undo-SysOrgPlan {
    <# Reverses a plan using its undo journal, in reverse order. Never overwrites:
       if the original slot is occupied again, the file is restored alongside with a suffix. #>
    param([Parameter(Mandatory)][string]$PlanId,[Parameter(Mandatory)][string]$AppRoot,$Config)
    $undoPath = Join-Path (Join-Path $AppRoot 'Undo') ('undo-{0}.csv' -f $PlanId)
    if(-not (Test-Path -LiteralPath $undoPath)){ throw "No undo journal found for plan '$PlanId'." }
    $logFolder = Join-Path $AppRoot 'Logs'
    $rows = @(Import-Csv -LiteralPath $undoPath)
    $restored=0; $failed=0; $skipped=0

    for($i=$rows.Count-1; $i -ge 0; $i--){
        $row = $rows[$i]
        $current  = $row.CurrentLocation
        $original = $row.OriginalSource
        if(-not (Test-Path -LiteralPath $current)){ $skipped++; Write-SysOrgLog "Undo skip (missing): $current" -Level WARN -LogFolder $logFolder; continue }
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
    return [pscustomobject]@{ Restored=$restored; Failed=$failed; SkippedMissing=$skipped }
}

function New-SysOrgScanReport {
    <# Report-only scan used by the weekly scheduled task. Writes text; moves nothing. #>
    param([Parameter(Mandatory)][string]$Letter,$Config,[Parameter(Mandatory)][string]$AppRoot)
    $logFolder = Join-Path $AppRoot 'Logs'
    Write-SysOrgLog "Scheduled report scan starting for drive $Letter`:" -LogFolder $logFolder
    $inv = Get-SysOrgInventory -Letter $Letter -Config $Config -CacheFolder (Join-Path $AppRoot 'Cache')
    $catCounts = $inv | Group-Object Category | Sort-Object Count -Descending
    $dupGroups = Find-SysOrgDuplicates -Inventory $inv -Config $Config
    $clusters  = Get-SysOrgProjectClusters -Inventory $inv -Config $Config

    $reportsFolder = Join-Path (Get-SysOrgDestinationRoot -Letter $Letter -Config $Config) (Get-SysOrgSetting $Config 'ReportsFolderName' '_Reports')
    if(-not (Test-Path -LiteralPath $reportsFolder)){ New-Item -ItemType Directory -Path $reportsFolder -Force | Out-Null }
    $file = Join-Path $reportsFolder ('SysOrg-ScanReport-{0}-{1}.txt' -f $Letter, (Get-Date -Format 'yyyyMMdd-HHmm'))

    $lines = @()
    $lines += "SysOrg scan report - drive $Letter`: - $(Get-Date)"
    $lines += "Files scanned: $($inv.Count)   (REPORT ONLY - nothing was moved)"
    $lines += ''
    $lines += 'By category:'
    foreach($c in $catCounts){ $lines += ('  {0,-15} {1}' -f $c.Name, $c.Count) }
    $lines += ''
    $lines += "Duplicate groups: $(@($dupGroups).Count)"
    foreach($dg in (@($dupGroups) | Select-Object -First 20)){
        $lines += ('  Keep: ' + $dg.KeepPath)
        foreach($d in $dg.Duplicates){ $lines += ('    dup: ' + $d) }
    }
    $lines += ''
    $lines += "Detected project clusters: $(@($clusters.Clusters).Count)"
    foreach($cl in (@($clusters.Clusters) | Select-Object -First 20)){
        $lines += ('  {0}  ({1} files, {2})' -f $cl.Key, $cl.FileCount, $cl.Basis)
    }
    $lines | Set-Content -LiteralPath $file -Encoding UTF8
    Write-SysOrgLog "Report written: $file" -LogFolder $logFolder
    return $file
}

Export-ModuleMember -Function *-SysOrg*
