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
<#
.SYNOPSIS
    Maps a file extension to a category name; user Categories overrides win.
.EXAMPLE
    Get-SysOrgCategory -Extension '.pdf' -Config $cfg   # -> 'Documents'
#>
    param([string]$Extension,$Config)
    $ext = $Extension.ToLowerInvariant()
    $overrides = Get-SysOrgSetting $Config 'Categories' $null
    if($overrides -is [hashtable] -and $overrides.ContainsKey($ext)){ return $overrides[$ext] }
    if($script:ExtToCategory.ContainsKey($ext)){ return $script:ExtToCategory[$ext] }
    return 'Other'
}

function Test-SysOrgCloudPlaceholderAttributes {
<#
.SYNOPSIS
    True when raw file attributes mark a cloud placeholder (OneDrive files-on-demand).
.DESCRIPTION
    Checks Offline (0x1000) and RecallOnDataAccess (0x400000) on the raw integer so
    it behaves identically on Windows PowerShell 5.1 and PowerShell 7 - the
    .NET Framework FileAttributes enum has no RecallOnDataAccess member, and
    casting the value would throw. Hashing or opening such a file would silently
    hydrate the whole cloud library, so the scanner must skip it.
.EXAMPLE
    Test-SysOrgCloudPlaceholderAttributes -Attributes 0x400020   # -> True
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Attributes)
    return ((($Attributes -band 0x1000) -ne 0) -or (($Attributes -band 0x400000) -ne 0))
}

