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

function Join-SysOrgProtectedList {
<#
.SYNOPSIS
    Additive merge for protection lists (v2.1.1): user entries + built-ins, built-ins re-added.
.DESCRIPTION
    A user config can ADD entries to Policy.ProtectedArtifacts and the per-scope
    BlockedExtensions lists, but cannot REMOVE the built-in entries. Missing built-ins
    are re-added and a warning is written, so a hostile or careless config can never
    shrink the protection lists. Comparison is case-insensitive.
.EXAMPLE
    Join-SysOrgProtectedList -User @('.foo') -BuiltIn @('.dll','.sys') -Label 'Policy.SystemDrive.BlockedExtensions'
#>
    param([AllowEmptyCollection()]$User,[AllowEmptyCollection()][string[]]$BuiltIn,[string]$Label)
    $out = New-Object System.Collections.Generic.List[string]
    foreach($v in @($User)){
        $s = "$v"
        if(-not [string]::IsNullOrWhiteSpace($s) -and (-not ($out -contains $s))){ [void]$out.Add($s) }
    }
    $missing = @()
    foreach($b in $BuiltIn){
        if(-not ($out -contains $b)){ $missing += $b; [void]$out.Add($b) }
    }
    if($missing.Count -gt 0){
        Write-Warning ("{0}: user configuration cannot remove built-in entries; re-added: {1}" -f $Label, ($missing -join ', '))
    }
    return $out.ToArray()
}

