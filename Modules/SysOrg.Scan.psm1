#Requires -Version 5.1
# SysOrg.Scan.psm1 - inventory, classification (TypeMap -> built-in map -> PerceivedType),
#                    download provenance, code project folders, multipart sets,
#                    type-first name families, duplicate detection.

# ---------------------------------------------------------------------------
# Classification (W4): routing categories are the Windows set.
#   Documents, Pictures, Videos, Music, Archives, Code, Installers, Other (, SKIP)
# Legacy v1.x category names translate through $script:CategoryToRoute.
# ---------------------------------------------------------------------------
$script:CategoryMap = @{
    Documents     = @('.pdf','.doc','.docx','.txt','.rtf','.odt','.md','.xps','.djvu','.epub','.chm')
    Spreadsheets  = @('.xls','.xlsx','.csv','.ods','.tsv')
    Presentations = @('.ppt','.pptx','.odp','.key')
    Images        = @('.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp','.svg','.heic','.raw','.cr2','.nef','.arw','.dng','.psd','.ai','.xcf','.ico')
    Videos        = @('.mp4','.mkv','.avi','.mov','.wmv','.flv','.webm','.m4v','.mpg','.mpeg','.3gp')
    Audio         = @('.mp3','.wav','.flac','.aac','.ogg','.m4a','.wma','.mid','.opus')
    Archives      = @('.zip','.rar','.7z','.tar','.gz','.bz2','.xz','.iso','.cab')
    Code          = @('.py','.js','.ts','.html','.css','.java','.c','.cpp','.cs','.go','.rs','.php','.rb','.sh','.ps1','.psm1','.bat','.cmd','.sql','.json','.xml','.yml','.yaml','.ini','.toml')
    Installers    = @('.exe','.msi','.msix','.appx','.apk')
    Fonts         = @('.ttf','.otf','.woff','.woff2','.fon')
    Databases     = @('.db','.sqlite','.mdb','.accdb','.bak')
}
# NOTE (v2.1.1): '.ts' is intentionally mapped ONLY as Code (TypeScript). MPEG transport
# streams are detected at scan time by content sniffing (Test-SysOrgMpegTransportStream)
# and routed to Videos there - no extension may appear in two categories, and the map is
# built deterministically (Keys | Sort-Object) because hashtable enumeration order is
# not defined in Windows PowerShell 5.1.
$script:ExtToCategory = @{}
foreach($cat in ($script:CategoryMap.Keys | Sort-Object)){
    foreach($e in $script:CategoryMap[$cat]){ $script:ExtToCategory[$e] = $cat }
}
$script:CategoryToRoute = @{
    Documents='Documents'; Spreadsheets='Documents'; Presentations='Documents'; Fonts='Documents'; Databases='Documents'
    Images='Pictures'; Videos='Videos'; Audio='Music'; Archives='Archives'; Code='Code'; Installers='Installers'
}

$script:PerceivedCache = @{}
$script:RouteByPerceivedType = @{
    'image'='Pictures'; 'video'='Videos'; 'audio'='Music'; 'text'='Documents'
    'document'='Documents'; 'compressed'='Archives'; 'application'='Installers'
}

