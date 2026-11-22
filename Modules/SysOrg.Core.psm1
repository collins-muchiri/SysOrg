#Requires -Version 5.1
# SysOrg.Core.psm1 - configuration (v2.1), logging, hashing, natural sort, mutability engine,
#                    exclusions, collision-safe moves (files and folders), ADS helpers.

function Merge-SysOrgHashtable {
<#
.SYNOPSIS
    Recursively merges the Override h[hashtable into Base (in place) and returns Base.
.DESCRIPTION
    Nested h[hashtables are merged key-by-key so a user override like
    Copies = @{ MinFileSizeKB = 999 } does not lose sibling defaults
    such as Copies.Policy. All other value types are replaced wholesale.
.EXAMPLE
    Merge-SysOrgHashtable -Base $defaults -Override $loadedFromConfigFile
#>
    param([hashtable]$Base,[hashtable]$Override)
    foreach($key in $Override.Keys){
        if($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Override[$key] -is [hashtable]){
            [void](Merge-SysOrgHashtable -Base $Base[$key] -Override $Override[$key])
        } else { $Base[$key] = $Override[$key] }
    }
    return $Base
}

function Test-SysOrgConfig {
<#
.SYNOPSIS
    Validates a merged SysOrg configuration h[hashtable. Throws on invalid values.
.DESCRIPTION
    Fails loudly at startup instead of misbehaving at move time. Covers the rev 2.1
    policy keys: NamingPreset, DestinationStyle, Copies.Policy, Copies.SuffixStyle,
    Downloads.GroupBy, Families.MinFiles >= 2, Families.CrossTypeLink, Copies.StartIndex >= 2,
    and the mutability Scope values (FullDrive is rejected under Policy.SystemDrive -
    whole-C organizing is not a supported scenario).
.EXAMPLE
    Test-SysOrgConfig -Config $cfg   # throws if any policy value is bad
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $errors = @()
    $dateMode = Get-SysOrgSetting $Config 'DateFolders' 'Year'
    if(@('Year','YearMonth','None') -notcontains $dateMode){ $errors += "DateFolders must be Year, YearMonth, or None (got '$dateMode')." }
    $naming = Get-SysOrgSetting $Config 'NamingPreset' 'Windows'
    if(@('Windows','Compact4') -notcontains $naming){ $errors += "NamingPreset must be Windows or Compact4 (got '$naming')." }
    $style = Get-SysOrgSetting $Config 'DestinationStyle' 'OrganizedRoot'
    if(@('OrganizedRoot','KnownFolders') -notcontains $style){ $errors += "DestinationStyle must be OrganizedRoot or KnownFolders (got '$style')." }
    $cpol = Get-SysOrgSetting $Config 'Copies.Policy' 'NumberCopies'
    if(@('NumberCopies','Quarantine','ReportOnly') -notcontains $cpol){ $errors += "Copies.Policy must be NumberCopies, Quarantine, or ReportOnly (got '$cpol')." }
    $cstyle = Get-SysOrgSetting $Config 'Copies.SuffixStyle' 'Parentheses'
    if(@('Parentheses','DashCopy') -notcontains $cstyle){ $errors += "Copies.SuffixStyle must be Parentheses or DashCopy (got '$cstyle')." }
    $groupBy = Get-SysOrgSetting $Config 'Downloads.GroupBy' 'SourceFirst'
    if(@('SourceFirst','TypeFirst') -notcontains $groupBy){ $errors += "Downloads.GroupBy must be SourceFirst or TypeFirst (got '$groupBy')." }
    $cross = Get-SysOrgSetting $Config 'Families.CrossTypeLink' 'SameName'
    if(@('SameName','Dominant') -notcontains $cross){ $errors += "Families.CrossTypeLink must be SameName or Dominant (got '$cross')." }
    $minFiles = Get-SysOrgSetting $Config 'Families.MinFiles' 2
    if(-not (($minFiles -is [int]) -or ($minFiles -is [long])) -or ($minFiles -lt 2)){ $errors += 'Families.MinFiles must be an integer >= 2 (got ' + $minFiles + ').' }
    $startIdx = Get-SysOrgSetting $Config 'Copies.StartIndex' 2
    if(-not (($startIdx -is [int]) -or ($startIdx -is [long])) -or ($startIdx -lt 2)){ $errors += 'Copies.StartIndex must be an integer >= 2 (got ' + $startIdx + ').' }
    $sysScope = Get-SysOrgSetting $Config 'Policy.SystemDrive.Scope' 'KnownFolders'
    if(@('KnownFolders','ExplicitPaths') -notcontains $sysScope){
        $errors += "Policy.SystemDrive.Scope must be KnownFolders or ExplicitPaths (got '$sysScope'); FullDrive is not supported on the system drive."
    }
    $dataScope = Get-SysOrgSetting $Config 'Policy.DataDrives.Scope' 'FullDrive'
    if(@('KnownFolders','ExplicitPaths','FullDrive') -notcontains $dataScope){ $errors += "Policy.DataDrives.Scope must be KnownFolders, ExplicitPaths, or FullDrive (got '$dataScope')." }
    $mainFolders = Get-SysOrgSetting $Config 'MainFolders' $null
    if($mainFolders){
        $expect = @('Documents','Pictures','Videos','Music','Downloads')
        if($naming -eq 'Compact4'){ $expect = @('Documents','Photo','Video','Downloads') }
        $a = @(@($mainFolders) | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object) -join ','
        $b = @($expect | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join ','
        if($a -ne $b){ $errors += ("MainFolders must match the '{0}' preset ({1})." -f $naming, ($expect -join ', ')) }
    }
    foreach($k in @('MaxPlanActions','PreserveMinFiles','InventoryCacheHours')){
        $v = Get-SysOrgSetting $Config $k 1
        if(-not (($v -is [int]) -or ($v -is [long])) -or ($v -lt 0)){ $errors += "$k must be a non-negative integer (got '$v')." }
    }
    $ratio = Get-SysOrgSetting $Config 'PreserveSingleCategoryRatio' 0.9
    if($ratio -lt 0 -or $ratio -gt 1){ $errors += 'PreserveSingleCategoryRatio must be between 0 and 1.' }
    if($errors.Count -gt 0){ throw ('Invalid configuration: ' + ($errors -join ' ')) }
}

function Import-SysOrgConfig {
<#
.SYNOPSIS
    Loads SysOrg.config.psd1 over built-in safe defaults, with deep merge and validation.
.DESCRIPTION
    Rev 2.1 additions (W10): deprecated keys are mapped on load with a warning -
      Duplicates       -> Copies (v2.0 configs keep working, Policy maps to Quarantine)
      Categories       -> TypeMap (legacy category values are translated)
      ProjectDetection -> Projects.Enabled (file clusters were replaced by name families)
    W9: Policy.ProtectedArtifacts are appended for EVERY fixed drive (not just C) after the
    user merge, so D:\WindowsApps and E:\XboxGames are protected without user configuration.
.PARAMETER Path
    Path to the .psd1 config file. Missing file silently yields defaults.
.PARAMETER AppRoot
    Folder containing SysOrg.ps1; recorded in the config and excluded from scans.
.EXAMPLE
    $cfg = Import-SysOrgConfig -Path .\SysOrg.config.psd1 -AppRoot (Get-Location)
#>
    param([string]$Path,[string]$AppRoot)
    $defaults = @{
        Version          = '2.1.0'
        NamingPreset     = 'Windows'
        DestinationStyle = 'OrganizedRoot'
        OrganizedRoots   = @{ '*' = '__AUTO__' }
        MainFolders      = @('Documents','Pictures','Videos','Music','Downloads')
        TypeMap          = @{}
        ExcludedPaths    = @('C:\Windows','C:\Program Files','C:\Program Files (x86)','C:\ProgramData',
                            'C:\Users\*\AppData','$Recycle.Bin','System Volume Information',
                            'Recovery','OneDriveTemp','*\node_modules','*\.git','*\.sysorg-ignore')
        ExcludedFilePatterns = @('*.tmp','~$*','*.part','*.crdownload','*.partial','desktop.ini','thumbs.db','.DS_Store')
        SkipHiddenSystemFiles = $true
        ExcludeDestinations   = $true
        ScanRoots        = @{ '*' = @('Desktop','Documents','Downloads','Pictures','Videos','Music') }
        DateFolders      = 'Year'
        PreserveExistingFolders = $true
        PreserveMinFiles = 5
        PreserveSingleCategoryRatio = 0.9
        AlwaysScanFolders = @('downloads','desktop','documents','temp','tmp','new folder')
        Policy = @{
            SystemDrive = @{ Scope='KnownFolders'; WritablePaths=@()
                             BlockedExtensions=@('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url')
                             AllowInstallersInDownloads=$true }
            DataDrives  = @{ Scope='FullDrive'; WritablePaths=@()
                             BlockedExtensions=@('.dll','.sys','.drv','.ocx','.cpl','.scr')
                             AllowInstallersInDownloads=$true }
            ProtectedArtifacts = @('Windows','Program Files','Program Files (x86)','ProgramData','WindowsApps',
                             'XboxGames','$Recycle.Bin','System Volume Information','Recovery','Boot','MSOCache','PerfLogs')
        }
        Families = @{ Enabled=$true; MinFiles=2; WithinTypeOnly=$true; CrossTypeLink='SameName'
                      NoiseTokens=@('copy','copie','final','new','old','backup','bak','draft','rev','revised','edit','edited','version','untitled')
                      StripVersionSuffix=$true; KeepDates=$true; MaxNameLength=60 }
        Copies   = @{ Policy='NumberCopies'; SuffixStyle='Parentheses'; StartIndex=2
                      MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates' }
        Downloads = @{ Roots=@('Downloads'); GroupBy='SourceFirst'; DateFolders='Year'
                       UseZoneIdentifier=$true; UnknownSourceFolder='_NoSource' }
        Projects = @{ Enabled=$true; Destination='Documents\Projects\Code'; Markers=@()
                      GenericNames=@('new folder','project','code','test','src','untitled','app')
                      VerifyCrossVolumeHashes=$true }
        Archives = @{ Extract=$false; KeepMultipartTogether=$true }
        Preview  = @{ NaturalSort=$true; ShowDenied=$true; WarnOneDriveSyncOut=$true }
        Privacy  = @{ StoreFullUrlsInJournal=$true }
        FolderAudit = @{ Enabled=$true; MaxTopLevelDepth=2; SkipHiddenSystemDirs=$true; RespectDefenderCFA=$true; IncludeRestrictedInPlans=$false }
        Move     = @{ AllowCrossVolume = $true }
        MaxPlanActions         = 5000
        InventoryCacheHours    = 24
        ReportsFolderName      = '_Reports'
        ScheduledTaskName      = 'SysOrg Weekly Scan'
        ScheduledDrives        = @('*')
    }
    if($Path -and (Test-Path -LiteralPath $Path)){
        try{
            $loaded = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
            if($loaded -is [hashtable]){
                # W10: deprecation mappings BEFORE the merge, so v1.x/2.0 configs keep working
                if($loaded.ContainsKey('Duplicates') -and -not $loaded.ContainsKey('Copies')){
                    Write-Warning "Config key 'Duplicates' is deprecated since v2.1.0 - mapped to 'Copies'. Update SysOrg.config.psd1 when convenient."
                    $d = $loaded['Duplicates']
                    $cop = @{ Policy='Quarantine'; SuffixStyle='Parentheses'; StartIndex=2
                              MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates' }
                    if($d -is [hashtable]){
                        if($d.ContainsKey('Policy')){ $cop.Policy = "$($d['Policy'])" }
                        if($d.ContainsKey('MinFileSizeKB')){ $cop.MinFileSizeKB = [int]$d['MinFileSizeKB'] }
                        if($d.ContainsKey('HeaderHashKB')){ $cop.HeaderHashKB = [int]$d['HeaderHashKB'] }
                        if($d.ContainsKey('QuarantineFolderName')){ $cop.QuarantineFolderName = "$($d['QuarantineFolderName'])" }
                    }
                    $loaded['Copies'] = $cop
                    [void]$loaded.Remove('Duplicates')
                }
                if($loaded.ContainsKey('Categories') -and -not $loaded.ContainsKey('TypeMap')){
                    Write-Warning "Config key 'Categories' is deprecated since v2.1.0 - mapped to 'TypeMap'."
                    $tm = @{}
                    $legacyCat = @{ 'Images'='Pictures'; 'Audio'='Music'; 'Spreadsheets'='Documents'
                                    'Presentations'='Documents'; 'Fonts'='Documents'; 'Databases'='Documents' }
                    $raw = $loaded['Categories']
                    if($raw -is [hashtable]){
                        foreach($k in $raw.Keys){
                            $v = "$($raw[$k])"
                            if($legacyCat.ContainsKey($v)){ $v = $legacyCat[$v] }
                            $tm[$k] = $v
                        }
                    }
                    $loaded['TypeMap'] = $tm
                    [void]$loaded.Remove('Categories')
                }
                if($loaded.ContainsKey('ProjectDetection') -and -not $loaded.ContainsKey('Projects')){
                    Write-Warning "Config key 'ProjectDetection' is deprecated since v2.1.0 (file clusters were replaced by name families); the Enabled flag was mapped to 'Projects.Enabled'."
                    $pd = $loaded['ProjectDetection']
                    if($pd -is [hashtable] -and $pd.ContainsKey('Enabled')){
                        $loaded['Projects'] = @{ Enabled = ($pd['Enabled'] -eq $true) }
                    }
                    [void]$loaded.Remove('ProjectDetection')
                }
                [void](Merge-SysOrgHashtable -Base $defaults -Override $loaded)
            }
        } catch {
            Write-Warning "Config '$Path' could not be parsed ($($_.Exception.Message)). Using safe defaults."
        }
    }
    if($defaults.ExcludedPaths -is [string]){ $defaults.ExcludedPaths = @($defaults.ExcludedPaths) }
    # W9/P1-7: protected artifacts on EVERY fixed drive, appended after the user merge so they
    # can never be opted away by accident (the user override replaces the array wholesale).
    try{
        $artifacts = @($defaults.Policy.ProtectedArtifacts)
        foreach($drv in [System.IO.DriveInfo]::GetDrives()){
            if($drv.DriveType -ne 'Fixed'){ continue }
            if(-not $drv.IsReady){ continue }
            $r = $drv.Name.TrimEnd('\')
            foreach($a in $artifacts){ $defaults.ExcludedPaths += ($r + '\' + $a) }
        }
    } catch { Write-Verbose "Could not enumerate fixed drives for default exclusions: $($_.Exception.Message)" }
    Test-SysOrgConfig -Config $defaults
    $defaults.AppRoot = $AppRoot
    return ,$defaults
}

function Get-SysOrgSetting {
<#
.SYNOPSIS
    Dot-path lookup into a config h[hashtable, e.g. 'Copies.Policy'.
.PARAMETER Default
    Returned when the path is missing or the value is null.
.EXAMPLE
    Get-SysOrgSetting $cfg 'Copies.Policy' 'ReportOnly'
#>
    param($Config,[string]$Path,$Default)
    $node = $Config
    foreach($part in $Path.Split('.')){
        if($node -is [hashtable] -and $node.ContainsKey($part)){ $node = $node[$part] }
        elseif($node -is [pscustomobject] -and ($node.PSObject.Properties.Name -contains $part)){ $node = $node.$part }
        else { return $Default }
    }
    if($null -eq $node){ return $Default }
    # NOTE: return the node WITHOUT comma-wrapping. The previous ',$node' wrapped arrays
    # into a single pipeline object, so @(Get-SysOrgSetting ... 'X.Y' @()) returned a
    # ONE-ELEMENT array whose element was the whole inner array - blocked-extension,
    # artifact, marker and noise-token lookups silently never matched. Streaming the
    # value is correct: callers that need an array collect with @(), which rebuilds
    # 0/1/N-element arrays properly; scalar callers are unaffected.
    return $node
}

function Write-SysOrgLog {
<#
.SYNOPSIS
    Writes one console line (color-coded) and appends to Logs\sysorg-<date>.log.
.PARAMETER Level
    INFO, WARN, ERROR or ACTION.
.EXAMPLE
    Write-SysOrgLog 'Moved: report.pdf' -Level ACTION -LogFolder C:\SysOrg\Logs
#>
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level='INFO',[string]$LogFolder)
    $line = '{0} [{1,-6}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if($LogFolder){
        try{
            if(-not (Test-Path -LiteralPath $LogFolder)){ New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $LogFolder ('sysorg-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))) -Value $line -Encoding UTF8
        } catch { Write-Verbose ("SysOrg log write failed: " + $_.Exception.Message) }
    }
    $color = @{ INFO='Gray'; WARN='Yellow'; ERROR='Red'; ACTION='Cyan' }[$Level]
    Write-Host $line -ForegroundColor $color
}

function Get-SysOrgFileHash {
<#
.SYNOPSIS
    SHA256 of a file; -HeaderOnly hashes the first N KB (fast duplicate pre-filter).
.DESCRIPTION
    Never modifies files. Opens with Read sharing so locked files yield $null instead
    of errors. Header reads loop until the buffer is filled (P2-2): a single
    Stream.Read may short-read on network/filtered volumes and hash an uninitialized
    buffer tail.
.EXAMPLE
    Get-SysOrgFileHash -Path C:\report.pdf -HeaderOnly -HeaderKB 64
#>
    param([Parameter(Mandatory)][string]$Path,[switch]$HeaderOnly,[int]$HeaderKB=64)
    try{
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try{
            $stream = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
            try{
                if($HeaderOnly){
                    $len = [int][Math]::Min(($HeaderKB * 1KB), $stream.Length)
                    if($len -le 0){ return 'EMPTY' }
                    $buf = New-Object byte[] $len
                    $read = 0
                    while($read -lt $len){
                        $n = $stream.Read($buf, $read, $len - $read)
                        if($n -le 0){ break }
                        $read += $n
                    }
                    $hashBytes = $sha.ComputeHash($buf, 0, $read)
                } else {
                    $hashBytes = $sha.ComputeHash($stream)
                }
            } finally { $stream.Dispose() }
        } finally { $sha.Dispose() }
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-','')
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# W7: natural sort, exactly like Explorer (StrCmpLogicalW), with a portable
# fallback for non-Windows hosts so tests behave identically everywhere.
# ---------------------------------------------------------------------------
if(-not ('SysOrg.NativeSort' -as [type])){
    try{
        Add-Type -Namespace SysOrg -Name NativeSort -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern int StrCmpLogicalW(string x, string y);
'@
    } catch { Write-Verbose "Native sort P/Invoke unavailable: $($_.Exception.Message)" }
}

function Sort-SysOrgNatural {
<#
.SYNOPSIS
    Sorts strings the way Explorer does: file (2) before file (10), Track 2 before Track 11.
.DESCRIPTION
    Uses shlwapi StrCmpLogicalW on Windows. On hosts where the P/Invoke is unavailable
    (test runners) a number-aware chunk comparison is used with identical ordering.
.EXAMPLE
    Sort-SysOrgNatural -Values @('file (10).txt','file (2).txt')   # -> file (2).txt, file (10).txt
#>
    param([string[]]$Values)
    $vals = @($Values)
    if($vals.Count -eq 0){ return @() }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach($v in $vals){ [void]$list.Add([string]$v) }
    # StrCmpLogicalW lives in shlwapi.dll (Windows only): on other hosts the compiled type
    # exists but the P/Invoke must not be invoked, so guard on the OS and fall back to the
    # number-aware chunk comparison with identical ordering.
    if(('SysOrg.NativeSort' -as [type]) -and ($env:OS -eq 'Windows_NT')){
        $list.Sort([Comparison[string]]{ param($a,$b) [SysOrg.NativeSort]::StrCmpLogicalW($a,$b) })
    } else {
        $list.Sort([Comparison[string]]{
            param($a,$b)
            $ca = [System.Text.RegularExpressions.Regex]::Split("$a",'(\d+)')
            $cb = [System.Text.RegularExpressions.Regex]::Split("$b",'(\d+)')
            $n = [Math]::Min($ca.Count,$cb.Count)
            for($i=0; $i -lt $n; $i++){
                if($ca[$i] -eq $cb[$i]){ continue }
                $na = 0L; $nb = 0L
                $okA = [int64]::TryParse($ca[$i],[ref]$na)
                $okB = [int64]::TryParse($cb[$i],[ref]$nb)
                if($okA -and $okB){ return $na.CompareTo($nb) }
                return ([string]::Compare($ca[$i],$cb[$i],$true))
            }
            return ($ca.Count.CompareTo($cb.Count))
        })
    }
    return ,$list.ToArray()
}

function Get-SysOrgNaturalKey {
<#
.SYNOPSIS
    Number-padded sort key for use inside Sort-Object expressions.
.EXAMPLE
    Sort-Object -Property @{e={ Get-SysOrgNaturalKey -Name $_.Name }}
#>
    param([string]$Name)
    if(-not $Name){ return '' }
    $parts = [System.Text.RegularExpressions.Regex]::Split("$Name",'(\d+)')
    $sb = New-Object System.Text.StringBuilder
    foreach($p in $parts){
        if($p -match '^\d+$'){ [void]$sb.Append($p.PadLeft(20,'0')) }
        else { [void]$sb.Append($p.ToLowerInvariant()) }
    }
    return $sb.ToString()
}

function Get-SysOrgSafeFolderName {
<#
.SYNOPSIS
    Sanitizes a name for use as a folder name (family folders, project folders).
.DESCRIPTION
    Strips characters Windows forbids, collapses whitespace, trims trailing dots/spaces,
    truncates to MaxLength and guards the reserved device names.
.EXAMPLE
    Get-SysOrgSafeFolderName -Name 'Report: final?'   # -> 'Report final'
#>
    param([Parameter(Mandatory)][string]$Name,[int]$MaxLength=60)
    $n = $Name -replace '[<>:"/\\|?*]', ' '
    $n = $n -replace "[\x00-\x1F]", ''
    $n = ($n -replace '\s+', ' ').Trim()
    $n = $n.Trim('.')
    if([string]::IsNullOrWhiteSpace($n)){ $n = 'Family' }
    if($n.Length -gt $MaxLength){ $n = $n.Substring(0, $MaxLength).Trim().Trim('.') }
    if([string]::IsNullOrWhiteSpace($n)){ $n = 'Family' }
    $reserved = @('CON','PRN','AUX','NUL','COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
                  'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
    if($reserved -contains $n.ToUpperInvariant()){ $n = '_' + $n }
    return $n
}

function Test-SysOrgExcludedPath {
<#
.SYNOPSIS
    True when a path must never be scanned or modified.
.DESCRIPTION
    Supports wildcard patterns, absolute prefix rules, and (P1-7) root-less
    single-segment names: 'Recovery' matches any path segment, so D:\Recovery is
    protected as well as C:\Recovery. A folder named 'Recovery-notes' is NOT matched.
    The app root is always protected.
.EXAMPLE
    Test-SysOrgExcludedPath -Path 'D:\$Recycle.Bin' -Config $cfg   # -> True
#>
    param([string]$Path,$Config)
    $p = $Path.TrimEnd('\')
    foreach($pat in @($Config.ExcludedPaths)){
        if([string]::IsNullOrWhiteSpace($pat)){ continue }
        if($pat.Contains('*') -or $pat.Contains('?')){
            # Match the path itself AND anything inside it: a wildcard rule like
            # 'C:\Users\*\AppData' must also cover 'C:\Users\alice\AppData\Local\Temp'.
            if($p -like $pat -or $p -like ($pat + '\*')){ return $true }
        } else {
            $pn = $pat.TrimEnd('\')
            if($p -ieq $pn -or $p.StartsWith($pn + '\',[StringComparison]::OrdinalIgnoreCase)){ return $true }
            if(($pn -notmatch '^[A-Za-z]:') -and ($pn -notmatch '\\')){
                if($p.Split('\') -contains $pn){ return $true }
            }
        }
    }
    $appRoot = Get-SysOrgSetting $Config 'AppRoot' $null
    if($appRoot){
        $ap = $appRoot.TrimEnd('\')
        if($p -ieq $ap -or $p.StartsWith($ap + '\',[StringComparison]::OrdinalIgnoreCase)){ return $true }
    }
    return $false
}

function Test-SysOrgExcludedFile {
<#
.SYNOPSIS
    True when a file name matches an excluded pattern (e.g. *.tmp, ~$*, desktop.ini).
.EXAMPLE
    Test-SysOrgExcludedFile -Path 'C:\x\~doc.docx' -Config $cfg   # -> True
#>
    param([string]$Path,$Config)
    $name = Split-Path $Path -Leaf
    foreach($pat in @($Config.ExcludedFilePatterns)){ if($name -like $pat){ return $true } }
    return $false
}

function Get-SysOrgDestinationRoot {
<#
.SYNOPSIS
    Resolves the organized-files root for a drive letter (config or '<Drive>:\_Organized').
.EXAMPLE
    Get-SysOrgDestinationRoot -Letter D -Config $cfg   # -> 'D:\_Organized' with __AUTO__
#>
    param([string]$Letter,$Config)
    $roots = $Config.OrganizedRoots
    $val = $null
    if($roots -is [hashtable]){
        if($roots.ContainsKey($Letter)){ $val = $roots[$Letter] }
        elseif($roots.ContainsKey('*')){ $val = $roots['*'] }
    }
    if([string]::IsNullOrWhiteSpace($val)){ $val = '__AUTO__' }
    if($val -eq '__AUTO__'){ $val = ('{0}:\_Organized' -f $Letter) }
    return $val.TrimEnd('\')
}

function Test-SysOrgDestinationPath {
<#
.SYNOPSIS
    True when a path lives inside the organized-files root for its drive.
.EXAMPLE
    Test-SysOrgDestinationPath -Path 'D:\_Organized\Documents\2026\a.pdf' -Config $cfg
#>
    param([string]$Path,$Config)
    # Paths without a drive qualifier (UNC tails, Unix-style paths in test hosts)
    # can never be an organized destination.
    $qual = Split-Path $Path -Qualifier -ErrorAction SilentlyContinue
    if(-not $qual){ return $false }
    $letter = $qual.TrimEnd(':')
    $root = Get-SysOrgDestinationRoot -Letter $letter -Config $Config
    $p = $Path.TrimEnd('\')
    if($p -ieq $root -or $p.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)){ return $true }
    return $false
}

function Get-SysOrgUniquePath {
<#
.SYNOPSIS
    Returns a non-existing path; appends ' (2)', ' (3)', ... Never overwrites.
.EXAMPLE
    Get-SysOrgUniquePath -Path 'C:\org\Documents\2026\report.pdf'   # -> ...\report (2).pdf
#>
    param([string]$Path)
    if(-not (Test-Path -LiteralPath $Path)){ return $Path }
    $dir  = Split-Path $Path -Parent
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [System.IO.Path]::GetExtension($Path)
    for($i=2; $i -lt 1000; $i++){
        $candidate = Join-Path $dir ('{0} ({1}){2}' -f $stem,$i,$ext)
        if(-not (Test-Path -LiteralPath $candidate)){ return $candidate }
    }
    return (Join-Path $dir (([guid]::NewGuid().ToString('N').Substring(0,8)) + $ext))
}

function Get-SysOrgCopyName {
<#
.SYNOPSIS
    Builds the name for an exact copy at plan time (section 9 of the design).
.DESCRIPTION
    Parentheses style (default): KeeperStem (2).ext, (3), ... - the original is implicitly 1.
    DashCopy style (Explorer paste): 'Report - Copy.docx' for the first copy, then
    'Report - Copy (2).docx', (3), ... Index is the absolute copy index (StartIndex-based).
.EXAMPLE
    Get-SysOrgCopyName -Stem 'Report' -Extension '.docx' -Index 2   # -> 'Report (2).docx'
#>
    param([Parameter(Mandatory)][string]$Stem,[Parameter(Mandatory)][string]$Extension,
          [Parameter(Mandatory)][int]$Index,[string]$Style='Parentheses')
    if($Style -eq 'DashCopy'){
        if($Index -le 2){ return ('{0} - Copy{1}' -f $Stem, $Extension) }
        return ('{0} - Copy ({1}){2}' -f $Stem, ($Index - 1), $Extension)
    }
    return ('{0} ({1}){2}' -f $Stem, $Index, $Extension)
}

function Test-SysOrgFileMutable {
<#
.SYNOPSIS
    The mutability engine (design section 5): may THIS file be moved at all?
.DESCRIPTION
    Returns Allowed plus a denial Reason that appears verbatim in the preview:
      'Protected path', 'Blocked extension .dll', 'Outside writable scope on system drive'.
    Checks, in order: protected paths, blocked extensions (with the installer-in-download-roots
    exception), then the writable scope. On the system drive the default scope is the resolved
    known folders plus Policy.SystemDrive.WritablePaths; data drives default to FullDrive.
    -Container checks a FOLDER instead of a file (project folders, migration roots).
.EXAMPLE
    Test-SysOrgFileMutable -Path 'C:\Users\t\Documents\x.dll' -Extension '.dll' -DriveProfile $prof -Config $cfg
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[AllowEmptyString()][string]$Extension,
          [Parameter(Mandatory)]$DriveProfile,$Config,[switch]$Container)
    $checkPath = if($Container){ $Path.TrimEnd('\') } else { Split-Path $Path -Parent }
    if(Test-SysOrgExcludedPath -Path $checkPath -Config $Config){
        return [pscustomobject]@{ Allowed=$false; Reason='Protected path' }
    }
    $role = "$($DriveProfile.Role)"
    if($role -ieq 'System'){ $polKey = 'Policy.SystemDrive' } else { $polKey = 'Policy.DataDrives' }
    $blocked = @(Get-SysOrgSetting $Config ($polKey + '.BlockedExtensions') @())
    if((-not $Container) -and ($blocked -contains $Extension)){
        return [pscustomobject]@{ Allowed=$false; Reason=("Blocked extension {0}" -f $Extension) }
    }
    # 5.1 policy matrix: installers (.exe .msi .msix .appx .apk) are movable ONLY inside
    # download roots (the installer exception, on every drive role). With
    # AllowInstallersInDownloads=$false they never move at all.
    if((-not $Container) -and (@('.exe','.msi','.msix','.appx','.apk') -contains $Extension)){
        $inDownloads = $false
        $pathNorm = $Path.Replace('/','\')
        foreach($r in @($DriveProfile.DownloadRoots)){
            if([string]::IsNullOrWhiteSpace("$r")){ continue }
            $r2 = (("$r").Replace('/','\')).TrimEnd('\')
            if($pathNorm.StartsWith($r2 + '\',[StringComparison]::OrdinalIgnoreCase)){ $inDownloads = $true; break }
        }
        if((-not $inDownloads) -or (-not (Get-SysOrgSetting $Config ($polKey + '.AllowInstallersInDownloads') $true))){
            return [pscustomobject]@{ Allowed=$false; Reason='Installer outside download roots' }
        }
    }
    $defaultScope = if($role -ieq 'System'){ 'KnownFolders' } else { 'FullDrive' }
    $scope = Get-SysOrgSetting $Config ($polKey + '.Scope') $defaultScope
    if("$scope" -eq 'FullDrive'){
        return [pscustomobject]@{ Allowed=$true; Reason='' }
    }
    $writable = @()
    if("$scope" -eq 'KnownFolders'){
        foreach($k in @($DriveProfile.KnownFolders)){
            if($k.Path){ $writable += [string]$k.Path }
        }
    }
    $writable += @(Get-SysOrgSetting $Config ($polKey + '.WritablePaths') @())
    foreach($w in $writable){
        if([string]::IsNullOrWhiteSpace("$w")){ continue }
        $w2 = ("$w").TrimEnd('\')
        if($Path.StartsWith($w2 + '\',[StringComparison]::OrdinalIgnoreCase) -or ($Path -ieq $w2)){
            return [pscustomobject]@{ Allowed=$true; Reason='' }
        }
    }
    if($role -ieq 'System'){ $reason = 'Outside writable scope on system drive' }
    else { $reason = 'Outside writable scope' }
    return [pscustomobject]@{ Allowed=$false; Reason=$reason }
}

function Get-SysOrgFolderMap {
<#
.SYNOPSIS
    Routing-category -> destination folder map for the active naming preset (W4).
.DESCRIPTION
    Windows preset roots: Documents, Pictures, Videos, Music, Downloads.
    Archives, Code and Other live under Documents; Installers routes to the Downloads branch.
    Compact4 restores rev 2.0 naming (Documents, Photo, Video, Downloads; Music under Video\Audio).
.EXAMPLE
    Get-SysOrgFolderMap -Config $cfg['Pictures']   # -> 'Pictures' (Windows) or 'Photo' (Compact4)
#>
    param($Config)
    $preset = Get-SysOrgSetting $Config 'NamingPreset' 'Windows'
    if("$preset" -eq 'Compact4'){
        return @{
            Documents  = 'Documents'
            Pictures   = 'Photo'
            Videos     = 'Video'
            Music      = 'Video\Audio'
            Archives   = 'Documents\Archives'
            Code       = 'Documents\Code'
            Other      = 'Documents\Other'
            Installers = 'Downloads\Installers'
            Downloads  = 'Downloads'
        }
    }
    return @{
        Documents  = 'Documents'
        Pictures   = 'Pictures'
        Videos     = 'Videos'
        Music      = 'Music'
        Archives   = 'Documents\Archives'
        Code       = 'Documents\Code'
        Other      = 'Documents\Other'
        Installers = 'Downloads\Installers'
        Downloads  = 'Downloads'
    }
}

function Get-SysOrgZoneIdentifier {
<#
.SYNOPSIS
    Reads the Zone.Identifier alternate data stream (download provenance).
.DESCRIPTION
    Returns a h[hashtable with HostUrl / ReferrerUrl when the stream exists, otherwise $null.
    Only called AFTER the placeholder skip (P1-5): opening a cloud placeholder would hydrate it.
.EXAMPLE
    $z = Get-SysOrgZoneIdentifier -Path 'C:\Users\t\Downloads\setup.exe'
#>
    param([Parameter(Mandatory)][string]$Path)
    try{
        $content = Get-Content -LiteralPath $Path -Stream 'Zone.Identifier' -ErrorAction Stop
        $info = @{}
        foreach($line in @($content)){
            if("$line" -match '^HostUrl=(.+)$'){ $info['HostUrl'] = $Matches[1] }
            elseif("$line" -match '^ReferrerUrl=(.+)$'){ $info['ReferrerUrl'] = $Matches[1] }
        }
        if($info.Count -gt 0){ return $info }
    } catch { }
    return $null
}

function Copy-SysOrgZoneIdentifier {
<#
.SYNOPSIS
    Reattaches the Zone.Identifier stream after a verified cross-volume copy (rev 2.0 D7).
.DESCRIPTION
    Same-volume renames keep streams automatically; cross-volume Copy-Item does not.
    Called BEFORE the source is removed, while the source stream is still readable.
.EXAMPLE
    Copy-SysOrgZoneIdentifier -Source C:\a.exe -Destination D:\org\a.exe
#>
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    try{
        $raw = Get-Content -LiteralPath $Source -Stream 'Zone.Identifier' -ErrorAction Stop
        if($raw){
            Set-Content -LiteralPath $Destination -Stream 'Zone.Identifier' -Value $raw -Encoding UTF8 -ErrorAction Stop
            return $true
        }
    } catch { Write-Verbose "Zone.Identifier reattach failed: $($_.Exception.Message)" }
    return $false
}

function Invoke-SysOrgSafeMove {
<#
.SYNOPSIS
    The single primitive that touches files. Every plan action routes through it.
.DESCRIPTION
    Guarantees:
      - never overwrites: destination is always a unique path (' (2)' suffixes)
      - identical content already at destination -> Status 'CollisionDuplicate'
        (size compared first, then SHA256 - P2-1 hash economy)
      - same volume  : Move-Item (atomic rename; NTFS streams travel with the file)
      - cross volume : Copy-Item -> SHA256 verify -> Zone.Identifier reattached (D7) ->
                       only then remove source; on any mismatch or locked source, source is KEPT
      - Move.AllowCrossVolume = $false (P1-10): verified copy-only; every source kept
.EXAMPLE
    Invoke-SysOrgSafeMove -Source C:\a.pdf -Destination D:\_Organized\Documents\2026\a.pdf -Config $cfg
#>
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,$Config)
    $result = [pscustomobject]@{ Status='Failed'; Source=$Source; Destination=$null; Message='' }
    try{
        if(-not (Test-Path -LiteralPath $Source)){ $result.Message='Source not found'; return $result }
        $destDir = Split-Path $Destination -Parent
        if(-not (Test-Path -LiteralPath $destDir)){ New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        if(Test-Path -LiteralPath $Destination){
            # P2-1: compare sizes before hashing either file
            $srcLen = (Get-Item -LiteralPath $Source).Length
            $dstLen = (Get-Item -LiteralPath $Destination).Length
            if($srcLen -eq $dstLen){
                $dstHash = Get-SysOrgFileHash -Path $Destination
                $srcHash = Get-SysOrgFileHash -Path $Source
                if($dstHash -and $srcHash -and ($dstHash -eq $srcHash)){
                    $result.Status='CollisionDuplicate'; $result.Destination=$Destination
                    $result.Message='Identical content already exists at destination'
                    return $result
                }
            }
        }
        $final = Get-SysOrgUniquePath -Path $Destination

        $sameVolume = ((Split-Path $Source -Qualifier -ErrorAction SilentlyContinue) -ieq (Split-Path $final -Qualifier -ErrorAction SilentlyContinue))
        $allowCross = Get-SysOrgSetting $Config 'Move.AllowCrossVolume' $true

        if($sameVolume){
            Move-Item -LiteralPath $Source -Destination $final -ErrorAction Stop
            $result.Status='Moved'
        }
        else {
            # One verified-copy path for all cross-volume cases (P1-10)
            Copy-Item -LiteralPath $Source -Destination $final -ErrorAction Stop
            $copyHash = Get-SysOrgFileHash -Path $final
            $origHash = Get-SysOrgFileHash -Path $Source
            if((-not $copyHash) -or (-not $origHash) -or ($copyHash -ne $origHash)){
                Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
                $result.Message='Copy verification failed; source untouched'
                return $result
            }
            # rev 2.0 D7: reattach the Zone.Identifier stream to the verified copy while
            # the source still exists; same-volume renames keep streams automatically.
            [void](Copy-SysOrgZoneIdentifier -Source $Source -Destination $final)
            if($allowCross){
                try {
                    Remove-Item -LiteralPath $Source -Force -ErrorAction Stop
                    $result.Status = 'Moved'
                } catch {
                    $result.Status = 'CopiedVerified'
                    $result.Message = 'Copied and verified; source is locked and was kept'
                }
            } else {
                $result.Status = 'CopiedVerified'
                $result.Message = 'Copied and verified; source kept (Move.AllowCrossVolume=$false)'
            }
        }
        $result.Destination=$final
    } catch { $result.Message=$_.Exception.Message }
    return $result
}

function Invoke-SysOrgSafeMoveFolder {
<#
.SYNOPSIS
    Folder primitive for code project folders and migration moves. Never overwrites.
.DESCRIPTION
    Same volume: Move-Item (atomic). Cross volume: Copy-Item -Recurse -> verify
    (file count + total bytes, optional full hash pass disabled for speed) ->
    only then remove the source; on any mismatch the verified copy is removed and
    the source is kept. A destination that already exists gets a unique ' (2)' suffix.
.EXAMPLE
    Invoke-SysOrgSafeMoveFolder -Source C:\src\repo -Destination D:\org\Documents\Projects\Code\repo -Config $cfg
#>
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,$Config)
    $result = [pscustomobject]@{ Status='Failed'; Source=$Source; Destination=$null; Message=''
                                 FilesCopied=0; BytesCopied=[int64]0 }
    $final = $null
    $copied = $false
    try{
        if(-not (Test-Path -LiteralPath $Source -PathType Container)){ $result.Message='Source folder not found'; return $result }
        $parent = Split-Path $Destination -Parent
        if(-not (Test-Path -LiteralPath $parent)){ New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $final = Get-SysOrgUniquePath -Path $Destination

        $sameVolume = ((Split-Path $Source -Qualifier -ErrorAction SilentlyContinue) -ieq (Split-Path $final -Qualifier -ErrorAction SilentlyContinue))
        if($sameVolume){
            Move-Item -LiteralPath $Source -Destination $final -ErrorAction Stop
            $result.Status='Moved'
            $result.Destination=$final
            return $result
        }
        Copy-Item -LiteralPath $Source -Destination $final -Recurse -Force -ErrorAction Stop
        $copied = $true
        # Verify: file count and total byte size must match exactly.
        $srcFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)
        $dstFiles = @(Get-ChildItem -LiteralPath $final -Recurse -File -Force -ErrorAction SilentlyContinue)
        if($srcFiles.Count -ne $dstFiles.Count){ throw ('File count mismatch after folder copy ({0} vs {1})' -f $srcFiles.Count, $dstFiles.Count) }
        $sb = [int64]0; if($srcFiles.Count -gt 0){ $sb = [int64]($srcFiles | Measure-Object -Property Length -Sum).Sum }
        $db = [int64]0; if($dstFiles.Count -gt 0){ $db = [int64]($dstFiles | Measure-Object -Property Length -Sum).Sum }
        if($sb -ne $db){ throw 'Byte total mismatch after folder copy' }
        $result.FilesCopied = $srcFiles.Count
        $result.BytesCopied = $sb
        if(Get-SysOrgSetting $Config 'Move.AllowCrossVolume' $true){
            try {
                Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction Stop
                $result.Status = 'Moved'
            } catch {
                $result.Status = 'CopiedVerified'
                $result.Message = 'Copied and verified; source is locked and was kept'
            }
        } else {
            $result.Status = 'CopiedVerified'
            $result.Message = 'Copied and verified; source kept (Move.AllowCrossVolume=$false)'
        }
        $result.Destination = $final
    } catch {
        $result.Message = $_.Exception.Message
        # Remove only OUR partial copy; the source is never touched.
        if($copied -and $final -and ($result.Status -eq 'Failed') -and (Test-Path -LiteralPath $final)){
            Remove-Item -LiteralPath $final -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $result
}

function Format-SysOrgFileSize {
<#
.SYNOPSIS
    Human-readable byte size ('1.2 MB', '3.4 GB').
.EXAMPLE
    Format-SysOrgFileSize -Bytes 5242880   # -> '5.0 MB'
#>
    param([int64]$Bytes)
    if($Bytes -ge 1GB){ return '{0:N2} GB' -f ($Bytes/1GB) }
    if($Bytes -ge 1MB){ return '{0:N1} MB' -f ($Bytes/1MB) }
    if($Bytes -ge 1KB){ return '{0:N1} KB' -f ($Bytes/1KB) }
    return "$Bytes B"
}

function New-SysOrgAppFolders {
<#
.SYNOPSIS
    Creates and returns the runtime folders (Logs, Plans, Undo, Cache) under AppRoot.
.EXAMPLE
    $folders = New-SysOrgAppFolders -AppRoot C:\SysOrg
#>
    param([Parameter(Mandatory)][string]$AppRoot)
    $map = @{ AppRoot=$AppRoot
              Logs=  (Join-Path $AppRoot 'Logs')
              Plans= (Join-Path $AppRoot 'Plans')
              Undo=  (Join-Path $AppRoot 'Undo')
              Cache= (Join-Path $AppRoot 'Cache') }
    foreach($k in @('Logs','Plans','Undo','Cache')){
        if(-not (Test-Path -LiteralPath $map[$k])){ New-Item -ItemType Directory -Path $map[$k] -Force | Out-Null }
    }
    return ,$map
}

function ConvertTo-SysOrgCsvField {
<#
.SYNOPSIS
    Escapes a single CSV field (v2.1.1): wraps in quotes and doubles embedded quotes.
.DESCRIPTION
    Replaces hand-formatted CSV lines for untrusted values (download URLs, file names with
    commas or quotes). The output is Import-Csv-compatible and keeps the journal column
    layout backward compatible with pre-2.1.1 files.
.EXAMPLE
    ConvertTo-SysOrgCsvField 'https://x.test/a,"b'   # -> '"https://x.test/a,""b"'
#>
    param([AllowEmptyString()][string]$Value)
    return ('"' + ($Value -replace '"','""') + '"')
}

function Test-SysOrgElevated {
<#
.SYNOPSIS
    True when the current process runs as Administrator.
.EXAMPLE
    if(Test-SysOrgElevated){ Write-Host 'admin' }
#>
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
    hydrate the whole cloud library, so the scanner must skip it. Lives in Core so
    the plan executor can use it without importing the Scan module.
.EXAMPLE
    Test-SysOrgCloudPlaceholderAttributes -Attributes 0x400020   # -> True
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Attributes)
    return ((($Attributes -band 0x1000) -ne 0) -or (($Attributes -band 0x400000) -ne 0))
}

function Get-SysOrgCanonicalPlanPath {
<#
.SYNOPSIS
    Canonicalizes a plan/journal path and rejects unsafe forms (v2.1.1, audit High #1).
.DESCRIPTION
    A plan or undo journal is UNTRUSTED INPUT. Before any path is used for a move it must
    pass through this function. It canonicalizes with [IO.Path]::GetFullPath and rejects:
      - empty / not absolute paths
      - the \\?\ device namespace (GetFullPath would not normalize it, and it is how
        exclusion rules are bypassed)
      - any '..' segment (rejected BEFORE normalization so 'C:\x\..\Windows' is refused
        instead of silently resolving to a different location than the exclusion check saw)
      - any '..' segment that survives normalization (defense in depth)
      - 8.3 short-name segments ('REPORT~1'), which defeat exclusion prefix matching
    Returns [pscustomobject]@{ Path=<canonical>; Error=<'' or reason> }.
.EXAMPLE
    $c = Get-SysOrgCanonicalPlanPath -Path 'C:\Users\t\..\Windows\evil.txt'
    $c.Error   # -> a reason; the executor records the action as Failed
#>
    param([AllowEmptyString()][string]$Path)
    $err = ''
    $canon = $null
    if([string]::IsNullOrWhiteSpace($Path)){
        return [pscustomobject]@{ Path=''; Error='path is empty' }
    }
    if($Path -like '\\?\*'){
        return [pscustomobject]@{ Path=''; Error='device namespace path (\\?\ prefix) is not allowed' }
    }
    # Split on BOTH separators: on Windows '\' is the separator, on the portable test
    # hosts '/' is, and plan strings always use '\'. A '..' segment in either form is refused.
    foreach($seg in ($Path -split '[\\/]')){
        if($seg -eq '..'){ return [pscustomobject]@{ Path=''; Error="parent-relative '..' segment is not allowed" } }
        if($seg -match '~\d'){ return [pscustomobject]@{ Path=''; Error="8.3 short-name segment ('$seg') is not allowed" } }
    }
    if(-not [System.IO.Path]::IsPathRooted($Path)){
        return [pscustomobject]@{ Path=''; Error='path is not absolute' }
    }
    try{
        $canon = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return [pscustomobject]@{ Path=''; Error=('path could not be canonicalized: ' + $_.Exception.Message) }
    }
    foreach($seg in ($canon -split '[\\/]')){
        if($seg -eq '..'){ return [pscustomobject]@{ Path=''; Error="parent-relative '..' survived normalization" } }
    }
    return [pscustomobject]@{ Path=$canon; Error=$err }
}

function Test-SysOrgReparsePoint {
<#
.SYNOPSIS
    True when the file or folder itself is a reparse point (junction, symlink, OneDrive link).
.DESCRIPTION
    Checked via the raw attributes (0x400 ReparsePoint) so it behaves identically on
    Windows PowerShell 5.1 and PowerShell 7. On .NET Core hosts (PowerShell 7 on Linux)
    symlinks do not carry the ReparsePoint attribute, so the LinkTarget property is
    consulted as well when it exists.
.EXAMPLE
    Test-SysOrgReparsePoint -Path 'C:\Some\Junction'   # -> True
#>
    param([Parameter(Mandatory)][string]$Path)
    try{
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if((([int]$item.Attributes) -band 0x400) -ne 0){ return $true }
        if($item.PSObject.Properties['LinkTarget'] -and $item.LinkTarget){ return $true }
    } catch { return $false }
    return $false
}

function Test-SysOrgPlanDestinationAllowed {
<#
.SYNOPSIS
    Checks that a plan action's destination is inside the area the plan was allowed to write.
.DESCRIPTION
    Executor-side re-validation (v2.1.1): the destination must be under the plan's
    DestinationRoot, or - when DestinationStyle='KnownFolders' - under a resolved known
    folder (freshly resolved, plus the plan's own profile folders, which are covered by
    the plan integrity hash). Migration plans may only target under their own root.
    Legacy plans without a DestinationRoot property cannot be containment-checked; they
    are allowed and the executor warns.
    Comparison is case-insensitive and separator-normalized for both platforms.
.EXAMPLE
    Test-SysOrgPlanDestinationAllowed -Destination 'C:\Windows\evil.txt' -Plan $plan -Config $cfg
#>
    param([Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)]$Plan,$Config)
    $destN = ("$Destination").Replace('/','\').TrimEnd('\').ToLowerInvariant()
    $roots = New-Object System.Collections.Generic.List[string]
    $style = ''
    if($Plan.PSObject.Properties['DestinationStyle']){ $style = "$($Plan.DestinationStyle)" }
    $planRoot = $null
    if($Plan.PSObject.Properties['DestinationRoot'] -and "$($Plan.DestinationRoot)"){
        $planRoot = ("$($Plan.DestinationRoot)").Replace('/','\').TrimEnd('\')
        [void]$roots.Add($planRoot.ToLowerInvariant())
    }
    if("$style" -eq 'KnownFolders'){
        # Migration plans only ever target under their own root.
        $isMigration = "$($Plan.PlanId)" -like 'migrate-*'
        if(-not $isMigration){
            try{
                foreach($k in @(Get-SysOrgKnownFolders)){
                    if($k.Path){ [void]$roots.Add((("$($k.Path)").Replace('/','\').TrimEnd('\')).ToLowerInvariant()) }
                }
            } catch { Write-Verbose "Known-folder containment check unavailable: $($_.Exception.Message)" }
            if($Plan.PSObject.Properties['DriveProfile'] -and $Plan.DriveProfile){
                foreach($k in @($Plan.DriveProfile.KnownFolders)){
                    if($k.Path){ [void]$roots.Add((("$($k.Path)").Replace('/','\').TrimEnd('\')).ToLowerInvariant()) }
                }
            }
        }
    }
    if($roots.Count -eq 0){
        return [pscustomobject]@{ Allowed=$true; Legacy=$true; Reason='plan has no DestinationRoot; containment not verifiable' }
    }
    foreach($r in $roots){
        if([string]::IsNullOrWhiteSpace($r)){ continue }
        if($destN -eq $r -or $destN.StartsWith($r + '\',[StringComparison]::OrdinalIgnoreCase)){
            return [pscustomobject]@{ Allowed=$true; Legacy=$false; Reason='' }
        }
    }
    return [pscustomobject]@{ Allowed=$false; Legacy=$false; Reason=('destination is outside the plan root ({0})' -f $planRoot) }
}

function Get-SysOrgPlanIntegrityHash {
<#
.SYNOPSIS
    SHA256 over the canonical serialization of a plan's action list (v2.1.1).
.DESCRIPTION
    Save-SysOrgPlan stores this hash in the plan JSON; Invoke-SysOrgPlan recomputes it from
    the loaded actions and refuses to execute when they no longer match (hand-edited plans,
    corrupted files). The serialization normalizes every action to 'Name=Value' pairs sorted
    by property name, joined with ';' and newline separators, so the hash is stable across
    the ConvertTo-Json/ConvertFrom-Json round trip and across PowerShell versions.
.EXAMPLE
    Get-SysOrgPlanIntegrityHash -Actions $plan.Actions
#>
    param([Parameter(Mandatory)]$Actions)
    $all = @($Actions)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach($a in $all){
        if($null -eq $a){ continue }
        # DateTime values are normalized to a round-trip-invariant string: ConvertFrom-Json
        # parses ISO-8601-looking strings back into [datetime], so the canonical form must
        # be stable across that conversion.
        $props = @($a.PSObject.Properties | Sort-Object -Property Name)
        [void]$lines.Add((@($props | ForEach-Object {
            $v = $_.Value
            if($v -is [datetime]){ '{0}={1}' -f $_.Name, $v.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
            else { '{0}={1}' -f $_.Name, "$v" }
        }) -join ';'))
    }
    $payload = ($lines -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try{
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
    } finally { $sha.Dispose() }
}

Export-ModuleMember -Function *-SysOrg*
