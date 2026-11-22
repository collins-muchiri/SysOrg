#Requires -Version 5.1
# SysOrg.Layout.psm1 - the Findable layout (v3.0 Phase 1).
#
# LayoutProfile = Windows | Compact4 | Findable.
#   Windows/Compact4 are the legacy v2.1 layouts (NamingPreset governs them).
#   Findable is the new layout: depth <= 4 below the root, at most 10 routing
#   roots, ISO dates (YYYY / YYYY-MM / YYYY-MM-DD) with ADAPTIVE granularity,
#   a 200-character path budget with deterministic hash-suffixed shortening,
#   and "needs a decision" handling instead of a junk folder.
#
# Determinism: every decision is a pure function of the routed set - leaves are
# iterated in sorted order and all tie-breaks are natural-sorted.

# The Findable routing roots, in stable order. Downloads and _Index are part of
# the tree but app-managed (existing provenance branch / index folder) and do not
# count against the 10-root cap: Documents, Pictures, Videos, Music,
# Audio-Recordings, Data, Software, Archives, Code, Design.
$script:FindableRoots = @('Documents','Pictures','Videos','Music','Audio-Recordings','Data','Software','Archives','Code','Design')
$script:FindableExemptRoots = @('Downloads','_Index','_Review','_Duplicates','_Reports')

function Get-SysOrgLayoutProfile {
<#
.SYNOPSIS
    Resolves the active LayoutProfile from config (v3.0 Phase 1).
.DESCRIPTION
    - An explicit LayoutProfile ('Windows' | 'Compact4' | 'Findable') always wins.
    - Without one, NamingPreset='Compact4' maps to the Compact4 profile (legacy
      configs keep working unchanged).
    - Otherwise 'Windows' - the v2.1 behaviour.
    New installs default to 'Findable' because Import-SysOrgConfig only injects the
    Findable default when NO config file was loaded; a config file that does not
    carry the key keeps its current (Windows) profile.
.EXAMPLE
    Get-SysOrgLayoutProfile -Config $cfg   # -> 'Findable'
#>
    param($Config)
    $explicit = Get-SysOrgSetting $Config 'LayoutProfile' $null
    if($explicit -and ("$explicit" -ne '')){
        $v = "$explicit"
        if(@('Windows','Compact4','Findable') -notcontains $v){ throw ("LayoutProfile must be Windows, Compact4, or Findable (got '$v').") }
        return $v
    }
    if("$(Get-SysOrgSetting $Config 'NamingPreset' 'Windows')" -eq 'Compact4'){ return 'Compact4' }
    return 'Windows'
}

function Get-SysOrgFindableTopLevel {
<#
.SYNOPSIS
    Returns the Findable routing roots (max 10) and the app-managed exempt roots.
.EXAMPLE
    Get-SysOrgFindableTopLevel   # -> @{ Roots=@(...); Exempt=@(...); RootCap=10 }
#>
    return @{
        Roots  = $script:FindableRoots
        Exempt = $script:FindableExemptRoots
        RootCap = 10
    }
}