function Get-SysOrgPerceivedSub {
<#
.SYNOPSIS
    Windows PerceivedType registry fallback for extensions missing from the map (W4).
.DESCRIPTION
    Explorer groups by Kind using the perceived type registered per extension; unknown types
    land where Windows would put them. 'system' returns 'SKIP' (the file is never moved).
    Results are cached per session; the registry read is wrapped so non-Windows test hosts
    return $null instead of throwing.
.EXAMPLE
    Get-SysOrgPerceivedSub -Extension '.heic'   # -> 'Pictures' when PerceivedType=image
#>
    param([string]$Extension)
    $ext = "$Extension".ToLowerInvariant()
    if(-not $ext){ return $null }
    if($script:PerceivedCache.ContainsKey($ext)){ return $script:PerceivedCache[$ext] }
    $sub = $null
    try{
        $pt = (Get-ItemProperty -LiteralPath ('Registry::HKEY_CLASSES_ROOT\' + $ext) -Name 'PerceivedType' -ErrorAction Stop).PerceivedType
        $pt = "$pt".ToLowerInvariant()
        if($script:RouteByPerceivedType.ContainsKey($pt)){ $sub = $script:RouteByPerceivedType[$pt] }
        if($pt -eq 'system'){ $sub = 'SKIP' }
    } catch { }
    $script:PerceivedCache[$ext] = $sub
    return $sub
}

function Get-SysOrgCategory {
<#
.SYNOPSIS
    Maps a file extension to a ROUTING category.
.DESCRIPTION
    Resolution order (design 3.3): config TypeMap override, built-in extension map,
    Windows PerceivedType registry fallback, then 'Other'. Legacy config values
    (Images, Audio, ...) are translated to the routing set. 'SKIP' means never moved.
.EXAMPLE
    Get-SysOrgCategory -Extension '.pdf' -Config $cfg   # -> 'Documents'
#>
    param([string]$Extension,$Config)
    $ext = $Extension.ToLowerInvariant()
    $overrides = Get-SysOrgSetting $Config 'TypeMap' $null
    if(-not ($overrides -is [hashtable])){ $overrides = Get-SysOrgSetting $Config 'Categories' $null }
    if($overrides -is [hashtable] -and $overrides.ContainsKey($ext)){
        $v = "$($overrides[$ext])"
        if($script:CategoryToRoute.ContainsKey($v)){ return $script:CategoryToRoute[$v] }
        return $v
    }
    if($script:ExtToCategory.ContainsKey($ext)){ return $script:CategoryToRoute[$script:ExtToCategory[$ext]] }
    # PerceivedType fallback: Get-SysOrgPerceivedSub already maps raw registry values to
    # routing categories; map again here so raw values (e.g. 'image' from a mock) resolve too.
    $pt = Get-SysOrgPerceivedSub -Extension $ext
    if($pt){
        if("$pt" -eq 'SKIP'){ return 'SKIP' }
        if($script:RouteByPerceivedType.ContainsKey("$pt")){ return $script:RouteByPerceivedType["$pt"] }
        return "$pt"
    }
    return 'Other'
}

# NOTE: Test-SysOrgCloudPlaceholderAttributes moved to SysOrg.Core.psm1 in v2.1.1 so the
# plan executor can re-check placeholders without importing the Scan module.

function Test-SysOrgMpegTransportStream {
<#
.SYNOPSIS
    Content sniff for MPEG transport streams (v2.1.1): 0x47 sync bytes at offsets 0 and 188.
.DESCRIPTION
    Used to route real .ts transport streams to Videos even though the '.ts' extension maps
    to Code (TypeScript) - the extension itself must stay single-valued. Reads only the
    first 189 bytes, is read-only, and returns $false for anything unreadable, empty or
    shorter than one packet. Callers must have already skipped cloud placeholders (opening
    one would hydrate it).
.EXAMPLE
    Test-SysOrgMpegTransportStream -Path 'C:\dl\video.ts'   # -> True
#>
    param([Parameter(Mandatory)][string]$Path)
    try{
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try{
            if($fs.Length -lt 189){ return $false }
            $buf = New-Object byte[] 189
            $read = 0
            while($read -lt 189){
                $n = $fs.Read($buf, $read, 189 - $read)
                if($n -le 0){ break }
                $read += $n
            }
            if($read -lt 189){ return $false }
            return (($buf[0] -eq 0x47) -and ($buf[188] -eq 0x47))
        } finally { $fs.Dispose() }
    } catch { return $false }
}

function Get-SysOrgScanRoots {
<#
.SYNOPSIS
    Resolves the scan start folders and scope tag for a drive (P1-6, extended by W2).
.DESCRIPTION
    -Roots wins; -DefaultScope resolves ScanRoots AND the known folders that live on this
    drive (registry-resolved, so a redirected Pictures folder on D:\Bilder is scoped on D);
    otherwise the whole drive. Returns @{ Scope; Initial }.
.EXAMPLE
    $r = Get-SysOrgScanRoots -Letter C -Config $cfg -DefaultScope
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter,$Config,[switch]$DefaultScope,[string[]]$Roots,[object[]]$KnownFolders)
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
        $resolved = New-Object System.Collections.Generic.HashSet[string]
        if($subs){
            foreach($sub in @($subs)){
                if([string]::IsNullOrWhiteSpace("$sub")){ continue }
                $driveRel = ('{0}:\{1}' -f $Letter, ("$sub").TrimStart('\'))
                if(Test-Path -LiteralPath $driveRel){ [void]$resolved.Add($driveRel) }
                if($env:USERPROFILE){
                    $prof = Join-Path $env:USERPROFILE "$sub"
                    $qual = $null
                    try { $qual = Split-Path $prof -Qualifier -ErrorAction Stop } catch { $qual = $null }
                    if($qual -and ($qual -ieq ('{0}:' -f $Letter)) -and (Test-Path -LiteralPath $prof)){ [void]$resolved.Add($prof) }
                }
            }
        }
        try{
            if(-not $KnownFolders -or @($KnownFolders).Count -eq 0){ $KnownFolders = @(Get-SysOrgKnownFolders) }
            foreach($k in @($KnownFolders)){
                $kp = "$($k.Path)"
                if(-not $kp){ continue }
                $qual = $null
                try { $qual = Split-Path $kp -Qualifier -ErrorAction Stop } catch { $qual = $null }
                if($qual -and ($qual.TrimEnd(':').ToUpperInvariant() -eq $Letter.ToUpperInvariant())){
                    if(Test-Path -LiteralPath $kp){ [void]$resolved.Add($kp) }
                }
            }
        } catch { Write-Verbose "Known-folder scan scope unavailable: $($_.Exception.Message)" }
        if($resolved.Count -gt 0){ $initial = @($resolved); $scope = 'scoped' }
    }
    else { $initial = @(('{0}:\' -f $Letter)) }
    return [pscustomobject]@{ Scope=$scope; Initial=$initial }
}

function Get-SysOrgInventory {
<#
.SYNOPSIS
    Recursive file inventory with exclusions, folder safety gates, cloud-placeholder
    skip, long-path recording and a config-keyed JSON cache.
.DESCRIPTION
    Default start point is the drive root. With -DefaultScope, Get-SysOrgScanRoots narrows
    the scan to existing profile folders and known folders on the scanned drive. -Roots
    forces explicit start folders (used by tests and power users). Cloud placeholders
    (OneDrive files-on-demand) are never opened, so scanning cannot hydrate them.
    Files at or above 260 characters of path are recorded with Category
    'SkippedLongPath' (Windows PowerShell 5.1 cannot reliably address them).
.PARAMETER Letter
    Drive letter whose root is scanned (also keys the cache file).
.PARAMETER DefaultScope
    Resolve the ScanRoots config entry + known folders for this drive instead of the whole drive.
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
        [object[]]$KnownFolders,
        [System.Collections.Generic.List[object]]$AuditTrail
    )
    $root = ('{0}:\' -f $Letter)
    if(-not ($Roots -and @($Roots).Count -gt 0) -and (-not $DefaultScope)){
        if(-not (Test-Path -LiteralPath $root)){ throw "Drive $root not found." }
    }
    if(-not $cfaFolders){ $cfaFolders = Get-SysOrgDefenderProtectedFolders -Config $Config }

    # --- P1-6 + W2: resolve scan roots ---
    $rootsInfo = Get-SysOrgScanRoots -Letter $Letter -Config $Config -DefaultScope:$DefaultScope -Roots $Roots -KnownFolders $KnownFolders
    $scope = $rootsInfo.Scope
    $initial = @($rootsInfo.Initial)
    if($scope -eq 'full'){
        if($initial.Count -gt 0){ if(-not (Test-Path -LiteralPath $initial[0])){ throw "Drive $root not found." } }
    }
    if($initial.Count -eq 0){
        Write-Warning ("No ScanRoots folders found on drive {0}:. Use -FullDrive to scan the whole drive, or edit ScanRoots in SysOrg.config.psd1." -f $Letter)
        return @()
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
    # v3.0 Phase 3.3: ONE precompiled exclusion matcher for the whole scan
    $exMatcher = $null
    try { $exMatcher = New-SysOrgExclusionMatcher -Config $Config } catch { $exMatcher = $null }

    while($stack.Count -gt 0){
        $dir = [string]$stack.Pop()

        # P1-8: a .sysorg-ignore marker excludes the WHOLE tree, not just the marker itself
        if(Test-Path -LiteralPath (Join-Path $dir '.sysorg-ignore')){
            Write-Verbose "Marker .sysorg-ignore found; skipping tree: $dir"
            continue
        }
        if($exMatcher){
            if(Test-SysOrgExcludedPathFast -Path $dir -Matcher $exMatcher){ continue }
        } else {
            if(Test-SysOrgExcludedPath -Path $dir -Config $Config){ continue }
        }
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
                $category = Get-SysOrgCategory -Extension $ext -Config $Config
                # v2.1.1: '.ts' maps to Code (TypeScript), but a real MPEG transport stream
                # (sync bytes 0x47 at 0 and 188) routes to Videos. Sniffed only here, after
                # the placeholder/reparse gates, so cloud files are never opened.
                if(($ext -eq '.ts') -and (Test-SysOrgMpegTransportStream -Path $fi.FullName)){
                    $category = 'Videos'
                }
                $records.Add([pscustomobject]@{
                    FullName      = $fi.FullName
                    Name          = $fi.Name
                    Stem          = $fi.BaseName
                    Extension     = $ext
                    Length        = [int64]$fi.Length
                    LastWriteTime = $fi.LastWriteTime
                    Directory     = $fi.DirectoryName
                    Category      = $category
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
    $cur = ("$Directory").Replace('/','\').TrimEnd('\')
    while($cur -and ($cur.Length -gt 3)){
        if($OrganizedSet.ContainsKey($cur.ToLowerInvariant())){ return $true }
        $next = Split-Path $cur -Parent
        if(-not $next -or ("$next").Length -ge $cur.Length){ break }
        $cur = "$next"
    }
    return $false
}

# ---------------------------------------------------------------------------
# W5: type-first name families. Records are partitioned by context leaf (main type
# root, or Downloads\<Source>\<Sub>); clustering happens ONLY within a partition.
# Cross-type signatures get the SAME family name in each type root - nothing crosses
# the type boundary (Families.WithinTypeOnly=$true, the point of revision 2.1).
# ---------------------------------------------------------------------------
function Get-SysOrgFamilySignature {
<#
.SYNOPSIS
    Normalizes a file stem into a family signature (rev 2.0 normalization rules).
.DESCRIPTION
    Strips ' (n)' copy counters, copy markers, optional vN version suffixes and noise
    tokens; dates are kept or stripped per Families.KeepDates. The token signature is
    order-independent (P2-6 sort fix).
.EXAMPLE
    Get-SysOrgFamilySignature -Stem 'Report final v2' -NoiseTokens @('final') -StripVersionSuffix:$true -KeepDates:$true   # -> 'report'
#>
    param([Parameter(Mandatory)][string]$Stem,[string[]]$NoiseTokens,[bool]$StripVersionSuffix,[bool]$KeepDates)
    $s = $Stem.ToLowerInvariant()
    $s = [regex]::Replace($s, '\(\d+\)', ' ')
    $s = [regex]::Replace($s, '\s*[-_]\s*cop(y|ies)(\s*\(\d+\))?\s*', ' ')
    if($StripVersionSuffix){
        $s = [regex]::Replace($s, '\s*v\d+(\.\d+)*\s*$', ' ')
    }
    $tokens = @(($s -split '[^a-z0-9]+') | Where-Object { $_ -and ("$_" -ne '') })
    $out = New-Object System.Collections.Generic.List[string]
    foreach($t in $tokens){
        if($NoiseTokens -contains $t){ continue }
        if($StripVersionSuffix -and ($t -match '^v\d+(\.\d+)*$')){ continue }
        [void]$out.Add($t)
    }
    if(-not $KeepDates){
        $hadYear = $false
        foreach($t in $out){ if($t -match '^(19|20)\d{2}$'){ $hadYear = $true; break } }
        if($hadYear){
            $filtered = New-Object System.Collections.Generic.List[string]
            foreach($t in $out){
                if($t -match '^(19|20)\d{2}$'){ continue }
                if($t -match '^\d{1,2}$'){ continue }
                [void]$filtered.Add($t)
            }
            $out = $filtered
        }
    }
    $sig = (@($out.ToArray()) | Sort-Object -Unique) -join '+'
    return $sig
}

function Get-SysOrgNameFamilies {
<#
.SYNOPSIS
    Type-first family partition over routed inventory records (W5).
.DESCRIPTION
    Partition records by context leaf (via $PartitionLookup), normalize stems, and group:
      1) same signature with >= Families.MinFiles members in one partition -> family;
      2) a signature spanning >= 2 type roots qualifies EVERY partition holding it,
         so holiday.jpg and holiday.mp4 produce Pictures\holiday\ AND Videos\holiday\
         with the SAME family name - never one mixed folder.
    Family folder name = most frequent original stem (sanitized, truncated).
    Families.CrossTypeLink='Dominant' (opt-in) additionally links leftovers that share a
    family signature; with Families.WithinTypeOnly=$false they may cross the type boundary.
.EXAMPLE
    $fam = Get-SysOrgNameFamilies -Inventory $inv -PartitionLookup $pk -Config $cfg
    $fam.Lookup['C:\x\holiday.jpg'].Name   # -> 'holiday'
#>
    [CmdletBinding()]
    param([AllowEmptyCollection()]$Inventory,$PartitionLookup,$Config)
    $lookup = @{}
    $families = New-Object System.Collections.Generic.List[object]
    # NOTE: @() collecting a generic List[object] throws 'Argument types do not match'
    # on both Windows PowerShell 5.1 and PowerShell 7 - normalize via ToArray first.
    $inv = @()
    if($Inventory -is [System.Collections.Generic.List[object]]){ $inv = $Inventory.ToArray() }
    elseif($null -ne $Inventory){ $inv = @($Inventory) }
    if(-not (Get-SysOrgSetting $Config 'Families.Enabled' $true)){ return [pscustomobject]@{ Lookup=$lookup; Families=$families.ToArray() } }
    if($inv.Count -eq 0){ return [pscustomobject]@{ Lookup=$lookup; Families=$families.ToArray() } }

    $noise    = @(Get-SysOrgSetting $Config 'Families.NoiseTokens' @())
    $stripVer = [bool](Get-SysOrgSetting $Config 'Families.StripVersionSuffix' $true)
    $keepDates = [bool](Get-SysOrgSetting $Config 'Families.KeepDates' $true)
    $minFiles = [int](Get-SysOrgSetting $Config 'Families.MinFiles' 2)
    $withinType = [bool](Get-SysOrgSetting $Config 'Families.WithinTypeOnly' $true)
    $crossLink = "$(Get-SysOrgSetting $Config 'Families.CrossTypeLink' 'SameName')"
    $maxLen   = [int](Get-SysOrgSetting $Config 'Families.MaxNameLength' 60)

    # signature -> partition -> records
    $bySig = @{}
    foreach($f in $inv){
        $pk = ''
        if($PartitionLookup -and $PartitionLookup.ContainsKey($f.FullName)){ $pk = [string]$PartitionLookup[$f.FullName] }
        if(-not $pk){ $pk = [string]$f.Category }
        $sig = Get-SysOrgFamilySignature -Stem ([string]$f.Stem) -NoiseTokens $noise -StripVersionSuffix:$stripVer -KeepDates:$keepDates
        if([string]::IsNullOrEmpty($sig)){ continue }
        if(-not $bySig.ContainsKey($sig)){ $bySig[$sig] = @{} }
        if(-not $bySig[$sig].ContainsKey($pk)){ $bySig[$sig][$pk] = New-Object System.Collections.Generic.List[object] }
        [void]$bySig[$sig][$pk].Add($f)
    }

    foreach($sig in $bySig.Keys){
        $partMap = $bySig[$sig]
        $partKeys = @($partMap.Keys)
        $roots = New-Object System.Collections.Generic.HashSet[string]
        foreach($pk in $partKeys){ [void]$roots.Add(("$pk".Split('\')[0]).ToLowerInvariant()) }
        $crossType = ($roots.Count -ge 2)
        foreach($pk in $partKeys){
            $members = $partMap[$pk].ToArray()
            $isFamily = ($members.Count -ge $minFiles)
            $basis = 'Same normalized name within the type root'
            if((-not $isFamily) -and $crossType){
                $isFamily = $true
                $basis = 'Same name across types (same family name in each type root)'
            }
            if(-not $isFamily){ continue }
            $famName = Get-SysOrgFamilyFolderName -Members $members -MaxNameLength $maxLen
            foreach($m in $members){ $lookup[$m.FullName] = @{ Name=$famName; Partition=[string]$pk } }
            [void]$families.Add([pscustomobject]@{
                Name=$famName; Partition=[string]$pk; Members=$members.Count
                MemberPaths=@($members | ForEach-Object { "$($_.FullName)" })
                Signature=$sig; Basis=$basis
            })
        }
    }

    if($crossLink -eq 'Dominant'){
        foreach($sig in $bySig.Keys){
            $partMap = $bySig[$sig]
            $domPk = $null; $domCount = -1
            $pks = Sort-SysOrgNatural -Values @($partMap.Keys)
            foreach($pk in $pks){ if($partMap[$pk].Count -gt $domCount){ $domCount = $partMap[$pk].Count; $domPk = $pk } }
            if($domCount -lt $minFiles){ continue }
            $domMembers = $partMap[$domPk].ToArray()
            $famName = Get-SysOrgFamilyFolderName -Members $domMembers -MaxNameLength $maxLen
            foreach($pk in @($partMap.Keys)){
                if($pk -eq $domPk){ continue }
                $targetPk = [string]$pk
                if(-not $withinType){ $targetPk = [string]$domPk }   # opt-in: cross the type boundary
                foreach($m in $partMap[$pk]){
                    if($lookup.ContainsKey($m.FullName)){ continue }
                    $lookup[$m.FullName] = @{ Name=$famName; Partition=$targetPk }
                }
            }
        }
    }
    return [pscustomobject]@{ Lookup=$lookup; Families=$families.ToArray() }
}

function Get-SysOrgFamilyFolderName {
<#
.SYNOPSIS
    Family folder name: most frequent original stem among members, sanitized.
.DESCRIPTION
    Ties break by natural name order (deterministic across runs, W7).
.EXAMPLE
    Get-SysOrgFamilyFolderName -Members $records -MaxNameLength 60   # -> 'Report'
#>
    param([Parameter(Mandatory)]$Members,[int]$MaxNameLength=60)
    $stemCounts = @{}
    $stemOriginal = @{}
    foreach($m in @($Members)){
        $orig = [string]$m.Stem
        $k2 = $orig.ToLowerInvariant()
        if(-not $stemCounts.ContainsKey($k2)){ $stemCounts[$k2] = 0; $stemOriginal[$k2] = $orig }
        $stemCounts[$k2]++
    }
    $best = $null; $bestCount = -1
    $ordered = Sort-SysOrgNatural -Values @($stemCounts.Keys)
    foreach($st in $ordered){
        if($stemCounts[$st] -gt $bestCount){ $bestCount = $stemCounts[$st]; $best = $st }
    }
    if(-not $best){ $best = 'Family' }
    else { $best = $stemOriginal[$best] }   # keep the original stem's casing
    return (Get-SysOrgSafeFolderName -Name $best -MaxLength $MaxNameLength)
}

function Get-SysOrgProjectFolders {
<#
.SYNOPSIS
    Detects code project FOLDERS by their marker files (.git, package.json, *.sln, ...).
.DESCRIPTION
    Project folders move as ONE MoveFolder unit (rev 2.0 D4): `Documents\Projects\Code\<Name>`,
    .git intact. Detection walks the scan roots to depth 4, never descends into a found
    project, and never treats known folders, the app root, the user profile or destination
    roots as projects. Generic names ('src', 'new folder', ...) get a deterministic suffix
    so distinct generic folders cannot collide at the destination.
.EXAMPLE
    $projects = Get-SysOrgProjectFolders -Roots @('C:\Users\t\Documents') -Config $cfg -DriveProfile $prof
#>
    [CmdletBinding()]
    param([string[]]$Roots,$Config,$DriveProfile,[object[]]$KnownFolders)
    $result = New-Object System.Collections.Generic.List[object]
    if(-not (Get-SysOrgSetting $Config 'Projects.Enabled' $true)){ return $result.ToArray() }
    if(-not $Roots -or @($Roots).Count -eq 0){ return $result.ToArray() }

    $markers = @(Get-SysOrgSetting $Config 'Projects.Markers' @())
    if($markers.Count -eq 0){
        $markers = @('.git','.svn','.hg','.jj','.gitignore','package.json','package-lock.json','yarn.lock',
                     'pnpm-lock.yaml','Cargo.toml','go.mod','go.sum','pyproject.toml','setup.py','composer.json',
                     'Gemfile','pom.xml','build.gradle','build.gradle.kts','Makefile','CMakeLists.txt',
                     '*.sln','*.csproj','*.vcxproj','*.fsproj')
    }
    $generic = @(@(Get-SysOrgSetting $Config 'Projects.GenericNames' @()) | ForEach-Object { "$_".ToLowerInvariant() })
    $maxDepth = 4
    $maxCount = 200

    $guard = New-Object System.Collections.Generic.HashSet[string]
    $appRoot = Get-SysOrgSetting $Config 'AppRoot' $null
    if($appRoot){ [void]$guard.Add(("$appRoot").TrimEnd('\').ToLowerInvariant()) }
    if($env:USERPROFILE){ [void]$guard.Add(($env:USERPROFILE).TrimEnd('\').ToLowerInvariant()) }
    if($DriveProfile){
        $dr = Get-SysOrgDestinationRoot -Letter "$($DriveProfile.Letter)" -Config $Config
        [void]$guard.Add($dr.ToLowerInvariant())
    }
    foreach($k in @($KnownFolders)){ if($k.Path){ [void]$guard.Add(("$($k.Path)").TrimEnd('\').ToLowerInvariant()) } }

    $stack = New-Object System.Collections.Stack
    foreach($r in @($Roots)){ if(Test-Path -LiteralPath $r){ [void]$stack.Push(@{ Path=[string]$r; Depth=0 }) } }

    while($stack.Count -gt 0){
        $item = $stack.Pop()
        $dir = [string]$item.Path; $depth = [int]$item.Depth
        $lc = ($dir.Replace('/','\')).TrimEnd('\').ToLowerInvariant()
        if($guard.Contains($lc)){ continue }
        if(Test-Path -LiteralPath (Join-Path $dir '.sysorg-ignore')){ continue }
        if(Test-SysOrgExcludedPath -Path $dir -Config $Config){ continue }
        if((Get-SysOrgSetting $Config 'ExcludeDestinations' $true) -and (Test-SysOrgDestinationPath -Path $dir -Config $Config)){ continue }
        try{
            $di = New-Object System.IO.DirectoryInfo($dir)
            if(($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint){ continue }
            if((Get-SysOrgSetting $Config 'FolderAudit.SkipHiddenSystemDirs' $true) -and
               ((($di.Attributes -band [System.IO.FileAttributes]::Hidden) -eq [System.IO.FileAttributes]::Hidden) -or
                (($di.Attributes -band [System.IO.FileAttributes]::System) -eq [System.IO.FileAttributes]::System))){ continue }
        } catch { continue }

        $entries = @()
        try { $entries = @([System.IO.Directory]::GetFileSystemEntries($dir) | ForEach-Object { Split-Path $_ -Leaf }) } catch { $entries = @() }
        $isProject = $false
        if($entries.Count -gt 0){
            # v2.1.1: a project needs a VCS marker (.git/.hg/.svn/.jj) OR at least TWO
            # distinct markers. A lone .gitignore, Makefile or lock file is not enough
            # (thesis folders, data directories and exports carry those too).
            $matched = New-Object System.Collections.Generic.List[string]
            foreach($m in $markers){
                if([string]::IsNullOrWhiteSpace("$m")){ continue }
                if("$m".Contains('*') -or "$m".Contains('?')){
                    foreach($e in $entries){ if($e -like "$m"){ [void]$matched.Add("$m"); break } }
                } elseif($entries -contains "$m"){ [void]$matched.Add("$m") }
            }
            $vcsHit = $false
            foreach($v in @('.git','.hg','.svn','.jj')){ if($matched -contains $v){ $vcsHit = $true; break } }
            if($vcsHit -or ($matched.Count -ge 2)){ $isProject = $true }
        }
        if($isProject){
            $name = Split-Path $dir -Leaf
            $safe = Get-SysOrgSafeFolderName -Name $name -MaxLength 60
            if($generic -contains $name.ToLowerInvariant()){
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try{
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($lc)
                    $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
                    $safe = ('{0} ({1})' -f $safe, $hash.Substring(0,8))
                } finally { $sha.Dispose() }
            }
            [void]$result.Add([pscustomobject]@{ Path=$dir; Name=$name; SafeName=$safe })
            if($result.Count -ge $maxCount){ break }
            continue   # do not descend: nested projects belong to the outer project
        }
        if($depth -lt $maxDepth){
            try{
                foreach($k in @([System.IO.Directory]::GetDirectories($dir))){ [void]$stack.Push(@{ Path=[string]$k; Depth=($depth+1) }) }
            } catch { Write-Verbose "Project scan could not list '$dir': $($_.Exception.Message)" }
        }
    }
    return $result.ToArray()
}

function Get-SysOrgMultipartSets {
<#
.SYNOPSIS
    Groups multipart archives into single move units (rev 2.0 D5).
.DESCRIPTION
    Recognizes name.zip.001/002..., name.7z.001..., name.part1.rar/name.part2.rar and
    name.rar + name.r00/r01 sets. Returns @{ Map; Sets } where Map routes every member
    path to its set key and Sets carries the natural-ordered members with the leader.
    Multipart members are exempt from copy numbering and quarantine.
.EXAMPLE
    $mp = Get-SysOrgMultipartSets -Inventory $inv -Config $cfg
    $mp.Map['C:\dl\Trip.zip.001']   # -> 'set-trip-zip'
#>
    param($Inventory,$Config)
    $map = @{}
    $sets = New-Object System.Collections.Generic.List[object]
    if(-not (Get-SysOrgSetting $Config 'Archives.KeepMultipartTogether' $true)){
        return [pscustomobject]@{ Map=$map; Sets=$sets.ToArray() }
    }
    $byKey = @{}
    foreach($f in @($Inventory)){
        $name = "$($f.Name)"
        $key = $null
        if($name -imatch '^(?<base>.+)\.part(?<num>\d+)\.(rar|rev)$'){ $key = $Matches.base.ToLowerInvariant() }
        elseif($name -imatch '^(?<base>.+)\.(?<ext2>zip|7z)\.(?<num>\d{3})$'){ $key = ($Matches.base + '.' + $Matches.ext2).ToLowerInvariant() }
        elseif($name -imatch '^(?<base>.+)\.r(?<num>\d{2})$'){ $key = $Matches.base.ToLowerInvariant() }
        elseif($name -imatch '^(?<base>.+)\.rar$'){ $key = $Matches.base.ToLowerInvariant() }
        if($key){
            if(-not $byKey.ContainsKey($key)){ $byKey[$key] = New-Object System.Collections.Generic.List[object] }
            [void]$byKey[$key].Add($f)
        }
    }
    foreach($k in $byKey.Keys){
        $members = $byKey[$k].ToArray()
        if($members.Count -lt 2){ continue }
        $ordered = Sort-SysOrgNatural -Values @($members | ForEach-Object { "$($_.FullName)" })
        $leaderPath = $ordered[0]
        $setKey = 'set-' + ($k -replace '[^a-z0-9]+','-')
        foreach($m in $members){ $map["$($m.FullName)"] = $setKey }
        [void]$sets.Add([pscustomobject]@{ Key=$setKey; Base=$k; Leader=$leaderPath; Members=$members })
    }
    return [pscustomobject]@{ Map=$map; Sets=$sets.ToArray() }
}

# ---------------------------------------------------------------------------
# A4 (v3.0.1): the source bucket map is extensible via Rules\Sources.psd1
# (config Rules.SourcesPath). The built-in defaults below keep working when the
# file is missing; a file that exists but cannot be parsed FAILS CLOSED (like a
# broken lexicon). File entries MERGE over the built-ins: users can add hosts,
# second-level suffixes and filename patterns without losing the shipped ones.
# ---------------------------------------------------------------------------
$script:SysOrgSourceMapCache = @{}

$script:SysOrgBuiltinSourceHosts = @{
    'github.com'='GitHub'; 'raw.githubusercontent.com'='GitHub'; 'objects.githubusercontent.com'='GitHub'
    'codeload.github.com'='GitHub'; 'gist.github.com'='GitHub'
    'z.ai'='Z-AI'; 'chat.z.ai'='Z-AI'; 'meta.ai'='Meta-AI'; 'claude.ai'='Claude'
    'chatgpt.com'='OpenAI'; 'openai.com'='OpenAI'; 'gemini.google.com'='Gemini'; 'gemini.googleusercontent.com'='Gemini'
    'whatsapp.com'='WhatsApp'; 'web.whatsapp.com'='WhatsApp'; 'cdn.whatsapp.net'='WhatsApp'
    'telegram.org'='Telegram'; 't.me'='Telegram'; 'cdn-telegram.org'='Telegram'
    'signal.org'='Signal'; 'updates.signal.org'='Signal'
    'discord.com'='Discord'; 'discordapp.com'='Discord'; 'cdn.discordapp.com'='Discord'
    'dropbox.com'='Dropbox'; 'dl.dropboxusercontent.com'='Dropbox'
    'drive.google.com'='GoogleDrive'; 'docs.google.com'='GoogleDrive'
    'onedrive.live.com'='OneDrive'; '1drv.ms'='OneDrive'
    'live.com'='Microsoft'; 'sharepoint.com'='Microsoft'; 'office.com'='Microsoft'; 'microsoft.com'='Microsoft'
    'slack.com'='Slack'; 'files.slack.com'='Slack'
    'reddit.com'='Reddit'; 'i.redd.it'='Reddit'
    'steamcontent.com'='Steam'; 'steampowered.com'='Steam'
    'zoom.us'='Zoom'; 'archive.org'='InternetArchive'
}

$script:SysOrgBuiltinSourceSuffixes = @{
    'co.uk'=$true;'org.uk'=$true;'ac.uk'=$true;'gov.uk'=$true;'me.uk'=$true;'net.uk'=$true;'ltd.uk'=$true;'plc.uk'=$true
    'com.au'=$true;'net.au'=$true;'org.au'=$true;'edu.au'=$true;'gov.au'=$true
    'co.nz'=$true;'net.nz'=$true;'org.nz'=$true
    'co.za'=$true;'org.za'=$true;'ac.za'=$true;'gov.za'=$true
    'co.ke'=$true;'or.ke'=$true;'go.ke'=$true;'ac.ke'=$true;'ne.ke'=$true;'sc.ke'=$true;'info.ke'=$true
    'com.ng'=$true;'org.ng'=$true;'gov.ng'=$true;'edu.ng'=$true;'net.ng'=$true
    'co.in'=$true;'net.in'=$true;'org.in'=$true;'gov.in'=$true;'ac.in'=$true;'firm.in'=$true
    'com.br'=$true;'net.br'=$true;'org.br'=$true;'gov.br'=$true
    'com.mx'=$true;'org.mx'=$true;'net.mx'=$true
    'com.tr'=$true;'net.tr'=$true;'org.tr'=$true
    'co.kr'=$true;'ne.kr'=$true;'or.kr'=$true
    'co.jp'=$true;'ne.jp'=$true;'or.jp'=$true;'ac.jp'=$true;'go.jp'=$true
    'com.sg'=$true;'net.sg'=$true;'org.sg'=$true;'gov.sg'=$true
    'com.cn'=$true;'net.cn'=$true;'org.cn'=$true;'gov.cn'=$true
    'com.ar'=$true;'net.ar'=$true;'org.ar'=$true
    'com.hk'=$true;'org.hk'=$true;'net.hk'=$true
    'co.id'=$true;'or.id'=$true;'web.id'=$true
    'com.my'=$true;'org.my'=$true;'net.my'=$true
    'com.ph'=$true;'org.ph'=$true;'net.ph'=$true
    'com.tw'=$true;'org.tw'=$true;'net.tw'=$true
    'com.vn'=$true;'net.vn'=$true;'org.vn'=$true
    'com.pk'=$true;'net.pk'=$true;'org.pk'=$true
    'com.eg'=$true;'net.eg'=$true;'org.eg'=$true
    'co.th'=$true;'or.th'=$true;'ac.th'=$true
    'com.ua'=$true;'net.ua'=$true;'org.ua'=$true
    'co.il'=$true;'org.il'=$true;'net.il'=$true;'ac.il'=$true
    'com.co'=$true;'net.co'=$true;'org.co'=$true
}

$script:SysOrgBuiltinSourcePatterns = @(
    @{ Pattern='^whatsapp';   Bucket='WhatsApp' }
    @{ Pattern='wa\d{4}';     Bucket='WhatsApp' }
    @{ Pattern='^telegram';   Bucket='Telegram' }
    @{ Pattern='^signal-';    Bucket='Signal' }
    @{ Pattern='^screenshot'; Bucket='Screenshots' }
)

function Get-SysOrgSourceMap {
<#
.SYNOPSIS
    Loads the extensible source-bucket map (Rules\Sources.psd1) over the built-ins.
.DESCRIPTION
    Resolution: config Rules.SourcesPath, or <AppRoot>\Rules\Sources.psd1. A missing
    file yields the built-in defaults; a file that exists but cannot be parsed, or
    that has the wrong shape, THROWS (fail closed - a broken source map is a broken
    rule set). File entries merge over the built-ins per key: Hosts and
    SecondLevelSuffixes by host/suffix key, FileNamePatterns appended after the
    built-in patterns. Results are cached per (path, file mtime).
.EXAMPLE
    $map = Get-SysOrgSourceMap -Config $cfg -AppRoot 'C:\SysOrg'
    $map.Hosts['z.ai']   # -> 'Z-AI'
#>
    [CmdletBinding()]
    param($Config,[string]$AppRoot)
    $path = "$(Get-SysOrgSetting $Config 'Rules.SourcesPath' '')"
    if([string]::IsNullOrWhiteSpace($path) -and $AppRoot){ $path = (Join-Path $AppRoot 'Rules\Sources.psd1') }
    $hosts = $script:SysOrgBuiltinSourceHosts.Clone()
    $suffixes = $script:SysOrgBuiltinSourceSuffixes.Clone()
    $patterns = @($script:SysOrgBuiltinSourcePatterns)
    if([string]::IsNullOrWhiteSpace($path) -or (-not (Test-Path -LiteralPath $path))){
        return [pscustomobject]@{ Hosts=$hosts; SecondLevelSuffixes=$suffixes; FileNamePatterns=$patterns; SourceFile='' }
    }
    $mtime = (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc.Ticks
    $cacheKey = ('{0}|{1}' -f $path, $mtime)
    if($script:SysOrgSourceMapCache.ContainsKey($cacheKey)){ return $script:SysOrgSourceMapCache[$cacheKey] }
    $loaded = $null
    try { $loaded = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop }
    catch { throw ("Source map file '{0}' could not be parsed: {1} (fix the file or remove it to use the built-in defaults)." -f $path, $_.Exception.Message) }
    if($loaded -isnot [hashtable]){ throw ("Source map file '{0}' must be a hashtable with Hosts / SecondLevelSuffixes / FileNamePatterns." -f $path) }
    if($loaded.ContainsKey('Hosts') -and ($loaded['Hosts'] -is [hashtable])){
        foreach($k in $loaded['Hosts'].Keys){ $hosts[[string]$k] = [string]$loaded['Hosts'][$k] }
    }
    if($loaded.ContainsKey('SecondLevelSuffixes') -and ($loaded['SecondLevelSuffixes'] -is [hashtable])){
        foreach($k in $loaded['SecondLevelSuffixes'].Keys){ $suffixes[[string]$k] = $true }
    }
    if($loaded.ContainsKey('FileNamePatterns') -and ($loaded['FileNamePatterns'] -is [System.Collections.IEnumerable])){
        foreach($p in @($loaded['FileNamePatterns'])){
            if($p -is [hashtable] -and (-not [string]::IsNullOrWhiteSpace("$($p['Pattern'])"))){
                $patterns += @{ Pattern=[string]$p['Pattern']; Bucket=[string]$p['Bucket'] }
            }
        }
    }
    $map = [pscustomobject]@{ Hosts=$hosts; SecondLevelSuffixes=$suffixes; FileNamePatterns=$patterns; SourceFile=$path }
    $script:SysOrgSourceMapCache[$cacheKey] = $map
    return $map
}

function Get-SysOrgSourceBucket {
<#
.SYNOPSIS
    Maps download provenance to a source bucket name (Downloads branch).
.DESCRIPTION
    Resolution order: Zone.Identifier HostUrl, then ReferrerUrl (exact host map, then the
    registrable domain), then filename heuristics (WhatsApp, Telegram, Signal, Screenshots).
    v2.1.1: multi-label public suffixes are honored (www.kra.go.ke -> Kra, not Go), IP
    addresses and localhost fall through to the filename heuristics instead of producing
    buckets like '1' or 'Localhost', and every bucket passes through
    Get-SysOrgSafeFolderName so reserved device names ('nul', 'con', ...) come out safe.
    v3.0.1 A4: the host/suffix/pattern maps are extensible via Rules\Sources.psd1
    (pass -Config/-AppRoot to load it); AI sources (z.ai, meta.ai, claude.ai,
    chatgpt.com/openai.com, gemini.google.com) are built in. A derived bucket name
    SHORTER THAN 3 characters (e.g. 'q' from 'q.io') is replaced by the FULL HOST
    label, so single-letter folders never appear in the tree.
    Returns $null when nothing matches - the caller decides the fallback routing.
.EXAMPLE
    Get-SysOrgSourceBucket -HostUrl 'https://github.com/x/y/releases/download/1/f.zip'   # -> 'GitHub'
.EXAMPLE
    Get-SysOrgSourceBucket -HostUrl 'https://chat.z.ai/f/x' -Config $cfg -AppRoot 'C:\SysOrg'   # -> 'Z-AI'
#>
    [CmdletBinding()]
    param([string]$HostUrl,[string]$ReferrerUrl,[string]$FileName,$Config,[string]$AppRoot)
    $map = Get-SysOrgSourceMap -Config $Config -AppRoot $AppRoot
    $hostMap = $map.Hosts
    $secondLevelSuffixes = $map.SecondLevelSuffixes
    $u = $null
    foreach($c in @($HostUrl,$ReferrerUrl)){ if("$c"){ $u = "$c"; break } }
    if($u){
        try{
            if($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://'){ $u = 'https://' + $u }
            $uri = [uri]$u
            $h = $uri.Host.ToLowerInvariant()
            if($hostMap.ContainsKey($h)){ return (Get-SysOrgSafeFolderName -Name ([string]$hostMap[$h]) -MaxLength 60) }
            foreach($pfx in @('cdn.','dl.','download.','downloads.','www.','data.','assets.','static.','media.')){
                if($h.StartsWith($pfx)){ $h = $h.Substring($pfx.Length); break }
            }
            if($hostMap.ContainsKey($h)){ return (Get-SysOrgSafeFolderName -Name ([string]$hostMap[$h]) -MaxLength 60) }
            $parts = $h.Split('.')
            $name = $null
            # v2.1.1: IP addresses and localhost have no registrable domain - leave the
            # name empty so the URL branch returns nothing and the FILENAME heuristics run.
            if(($h -match '^\d{1,3}(\.\d{1,3}){3}$') -or ($h -eq 'localhost') -or ($h.Contains(':'))){
                $name = $null
            }
            elseif(($parts.Count -ge 3) -and $secondLevelSuffixes.ContainsKey(($parts[($parts.Count - 2)..($parts.Count - 1)] -join '.'))){
                $name = $parts[$parts.Count - 3]
            }
            elseif($parts.Count -ge 2){ $name = $parts[$parts.Count - 2] }
            else { $name = $parts[0] }
            if($name -and ("$name" -ne '')){
                $ti = (Get-Culture).TextInfo
                # v3.0.1 A4: a derived label shorter than 3 characters ('q' from 'q.io')
                # is too generic for a folder - use the full host as the label instead.
                $label = "$name"
                if($label.Length -lt 3){ $label = $h }
                if($label.Length -lt 3){ return $null }   # the whole host is shorter than 3 chars
                # v2.1.1: sanitize - reserved device names ('nul.com' -> Nul) must never
                # become destination folder names.
                if($label -eq $h){ return (Get-SysOrgSafeFolderName -Name $label -MaxLength 60) }
                return (Get-SysOrgSafeFolderName -Name ($ti.ToTitleCase("$label")) -MaxLength 60)
            }
        } catch { Write-Verbose "Source bucket parse failed for '$u': $($_.Exception.Message)" }
    }
    if($FileName){
        foreach($fp in @($map.FileNamePatterns)){
            if("$FileName" -imatch "$($fp.Pattern)"){ return ([string]$fp.Bucket) }
        }
    }
    return $null
}

function Find-SysOrgDuplicates {
<#
.SYNOPSIS
    Exact duplicate detection: size -> 64 KB header hash -> head+tail hash -> full SHA256.
.DESCRIPTION
    Rev 2.1 keeper rule (W6): the keeper is the OLDEST LastWriteTime, then natural name
    order - the original is the one the user created first. WastedBytes reports the
    reclaimable size per group. Only hashes candidate files; cloud placeholders never
    reach this stage.
    v3.0 speed work (Phase 3.1/3.4/3.5): every hash is looked up in the persistent
    file-state cache FIRST (key = path|size|mtime, so unchanged files are never
    re-read); the pre-filter adds a head+tail hash before the full SHA256; and the
    full-hash stage runs through a RunspacePool (results stay in input order -
    deterministic). -FileCache/-NewEntries/-CachePath are optional: without them the
    behaviour is identical to v2.1.1.
.EXAMPLE
    $dups = Find-SysOrgDuplicates -Inventory $inv -Config $cfg -FileCache $c -NewEntries $n -Parallelism 3
#>
    [CmdletBinding()]
    param($Inventory,$Config,$FileCache,[hashtable]$NewEntries,[int]$Parallelism=1,[long]$BytesHashed=[long]0)
    $groups = New-Object System.Collections.Generic.List[object]
    $minKB    = Get-SysOrgSetting $Config 'Copies.MinFileSizeKB' 256
    $headerKB = Get-SysOrgSetting $Config 'Copies.HeaderHashKB' 64
    $minBytes = [int64]$minKB * 1KB

    $sizeCandidates = @($Inventory | Where-Object { $_.Category -ne 'SkippedLongPath' -and $_.Length -ge $minBytes } | Group-Object -Property Length | Where-Object { $_.Count -gt 1 })
    $total = $sizeCandidates.Count; $done = 0
    $fullCandidates = New-Object System.Collections.Generic.List[object]      # records needing a full hash
    $headTailMap = @{}                                                        # path -> head+tail hash

    foreach($sizeGroup in $sizeCandidates){
        $done++
        Write-Progress -Activity 'Duplicate detection' `
            -Status "Size group $($sizeGroup.Name) bytes ($done of $total)" `
            -PercentComplete $(if($total -gt 0){ [int](100 * $done / $total) } else { 0 })
        $headerMap = @{}
        foreach($f in $sizeGroup.Group){
            $hh = $null
            # v3.0: header hash through the cache first
            if($FileCache){
                try{
                    $fi = Get-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $k = Get-SysOrgFileCacheKey -Path $f.FullName -Length ([long]$fi.Length) -LastWriteTimeUtc $fi.LastWriteTimeUtc
                    if($FileCache.ContainsKey($k)){
                        $e = $FileCache[$k]
                        if($e.PSObject.Properties['HeaderHash'] -and "$($e.HeaderHash)"){ $hh = "$($e.HeaderHash)" }
                    }
                } catch { $hh = $null }
            }
            if(-not $hh){
                $hh = Get-SysOrgFileHash -Path $f.FullName -HeaderOnly -HeaderKB $headerKB
                if(($hh) -and $FileCache){
                    try{
                        $fi = Get-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                        $k = Get-SysOrgFileCacheKey -Path $f.FullName -Length ([long]$fi.Length) -LastWriteTimeUtc $fi.LastWriteTimeUtc
                        $e = $FileCache[$k]
                        if($e){ $e.HeaderHash = $hh } else { $FileCache[$k] = [pscustomobject]@{ Hash=''; HeaderHash=$hh; HeadTailHash=''; Meta=$null } }
                    } catch { }
                }
            }
            if($hh){
                if(-not $headerMap.ContainsKey($hh)){ $headerMap[$hh] = New-Object System.Collections.Generic.List[object] }
                [void]$headerMap[$hh].Add($f)
            }
        }
        foreach($h in $headerMap.Keys){
            $candidates = $headerMap[$h]
            if($candidates.Count -lt 2){ continue }
            # v3.0 Phase 3.5: head+tail hash separates files with identical headers
            foreach($f in $candidates){
                $ht = $null
                if($FileCache){
                    try{
                        $fi = Get-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                        $k = Get-SysOrgFileCacheKey -Path $f.FullName -Length ([long]$fi.Length) -LastWriteTimeUtc $fi.LastWriteTimeUtc
                        if($FileCache.ContainsKey($k)){
                            $e = $FileCache[$k]
                            if($e.PSObject.Properties['HeadTailHash'] -and "$($e.HeadTailHash)"){ $ht = "$($e.HeadTailHash)" }
                        }
                    } catch { $ht = $null }
                }
                if(-not $ht){
                    $ht = Get-SysOrgFileHashHeadTail -Path $f.FullName -HeaderKB $headerKB -TailKB $headerKB
                    if(($ht) -and $FileCache){
                        try{
                            $fi = Get-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                            $k = Get-SysOrgFileCacheKey -Path $f.FullName -Length ([long]$fi.Length) -LastWriteTimeUtc $fi.LastWriteTimeUtc
                            $e = $FileCache[$k]
                            if($e){ $e.HeadTailHash = $ht } else { $FileCache[$k] = [pscustomobject]@{ Hash=''; HeaderHash=$h; HeadTailHash=$ht; Meta=$null } }
                        } catch { }
                    }
                }
                $headTailMap[$f.FullName] = $ht
            }
            $htGroups = @($candidates | Group-Object -Property { $headTailMap[$_.FullName] } | Where-Object { $_.Count -gt 1 })
            foreach($htg in $htGroups){
                foreach($f in @($htg.Group)){ [void]$fullCandidates.Add($f) }
            }
        }
    }
    Write-Progress -Activity 'Duplicate detection' -Completed

    # v3.0 Phase 3.4: full hashes come from the cache when fresh; ONLY the misses go
    # through the RunspacePool (results in input order, deterministic), then group by
    # size + head/tail + full hash.
    $uniqueFull = @(@($fullCandidates.ToArray()) | Sort-Object -Property FullName -Unique)
    $fullMap = @{}
    $toHash = New-Object System.Collections.Generic.List[string]
    foreach($rec in $uniqueFull){
        $p2 = "$($rec.FullName)"
        if($FileCache){
            try{
                $fi = Get-Item -LiteralPath $p2 -Force -ErrorAction Stop
                $k2 = Get-SysOrgFileCacheKey -Path $p2 -Length ([long]$fi.Length) -LastWriteTimeUtc $fi.LastWriteTimeUtc
                if($FileCache.ContainsKey($k2)){
                    $e2 = $FileCache[$k2]
                    if($e2.PSObject.Properties['Hash'] -and "$($e2.Hash)"){ $fullMap[$p2] = "$($e2.Hash)"; continue }
                }
            } catch { }
        }
        $toHash.Add($p2)
    }
    if($toHash.Count -gt 0){
        $paths = @($toHash.ToArray())
        $hashes = Invoke-SysOrgParallelHash -Paths $paths -Parallelism $Parallelism
        for($i=0; $i -lt $paths.Count; $i++){
            if($hashes[$i]){
                # store into the cache (the full hash is the expensive one)
                if($FileCache){
                    try{
                        $fi = Get-Item -LiteralPath $paths[$i] -Force -ErrorAction Stop
                        $k = Get-SysOrgFileCacheKey -Path $paths[$i] -Length ([long]$fi.Length) -LastWriteTimeUtc $fi.LastWriteTimeUtc
                        $e = $FileCache[$k]
                        if($e){ $e.Hash = $hashes[$i] } else { $FileCache[$k] = [pscustomobject]@{ Hash=$hashes[$i]; HeaderHash=''; HeadTailHash=''; Meta=$null } }
                    } catch { }
                }
                $fullMap[$paths[$i]] = $hashes[$i]
            }
        }
    }

    # group survivors: same size + same head/tail + same full hash
    $byKey = @{}
    foreach($f in $fullCandidates.ToArray()){
        $fh = $fullMap["$($f.FullName)"]
        if(-not $fh){ continue }
        $key = ('{0}|{1}|{2}' -f $f.Length, $headTailMap[$f.FullName], $fh)
        if(-not $byKey.ContainsKey($key)){ $byKey[$key] = New-Object System.Collections.Generic.List[object] }
        [void]$byKey[$key].Add($f)
    }
    foreach($key in ($byKey.Keys | Sort-Object)){
        $dupes = $byKey[$key].ToArray()
        if($dupes.Count -lt 2){ continue }
        # W6: keeper = oldest LastWriteTime, then natural name order (W7 key)
        $withKeys = New-Object System.Collections.Generic.List[object]
        foreach($d in $dupes){
            [void]$withKeys.Add([pscustomobject]@{ Rec=$d; Key=(Get-SysOrgNaturalKey -Name "$($d.FullName)") })
        }
        $sorted = @($withKeys | Sort-Object -Property @{e={$_.Rec.LastWriteTime.Ticks}}, @{e={$_.Key}})
        $keep   = $sorted[0].Rec
        $others = @($sorted | Select-Object -Skip 1 | ForEach-Object { $_.Rec })
        $wasted = [int64]0
        if($others.Count -gt 0){ $wasted = [int64]($others | Measure-Object -Property Length -Sum).Sum }
        $groups.Add([pscustomobject]@{
            Hash=$key.Substring($key.LastIndexOf('|') + 1); KeepPath=$keep.FullName; KeepName=$keep.Name
            KeepReason='Oldest LastWriteTime, then natural name order (the original the user created first)'
            Duplicates=@($others | ForEach-Object { "$($_.FullName)" })
            WastedBytes=$wasted
        })
    }
    # Stream groups (see Get-SysOrgInventory for why 'return ,$array' is wrong):
    # callers collect with @(); an empty result emits nothing.
    return $groups.ToArray()
}

Export-ModuleMember -Function *-SysOrg*
