#Requires -Version 5.1
# SysOrg.Scan.psm1 - inventory, classification, project clusters, duplicate detection.

$script:CategoryMap = @{
    Documents     = @('.pdf','.doc','.docx','.txt','.rtf','.odt','.md','.xps','.djvu','.epub','.chm')
    Spreadsheets  = @('.xls','.xlsx','.csv','.ods','.tsv')
    Presentations = @('.ppt','.pptx','.odp','.key')
    Images        = @('.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp','.svg','.heic','.raw','.cr2','.nef','.arw','.dng','.psd','.ai','.xcf','.ico')
    Videos        = @('.mp4','.mkv','.avi','.mov','.wmv','.flv','.webm','.m4v','.mpg','.mpeg','.3gp','.ts')
    Audio         = @('.mp3','.wav','.flac','.aac','.ogg','.m4a','.wma','.mid','.opus')
    Archives      = @('.zip','.rar','.7z','.tar','.gz','.bz2','.xz','.iso','.cab')
    Code          = @('.py','.js','.ts','.html','.css','.java','.c','.cpp','.cs','.go','.rs','.php','.rb','.sh','.ps1','.psm1','.bat','.cmd','.sql','.json','.xml','.yml','.yaml','.ini','.toml')
    Installers    = @('.exe','.msi','.msix','.appx','.apk')
    Fonts         = @('.ttf','.otf','.woff','.woff2','.fon')
    Databases     = @('.db','.sqlite','.mdb','.accdb','.bak')
}
$script:ExtToCategory = @{}
foreach($cat in $script:CategoryMap.Keys){
    foreach($e in $script:CategoryMap[$cat]){ $script:ExtToCategory[$e] = $cat }
}

function Get-SysOrgCategory {
    param([string]$Extension,$Config)
    $ext = $Extension.ToLowerInvariant()
    $overrides = Get-SysOrgSetting $Config 'Categories' $null
    if($overrides -is [hashtable] -and $overrides.ContainsKey($ext)){ return $overrides[$ext] }
    if($script:ExtToCategory.ContainsKey($ext)){ return $script:ExtToCategory[$ext] }
    return 'Other'
}