function Get-SysOrgFindableSubtype {
<#
.SYNOPSIS
    Derives the Findable subtype for one file from its category, filename and
    source bucket (v3.0 Phase 1 - filename heuristics; the Phase 2 Decision
    pipeline feeds richer signals into the same contract).
.DESCRIPTION
    Deterministic token matching on the lowercased stem. 'SKIP' categories and
    long-path records never reach this function. Data-type files (csv/xlsx/json/db
    exports) route to Data via the EXTENSION even though the scanner routes them
    to the Documents category (the Windows routing set has no Spreadsheets leaf).
.EXAMPLE
    Get-SysOrgFindableSubtype -Category 'Documents' -Name 'KRA PAYE return 2024.pdf' -Source $null   # -> 'Finance\Tax'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Category,[Parameter(Mandatory)][string]$Name,[string]$Source,[string]$Extension)
    $stem = ([System.IO.Path]::GetFileNameWithoutExtension("$Name")).ToLowerInvariant()
    $ext = "$Extension".ToLowerInvariant()
    if(($Category -eq 'Documents') -and ($ext -in @('.csv','.tsv','.xlsx','.xls','.ods','.db','.sqlite','.json','.mdb','.accdb'))){
        return 'Data'
    }
    if($Category -eq 'Pictures'){
        if($stem -match '(^|[^a-z])screenshot'){ return 'Screenshots' }
        if($Source){ return 'Messaging' }
        if($stem -match '(^|[^a-z])scan([^a-z]|$)'){ return 'Scans' }
        if($stem -match '(edited|photoshopped|lightroom|retouch)'){ return 'Edited' }
        return 'Camera'
    }
    if($Category -eq 'Videos'){
        if($stem -match '(screen ?rec|screen ?capt|screenrecord)'){ return 'Screen-Recordings' }
        if($Source){ return 'Messaging' }
        return 'Media'
    }
    if(($Category -eq 'Audio') -or ($Category -eq 'Music')){
        # tagged music arrives as Music with Artist/Album metadata (Phase 2.4 feeds
        # Subtype='TaggedMusic'); untagged audio and voice-note naming rules decide here
        if($stem -match '^(voice|voice ?note|voice ?memo|whatsapp|telegram|signal|record|meeting|call)'){ return 'VoiceNote' }
        return 'UntaggedMusic'
    }
    if($Category -eq 'Documents'){
        if($stem -match 'invoice'){ return 'Finance\Invoices' }
        if($stem -match 'receipt'){ return 'Finance\Receipts' }
        if($stem -match 'statement'){ return 'Finance\Statements' }
        if($stem -match '(tax|paye|kra|vat|nhif|nssf|withholding)'){ return 'Finance\Tax' }
        if($stem -match '(contract|agreement|certificate|passport|identity|id ?scan|deed|licence|license|permit)'){ return 'Legal-Identity' }
        if($stem -match '(manual|handbook|user ?guide|quick ?start)'){ return 'Manuals' }
        if($stem -match '(book|novel|textbook|epub)'){ return 'Books' }
        if($stem -match '(thesis|dissertation|syllabus|course|lecture|assignment|exam|school|university|college)'){ return 'Education' }
        if($stem -match '(work|meeting|minutes|proposal|report|memo)'){ return 'Work' }
        return 'General'
    }
    if($Category -eq 'Spreadsheets'){ return 'Data' }
    if($Category -eq 'Databases'){ return 'Data' }
    if($Category -eq 'Installers'){
        if($stem -match 'driver'){ return 'Drivers' }
        return 'InstallerApp'
    }
    if($Category -eq 'Fonts'){ return 'Fonts' }
    if($Category -eq 'Code'){ return 'CodeFile' }
    if($Category -eq 'Archives'){ return 'Archive' }
    return 'Unsorted'
}

function Get-SysOrgFindableTypeLeaf {
<#
.SYNOPSIS
    The Type segment of the Downloads provenance branch (Downloads\<Source>\<Type>).
.EXAMPLE
    Get-SysOrgFindableTypeLeaf -Category 'Spreadsheets'   # -> 'Data'
#>
    param([Parameter(Mandatory)][string]$Category)
    switch($Category){
        'Pictures'     { return 'Pictures' }
        'Videos'       { return 'Videos' }
        'Music'        { return 'Music' }
        'Audio'        { return 'Audio-Recordings' }
        'Documents'    { return 'Documents' }
        'Spreadsheets' { return 'Data' }
        'Databases'    { return 'Data' }
        'Installers'   { return 'Software' }
        'Fonts'        { return 'Design' }
        'Code'         { return 'Code' }
        'Archives'     { return 'Archives' }
        default        { return 'Files' }
    }
}