function Resolve-SysOrgWritablePath {
<#
.SYNOPSIS
    Resolves -WritablePath input to a full canonical path (v2.1.1).
.DESCRIPTION
    Previously a relative -WritablePath was stored raw into the policy and never matched
    any absolute path at mutability-check time. This resolves the path against the
    current location and canonicalizes it with [IO.Path]::GetFullPath. Throws when the
    path does not exist (the CLI warns and continues).
.EXAMPLE
    Resolve-SysOrgWritablePath -Path 'C:\Work\Exports'
#>
    param([Parameter(Mandatory)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path)){ throw ("WritablePath does not exist: $Path") }
    $rp = (Resolve-Path -LiteralPath $Path).ProviderPath
    return ([System.IO.Path]::GetFullPath($rp))
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
    # v3.0: the layout profile. Findable activates the new layout engine; Windows and
    # Compact4 keep the legacy behaviour exactly.
    $layoutProfile = Get-SysOrgSetting $Config 'LayoutProfile' 'Windows'
    if(@('Windows','Compact4','Findable') -notcontains $layoutProfile){ $errors += "LayoutProfile must be Windows, Compact4, or Findable (got '$layoutProfile')." }
    $reviewMode = Get-SysOrgSetting $Config 'Review.Mode' 'Report'
    if(@('Report','Move') -notcontains $reviewMode){ $errors += "Review.Mode must be Report or Move (got '$reviewMode')." }
    # v3.0 confidence thresholds
    $minConf = Get-SysOrgSetting $Config 'Classify.MinConfidence' 0.40
    $revConf = Get-SysOrgSetting $Config 'Classify.ReviewConfidence' 0.70
    foreach($pair in @(@('Classify.MinConfidence',$minConf), @('Classify.ReviewConfidence',$revConf))){
        $v = $pair[1]
        if(($v -isnot [int]) -and ($v -isnot [long]) -and ($v -isnot [double])){ $errors += ($pair[0] + ' must be a number between 0 and 1 (got ' + "$v" + ').') }
        elseif([double]$v -lt 0 -or [double]$v -gt 1){ $errors += ($pair[0] + ' must be a number between 0 and 1 (got ' + "$v" + ').') }
    }
    if([double]$minConf -ge [double]$revConf){ $errors += 'Classify.MinConfidence must be below Classify.ReviewConfidence.' }
    $style = Get-SysOrgSetting $Config 'DestinationStyle' 'OrganizedRoot'
    if(@('OrganizedRoot','KnownFolders') -notcontains $style){ $errors += "DestinationStyle must be OrganizedRoot or KnownFolders (got '$style')." }
    $cpol = Get-SysOrgSetting $Config 'Copies.Policy' 'NumberCopies'
    if(@('NumberCopies','Quarantine','ReportOnly') -notcontains $cpol){ $errors += "Copies.Policy must be NumberCopies, Quarantine, or ReportOnly (got '$cpol')." }
    $cstyle = Get-SysOrgSetting $Config 'Copies.SuffixStyle' 'Parentheses'
    if(@('Parentheses','DashCopy') -notcontains $cstyle){ $errors += "Copies.SuffixStyle must be Parentheses or DashCopy (got '$cstyle')." }
    $renameToKeeper = Get-SysOrgSetting $Config 'Copies.RenameToKeeper' $false
    if(-not ($renameToKeeper -is [bool])){ $errors += 'Copies.RenameToKeeper must be $true or $false (got ' + "$renameToKeeper" + ').' }
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
    # v3.0: Layout caps and Score targets are integers/numbers where noted.
    foreach($k in @('Layout.MaxFilesPerFolder','Layout.MinFilesPerFolder','Layout.MaxTopLevelFolders','Layout.MaxDepth','Layout.MaxPathChars')){
        $v = Get-SysOrgSetting $Config $k 1
        if(-not (($v -is [int]) -or ($v -is [long])) -or ($v -lt 1)){ $errors += "$k must be a positive integer (got '$v')." }
    }
    foreach($k in @('Score.Targets.OverCapShare','Score.Targets.NearEmptyShare','Score.Targets.ConfidentShare','Score.Targets.DupByteShare')){
        $v = Get-SysOrgSetting $Config $k 0.5
        if(($v -isnot [int]) -and ($v -isnot [long]) -and ($v -isnot [double])){ $errors += "$k must be a number between 0 and 1 (got '$v')." }
        elseif([double]$v -lt 0 -or [double]$v -gt 1){ $errors += "$k must be a number between 0 and 1 (got '$v')." }
    }
    foreach($k in @('Score.Targets.MaxDepth','Score.Targets.AvgDepth')){
        $v = Get-SysOrgSetting $Config $k 3
        if(($v -isnot [int]) -and ($v -isnot [long]) -and ($v -isnot [double])){ $errors += "$k must be a positive number (got '$v')." }
        elseif([double]$v -lt 0){ $errors += "$k must be a positive number (got '$v')." }
    }
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
    v2.1.1 (audit High #2):
      - FAIL CLOSED: when the config file exists but cannot be parsed, Import-SysOrgConfig
        THROWS by default - silently moving files on dropped user exclusions is not
        acceptable. Report-only/scheduled sessions may pass -AllowDegradedMode to continue
        with safe defaults after a loud warning.
      - NON-OVERRIDABLE PROTECTION FLOOR: SystemRoot, Program Files, Program Files (x86),
        ProgramData plus $Recycle.Bin and System Volume Information at every fixed drive
        root are always appended to ExcludedPaths after the merge, independent of
        Policy.ProtectedArtifacts.
      - ADDITIVE MERGE: Policy.ProtectedArtifacts and the per-scope BlockedExtensions lists
        merge additively - user configs can add entries but cannot remove built-ins.
.PARAMETER Path
    Path to the .psd1 config file. Missing file silently yields defaults.
.PARAMETER AppRoot
    Folder containing SysOrg.ps1; recorded in the config and excluded from scans.
.PARAMETER AllowDegradedMode
    Report-only/scheduled switch: on a parse error, continue with safe defaults after a
    loud warning instead of throwing. Never combine with plan execution.
.EXAMPLE
    $cfg = Import-SysOrgConfig -Path .\SysOrg.config.psd1 -AppRoot (Get-Location)
#>
    [CmdletBinding()]
    param([string]$Path,[string]$AppRoot,[switch]$AllowDegradedMode)
    $defaults = @{
        Version          = '3.0.1'
        # v3.0 LayoutProfile: 'Findable' is the NEW-install default (injected only when no
        # config file was loaded - see the load block below). A config file that exists
        # but does not carry the key keeps its current 'Windows' behaviour, so upgrading
        # an existing install never changes where files go.
        LayoutProfile    = 'Findable'
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
                      MinFileSizeKB=256; DocMinFileSizeKB=0; HeaderHashKB=64; QuarantineFolderName='_Duplicates'
                      RenameToKeeper=$false }
        Downloads = @{ Roots=@('Downloads'); GroupBy='SourceFirst'; DateFolders='Year'
                       UseZoneIdentifier=$true; UnknownSourceFolder='_NoSource' }
        Projects = @{ Enabled=$true; Destination='Documents\Projects\Code'; Markers=@()
                      GenericNames=@('new folder','project','code','test','src','untitled','app')
                      VerifyCrossVolumeHashes=$true }
        # v3.0.1 B2: a user-named folder inside a scan root is a signal - it moves as
        # ONE unit (never flattened) to the destination chosen by the majority
        # classification of its contents. Bounds keep the unit sane; generic, date and
        # auto-generated names are never treated as collections.
        Folders = @{ PreserveUserCollections=$true; MaxFiles=200; MaxDepth=3; MinMajorityRatio=0.6
                     GenericNames=@('new folder','untitled','copy of','archive','backup','old','misc',
                                    'miscellaneous','various','stuff','things','random','temp','tmp',
                                    'downloads','desktop','documents','pictures','videos','music') }
        Archives = @{ Extract=$false; KeepMultipartTogether=$true }
        # v3.0.1 C2: prune dependency/build directories DURING the walk - their
        # subtrees are never enumerated (counted as preserved, never moved) and code
        # projects are detected in the same pass (the separate depth-4 walk goes away).
        # A dependency folder is identified by its NAME; a project by a VCS marker or
        # two distinct project markers (see Projects.Markers).
        Prune = @{ Enabled=$true
                   DirectoryNames=@('node_modules','.venv','venv','site-packages','vendor','__pycache__',
                                    '.next','dist','build','target','.gradle','bower_components','Pods','.git') }
        Preview  = @{ NaturalSort=$true; ShowDenied=$true; WarnOneDriveSyncOut=$true }
        Privacy  = @{ StoreFullUrlsInJournal=$true }
        # v3.0 Findable layout knobs (used by the Findable LayoutProfile; the legacy
        # Windows/Compact4 profiles ignore them):
        Layout = @{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10
                    MaxDepth=4; MaxPathChars=200 }
        # v3.0 findability score targets (Score.Targets) - see SysOrg.Score.psm1.
        # v3.0.1 A2: MinPopulation = the honest 'n/a' floor for composite scores;
        # MeaningfulChangeShare = below this affected share a plan verdict reads
        # 'no meaningful change', never 'improves'/'worsens'.
        Score  = @{ Targets = @{ MaxDepth=4; AvgDepth=3.0; OverCapShare=0.05; NearEmptyShare=0.10
                                 ConfidentShare=0.80; DupByteShare=0.10 }
                    MinPopulation=20; MeaningfulChangeShare=0.05 }
        # v3.0: files the classifier cannot place with at least Classify.MinConfidence
        # are NEVER dumped into a junk folder. Mode='Report' lists them in the plan's
        # "needs a decision" section and leaves them in place; Mode='Move' files them
        # under <root>\_Review\<Year> (still previewed + undoable like any move).
        # v3.0.1 B6: InteractiveThreshold - when MORE than this share of the planned
        # moves sits below Classify.ReviewConfidence, the plan is not a ready-to-
        # execute default and the interactive [A]/[R]/[S]/[N] review runs instead.
        Review = @{ Mode='Report'; FolderName='_Review'; InteractiveThreshold=0.5 }
        # v3.0 confidence gating: >= ReviewConfidence plans normally, MinConfidence..
        # ReviewConfidence plans with a 'review' flag in the preview, below
        # MinConfidence the file is left in place (or moved to _Review) and reported.
        Classify = @{ MinConfidence=0.40; ReviewConfidence=0.70 }
        # v3.0.1 B3: self-supervised learning from the user's OWN curated folders.
        # Labels come from existing subfolders of the known folders in scope (plus
        # Learn.FromPaths); the naive Bayes model lives in <root>\_Index\model.json,
        # is versioned by an input fingerprint, and is ONLY a confidence signal that
        # appears in -Explain - it never moves anything by itself. Labels need at
        # least MinFilesPerLabel (5) files and a posterior margin of MinMargin (0.5)
        # to be trusted; generic labels are ignored.
        Learn = @{ Enabled=$true; FromPaths=@(); MinFilesPerLabel=5; MinMargin=0.5
                   MaxFilesPerLabel=500; MaxTokensPerLabel=2000
                   GenericLabels=@('documents','downloads','pictures','videos','music','desktop',
                                   'archive','archives','backup','misc','other','files','new folder','temp','tmp','unknown') }
        # v3.0 rules: UserRules are validated fail-closed at startup; learned rules are
        # NEVER applied unless ApplyLearned=$true (and they are flagged in the preview).
        # v3.0.1 A4: the source-bucket map is extensible via Rules\Sources.psd1
        # (empty path = <AppRoot>\Rules\Sources.psd1).
        Rules = @{ UserRulesPath=''; LexiconPath=''; LearnedRulesPath=''; SourcesPath=''; ApplyLearned=$false }
        # v3.0 speed: worker count for hashing/metadata. 0 = auto (min(4, cores-1);
        # an HDD spindle throttles to 1 automatically).
        Run = @{ Parallelism = 0 }
        FolderAudit = @{ Enabled=$true; MaxTopLevelDepth=2; SkipHiddenSystemDirs=$true; RespectDefenderCFA=$true; IncludeRestrictedInPlans=$false }
        Move     = @{ AllowCrossVolume = $true }
        MaxPlanActions         = 5000
        InventoryCacheHours    = 24
        # v3.0.1 D1: identical scans reuse the existing (not executed) plan
        Plans                  = @{ ReuseIdentical = $true }
        ReportsFolderName      = '_Reports'
        ScheduledTaskName      = 'SysOrg Weekly Scan'
        ScheduledDrives        = @('*')
    }
    if($Path -and (Test-Path -LiteralPath $Path)){
        $configFileLoaded = $false
        $configHasKey = $false
        try{
            $loaded = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
            if($loaded -is [hashtable]){
                $configFileLoaded = $true
                $configHasKey = $loaded.ContainsKey('LayoutProfile')
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
            $msg = "Config '$Path' could not be parsed ($($_.Exception.Message))."
            if($AllowDegradedMode){
                Write-Warning ("$msg CONTINUING WITH SAFE DEFAULTS in degraded/report-only mode - user exclusions from the config are NOT applied. Do not execute plans in this session.")
            } else {
                # v2.1.1 fail closed: a config that cannot be parsed may carry user
                # exclusions that are now unknown; moving files with defaults alone is
                # not acceptable.
                throw ("$msg SysOrg fails closed: fix or remove the config file, or use -AllowDegradedMode for report-only sessions.")
            }
        }
        # v3.0: an EXISTING config file without LayoutProfile keeps its current layout
        # (Windows). Only a fresh install (no config file at all) gets the Findable default.
        # A config that failed to parse also keeps Windows (degraded mode must not change
        # what would move).
        if(-not ($configFileLoaded -and $configHasKey)){ $defaults.LayoutProfile = 'Windows' }
    }
    if($defaults.ExcludedPaths -is [string]){ $defaults.ExcludedPaths = @($defaults.ExcludedPaths) }
    # v2.1.1: additive merges - user configuration can ADD to the protection lists but
    # cannot remove the built-in entries (a config with ProtectedArtifacts = @() used to
    # clear every system protection). Guards keep a hostile non-hashtable Policy harmless.
    $builtInArtifacts = @('Windows','Program Files','Program Files (x86)','ProgramData','WindowsApps',
                          'XboxGames','$Recycle.Bin','System Volume Information','Recovery','Boot','MSOCache','PerfLogs')
    $builtInBlockedSystem = @('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url')
    $builtInBlockedData   = @('.dll','.sys','.drv','.ocx','.cpl','.scr')
    if($defaults.Policy -is [hashtable]){
        $defaults.Policy.ProtectedArtifacts = Join-SysOrgProtectedList -User $defaults.Policy.ProtectedArtifacts -BuiltIn $builtInArtifacts -Label 'Policy.ProtectedArtifacts'
        if($defaults.Policy.SystemDrive -is [hashtable]){
            $defaults.Policy.SystemDrive.BlockedExtensions = Join-SysOrgProtectedList -User $defaults.Policy.SystemDrive.BlockedExtensions -BuiltIn $builtInBlockedSystem -Label 'Policy.SystemDrive.BlockedExtensions'
        }
        if($defaults.Policy.DataDrives -is [hashtable]){
            $defaults.Policy.DataDrives.BlockedExtensions = Join-SysOrgProtectedList -User $defaults.Policy.DataDrives.BlockedExtensions -BuiltIn $builtInBlockedData -Label 'Policy.DataDrives.BlockedExtensions'
        }
    }
    # W9/P1-7: protected artifacts on EVERY fixed drive, appended after the user merge.
    try{
        $artifacts = @($defaults.Policy.ProtectedArtifacts)
        foreach($drv in [System.IO.DriveInfo]::GetDrives()){
            if($drv.DriveType -ne 'Fixed'){ continue }
            if(-not $drv.IsReady){ continue }
            $r = $drv.Name.TrimEnd('\')
            foreach($a in $artifacts){ $defaults.ExcludedPaths += ($r + '\' + $a) }
        }
    } catch { Write-Verbose "Could not enumerate fixed drives for default exclusions: $($_.Exception.Message)" }
    # v2.1.1: NON-OVERRIDABLE protection floor - always appended after the merge,
    # independent of Policy.ProtectedArtifacts. Even a config that replaces ExcludedPaths
    # wholesale cannot remove these.
    $floor = @()
    foreach($envName in @('SystemRoot','ProgramFiles','ProgramFiles(x86)','ProgramData')){
        $v = [Environment]::GetEnvironmentVariable($envName)
        if($v -and (Test-Path -LiteralPath $v)){ $floor += ($v.TrimEnd('\')) }
    }
    try{
        foreach($drv in [System.IO.DriveInfo]::GetDrives()){
            if($drv.DriveType -ne 'Fixed'){ continue }
            if(-not $drv.IsReady){ continue }
            $r = $drv.Name.TrimEnd('\')
            $floor += ($r + '\$Recycle.Bin')
            $floor += ($r + '\System Volume Information')
        }
    } catch { Write-Verbose "Could not enumerate fixed drives for the protection floor: $($_.Exception.Message)" }
    foreach($f in $floor){
        if(@($defaults.ExcludedPaths) -notcontains $f){ $defaults.ExcludedPaths = @($defaults.ExcludedPaths) + $f }
    }
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

# ---------------------------------------------------------------------------
# v3.0.2 A1: last-error diagnostics for support. The menu catch-all and every
# CLI entry point log the FULL exception (type, message, script stack trace,
# invocation position) through Write-SysOrgErrorDiagnostic; the record is kept
# so -Diagnostics (v3.0.2 A4) can bundle it.
# ---------------------------------------------------------------------------
$script:SysOrgLastErrorRecord = $null

function Get-SysOrgLastError {
<#
.SYNOPSIS
    The last recorded SysOrg error with its full diagnostic fields (v3.0.2 A1/A4).
.DESCRIPTION
    $null when no error was recorded in this session.
.EXAMPLE
    Get-SysOrgLastError   # -> @{ When=...; Type=...; Message=...; ... }
#>
    return $script:SysOrgLastErrorRecord
}

function Write-SysOrgErrorDiagnostic {
<#
.SYNOPSIS
    Logs the FULL diagnostic of a terminating error and returns the log path.
.DESCRIPTION
    Writes exception type, message, ScriptStackTrace and
    InvocationInfo.PositionMessage to the dated log file (one [ERROR] block per
    field), remembers the record for Get-SysOrgLastError / -Diagnostics, and
    returns the log file path ('' when the log itself could not be written).
    Never throws.
.EXAMPLE
    $p = Write-SysOrgErrorDiagnostic -ErrorRecord $_ -LogFolder $logFolder -Phase 'preview'
    Write-Host ("Diagnostics written to: {0}" -f $p)
#>
    param([Parameter(Mandatory)]$ErrorRecord,
          [string]$LogFolder,
          [ValidateSet('preview','execute')][string]$Phase = 'preview')
    $ex = $ErrorRecord.Exception
    $type = if($null -ne $ex){ $ex.GetType().FullName } else { 'Unknown' }
    $msg  = if($null -ne $ex){ "$($ex.Message)" } else { "$ErrorRecord" }
    $stack = "$($ErrorRecord.ScriptStackTrace)"
    $pos = ''
    try { if($ErrorRecord.InvocationInfo){ $pos = "$($ErrorRecord.InvocationInfo.PositionMessage)" } } catch { }
    $script:SysOrgLastErrorRecord = [pscustomobject]@{
        When = (Get-Date).ToString('s'); Phase = $Phase; Type = $type
        Message = $msg; ScriptStackTrace = $stack; PositionMessage = $pos
    }
    $logPath = ''
    if($LogFolder){
        try{
            if(-not (Test-Path -LiteralPath $LogFolder)){ New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
            $logPath = Join-Path $LogFolder ('sysorg-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
            $lines = @(
                ("[{0}] [ERROR ] --- diagnostic begin (phase={1}) ---" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Phase),
                ("[{0}] [ERROR ] Exception type:    {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $type),
                ("[{0}] [ERROR ] Exception message: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg),
                ("[{0}] [ERROR ] Script stack trace: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $stack),
                ("[{0}] [ERROR ] Position: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $pos),
                ("[{0}] [ERROR ] --- diagnostic end ---" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            )
            Add-Content -LiteralPath $logPath -Value $lines -Encoding UTF8
        } catch { $logPath = ''; Write-Verbose ("SysOrg diagnostic log write failed: " + $_.Exception.Message) }
    }
    return $logPath
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

# ---------------------------------------------------------------------------
# v3.0.2 A2/B1: reparse-point TAG resolution. The 0x400 ReparsePoint ATTRIBUTE
# alone conflates junctions and symlinks with OneDrive cloud folders - which is
# how the real run's OneDrive Documents/Pictures/Desktop got skipped as
# 'cannot alter'. Get-SysOrgReparseTag reads the actual reparse TAG:
#   - in-process test mocks first (Set-SysOrgReparseTagMock),
#   - then the SYSORG_REPARSE_MOCK environment variable ('path=0xTag;...') so a
#     CHILD-PROCESS smoke run (real menu/CLI code path) can simulate cloud
#     folders on any machine,
#   - then the true tag from WIN32_FIND_DATA.dwReserved0 (FindFirstFileW).
# Tag constants are the documented Windows values (winnt.h / 'Reparse Point
# Tags' on Microsoft Learn): MOUNT_POINT 0xA0000003 (junction), SYMLINK
# 0xA000000C, and the cloud family 0x90000000-0x9000F001 (OneDrive cloud files).
# ---------------------------------------------------------------------------
$script:SysOrgReparseTagMocks = @{}

if(-not ('SysOrg.NativeFind' -as [type])){
    try{
        Add-Type -Namespace SysOrg -Name NativeFind -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct WIN32_FIND_DATAW {
    public uint dwFileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
    public uint nFileSizeHigh;
    public uint nFileSizeLow;
    public uint dwReserved0;
    public uint dwReserved1;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string cFileName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
    public string cAlternateFileName;
}
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr FindFirstFileW(string lpFileName, out WIN32_FIND_DATAW lpFindFileData);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FindClose(IntPtr hFindFile);
'@
    } catch { Write-Verbose "Native find P/Invoke unavailable: $($_.Exception.Message)" }
}

function Set-SysOrgReparseTagMock {
<#
.SYNOPSIS
    Registers an in-process reparse-tag mock for one path (v3.0.2 test seam).
.EXAMPLE
    Set-SysOrgReparseTagMock -Path 'C:\Users\a\Documents' -Tag 0x90000001   # OneDrive cloud
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Tag)
    $key = ("$Path").TrimEnd('\').TrimEnd('/').ToLowerInvariant()
    # 0x90000001-class literals parse as negative INTs in PowerShell - normalize
    # through long before the uint32 cast
    $script:SysOrgReparseTagMocks[$key] = [uint32]([long]$Tag -band 0xFFFFFFFFL)
}

function Clear-SysOrgReparseTagMocks {
<#
.SYNOPSIS
    Removes every in-process reparse-tag mock (v3.0.2 test seam).
#>
    $script:SysOrgReparseTagMocks = @{}
}

function Get-SysOrgReparseTag {
<#
.SYNOPSIS
    The reparse TAG of a path: uint32 tag, 0 for 'not a reparse point', $null when
    unknowable (non-Windows host without a mock). Never follows the link.
.DESCRIPTION
    Resolution order: in-process mocks, the SYSORG_REPARSE_MOCK env var
    ('path=0x90000001;path2=0xA0000003', case-insensitive on the path, values hex
    or decimal), then the true dwReserved0 via FindFirstFileW on Windows hosts.
.EXAMPLE
    Get-SysOrgReparseTag -Path 'C:\Users\a\Documents'   # -> 0x90000001 (cloud) / 0 / $null
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $key = ("$Path").TrimEnd('\').TrimEnd('/').ToLowerInvariant()
    # 1) in-process mocks (unit tests)
    if($script:SysOrgReparseTagMocks.ContainsKey($key)){ return [uint32]$script:SysOrgReparseTagMocks[$key] }
    # 2) environment mocks (child-process smoke runs)
    $envMock = $env:SYSORG_REPARSE_MOCK
    if(-not [string]::IsNullOrWhiteSpace($envMock)){
        foreach($pair in ($envMock -split ';')){
            if([string]::IsNullOrWhiteSpace("$pair")){ continue }
            $idx = "$pair".LastIndexOf('=')
            if($idx -lt 1){ continue }
            $mp = ("$pair".Substring(0,$idx)).Trim().TrimEnd('\').TrimEnd('/').ToLowerInvariant()
            if($mp -ieq $key){
                $raw = ("$pair".Substring($idx+1)).Trim()
                try {
                    if($raw -match '^(?i:0x)?([0-9A-Fa-f]{1,8})$'){ return [uint32][Convert]::ToUInt32($Matches[1], 16) }
                    return [uint32][Convert]::ToUInt32($raw)
                } catch { return $null }
            }
        }
    }
    # 3) the real tag (Windows only)
    if(($env:OS -eq 'Windows_NT') -and ('SysOrg.NativeFind' -as [type])){
        try{
            $fd = New-Object SysOrg.NativeFind+WIN32_FIND_DATAW
            $h = [SysOrg.NativeFind]::FindFirstFileW("$Path", [ref]$fd)
            if($h -eq [IntPtr](-1)){ return 0 }
            try {
                $tag = [uint32]$fd.dwReserved0
                if(([int]$fd.dwFileAttributes -band 0x400) -eq 0){ return 0 }
                return $tag
            } finally { [void][SysOrg.NativeFind]::FindClose($h) }
        } catch { return $null }
    }
    return $null
}

# ---------------------------------------------------------------------------
# v3.0.2 A4: session transcript + support bundle. Every interactive session
# auto-writes Logs\last-run.txt (PowerShell transcript) so a user asking for
# help can hand over exactly what happened; -Diagnostics bundles versions,
# config hash, the last 200 log lines and the last error into one file.
# ---------------------------------------------------------------------------
function Start-SysOrgTranscriptCapture {
<#
.SYNOPSIS
    Starts a PowerShell transcript into Logs\last-run.txt (v3.0.2 A4).
.DESCRIPTION
    Best effort: when the host forbids transcripts the session continues and ''
    is returned. A stale transcript from a crashed session is stopped first.
.EXAMPLE
    Start-SysOrgTranscriptCapture -LogFolder C:\SysOrg\Logs   # -> the path or ''
#>
    param([string]$LogFolder)
    try{
        if(-not (Test-Path -LiteralPath $LogFolder)){ New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
        $path = Join-Path $LogFolder 'last-run.txt'
        try { Stop-Transcript | Out-Null } catch { }   # stale transcript from a crashed session
        Start-Transcript -Path $path -ErrorAction Stop | Out-Null
        return $path
    } catch { Write-Verbose ("Transcript capture unavailable: " + $_.Exception.Message); return '' }
}

function Stop-SysOrgTranscriptCapture {
<#
.SYNOPSIS
    Stops the session transcript if one is running (v3.0.2 A4). Never throws.
#>
    try { Stop-Transcript | Out-Null } catch { }
}

function Get-SysOrgLogTail {
<#
.SYNOPSIS
    The last N lines of the newest SysOrg log file (v3.0.2 A4).
.DESCRIPTION
    Returns the log file path plus its tail. Best effort: an unreadable or
    missing log yields an empty tail, never a throw.
.EXAMPLE
    Get-SysOrgLogTail -LogFolder C:\SysOrg\Logs -Lines 200
#>
    param([string]$LogFolder,[int]$Lines=200)
    $result = @{ Path=''; Lines=@() }
    try{
        if([string]::IsNullOrWhiteSpace($LogFolder) -or (-not (Test-Path -LiteralPath $LogFolder))){ return $result }
        $newest = @(Get-ChildItem -LiteralPath $LogFolder -Filter 'sysorg-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if($newest.Count -eq 0){ return $result }
        $result.Path = $newest[0].FullName
        $result.Lines = @(Get-Content -LiteralPath $newest[0].FullName -Tail $Lines -ErrorAction SilentlyContinue)
    } catch { }
    return $result
}

function Get-SysOrgReparseClassification {
<#
.SYNOPSIS
    Classifies a path's reparse point by its TAG, not by the attribute alone.
.DESCRIPTION
    Returns one of:
      'None'     - not a reparse point (or the tag could not be read on Windows)
      'Symlink'  - IO_REPARSE_TAG_SYMLINK (0xA000000C) - never followed
      'Junction' - IO_REPARSE_TAG_MOUNT_POINT (0xA0000003) - never followed
      'Cloud'    - the cloud-files family (0x90000000-0x9000F001, OneDrive) - a
                   NORMAL folder: traversed, listed, planned like any other;
                   placeholder FILES are handled separately via
                   Test-SysOrgCloudPlaceholderAttributes and are never opened
      'Other'    - any other tag (APPEXECLINK etc.) - never followed
      'Unknown'  - the tag is unknowable (non-Windows host without a mock);
                   callers fall back to the attribute check
    Tag values are the documented Windows constants (winnt.h / 'Reparse Point
    Tags', Microsoft Learn) - never invented.
.EXAMPLE
    Get-SysOrgReparseClassification -Path 'C:\Users\a\Documents'   # -> Cloud
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $tag = Get-SysOrgReparseTag -Path $Path
    if($null -eq $tag){ return 'Unknown' }
    if($tag -eq 0){ return 'None' }
    # 0xA000000C / 0xA0000003 / 0xF0000000 / 0x90000000 as uint32 (hex literals of
    # this size parse as negative ints in PowerShell)
    $tagSymlink  = [uint32][Convert]::ToUInt32('A000000C',16)   # IO_REPARSE_TAG_SYMLINK
    $tagJunction = [uint32][Convert]::ToUInt32('A0000003',16)   # IO_REPARSE_TAG_MOUNT_POINT
    if($tag -eq $tagSymlink){ return 'Symlink' }
    if($tag -eq $tagJunction){ return 'Junction' }
    $tagFlagsMask = [uint32][Convert]::ToUInt32('F0000000',16)
    $tagCloudBase = [uint32]2415919104                          # 0x90000000 (cloud family)
    if((([long]$tag -band [long]$tagFlagsMask)) -eq [long]$tagCloudBase){ return 'Cloud' }
    return 'Other'
}

function Test-SysOrgLegacyJunctionName {
<#
.SYNOPSIS
    True for the legacy Windows junction names My Pictures / My Videos / My Music.
.DESCRIPTION
    These junctions exist on every Windows profile since XP; skipping them is
    EXPECTED behaviour and must not be reported as an alarming 'cannot alter'
    entry (v3.0.2 B3).
.EXAMPLE
    Test-SysOrgLegacyJunctionName -Name 'My Pictures'   # -> True
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $n = "$Name".ToLowerInvariant()
    return ($n -in @('my pictures','my videos','my music'))
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

function Get-SysOrgParallelism {
<#
.SYNOPSIS
    Resolves the worker count for hashing/metadata (v3.0 Phase 3.4).
.DESCRIPTION
    Run.Parallelism config overrides everything. Otherwise min(4, cores-1); a drive
    profile whose MediaType reports HDD (spindle) throttles to 1 - parallel random
    reads on one spindle make the seek pattern worse, not better.
.EXAMPLE
    Get-SysOrgParallelism -Config $cfg -DriveProfile $prof   # -> 3
#>
    [CmdletBinding()]
    param($Config,$DriveProfile)
    $cores = 2
    try { $cores = [Math]::Max(1, [Environment]::ProcessorCount) } catch { $cores = 2 }
    $auto = [Math]::Max(1, [Math]::Min(4, $cores - 1))
    $cfg = [int](Get-SysOrgSetting $Config 'Run.Parallelism' 0)
    if($cfg -gt 0){ return $cfg }
    try{
        if($DriveProfile -and $DriveProfile.Drive -and ("$($DriveProfile.Drive.MediaType)" -ieq 'HDD')){ return 1 }
    } catch { }
    return $auto
}

function Get-SysOrgFileHashHeadTail {
<#
.SYNOPSIS
    SHA256 over the head 64 KB + tail 64 KB (the fast duplicate pre-filter, v3.0 Phase 3.5).
.DESCRIPTION
    One SHA256 transform over both buffers, so identical files always produce the
    same value and different-size files at the same size bucket separate on their
    tails (MP3s with shared headers, appended logs, etc.). Fail soft: $null on
    unreadable files.
.EXAMPLE
    Get-SysOrgFileHashHeadTail -Path 'C:\big.zip' -HeaderKB 64 -TailKB 64
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[int]$HeaderKB=64,[int]$TailKB=64)
    try{
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try{
            $stream = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
            try{
                $headLen = [int][Math]::Min(($HeaderKB * 1KB), $stream.Length)
                $tailLen = [int][Math]::Min(($TailKB * 1KB), [Math]::Max(0, ($stream.Length - $headLen)))
                if(($headLen -le 0) -and ($tailLen -le 0)){ return 'EMPTY' }
                if($headLen -gt 0){
                    $head = New-Object byte[] $headLen
                    $read = 0
                    while($read -lt $headLen){
                        $n = $stream.Read($head, $read, $headLen - $read)
                        if($n -le 0){ break }
                        $read += $n
                    }
                    $sha.TransformBlock($head, 0, $read, $null, 0) | Out-Null
                }
                if($tailLen -gt 0){
                    $stream.Seek(-$tailLen, 'End') | Out-Null
                    $tail = New-Object byte[] $tailLen
                    $read = 0
                    while($read -lt $tailLen){
                        $n = $stream.Read($tail, $read, $tailLen - $read)
                        if($n -le 0){ break }
                        $read += $n
                    }
                    $sha.TransformBlock($tail, 0, $read, $null, 0) | Out-Null
                }
                $sha.TransformFinalBlock([byte[]]@(), 0, 0) | Out-Null
                return ([System.BitConverter]::ToString($sha.Hash)).Replace('-','')
            } finally { $stream.Dispose() }
        } finally { $sha.Dispose() }
    } catch { return $null }
}

function Invoke-SysOrgParallelHash {
<#
.SYNOPSIS
    Full SHA256 over a list of files with a RunspacePool (v3.0 Phase 3.4).
.DESCRIPTION
    PS 5.1-compatible RunspacePool bounded to -Parallelism workers; results are
    collected INTO THE INPUT ORDER (indexed), so output stays deterministic no
    matter which worker finishes first. Any pool failure falls back to sequential
    hashing. Locked/unreadable files yield $null entries (same as Get-SysOrgFileHash).
.EXAMPLE
    $hashes = Invoke-SysOrgParallelHash -Paths @('C:\a.zip','C:\b.zip') -Parallelism 3
#>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Paths,[int]$Parallelism=2)
    $paths = @($Paths)
    $results = New-Object 'object[]' $paths.Length
    if($paths.Count -eq 0){ return $results }
    $usePool = $Parallelism -gt 1
    $pool = $null
    if($usePool){
        try{
            $iss = [initialsessionstate]::CreateDefault()
            $pool = [runspacefactory]::CreateRunspacePool(1, $Parallelism, $iss, $Host)
            $pool.Open()
        } catch { $pool = $null; $usePool = $false }
    }
    $script = {
        param([string]$P)
        try{
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try{
                $stream = [System.IO.File]::Open($P,'Open','Read','ReadWrite')
                try{
                    $h = $sha.ComputeHash($stream)
                    return ([System.BitConverter]::ToString($h)).Replace('-','')
                } finally { $stream.Dispose() }
            } finally { $sha.Dispose() }
        } catch { return $null }
    }
    try{
        if($usePool -and $pool){
            $jobs = @()
            for($i=0; $i -lt $paths.Count; $i++){
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($script).AddArgument($paths[$i])
                $jobs += [pscustomobject]@{ Index=$i; PS=$ps; Handle=$ps.BeginInvoke() }
            }
            foreach($j in $jobs){
                try{
                    $out = $j.PS.EndInvoke($j.Handle)
                    $results[$j.Index] = $(if($out -and $out.Count -gt 0){ $out[0] } else { $null })
                } catch { $results[$j.Index] = $null }
            }
        } else {
            for($i=0; $i -lt $paths.Count; $i++){
                $results[$i] = & $script $paths[$i]
            }
        }
    } finally {
        foreach($j in $jobs){ try { $j.PS.Dispose() } catch { } }
        if($pool){ try { $pool.Close(); $pool.Dispose() } catch { } }
    }
    return $results
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
    # v3.0.1 C1: normalize separators like the compiled fast path - pwsh on non-Windows
    # hosts normalizes Split-Path output to '/', and the two paths must agree
    $p = ("$Path").Replace('/','\').TrimEnd('\')
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

function New-SysOrgExclusionMatcher {
<#
.SYNOPSIS
    Builds ONE precompiled matcher for the exclusion rules (v3.0 Phase 3.3).
.DESCRIPTION
    Instead of looping every pattern for every path, the matcher splits the rules
    once per run into: a case-insensitive HashSet of absolute prefixes, a single
    compiled alternation regex for wildcard patterns, a HashSet of root-less
    segment names, and the app root. Test-SysOrgExcludedPathFast then answers in a
    few lookups. Semantics are IDENTICAL to Test-SysOrgExcludedPath (documented
    behaviour must not change with the speed work).
.EXAMPLE
    $m = New-SysOrgExclusionMatcher -Config $cfg
    Test-SysOrgExcludedPathFast -Path 'D:\$Recycle.Bin\x' -Matcher $m   # -> True
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $exact = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $wildcards = New-Object System.Collections.Generic.List[string]
    $segments = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach($pat in @($Config.ExcludedPaths)){
        if([string]::IsNullOrWhiteSpace("$pat")){ continue }
        $p = ("$pat").TrimEnd('\')
        if($p.Contains('*') -or $p.Contains('?')){
            # -like semantics: '*' matches ANY run of characters INCLUDING separators,
            # '?' matches one character; the match is anchored over the whole path and
            # a trailing (\\|$) covers "anything inside this folder".
            $escaped = [regex]::Escape($p).Replace('\*','.*').Replace('\?','.')
            [void]$wildcards.Add($escaped)
        }
        elseif(($p -notmatch '^[A-Za-z]:') -and ($p -notmatch '\\')){
            [void]$segments.Add($p)
        }
        else {
            [void]$exact.Add($p)
        }
    }
    $wildRegex = $null
    if($wildcards.Count -gt 0){
        try { $wildRegex = [regex]::new(('^(' + ($wildcards -join '|') + ')(\\|$)'), 'IgnoreCase') } catch { $wildRegex = $null }
    }
    $appRoot = Get-SysOrgSetting $Config 'AppRoot' $null
    return [pscustomobject]@{
        Exact=$exact; WildRegex=$wildRegex; Segments=$segments
        AppRoot=$(if($appRoot){ ("$appRoot").TrimEnd('\') } else { $null })
    }
}

function Test-SysOrgExcludedPathFast {
<#
.SYNOPSIS
    Fast path-exclusion check against a precompiled matcher (v3.0 Phase 3.3).
.DESCRIPTION
    Identical semantics to Test-SysOrgExcludedPath: wildcard rules match the path
    itself AND anything inside it, root-less names match ANY path segment, the app
    root is always protected. O(1) hash lookups plus one regex over the whole path.
.EXAMPLE
    Test-SysOrgExcludedPathFast -Path 'C:\Windows\notepad.exe' -Matcher $m   # -> True
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Matcher)
    $p = ("$Path").Replace('/','\').TrimEnd('\')
    if([string]::IsNullOrWhiteSpace($p)){ return $false }
    if($Matcher.AppRoot -and ($p -ieq $Matcher.AppRoot -or $p.StartsWith($Matcher.AppRoot + '\',[StringComparison]::OrdinalIgnoreCase))){ return $true }
    # exact absolute rules match the path itself AND any ancestor (prefix semantics):
    # a handful of case-insensitive hash lookups, depth-bounded
    $cur = $p
    while($cur -and ($cur.Length -gt 3)){
        if($Matcher.Exact.Contains($cur)){ return $true }
        $idx = $cur.LastIndexOf('\')
        if($idx -le 0){ break }
        $cur = $cur.Substring(0, $idx)
    }
    if($Matcher.WildRegex){ if($Matcher.WildRegex.IsMatch($p)){ return $true } }
    if($Matcher.Segments.Count -gt 0){
        foreach($seg in ($p.Split('\'))){ if($Matcher.Segments.Contains($seg)){ return $true } }
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

# v3.0.1 C1/C4: ONE compiled alternation regex for ExcludedFilePatterns, cached per
# config object and looked up by REFERENCE identity (hashing a large config hashtable
# per file would itself cost milliseconds). -like semantics per pattern ('*' -> '.*',
# '?' -> '.', anchored over the file NAME) - identical matching to
# Test-SysOrgExcludedFile, one compiled regex per run.
$script:SysOrgExcludedFileRegexCache = @{}

function Get-SysOrgExcludedFileMatcher {
<#
.SYNOPSIS
    The compiled ExcludedFilePatterns regex for a config, cached per config object (v3.0.1 C1/C4).
.EXAMPLE
    $rx = Get-SysOrgExcludedFileMatcher -Config $cfg; $rx.IsMatch('a.tmp')   # -> True
#>
    [CmdletBinding()]
    param($Config)
    foreach($entry in $script:SysOrgExcludedFileRegexCache.Values){
        if([object]::ReferenceEquals($entry.Config, $Config)){ return $entry.Value }
    }
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach($pat in @($Config.ExcludedFilePatterns)){
        if([string]::IsNullOrWhiteSpace("$pat")){ continue }
        [void]$patterns.Add(([regex]::Escape("$pat")).Replace('\*','.*').Replace('\?','.'))
    }
    $rx = $null
    if($patterns.Count -gt 0){
        try { $rx = [regex]::new('^(' + ($patterns -join '|') + ')$', 'IgnoreCase') } catch { $rx = $null }
    }
    $script:SysOrgExcludedFileRegexCache[[guid]::NewGuid().ToString()] = @{ Config=$Config; Value=$rx }
    return $rx
}

function Test-SysOrgExcludedFileFast {
<#
.SYNOPSIS
    Compiled-regex fast path of Test-SysOrgExcludedFile (identical semantics, v3.0.1 C1/C4).
#>
    [CmdletBinding()]
    param([string]$Path,$Config)
    $rx = Get-SysOrgExcludedFileMatcher -Config $Config
    if(-not $rx){ return $false }
    return $rx.IsMatch((Split-Path $Path -Leaf))
}

function ConvertTo-SysOrgPath {
<#
.SYNOPSIS
    Normalizes one path to a full backslash form and REJECTS drive-relative forms (v3.0.1 A1).
.DESCRIPTION
    'C:file' and 'C:' resolve against the CURRENT DIRECTORY of drive C in .NET and
    Win32 - two runs can silently touch two different folders. The helper accepts
    full drive paths ('C:\', 'C:\a\b'), UNC paths ('\\server\share\...') and the
    \\?\ namespace, converts '/' separators, and THROWS on drive-relative input
    (^[A-Za-z]:(?![\\])), empty input and '.'/'..' segments.
.EXAMPLE
    ConvertTo-SysOrgPath -Path 'C:\a\b'   # -> 'C:\a\b'
.EXAMPLE
    ConvertTo-SysOrgPath -Path 'C:file'   # throws (drive-relative)
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $p = ("$Path").Replace('/','\').Trim()
    if([string]::IsNullOrWhiteSpace($p)){ throw 'Path is empty.' }
    if($p -match '^[A-Za-z]:(?![\\])'){
        throw ("Drive-relative path '{0}' is ambiguous: it resolves against the drive's CURRENT directory. Use the full form 'X:\...'." -f $p)
    }
    if($p -match '(^|\\)\.{1,2}(\\|$)'){
        throw ("Path '{0}' contains a '.' or '..' segment." -f $p)
    }
    return $p
}

function Get-SysOrgDriveRootPath {
<#
.SYNOPSIS
    The enumeration/probe path for a drive root: 'X:\' - NEVER the drive-relative 'X:' (v3.0.1 A1).
.DESCRIPTION
    'X:' (slash stripped) is a drive-relative path: .NET and Win32 resolve it against
    the drive's CURRENT directory, so a scan or audit started from a subfolder would
    enumerate that subfolder instead of the drive root. Every enumeration and every
    probe must use the full 'X:\' form; the slash is stripped only for DISPLAY.
.EXAMPLE
    Get-SysOrgDriveRootPath -Letter x   # -> 'X:\'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter)
    $l = ("$Letter").Trim().TrimEnd(':').TrimEnd('\').ToUpper()
    if($l -notmatch '^[A-Z]$'){ throw ("'{0}' is not a drive letter." -f $Letter) }
    return ('{0}:\' -f $l)
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
          [Parameter(Mandatory)]$DriveProfile,$Config,[switch]$Container,
          [hashtable]$PolicyCache,[AllowNull()]$ExMatcher)
    $checkPath = if($Container){ $Path.TrimEnd('\') } else { Split-Path $Path -Parent }
    if($ExMatcher){
        if(Test-SysOrgExcludedPathFast -Path $checkPath -Matcher $ExMatcher){
            return [pscustomobject]@{ Allowed=$false; Reason='Protected path' }
        }
    } elseif(Test-SysOrgExcludedPath -Path $checkPath -Config $Config){
        return [pscustomobject]@{ Allowed=$false; Reason='Protected path' }
    }
    # v3.0.1 C1: policy lookups are the per-file hotspot. When the caller supplies a
    # -PolicyCache (one per run), the resolved policy is computed ONCE and reused;
    # the cache key carries the config hash + role so distinct configs never collide
    # on identical content, and identical content can only produce identical policy.
    $role = "$($DriveProfile.Role)"
    $polKey = ''
    $blocked = $null
    $scope = $null
    $writable = $null
    $allowInstallers = $null
    $cacheHit = $false
    if($PolicyCache){
        # reference-identity config key: hashing a large config per file costs more
        # than the lookups it saves
        $ck = $null
        foreach($k in $PolicyCache.Keys){
            $e = $PolicyCache[$k]
            if([object]::ReferenceEquals($e.Config, $Config) -and "$($e.Letter)" -eq "$($DriveProfile.Letter)" -and "$($e.Role)" -eq $role){
                $ck = $k; break
            }
        }
        if($ck){
            $cacheHit = $true
            $pc = $PolicyCache[$ck]
            $polKey = $pc.PolKey; $blocked = $pc.Blocked; $scope = $pc.Scope; $writable = $pc.Writable; $allowInstallers = $pc.AllowInstallers
        } else {
            $polKey = if($role -ieq 'System'){ 'Policy.SystemDrive' } else { 'Policy.DataDrives' }
            $blocked = @(Get-SysOrgSetting $Config ($polKey + '.BlockedExtensions') @())
            $defaultScope = if($role -ieq 'System'){ 'KnownFolders' } else { 'FullDrive' }
            $scope = "$(Get-SysOrgSetting $Config ($polKey + '.Scope') $defaultScope)"
            $writable = @()
            if("$scope" -eq 'KnownFolders'){
                foreach($k in @($DriveProfile.KnownFolders)){
                    if($k.Path){ $writable += [string]$k.Path }
                }
            }
            $writable += @(Get-SysOrgSetting $Config ($polKey + '.WritablePaths') @())
            $allowInstallers = [bool](Get-SysOrgSetting $Config ($polKey + '.AllowInstallersInDownloads') $true)
            $PolicyCache[[guid]::NewGuid().ToString()] = @{ Config=$Config; Letter="$($DriveProfile.Letter)"; Role=$role
                PolKey=$polKey; Blocked=$blocked; Scope=$scope; Writable=$writable; AllowInstallers=$allowInstallers }
        }
    }
    if(-not $cacheHit){
        if($role -ieq 'System'){ $polKey = 'Policy.SystemDrive' } else { $polKey = 'Policy.DataDrives' }
        $blocked = @(Get-SysOrgSetting $Config ($polKey + '.BlockedExtensions') @())
        $allowInstallers = [bool](Get-SysOrgSetting $Config ($polKey + '.AllowInstallersInDownloads') $true)
    }
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
        if((-not $inDownloads) -or (-not $allowInstallers)){
            return [pscustomobject]@{ Allowed=$false; Reason='Installer outside download roots' }
        }
    }
    if(-not $cacheHit){
        $defaultScope = if($role -ieq 'System'){ 'KnownFolders' } else { 'FullDrive' }
        $scope = Get-SysOrgSetting $Config ($polKey + '.Scope') $defaultScope
        $writable = @()
        if("$scope" -eq 'KnownFolders'){
            foreach($k in @($DriveProfile.KnownFolders)){
                if($k.Path){ $writable += [string]$k.Path }
            }
        }
        $writable += @(Get-SysOrgSetting $Config ($polKey + '.WritablePaths') @())
    }
    if("$scope" -eq 'FullDrive'){
        return [pscustomobject]@{ Allowed=$true; Reason='' }
    }
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
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,$Config,[string]$ExpectedHash)
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
            # v2.1.1 (item 10): reuse a pre-move hash when the caller already computed one,
            # instead of hashing the source up to three times (scan-time, pre-move, here).
            $origHash = if($ExpectedHash){ $ExpectedHash } else { Get-SysOrgFileHash -Path $Source }
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

function Test-SysOrgFolderHasReparsePoint {
<#
.SYNOPSIS
    Walks a folder and reports whether its tree contains any junction or symlink (v2.1.1).
.DESCRIPTION
    Folder-move safety: a folder that contains a reparse point anywhere in its tree is
    refused for moves, because a verification or deletion pass could otherwise follow the
    link outside the folder. Detection uses the raw 0x400 ReparsePoint attribute (identical
    behavior on Windows PowerShell 5.1 and PowerShell 7) plus the .NET Core LinkTarget
    property for symlinks on non-Windows hosts, where reparse attributes do not exist.
    ANY enumeration error aborts with Error set - the caller keeps the source (fail closed).
    The path is resolved through the PowerShell provider FIRST: the provider accepts both
    separator styles ('X\Y' segments from plan JSON resolve on POSIX test hosts too), while
    raw .NET APIs do not, and a missing path reports Attributes=-1 (all bits set) instead of
    throwing - both traps are handled here.
.EXAMPLE
    Test-SysOrgFolderHasReparsePoint -Path 'C:\proj'   # -> @{ HasLink=$false; Error='' }
#>
    param([Parameter(Mandatory)][string]$Path)
    $rootPath = $Path
    try { $rootPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath }
    catch { return @{ HasLink=$true; Error=("path could not be resolved: '{0}'" -f $Path) } }
    $stack = New-Object System.Collections.Stack
    [void]$stack.Push($rootPath)
    $visited = @{}
    while($stack.Count -gt 0){
        $dir = [string]$stack.Pop()
        $key = $dir.ToLowerInvariant()
        if($visited.ContainsKey($key)){ continue }
        $visited[$key] = $true
        try{
            $di = New-Object System.IO.DirectoryInfo($dir)
            $da = [int]$di.Attributes
            if($da -eq -1){ return @{ HasLink=$true; Error=("folder vanished during the walk: {0}" -f $dir) } }
            if(($da -band 0x400) -ne 0){ return @{ HasLink=$true; Error='' } }
            if($di.PSObject.Properties['LinkTarget'] -and $di.LinkTarget){ return @{ HasLink=$true; Error='' } }
            foreach($sub in $di.GetDirectories()){
                $sa = [int]$sub.Attributes
                if($sa -eq -1){ return @{ HasLink=$true; Error=("folder vanished during the walk: {0}" -f $sub.FullName) } }
                if(($sa -band 0x400) -ne 0){ return @{ HasLink=$true; Error='' } }
                if($sub.PSObject.Properties['LinkTarget'] -and $sub.LinkTarget){ return @{ HasLink=$true; Error='' } }
                [void]$stack.Push($sub.FullName)
            }
            foreach($f in $di.GetFiles()){
                $fa = [int]$f.Attributes
                if($fa -eq -1){ return @{ HasLink=$true; Error=("file vanished during the walk: {0}" -f $f.FullName) } }
                if(($fa -band 0x400) -ne 0){ return @{ HasLink=$true; Error='' } }
                if($f.PSObject.Properties['LinkTarget'] -and $f.LinkTarget){ return @{ HasLink=$true; Error='' } }
            }
        } catch {
            return @{ HasLink=$true; Error=("enumeration failed on '{0}': {1}" -f $dir, $_.Exception.Message) }
        }
    }
    return @{ HasLink=$false; Error='' }
}

function Get-SysOrgFolderMoveStats {
<#
.SYNOPSIS
    Plan-time statistics for a folder move: file count, non-code files, blocked extensions.
.DESCRIPTION
    Used by the preview (v2.1.1): per folder move it shows how many files and how many
    non-code files the folder contains. Project folders containing BLOCKED extension files
    outside build-output directories are surfaced in the preview (documented choice - the
    folder still moves; the user sees the risk before confirming). VCS metadata (.git) and
    common build-output directories (node_modules, bin, obj, dist, ...) are excluded from
    the counts. The walk is reparse-point-aware: it never descends into junctions/symlinks.
.EXAMPLE
    Get-SysOrgFolderMoveStats -Path 'C:\proj\repo' -Config $cfg -DriveProfile $prof
#>
    param([Parameter(Mandatory)][string]$Path,$Config,$DriveProfile)
    $vcsDirs   = @('.git','.hg','.svn','.jj')
    $buildDirs = @('node_modules','bin','obj','dist','build','out','target','vendor','packages','__pycache__','.venv','venv','debug','release','cmake-files','.idea','.vs')
    $role = "$($DriveProfile.Role)"
    $polKey = if($role -ieq 'System'){ 'Policy.SystemDrive' } else { 'Policy.DataDrives' }
    $blockedExts = @(Get-SysOrgSetting $Config ($polKey + '.BlockedExtensions') @())
    $files = 0; $nonCode = 0; $blockedCount = 0
    $catCache = @{}
    $blockedSamples = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    [void]$stack.Push(@{ Path=$Path; InBuild=$false })
    while($stack.Count -gt 0){
        $entry = $stack.Pop()
        $dir = [string]$entry.Path
        try{
            # provider resolution first: plan paths can carry '\' segments on POSIX hosts
            $root2 = (Resolve-Path -LiteralPath $dir -ErrorAction Stop).ProviderPath
            $di = New-Object System.IO.DirectoryInfo($root2)
            $da = [int]$di.Attributes
            if($da -eq -1 -or (($da -band 0x400) -ne 0)){ continue }
            foreach($f in $di.GetFiles()){
                $fa = [int]$f.Attributes
                if($fa -eq -1){ continue }
                $files++
                $ext = $f.Extension.ToLowerInvariant()
                if(-not $catCache.ContainsKey($ext)){ $catCache[$ext] = (Get-SysOrgCategory -Extension $ext -Config $Config) }
                if("$($catCache[$ext])" -ne 'Code'){ $nonCode++ }
                # blocked extensions are surfaced only OUTSIDE build-output directories
                if((-not ([bool]$entry.InBuild)) -and ($blockedExts.Count -gt 0) -and ($blockedExts -contains $ext)){
                    $blockedCount++
                    if($blockedSamples.Count -lt 5){ [void]$blockedSamples.Add($f.FullName) }
                }
            }
            foreach($sub in $di.GetDirectories()){
                $sa = [int]$sub.Attributes
                if($sa -eq -1 -or (($sa -band 0x400) -ne 0)){ continue }   # never descend reparse points
                $leaf = $sub.Name.ToLowerInvariant()
                if($vcsDirs -contains $leaf){ continue }                   # VCS metadata is not counted
                $inBuild = ([bool]$entry.InBuild) -or ($buildDirs -contains $leaf)
                [void]$stack.Push(@{ Path=$sub.FullName; InBuild=$inBuild })
            }
        } catch { continue }   # stats are informational; the MOVE-time walk (strict) aborts on errors
    }
    return [pscustomobject]@{ Files=$files; NonCode=$nonCode; BlockedCount=$blockedCount; BlockedSamples=@($blockedSamples.ToArray()) }
}

function Invoke-SysOrgSafeMoveFolder {
<#
.SYNOPSIS
    Folder primitive for code project folders and migration moves. Never overwrites.
.DESCRIPTION
    v2.1.1: BEFORE any move the tree is walked reparse-point-aware; a folder containing
    any junction or symlink (or one whose tree cannot be fully enumerated) is refused and
    the source is kept. Same volume: Move-Item (atomic). Cross volume: Copy-Item -Recurse
    -> verify by PER-FILE SHA256 over matching relative paths (count and byte totals are
    checked too) -> only then remove the source. Enumeration on either side uses no
    SilentlyContinue: any enumeration error aborts and keeps the source. The recursive
    delete is safe because the pre-move walk verified the tree contains no reparse points
    that a traversal could follow. A destination that already exists gets a unique ' (2)'
    suffix.
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
        # v2.1.1: fail closed - refuse folders containing reparse points or trees that
        # cannot be fully enumerated.
        $link = Test-SysOrgFolderHasReparsePoint -Path $Source
        if($link.HasLink){
            if($link.Error){ $result.Message = ('Folder move refused - the tree could not be safely enumerated ({0}); source kept' -f $link.Error) }
            else { $result.Message = 'Folder move refused - the folder contains a junction or symlink (reparse point); source kept' }
            return $result
        }
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
        # v2.1.1: verify by per-file SHA256 over matching relative paths (in addition to
        # file count and byte totals). No SilentlyContinue on either side: any enumeration
        # error aborts and keeps the source.
        $srcFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction Stop)
        $dstFiles = @(Get-ChildItem -LiteralPath $final  -Recurse -File -Force -ErrorAction Stop)
        if($srcFiles.Count -ne $dstFiles.Count){ throw ('File count mismatch after folder copy ({0} vs {1})' -f $srcFiles.Count, $dstFiles.Count) }
        $srcMap = @{}
        foreach($f in $srcFiles){
            $rel = $f.FullName.Substring($Source.Length).TrimStart('\','/')
            $srcMap[$rel.ToLowerInvariant()] = Get-SysOrgFileHash -Path $f.FullName
        }
        $dstMap = @{}
        foreach($f in $dstFiles){
            $rel = $f.FullName.Substring($final.Length).TrimStart('\','/')
            $dstMap[$rel.ToLowerInvariant()] = Get-SysOrgFileHash -Path $f.FullName
        }
        foreach($k in $srcMap.Keys){
            if(-not $dstMap.ContainsKey($k)){ throw ("File missing at destination after copy: {0}" -f $k) }
            if("$($srcMap[$k])" -ne "$($dstMap[$k])"){ throw ("SHA256 mismatch after folder copy: {0}" -f $k) }
        }
        $result.FilesCopied = $srcFiles.Count
        $sb = [int64]0; if($srcFiles.Count -gt 0){ $sb = [int64]($srcFiles | Measure-Object -Property Length -Sum).Sum }
        $result.BytesCopied = $sb
        if(Get-SysOrgSetting $Config 'Move.AllowCrossVolume' $true){
            try {
                # Safe: the pre-move walk verified the tree contains no reparse points,
                # so a recursive traversal cannot follow links out of the folder.
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

function Get-SysOrgTimingSummary {
<#
.SYNOPSIS
    Formats per-phase wall times for the -Timing output (v3.0.1 C1).
.DESCRIPTION
    Deterministic: phases are listed alphabetically. Returns 'Timing: duplicates 4.58s, enumerate 1.99s, plan 7.19s'.
.EXAMPLE
    Get-SysOrgTimingSummary -Timings @{ enumerate=1.99; plan=7.19 }
#>
    [CmdletBinding()]
    param([AllowNull()][hashtable]$Timings)
    if(-not $Timings -or $Timings.Count -eq 0){ return $null }
    $parts = @($Timings.Keys | Sort-Object | ForEach-Object { '{0} {1}s' -f $_, $Timings[$_] })
    return ('Timing: ' + ($parts -join ', '))
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

function Get-SysOrgOneDriveRoots {
<#
.SYNOPSIS
    Returns every configured OneDrive sync root (v2.1.1): env vars + per-account registry.
.DESCRIPTION
    Considers $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer and the
    HKCU:\Software\Microsoft\OneDrive\Accounts\<account>\UserFolder registry values
    (a Business account often appears ONLY there). Separators are normalized and
    trailing separators trimmed; the registry read is wrapped so non-Windows test hosts
    contribute nothing. Duplicates are removed case-insensitively.
.EXAMPLE
    Get-SysOrgOneDriveRoots   # e.g. @('C:\Users\t\OneDrive', 'C:\Users\t\OneDrive - Contoso')
#>
    $roots = New-Object System.Collections.Generic.List[string]
    foreach($envName in @('OneDrive','OneDriveCommercial','OneDriveConsumer')){
        $v = [Environment]::GetEnvironmentVariable($envName)
        if(-not [string]::IsNullOrWhiteSpace("$v")){
            $n = ("$v").Replace('/','\').TrimEnd('\')
            if($n -and (-not ($roots -contains $n))){ [void]$roots.Add($n) }
        }
    }
    try{
        $accountsRoot = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        if(Test-Path -LiteralPath $accountsRoot){
            foreach($acct in @(Get-ChildItem -LiteralPath $accountsRoot -ErrorAction SilentlyContinue)){
                $uf = $null
                try { $uf = (Get-ItemProperty -LiteralPath $acct.PSPath -Name 'UserFolder' -ErrorAction Stop).UserFolder } catch { }
                if(-not [string]::IsNullOrWhiteSpace("$uf")){
                    $n = ("$uf").Replace('/','\').TrimEnd('\')
                    if($n -and (-not ($roots -contains $n))){ [void]$roots.Add($n) }
                }
            }
        }
    } catch { Write-Verbose "OneDrive account registry unavailable: $($_.Exception.Message)" }
    return ,$roots.ToArray()
}

function Test-SysOrgUnderOneDrive {
<#
.SYNOPSIS
    True when a path lives inside (or is) a OneDrive sync root (v2.1.1).
.DESCRIPTION
    Replaces the five duplicated inline checks (four in New-SysOrgPlan, one in
    Get-SysOrgKnownFolders): considers $env:OneDrive, $env:OneDriveCommercial,
    $env:OneDriveConsumer and the per-account UserFolder registry values. Prefix
    matching is case-insensitive and SEGMENT-SAFE: 'C:\Users\t\Od' is a root, but
    'C:\Users\t\Odyssey' merely shares a prefix and does not match.
.EXAMPLE
    Test-SysOrgUnderOneDrive -Path 'C:\Users\t\OneDrive - Contoso\Docs\a.docx'   # -> True
#>
    param([AllowEmptyString()][string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){ return $false }
    $p = ("$Path").Replace('/','\').TrimEnd('\')
    foreach($r in (Get-SysOrgOneDriveRoots)){
        if($p -ieq $r -or $p.StartsWith($r + '\',[StringComparison]::OrdinalIgnoreCase)){ return $true }
    }
    return $false
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
.DESCRIPTION
    v2.1.1: the CLI calls this at startup, so it must not throw on hosts without Windows
    identity support (PowerShell on non-Windows) - it returns $false there.
.EXAMPLE
    if(Test-SysOrgElevated){ Write-Host 'admin' }
#>
    try{
        $id=[Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
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
    consulted as well when it exists. Resolves through the PowerShell provider first,
    so mixed-separator plan paths resolve on POSIX hosts as well; a missing path is not
    a reparse point (Attributes=-1 on raw APIs must never be banded as one).
.EXAMPLE
    Test-SysOrgReparsePoint -Path 'C:\Some\Junction'   # -> True
#>
    param([Parameter(Mandatory)][string]$Path)
    try{
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $attrs = [int]$item.Attributes
        if(($attrs -ne -1) -and (($attrs -band 0x400) -ne 0)){ return $true }
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