function Get-SysOrgInventory {
<#
.SYNOPSIS
    Recursive file inventory with exclusions, folder safety gates, cloud-placeholder
    skip, long-path recording and a config-keyed JSON cache.
.DESCRIPTION
    Default start point is the drive root. With -DefaultScope, the ScanRoots config
    narrows the scan to existing profile folders (e.g. Desktop, Documents, Downloads,
    Pictures, Videos, Music) on the scanned drive - a drive with none of them yields
    zero records instead of scanning everything. -Roots forces explicit start folders
    (used by tests and power users). Cloud placeholders (OneDrive files-on-demand:
    Offline / RecallOnDataAccess) are never opened, so scanning cannot hydrate them.
    Files at or above 260 characters of path are recorded with Category
    'SkippedLongPath' (Windows PowerShell 5.1 cannot reliably address them; PowerShell
    7 with LongPathsEnabled lifts this).
.PARAMETER Letter
    Drive letter whose root is scanned (also keys the cache file).
.PARAMETER DefaultScope
    Resolve the ScanRoots config entry for this drive instead of the whole drive.
.PARAMETER Roots
    Explicit absolute start folders; overrides the drive root and -DefaultScope.
.PARAMETER NoCache
    Ignore and refresh the JSON inventory cache.
.PARAMETER CacheFolder
    Folder for the cache file; omitted = no caching.
.PARAMETER CfaFolders
    Defender Controlled Folder Access folders (auto-detected when omitted).
.PARAMETER AuditTrail
    Optional list receiving Protected/Restricted folder classification entries.
.EXAMPLE
    Get-SysOrgInventory -Letter C -Config $cfg -CacheFolder C:\SysOrg\Cache -DefaultScope
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Letter,
        $Config,
        [string]$CacheFolder,
        [switch]$NoCache,
        [switch]$DefaultScope,
        [string[]]$Roots,
        [string[]]$CfaFolders,
        [System.Collections.Generic.List[object]]$AuditTrail
    )
    $root = ('{0}:\' -f $Letter)
    if(-not ($Roots -and @($Roots).Count -gt 0)){
        if(-not (Test-Path -LiteralPath $root)){ throw "Drive $root not found." }
    }
    if(-not $cfaFolders){ $cfaFolders = Get-SysOrgDefenderProtectedFolders -Config $Config }

    # --- P1-6: resolve scan roots ---
    $initial = @()
    $scope = 'full'
    if($Roots -and @($Roots).Count -gt 0){
        $scope = 'custom'
        $initial = @($Roots | Where-Object { Test-Path -LiteralPath $_ })
    }
    elseif($DefaultScope){
        $subs = $null
        $rootsCfg = $Config.ScanRoots
        if($rootsCfg -is [hashtable]){
            if($rootsCfg.ContainsKey($Letter)){ $subs = $rootsCfg[$Letter] }
            elseif($rootsCfg.ContainsKey('*')){ $subs = $rootsCfg['*'] }
        }
        if($subs){
            $resolved = New-Object System.Collections.Generic.HashSet[string]
            foreach($sub in @($subs)){
                if([string]::IsNullOrWhiteSpace($sub)){ continue }
                $driveRel = ('{0}:\{1}' -f $Letter, ($sub.TrimStart('\')))
                if(Test-Path -LiteralPath $driveRel){ [void]$resolved.Add($driveRel) }
                $prof = Join-Path $env:USERPROFILE $sub
                if((Split-Path $prof -Qualifier) -ieq ('{0}:' -f $Letter)){
                    if(Test-Path -LiteralPath $prof){ [void]$resolved.Add($prof) }
                }
            }
            if($resolved.Count -gt 0){ $initial = @($resolved); $scope = 'scoped' }
        }
    }
    else { $initial = @($root) }

    if(@($initial).Count -eq 0){
        Write-Warning ("No ScanRoots folders found on drive {0}:. Use -FullDrive to scan the whole drive, or edit ScanRoots in SysOrg.config.psd1." -f $Letter)
        return @()   # streams nothing; callers collect with @() and get an empty array
    }
    Write-Host ("Scan scope ({0}): {1}" -f $scope, ($initial -join '; '))

    # --- P1-9: cache key includes scope tag + SHA256 prefix of the config file ---
    $cfgTag = ''
    try{
        $appRootForCfg = Get-SysOrgSetting $Config 'AppRoot' ''
        if($appRootForCfg){
            $cfgPath = Join-Path $appRootForCfg 'SysOrg.config.psd1'
            if(Test-Path -LiteralPath $cfgPath){
                $cfgTag = '-' + (Get-FileHash -LiteralPath $cfgPath -Algorithm SHA256).Hash.Substring(0,8)
            }
        }
    } catch { Write-Verbose "Config-hash cache tag unavailable: $($_.Exception.Message)" }

    $cacheFile = $null
    if($CacheFolder){
        $cacheFile = Join-Path $CacheFolder ('inventory-{0}-{1}{2}.json' -f $Letter, $scope, $cfgTag)
        if(-not $NoCache){
            if(Test-Path -LiteralPath $cacheFile){
                $ageHours = ((Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime).TotalHours
                $maxAge = Get-SysOrgSetting $Config 'InventoryCacheHours' 24
                if($ageHours -lt $maxAge){
                    Write-Host ("Using cached inventory ({0}; pass -NoCache to force a rescan)." -f (Get-Item -LiteralPath $cacheFile).LastWriteTime)
                    return @((Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json))
                }
            }
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    foreach($startDir in $initial){ [void]$stack.Push([string]$startDir) }
    $count = 0

    while($stack.Count -gt 0){
        $dir = [string]$stack.Pop()

        # P1-8: a .sysorg-ignore marker excludes the WHOLE tree, not just the marker itself
        if(Test-Path -LiteralPath (Join-Path $dir '.sysorg-ignore')){
            Write-Verbose "Marker .sysorg-ignore found; skipping tree: $dir"
            continue
        }
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
            try { $subDirs = $di.GetDirectories() } catch { Write-Verbose "Directory enumeration failed: $dir - $($_.Exception.Message)" }
            try { $files   = $di.GetFiles() } catch { Write-Verbose "File enumeration failed: $dir - $($_.Exception.Message)" }
        } catch { Write-Verbose "Folder skipped: $dir - $($_.Exception.Message)"; continue }

        foreach($d in $subDirs){ [void]$stack.Push($d.FullName) }

        foreach($fi in $files){
            try{
                if(Test-SysOrgExcludedFile -Path $fi.FullName -Config $Config){ continue }
                # Attribute flags are compared as raw ints: on Windows PowerShell 5.1
                # casting an int like 0x400020 to [System.IO.FileAttributes] throws
                # (that value is not defined in the .NET Framework enum).
                # 0x1 ReadOnly | 0x2 Hidden | 0x4 System | 0x400 ReparsePoint | 0x1000 Offline | 0x400000 RecallOnDataAccess
                $aInt = [int]$fi.Attributes
                if(Get-SysOrgSetting $Config 'SkipHiddenSystemFiles' $true){
                    if((($aInt -band 0x2) -ne 0) -or (($aInt -band 0x4) -ne 0)){ continue }
                }
                # P1-5: cloud placeholders - Offline (0x1000) and RecallOnDataAccess (0x400000).
                # Hashing or opening these files would silently hydrate the whole cloud library.
                if(Test-SysOrgCloudPlaceholderAttributes -Attributes $aInt){ continue }
                # P2-5: never follow file reparse points
                if(($aInt -band 0x400) -ne 0){ continue }
                # P2-5: long paths are recorded, not planned (PS 5.1 cannot address them reliably)
                if($fi.FullName.Length -ge 260){
                    $records.Add([pscustomobject]@{ FullName=$fi.FullName; Name=$fi.Name; Stem=$fi.BaseName
                        Extension=$fi.Extension.ToLowerInvariant(); Length=[int64]$fi.Length
                        LastWriteTime=$fi.LastWriteTime; Directory=$fi.DirectoryName; Category='SkippedLongPath' })
                    $count++
                    continue
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
            } catch { Write-Verbose "Skipped file $($fi.FullName): $($_.Exception.Message)" }
        }
    }
    Write-Progress -Activity "Scanning $root" -Completed
    $arr = $records.ToArray()

    if($cacheFile){
        try{
            if(-not (Test-Path -LiteralPath $CacheFolder)){ New-Item -ItemType Directory -Path $CacheFolder -Force | Out-Null }
            $arr | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        } catch { Write-Warning "Inventory cache could not be written: $($_.Exception.Message)" }
    }
    # Stream the records: an empty scan emits nothing, and callers collect with @().
    # The previous 'return ,$arr' idiom leaked its one-element wrapper in Pester
    # capture contexts, which is exactly what the P0-2 test failure exposed.
    return $arr
}

function Get-SysOrgOrganizedDirSet {
<#
.SYNOPSIS
    Folders that already look organized: >= MinFiles files with >= ratio in one
    category, excluding routine dump folders. Their subtrees are preserved.
.EXAMPLE
    $set = Get-SysOrgOrganizedDirSet -Inventory $inv -Config $cfg
#>
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
<#
.SYNOPSIS
    True when a file's directory is inside an already-organized (preserved) folder.
.EXAMPLE
    Test-SysOrgInOrganizedDir -Directory $f.Directory -OrganizedSet $set
#>
    param([string]$Directory,$OrganizedSet)
    $cur = $Directory.TrimEnd('\')
    while($cur -and ($cur.Length -gt 3)){
        if($OrganizedSet.ContainsKey($cur.ToLowerInvariant())){ return $true }
        $cur = Split-Path $cur -Parent
    }
    return $false
}

function Get-SysOrgProjectClusters {
<#
.SYNOPSIS
    Conservative relationship detection returning { Lookup, Clusters }.
.DESCRIPTION
    1) same filename stem across >= 2 file types (e.g. Report.docx + Report.pdf)
    2) shared distinctive name tokens (stopwords/numbers filtered).
    P2-6: the token signature is order-independent (tokens are sorted and
    de-duplicated before the first three are taken), so 'Report Q3 2025 Final'
    and 'Final Q3 Report 2025' cluster together. Cluster keys fall back to
    'cluster' when a stem produces an empty ASCII slug (non-ASCII names).
.EXAMPLE
    $c = Get-SysOrgProjectClusters -Inventory $inv -Config $cfg; $c.Lookup['C:\x\Report.pdf']
#>
    param($Inventory,$Config)
    $lookup = @{}
    $clusters = New-Object System.Collections.Generic.List[object]
    if(-not (Get-SysOrgSetting $Config 'ProjectDetection.Enabled' $true)){
        return [pscustomobject]@{ Lookup=$lookup; Clusters=$clusters.ToArray() }
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
            $slug = ($kv.Key -replace '[^a-z0-9]+','-').Trim('-')
            if([string]::IsNullOrWhiteSpace($slug)){ $slug = 'cluster' }
            $key = 'Project-{0:00}-{1}' -f $projectIndex, $slug
            foreach($f in $files){ $lookup[$f.FullName] = $key; [void]$assigned.Add($f.FullName) }
            $clusters.Add([pscustomobject]@{ Key=$key; FileCount=$files.Count; Basis='Same filename stem across file types'; Sample=$files[0].Name })
        }
    }

    # 2) shared distinctive tokens (P2-6: order-independent signature)
    $byTokens = @{}
    foreach($f in $Inventory){
        if($assigned.Contains($f.FullName)){ continue }
        $tokens = @(($f.Stem.ToLowerInvariant() -split '[^a-z0-9]+') | Where-Object { $_.Length -ge 4 -and ($stop -notcontains $_) -and ($_ -notmatch '^\d+$') })
        if($tokens.Count -lt 2){ continue }
        $sig = (@($tokens | Sort-Object -Unique | Select-Object -First 3)) -join '+'
        if(-not $byTokens.ContainsKey($sig)){ $byTokens[$sig] = New-Object System.Collections.Generic.List[object] }
        [void]$byTokens[$sig].Add($f)
    }
    foreach($kv in $byTokens.GetEnumerator()){
        $files = @($kv.Value | Where-Object { -not $assigned.Contains($_.FullName) })
        if($files.Count -ge $minFiles){
            $projectIndex++
            if($projectIndex -gt $maxProjects){ break }
            $slug = ($kv.Key -replace '[^a-z0-9]+','-').Trim('-')
            if([string]::IsNullOrWhiteSpace($slug)){ $slug = 'cluster' }
            $key = 'Project-{0:00}-{1}' -f $projectIndex, $slug
            foreach($f in $files){ $lookup[$f.FullName] = $key; [void]$assigned.Add($f.FullName) }
            $clusters.Add([pscustomobject]@{ Key=$key; FileCount=$files.Count; Basis='Shared distinctive name tokens'; Sample=$files[0].Name })
        }
    }
    return [pscustomobject]@{ Lookup=$lookup; Clusters=$clusters.ToArray() }
}

function Find-SysOrgDuplicates {
<#
.SYNOPSIS
    Exact duplicate detection: group by size -> 64 KB header hash -> full SHA256.
.DESCRIPTION
    Keeper = outside temp-like folders, shortest path, oldest write time.
    WastedBytes reports the reclaimable size per group (P0-2 acceptance).
    Only hashes candidate files; cloud placeholders never reach this stage.
.EXAMPLE
    $dups = Find-SysOrgDuplicates -Inventory $inv -Config $cfg
#>
    param($Inventory,$Config)
    $groups = New-Object System.Collections.Generic.List[object]
    $minKB    = Get-SysOrgSetting $Config 'Duplicates.MinFileSizeKB' 256
    $headerKB = Get-SysOrgSetting $Config 'Duplicates.HeaderHashKB' 64
    $minBytes = [int64]$minKB * 1KB
    $tempLike = @('\downloads\','\desktop\','\temp\','\tmp\')

    $sizeCandidates = @($Inventory | Where-Object { $_.Category -ne 'SkippedLongPath' -and $_.Length -ge $minBytes } | Group-Object -Property Length | Where-Object { $_.Count -gt 1 })
    $total = $sizeCandidates.Count; $done = 0

    foreach($sizeGroup in $sizeCandidates){
        $done++
        Write-Progress -Activity 'Duplicate detection' `
            -Status "Size group $($sizeGroup.Name) bytes ($done of $total)" `
            -PercentComplete $(if($total -gt 0){ [int](100 * $done / $total) } else { 0 })
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
                $wasted = [int64](($others | Measure-Object -Property Length -Sum).Sum)
                $groups.Add([pscustomobject]@{
                    Hash=$fh; KeepPath=$keep.FullName
                    KeepReason='Outside temp-like folders, shortest path, oldest first'
                    Duplicates=@($others | ForEach-Object { $_.FullName })
                    WastedBytes=$wasted
                })
            }
        }
    }
    Write-Progress -Activity 'Duplicate detection' -Completed
    # Stream groups (see Get-SysOrgInventory for why 'return ,$array' is wrong):
    # callers collect with @(); an empty result emits nothing.
    return $groups.ToArray()
}

Export-ModuleMember -Function *-SysOrg*