function Get-SysOrgFindableRelBase {
<#
.SYNOPSIS
    Maps one routed file to its Findable leaf folder (WITHOUT the date segment).
.DESCRIPTION
    Returns @{ RelBase=<string>; TakesDate=<bool> } where RelBase is relative to
    the destination root. Messaging and Downloads branches include the source
    bucket; music carries artist/album when metadata exists (Subtype='TaggedMusic').
.EXAMPLE
    Get-SysOrgFindableRelBase -Category 'Documents' -Subtype 'Finance\Invoices'   # -> Documents\Finance\Invoices
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Category,[Parameter(Mandatory)][string]$Subtype,
          [string]$Source,[string]$Artist,[string]$Album,[string]$Name,
          [bool]$InDownloads,[string]$TypeLeaf)
    if($InDownloads){
        # existing provenance branch: Downloads\<Source>\<Type>
        $src = $Source
        if([string]::IsNullOrWhiteSpace($src)){ $src = '_NoSource' }
        $leaf = $TypeLeaf
        if([string]::IsNullOrWhiteSpace($leaf)){ $leaf = 'Files' }
        return @{ RelBase=('Downloads\{0}\{1}' -f (Get-SysOrgSafeFolderName -Name $src -MaxLength 40), $leaf); TakesDate=$true }
    }
    if($Subtype -eq 'TaggedMusic'){
        $a = Get-SysOrgSafeFolderName -Name "$Artist" -MaxLength 60
        $al = Get-SysOrgSafeFolderName -Name "$Album" -MaxLength 60
        if([string]::IsNullOrWhiteSpace($a)){ $a = '_UnknownArtist' }
        if([string]::IsNullOrWhiteSpace($al)){ $al = '_UnknownAlbum' }
        return @{ RelBase=('Music\{0}\{1}' -f $a, $al); TakesDate=$false }
    }
    if($Subtype -eq 'UntaggedMusic'){ return @{ RelBase='Music\_Untagged'; TakesDate=$true } }
    if($Subtype -eq 'VoiceNote'){ return @{ RelBase='Audio-Recordings'; TakesDate=$true } }
    if($Category -eq 'Documents' -and $Subtype -eq 'Data'){ return @{ RelBase='Data'; TakesDate=$true } }
    switch($Category){
        'Pictures' {
            if($Subtype -eq 'Messaging'){ return @{ RelBase=('Pictures\Messaging\{0}' -f (Get-SysOrgSafeFolderName -Name "$Source" -MaxLength 40)); TakesDate=$true } }
            return @{ RelBase=('Pictures\{0}' -f $Subtype); TakesDate=$true }
        }
        'Videos' {
            if($Subtype -eq 'Messaging'){ return @{ RelBase=('Videos\Messaging\{0}' -f (Get-SysOrgSafeFolderName -Name "$Source" -MaxLength 40)); TakesDate=$true } }
            return @{ RelBase=('Videos\{0}' -f $Subtype); TakesDate=$true }
        }
        'Audio' { return @{ RelBase='Audio-Recordings'; TakesDate=$true } }
        'Music' { return @{ RelBase='Music\_Untagged'; TakesDate=$true } }
        'Documents' { return @{ RelBase=('Documents\{0}' -f $Subtype); TakesDate=$true } }
        'Spreadsheets' { return @{ RelBase='Data'; TakesDate=$true } }
        'Databases'    { return @{ RelBase='Data'; TakesDate=$true } }
        'Installers' {
            # Software\Installers\<App> - the app token is the first meaningful word of
            # the stem (generic installer words like 'setup' are skipped)
            $app = 'Unknown'
            $stem = ([System.IO.Path]::GetFileNameWithoutExtension("$Name")).ToLowerInvariant()
            $tokens = @([System.Text.RegularExpressions.Regex]::Split($stem, '[^a-z0-9]+') | Where-Object { "$_" -match '^[a-z][a-z0-9]{2,}$' })
            $generic = @('setup','install','installer','installers','freeware','win','win32','win64','x64','x86','full','final')
            foreach($tk in $tokens){
                if($generic -contains $tk){ continue }
                $app = $tk
                break
            }
            if($Subtype -eq 'Drivers'){ return @{ RelBase='Software\Drivers'; TakesDate=$false } }
            return @{ RelBase=('Software\Installers\{0}' -f (Get-SysOrgSafeFolderName -Name ([System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($app)) -MaxLength 40)); TakesDate=$false }
        }
        'Fonts' { return @{ RelBase='Design\Fonts'; TakesDate=$false } }
        'Code'  { return @{ RelBase='Code\Files'; TakesDate=$true } }
        'Archives' { return @{ RelBase='Archives'; TakesDate=$true } }
        'Images' { return @{ RelBase=('Pictures\{0}' -f $Subtype); TakesDate=$true } }
        default  { return @{ RelBase='Documents\General'; TakesDate=$true } }
    }
}