function Get-SysOrgInventory {
    <#
      Recursive file inventory. Skips excluded paths/files, hidden+system files,
      and reparse points (junctions/symlinks) to avoid loops and OneDrive churn.
      Caches to JSON for 24 h to make rescans fast.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Letter,
        $Config,
        [string]$CacheFolder,
        [switch]$NoCache,
        [string[]]$CfaFolders,
        [System.Collections.Generic.List[object]]$AuditTrail
    )
    $root = ('{0}:\' -f $Letter)
    if(-not (Test-Path -LiteralPath $root)){ throw "Drive $root not found." }
    if(-not $cfaFolders){ $cfaFolders = Get-SysOrgDefenderProtectedFolders -Config $Config }

    if($CacheFolder -and -not $NoCache){
        $cacheFile = Join-Path $CacheFolder ("inventory-{0}.json" -f $Letter)
        if(Test-Path -LiteralPath $cacheFile){
            $ageHours = ((Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime).TotalHours
            $maxAge = Get-SysOrgSetting $Config 'InventoryCacheHours' 24
            if($ageHours -lt $maxAge){
                Write-Host ("Using cached inventory ({0}; use -NoCache to force rescan)." -f (Get-Item -LiteralPath $cacheFile).LastWriteTime)
                return ,@((Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json))
            }
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    [void]$stack.Push($root)
    $count = 0

    while($stack.Count -gt 0){
        $dir = [string]$stack.Pop()
        if(Test-SysOrgExcludedPath -Path $dir -Config $Config){ continue }
        if((Get-SysOrgSetting $Config 'ExcludeDestinations' $true) -and (Test-SysOrgDestinationPath -Path $dir -Config $Config)){ continue }

        # v1.1 folder safety gates: protected (cannot alter) vs restricted (read-only) vs organizable
        if((Get-SysOrgSetting $Config 'FolderAudit.Enabled' $true) -and ($dir -ine $root)){
            $protectReason = Get-SysOrgFolderProtectionReason -Path $dir -Config $Config -CfaFolders $cfaFolders
            if($protectReason){
                if($AuditTrail){ [void]$AuditTrail.Add([pscustomobject]@{ Path=$dir; Status='Protected'; Reason=$protectReason }) }
                continue
            }
            $acc = Test-SysOrgDirAccess -Path $dir
            if(-not $acc.Readable){
                if($AuditTrail){ [void]$AuditTrail.Add([pscustomobject]@{ Path=$dir; Status='Protected'; Reason=('Access denied reading folder (error {0})' -f $acc.ReadError) }) }
                continue
            }
            if((-not $acc.Writable) -and (-not (Get-SysOrgSetting $Config 'FolderAudit.IncludeRestrictedInPlans' $false))){
                if($AuditTrail){ [void]$AuditTrail.Add([pscustomobject]@{ Path=$dir; Status='Restricted'; Reason='No write permission - folder left in place' }) }
                continue
            }
        }

        $subDirs = @(); $files = @()
        try{
            $di = New-Object System.IO.DirectoryInfo($dir)
            if(($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint){ continue }
            try { $subDirs = $di.GetDirectories() } catch { }
            try { $files   = $di.GetFiles() } catch { }
        } catch { continue }

        foreach($d in $subDirs){ [void]$stack.Push($d.FullName) }

        foreach($fi in $files){
            try{
                if(Test-SysOrgExcludedFile -Path $fi.FullName -Config $Config){ continue }
                if(Get-SysOrgSetting $Config 'SkipHiddenSystemFiles' $true){
                    $a = $fi.Attributes
                    if((($a -band [System.IO.FileAttributes]::Hidden) -eq [System.IO.FileAttributes]::Hidden) -or
                       (($a -band [System.IO.FileAttributes]::System)  -eq [System.IO.FileAttributes]::System)){ continue }
                }
                $ext = $fi.Extension.ToLowerInvariant()
                $records.Add([pscustomobject]@{
                    FullName      = $fi.FullName
                    Name          = $fi.Name
                    Stem          = $fi.BaseName
                    Extension     = $ext
                    Length        = [int64]$fi.Length
                    LastWriteTime = $fi.LastWriteTime
                    Directory     = $fi.DirectoryName
                    Category      = Get-SysOrgCategory -Extension $ext -Config $Config
                })
                $count++
                if($count % 200 -eq 0){ Write-Progress -Activity "Scanning $root" -Status "$count files (in: $dir)" }
            } catch { }
        }
    }
    Write-Progress -Activity "Scanning $root" -Completed
    $arr = $records.ToArray()

    if($CacheFolder){
        try{
            if(-not (Test-Path -LiteralPath $CacheFolder)){ New-Item -ItemType Directory -Path $CacheFolder -Force | Out-Null }
            $arr | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $CacheFolder ("inventory-{0}.json" -f $Letter)) -Encoding UTF8
        } catch { Write-Warning "Inventory cache could not be written: $($_.Exception.Message)" }
    }
    return ,$arr
}

function Get-SysOrgOrganizedDirSet {
    <# Folders that already look organized: >= MinFiles, >= ratio single category,
       and not a folder users routinely dump files into. Their subtrees are preserved. #>
    param($Inventory,$Config)
    $set = @{}
    if(-not (Get-SysOrgSetting $Config 'PreserveExistingFolders' $true)){ return ,$set }
    $min   = Get-SysOrgSetting $Config 'PreserveMinFiles' 5
    $ratio = Get-SysOrgSetting $Config 'PreserveSingleCategoryRatio' 0.9
    $always = @(Get-SysOrgSetting $Config 'AlwaysScanFolders' @())

    $stats = @{}
    foreach($f in $Inventory){
        $d = $f.Directory.ToLowerInvariant()
        if(-not $stats.ContainsKey($d)){ $stats[$d] = @{ Total=0; Cats=@{} } }
        $s = $stats[$d]; $s.Total++
        $c = $f.Category
        if(-not $s.Cats.ContainsKey($c)){ $s.Cats[$c]=0 }
        $s.Cats[$c]++
    }
    foreach($d in $stats.Keys){
        if($always -contains (Split-Path $d -Leaf).ToLowerInvariant()){ continue }
        $s = $stats[$d]
        if($s.Total -lt $min){ continue }
        $top = $s.Cats.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        if($top -and (($top.Value / $s.Total) -ge $ratio)){ $set[$d] = $true }
    }
    return ,$set
}

function Test-SysOrgInOrganizedDir {
    param([string]$Directory,$OrganizedSet)
    $cur = $Directory.TrimEnd('\')
    while($cur -and ($cur.Length -gt 3)){
        if($OrganizedSet.ContainsKey($cur.ToLowerInvariant())){ return $true }
        $cur = Split-Path $cur -Parent
    }
    return $false
}

function Get-SysOrgProjectClusters {
    <# Conservative relationship detection:
       1) same filename stem across >= 2 file types (e.g. Report.docx + Report.pdf)
       2) shared distinctive name tokens (stopwords/numbers filtered)
       Returns pscustomobject { Lookup (FullName->Key hashtable), Clusters (array) }. #>
    param($Inventory,$Config)
    $lookup = @{}; $clusters = @()
    if(-not (Get-SysOrgSetting $Config 'ProjectDetection.Enabled' $true)){
        return [pscustomobject]@{ Lookup=$lookup; Clusters=$clusters }
    }
    $minFiles    = Get-SysOrgSetting $Config 'ProjectDetection.MinFiles' 3
    $maxProjects = Get-SysOrgSetting $Config 'ProjectDetection.MaxProjects' 200
    $stop = @('copy','copies','final','new','old','backup','bak','untitled','scan','img','image','photo','video','audio','temp','tmp','draft','export','download','downloads','doc','document','file','output','out','test','sample','misc','edit','edited','version','the','and','for')

    $assigned = New-Object System.Collections.Generic.HashSet[string]
    $projectIndex = 0

    # 1) same stem, multiple extensions
    $byStem = @{}
    foreach($f in $Inventory){
        $stem = $f.Stem.ToLowerInvariant()
        if($stem.Length -lt 3){ continue }
        if(-not $byStem.ContainsKey($stem)){ $byStem[$stem] = New-Object System.Collections.Generic.List[object] }
        [void]$byStem[$stem].Add($f)
    }
    foreach($kv in $byStem.GetEnumerator()){
        $files = @($kv.Value | Where-Object { -not $assigned.Contains($_.FullName) })
        $exts  = @($files | ForEach-Object { $_.Extension } | Sort-Object -Unique)
        if(($files.Count -ge $minFiles) -and ($exts.Count -ge 2)){
            $projectIndex++
            if($projectIndex -gt $maxProjects){ break }
            $key = 'Project-{0:00}-{1}' -f $projectIndex, ($kv.Key -replace '[^a-z0-9]+','-')
            foreach($f in $files){ $lookup[$f.FullName] = $key; [void]$assigned.Add($f.FullName) }
            $clusters += [pscustomobject]@{ Key=$key; FileCount=$files.Count; Basis='Same filename stem across file types'; Sample=$files[0].Name }
        }
    }

    # 2) shared distinctive tokens
    $byTokens = @{}
    foreach($f in $Inventory){
        if($assigned.Contains($f.FullName)){ continue }
        $tokens = @(($f.Stem.ToLowerInvariant() -split '[^a-z0-9]+') | Where-Object { $_.Length -ge 4 -and ($stop -notcontains $_) -and ($_ -notmatch '^\d+$') })
        if($tokens.Count -lt 2){ continue }
        $sig = (@($tokens | Select-Object -First 3) | Sort-Object) -join '+'
        if(-not $byTokens.ContainsKey($sig)){ $byTokens[$sig] = New-Object System.Collections.Generic.List[object] }
        [void]$byTokens[$sig].Add($f)
    }
    foreach($kv in $byTokens.GetEnumerator()){
        $files = @($kv.Value | Where-Object { -not $assigned.Contains($_.FullName) })
        if($files.Count -ge $minFiles){
            $projectIndex++
            if($projectIndex -gt $maxProjects){ break }
            $key = 'Project-{0:00}-{1}' -f $projectIndex, ($kv.Key -replace '[^a-z0-9+]+','-')
            foreach($f in $files){ $lookup[$f.FullName] = $key; [void]$assigned.Add($f.FullName) }
            $clusters += [pscustomobject]@{ Key=$key; FileCount=$files.Count; Basis='Shared distinctive name tokens'; Sample=$files[0].Name }
        }
    }
    return [pscustomobject]@{ Lookup=$lookup; Clusters=$clusters }
}

function Find-SysOrgDuplicates {
    <# Exact duplicates only: group by size -> 64 KB header hash -> full SHA256.
       Keeper = outside temp-like folders, shortest path, oldest write time. #>
    param($Inventory,$Config)
    $groups = @()
    $minKB    = Get-SysOrgSetting $Config 'Duplicates.MinFileSizeKB' 256
    $headerKB = Get-SysOrgSetting $Config 'Duplicates.HeaderHashKB' 64
    $minBytes = [int64]$minKB * 1KB
    $tempLike = @('\downloads\','\desktop\','\temp\','\tmp\')

    $sizeCandidates = @($Inventory | Where-Object { $_.Length -ge $minBytes } | Group-Object -Property Length | Where-Object { $_.Count -gt 1 })
    $total = $sizeCandidates.Count; $done = 0

    foreach($sizeGroup in $sizeCandidates){
        $done++
        Write-Progress -Activity 'Duplicate detection' -Status "Size group $($sizeGroup.Name) bytes ($done of $total)" -PercentComplete ([int](100*$done/[math]::Max($total,1)))
        $headerMap = @{}
        foreach($f in $sizeGroup.Group){
            $h = Get-SysOrgFileHash -Path $f.FullName -HeaderOnly -HeaderKB $headerKB
            if($h){
                if(-not $headerMap.ContainsKey($h)){ $headerMap[$h] = New-Object System.Collections.Generic.List[object] }
                [void]$headerMap[$h].Add($f)
            }
        }
        foreach($h in $headerMap.Keys){
            $candidates = $headerMap[$h]
            if($candidates.Count -lt 2){ continue }
            $fullMap = @{}
            foreach($f in $candidates){
                $fh = Get-SysOrgFileHash -Path $f.FullName
                if($fh){
                    if(-not $fullMap.ContainsKey($fh)){ $fullMap[$fh] = New-Object System.Collections.Generic.List[object] }
                    [void]$fullMap[$fh].Add($f)
                }
            }
            foreach($fh in $fullMap.Keys){
                $dupes = $fullMap[$fh]
                if($dupes.Count -lt 2){ continue }
                $sorted = @($dupes | Sort-Object -Property `
                    @{e={ $n=$_.FullName.ToLowerInvariant(); $inTemp=$false; foreach($t in $tempLike){ if($n.Contains($t)){ $inTemp=$true; break } }; if($inTemp){1}else{0} }},
                    @{e={$_.FullName.Length}},
                    @{e={$_.LastWriteTime}})
                $keep   = $sorted[0]
                $others = @($sorted | Select-Object -Skip 1)
                $wasted = [int64]($others | Measure-Object -Property Length -Sum).Sum
                $groups += [pscustomobject]@{
                    Hash=$fh; KeepPath=$keep.FullName
                    KeepReason='Outside temp-like folders, shortest path, oldest first'
                    Duplicates=@($others | ForEach-Object { $_.FullName })
                    WastedBytes=$wasted
                }
            }
        }
    }
    Write-Progress -Activity 'Duplicate detection' -Completed
    return ,$groups
}

Export-ModuleMember -Function *-SysOrg*