function Test-SysOrgDateBuckets {
<#
.SYNOPSIS
    Buckets routed entries by an ISO date format; internal helper of the layout engine.
#>
    param([AllowEmptyCollection()]$Entries,[ValidateSet('yyyy','yyyy-MM','yyyy-MM-dd')][string]$Fmt)
    $b = @{}
    foreach($e in $Entries){
        $s = ([datetime]$e.Date).ToString($Fmt, [System.Globalization.CultureInfo]::InvariantCulture)
        if(-not $b.ContainsKey($s)){ $b[$s] = 0 }
        $b[$s]++
    }
    return $b
}

function Add-SysOrgFindableDateSegments {
<#
.SYNOPSIS
    Computes the adaptive date segment for a whole routed set (v3.0 Phase 1).
.DESCRIPTION
    Per leaf folder (the RelBase), the granularity starts at Year (YYYY). A leaf
    holding more than Layout.MaxFilesPerFolder (default 150) splits to YYYY-MM;
    a month bucket that still exceeds the cap splits to YYYY-MM-DD (the finest
    date granularity - a single-day burst above the cap is reported by the
    findability score rather than split by non-date chunks).
    Merge-back: if a split would leave MOST buckets below Layout.MinFilesPerFolder
    (default 8), it is undone one level (month back to year) unless the bucket it
    merges into exceeds the cap - the cap always wins, deterministically.
    Leaf keys marked Family=$true (family folders, which keep related files
    together) receive NO date segment unless they themselves exceed the cap.
    Input: a list of @{ Key=<leaf key>; FileKey=<unique file key>; Date=<datetime>;
    Family=<bool> } records. Output: hashtable leafKey -> hashtable FileKey -> date
    segment string ('' = none).
.EXAMPLE
    $seg = Add-SysOrgFindableDateSegments -Records $recs -Cap 150 -MinPerFolder 8
#>
    [CmdletBinding()]
    param([AllowEmptyCollection()]$Records,[int]$Cap=150,[int]$MinPerFolder=8)

    $byLeaf = @{}
    foreach($r in @($Records)){
        # leaf keys are case-insensitive (Windows paths): normalize to lowercase
        $k = ([string]$r.Key).ToLowerInvariant()
        if(-not $byLeaf.ContainsKey($k)){ $byLeaf[$k] = New-Object System.Collections.Generic.List[object] }
        [void]$byLeaf[$k].Add($r)
    }
    $result = @{}
    foreach($leafKey in ($byLeaf.Keys | Sort-Object)){
        # @() on a generic List[object] throws 'Argument types do not match' - use ToArray
        $items = $byLeaf[$leafKey].ToArray()
        $result[$leafKey] = @{}
        $n = $items.Count
        $isFamilyLeaf = [bool]($items[0].Family)

        if(($n -le $Cap) -or $isFamilyLeaf){
            if($n -le $Cap){
                # default granularity is Year; a family leaf stays date-free so related
                # files stay together
                if($isFamilyLeaf){
                    foreach($e in $items){ $result[$leafKey][$e.FileKey] = '' }
                } else {
                    foreach($e in $items){ $result[$leafKey][$e.FileKey] = ([datetime]$e.Date).ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture) }
                }
                continue
            }
            # an over-cap family leaf keeps the family together but gains year folders
            foreach($e in $items){ $result[$leafKey][$e.FileKey] = ([datetime]$e.Date).ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture) }
            continue
        }

        # over cap: try months
        $months = Test-SysOrgDateBuckets -Entries $items -Fmt 'yyyy-MM'
        $overMonth = @($months.Keys | Where-Object { [int]$months[$_] -gt $Cap })
        if($overMonth.Count -gt 0){
            # cap wins: split to days (finest date granularity)
            foreach($e in $items){ $result[$leafKey][$e.FileKey] = ([datetime]$e.Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
            continue
        }
        # merge-back: would months leave most buckets below MinPerFolder?
        $monthKeys = @($months.Keys)
        $under = 0
        foreach($mk in $monthKeys){ if([int]$months[$mk] -lt $MinPerFolder){ $under++ } }
        if(($monthKeys.Count -gt 1) -and (($under / $monthKeys.Count) -gt 0.5)){
            foreach($e in $items){ $result[$leafKey][$e.FileKey] = ([datetime]$e.Date).ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture) }
            continue
        }
        foreach($e in $items){ $result[$leafKey][$e.FileKey] = ([datetime]$e.Date).ToString('yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture) }
    }
    return $result
}

function Compress-SysOrgFindablePath {
<#
.SYNOPSIS
    Shortens a destination path to the configured character budget (default 200).
.DESCRIPTION
    Long segments are shortened deterministically: truncation + a 6-hex SHA256
    suffix of the original segment, so different names never collapse to the same
    folder. Passes: (1) the longest non-date folder segment, (2) any folder
    segment, (3) the file name stem (extension preserved). The root is never
    touched. Different original segments always produce different hashes, so no
    two folders can collapse into the same shortened name.
.EXAMPLE
    Compress-SysOrgFindablePath -Path 'C:\org\Documents\<very long folder>\2024\report.pdf' -Budget 200
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[int]$Budget=200)
    function Get-SysOrgShortHashSuffix { param([string]$S)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try{
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($S.ToLowerInvariant())
            return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,6)
        } finally { $sha.Dispose() }
    }
    function ConvertTo-SysOrgShortSeg { param([string]$Seg,[int]$Keep)
        $h = Get-SysOrgShortHashSuffix $Seg
        $k = [Math]::Min($Seg.Length, [Math]::Max(4, $Keep))
        return ('{0}~{1}' -f $Seg.Substring(0, $k), $h)
    }
    $segments = @("$Path".Split('\'))
    $isodate = '^\d{4}(-\d{2}(-\d{2})?)?$'
    $lastIdx = $segments.Count - 1
    for($pass = 1; $pass -le 3; $pass++){
        if(("$Path").Length -le $Budget){ break }
        if($segments.Count -lt 3){ break }
        $idx = -1; $len = 0
        if($pass -lt 3){
            for($i = 1; $i -lt $lastIdx; $i++){
                $s = $segments[$i]
                if(($pass -eq 1) -and ($s -match $isodate)){ continue }
                if($s.Length -gt $len){ $idx = $i; $len = $s.Length }
            }
            if($idx -ge 0){ $segments[$idx] = ConvertTo-SysOrgShortSeg -Seg $segments[$idx] -Keep 16 }
        } else {
            $fn = $segments[$lastIdx]
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($fn)
            $ext = [System.IO.Path]::GetExtension($fn)
            if($stem.Length -gt 12){ $segments[$lastIdx] = (ConvertTo-SysOrgShortSeg -Seg $stem -Keep 12) + $ext }
            else { break }   # nothing left to shorten
        }
        $Path = ($segments -join '\')
    }
    return $Path
}

Export-ModuleMember -Function *-SysOrg*
