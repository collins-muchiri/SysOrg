@{
    Version = '3.0.0'

    # v3.0 layout profile - the new Findable layout organizes EVERY file type into a
    # fast-to-browse tree (max depth 4 below the root, max 10 routing roots, adaptive
    # ISO date granularity: YYYY -> YYYY-MM -> YYYY-MM-DD when a folder exceeds
    # Layout.MaxFilesPerFolder, merged back up when it would leave mostly near-empty
    # folders, and a 200-character path budget with deterministic hash-suffixed
    # shortening). Files that cannot be classified with confidence are left in place
    # and listed in the plan's "needs a decision" section (Review.Mode below).
    #   Windows  = the v2.1 behaviour (NamingPreset below governs the folder names)
    #   Compact4 = the rev 2.0 naming (Documents, Photo, Video, Downloads)
    #   Findable = the v3.0 layout engine (recommended)
    LayoutProfile = 'Findable'

    # Naming preset for the organized roots - used by the Windows/Compact4 layout
    # profiles only (Findable has its own tree):
    #   Windows  = Documents, Pictures, Videos, Music, Downloads   (Windows known-folder names)
    #   Compact4 = Documents, Photo, Video, Downloads              (rev 2.0 naming; Music under Video\Audio)
    NamingPreset = 'Windows'

    # Destination style:
    #   OrganizedRoot = everything under the root below (reversible, library-neutral)
    #   KnownFolders  = files are filed into your REAL known folders (resolved from the registry,
    #                   e.g. C:\Users\you\Documents). Requires a second explicit confirmation at
    #                   execution time because moves into OneDrive-backed folders sync to the cloud.
    DestinationStyle = 'OrganizedRoot'

    # Destination root per drive letter. '*' = fallback for unlisted drives.
    # Token '__AUTO__' resolves to "<DriveLetter>:\_Organized".
    OrganizedRoots = @{
        C   = 'C:\Organized'
        '*' = '__AUTO__'
    }

    MainFolders = @('Documents','Pictures','Videos','Music','Downloads')

    # Extension -> routing-category overrides. Routing categories:
    #   Documents, Pictures, Videos, Music, Archives, Code, Installers, Other, SKIP
    # e.g. TypeMap = @{ '.heic' = 'Pictures'; '.dwg' = 'Other' }
    # Unmapped extensions fall back to the Windows PerceivedType registry value, then 'Other'.
    TypeMap = @{}

    # Paths never scanned or modified. Prefix match unless it contains wildcards.
    # Root-less single names (e.g. 'Recovery') match ANY path segment on ANY drive.
    # NOTE (v2.1.1): the protection floor - SystemRoot, Program Files, Program Files (x86),
    # ProgramData, and $Recycle.Bin / System Volume Information at every fixed drive root -
    # and the built-in entries of Policy.ProtectedArtifacts / BlockedExtensions are ALWAYS
    # re-added after the merge. User configuration can ADD entries but can never REMOVE
    # these built-ins, and a config file that cannot be parsed makes SysOrg fail closed.
    ExcludedPaths = @(
        'C:\Windows'
        'C:\Program Files'
        'C:\Program Files (x86)'
        'C:\ProgramData'
        'C:\Users\*\AppData'
        '$Recycle.Bin'
        'System Volume Information'
        'Recovery'
        'OneDriveTemp'
        '*\node_modules'
        '*\.git'
        '*\.sysorg-ignore'      # the marker file itself; the traversal check skips its whole tree
    )

    ExcludedFilePatterns = @(
        '*.tmp', '~$*', '*.part', '*.crdownload', '*.partial'
        'desktop.ini', 'thumbs.db', '.DS_Store'
    )

    SkipHiddenSystemFiles = $true     # files with Hidden and/or System attributes are skipped
    ExcludeDestinations   = $true     # destination roots are never re-scanned as sources

    # Default scan scope: scans start in these existing folders instead of the whole drive.
    # Known folders resolved from the registry (including redirected ones, e.g. Pictures on D)
    # are always added for their drive. Whole-drive scans require the -FullDrive switch.
    ScanRoots = @{
        '*' = @('Desktop','Documents','Downloads','Pictures','Videos','Music')
    }

    DateFolders = 'Year'              # Year | YearMonth | None  (subfolder inside each category)

    # "Already organized" heuristic: a folder with >= PreserveMinFiles files where
    # >= PreserveSingleCategoryRatio map to one category is left untouched (whole subtree).
    PreserveExistingFolders     = $true
    PreserveMinFiles            = 5
    PreserveSingleCategoryRatio = 0.9
    AlwaysScanFolders           = @('downloads','desktop','documents','temp','tmp','new folder')

    # Mutability engine: what may be changed where. Every file must pass
    # Test-SysOrgFileMutable before it can appear in a plan; denials are previewed.
    Policy = @{
        SystemDrive = @{
            # KnownFolders  = only the resolved known folders (+ WritablePaths below) are writable
            # ExplicitPaths = only WritablePaths are writable
            # FullDrive is deliberately NOT supported on the system drive.
            Scope = 'KnownFolders'
            WritablePaths = @()        # e.g. @('C:\Work\Exports')  (or pass -WritablePath on the CLI)
            BlockedExtensions = @('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url')
            AllowInstallersInDownloads = $true
        }
        DataDrives = @{
            Scope = 'FullDrive'        # FullDrive | KnownFolders | ExplicitPaths
            WritablePaths = @()
            BlockedExtensions = @('.dll','.sys','.drv','.ocx','.cpl','.scr')
            AllowInstallersInDownloads = $true
        }
        # Auto-protected at the root of EVERY drive when present (extends P1-7):
        ProtectedArtifacts = @(
            'Windows','Program Files','Program Files (x86)','ProgramData','WindowsApps','XboxGames',
            '$Recycle.Bin','System Volume Information','Recovery','Boot','MSOCache','PerfLogs'
        )
    }

    # Type-first name families: related files and look-alike versions share one named family
    # folder WITHIN their type root. Related files across types get the SAME family name in
    # each root (holiday.jpg -> Pictures\holiday\, holiday.mp4 -> Videos\holiday\).
    Families = @{
        Enabled           = $true
        MinFiles          = 2
        WithinTypeOnly    = $true      # family folders never cross the type boundary
        CrossTypeLink     = 'SameName' # SameName | Dominant (Dominant restores rev 2.0 cross-type merge)
        NoiseTokens       = @('copy','copie','final','new','old','backup','bak','draft','rev','revised','edit','edited','version','untitled')
        StripVersionSuffix = $true     # 'Report final v2' normalizes to 'Report'
        KeepDates         = $true      # 'Invoice 2025-01' and 'Invoice 2025-02' stay separate
        MaxNameLength     = 60
    }

    # Exact copies policy (v2.1.1: copies keep their OWN name by default).
    #   NumberCopies = exact copies are kept. A copy keeps its own stem and extension and is
    #                  numbered only when the name collides in the destination folder:
    #                  Report.docx + Report - Copy.docx -> Report.docx + Report - Copy.docx.
    #                  RenameToKeeper=$true restores the v2.1.0 behaviour where every copy
    #                  takes the keeper's stem (Report (2).docx, Report (3).docx).
    #   Quarantine   = copies move to _Duplicates\<PlanId>\ (rev 2.0 behavior, opt-in)
    #   ReportOnly   = copies are listed, nothing moves
    Copies = @{
        Policy               = 'NumberCopies'
        SuffixStyle          = 'Parentheses'   # Parentheses | DashCopy (Explorer paste style)
        StartIndex           = 2               # the original is implicitly 1
        # v3.0.1 B5: the size floor applies to MEDIA and INSTALLERS only. Documents and
        # data files (Documents/Spreadsheets/Presentations/Databases) use DocMinFileSizeKB
        # (default 0 = no floor) - size-grouping is cheap, so small duplicate documents
        # collapse into the copies policy too. 'name(1).ext' re-download pairs are also
        # compared: hash-identical pairs collapse into the policy; pairs that differ are
        # flagged 'possible newer version' in the preview (report-only, never moved).
        MinFileSizeKB        = 256             # media/installer floor (thousands of tiny cache files)
        DocMinFileSizeKB     = 0               # documents/data floor (0 = hash small docs too)
        HeaderHashKB         = 64              # fast pre-filter before full SHA256
        QuarantineFolderName = '_Duplicates'   # used only when Policy = Quarantine
        RenameToKeeper       = $false          # $true = copies take the keeper's stem (v2.1.0 behaviour)
    }

    # Downloads branch: provenance-aware routing of downloaded files.
    #   Downloads\GitHub\Archives\  (GroupBy = SourceFirst)
    #   Downloads\WhatsApp\Pictures\2025\
    #   Downloads\_NoSource\Installers\   (installers without provenance)
    Downloads = @{
        Roots               = @('Downloads')   # folder names treated as download roots on every drive
        GroupBy             = 'SourceFirst'    # SourceFirst | TypeFirst
        DateFolders         = 'Year'
        UseZoneIdentifier   = $true            # read HostUrl/ReferrerUrl from the Zone.Identifier stream
        UnknownSourceFolder = '_NoSource'
    }

    # Code project folders (dirs containing .git, package.json, *.sln, ...): moved whole,
    # one MoveFolder unit, .git intact -> Documents\Projects\Code\<Name>.
    # v2.1.1: detection requires a VCS marker (.git/.hg/.svn/.jj) OR at least TWO distinct
    # markers - a lone .gitignore/Makefile/lock file is not a project. Folders containing
    # junctions or symlinks are never moved. Blocked-extension files OUTSIDE build-output
    # directories (node_modules, bin, obj, dist, ...) are SURFACED IN THE PREVIEW - the
    # folder still moves (documented choice); the user sees the risk before confirming.
    Projects = @{
        Enabled        = $true
        Destination    = 'Documents\Projects\Code'
        Markers        = @()    # empty = built-in marker set
        GenericNames   = @('new folder','project','code','test','src','untitled','app')
        VerifyCrossVolumeHashes = $true
    }

    # v3.0.1 B2: respect user collections. A non-generic folder name inside a scanned
    # root ('UNDP', 'Field Workshop', ...) is a signal: the folder moves as ONE unit
    # (structure intact, never flattened) to the destination chosen by the majority
    # classification of its contents, e.g. Documents\Work\<FolderName> - or stays in
    # place when the confidence is low (reported in the preview). Bounded by file count
    # and depth; generic names, bare dates and auto-generated camera/screenshot names
    # are never treated as collections.
    Folders = @{
        PreserveUserCollections = $true
        MaxFiles          = 200    # a subtree with more files is not a collection
        MaxDepth          = 3      # collection folders live at most this deep below a scan root
        MinMajorityRatio  = 0.6    # below this majority the collection is left in place
        GenericNames      = @('new folder','untitled','copy of','archive','backup','old','misc',
                              'miscellaneous','various','stuff','things','random','temp','tmp',
                              'downloads','desktop','documents','pictures','videos','music')
    }

    Archives = @{
        Extract               = $false
        KeepMultipartTogether = $true   # .zip.001/.002, part1.rar/.r00 move as one unit
    }

    # v3.0.1 C2: prune during the walk. Directory NAMES listed here are never
    # descended into - their files are not even enumerated (counted as 'preserved'
    # in the summary, never moved). Code projects (VCS marker or two project
    # markers) are detected in the same single pass and move as ONE unit with .git
    # intact. Pruning is the main cold-scan speedup on trees with project or
    # dependency folders (a 9,500-file fixture where 99% sits in such folders scans
    # in well under a second instead of walking every file).
    Prune = @{
        Enabled       = $true
        DirectoryNames = @('node_modules','.venv','venv','site-packages','vendor','__pycache__',
                           '.next','dist','build','target','.gradle','bower_components','Pods','.git')
    }


    # v3.0 findability: the Data leaves (csv/xlsx/json/db exports route here via
    # their extension even though Windows' routing set calls them Documents).
    # Events cluster photos/videos by capture time (Events.GapHours); near-duplicate
    # images are REPORTED, never moved. Findability score targets live in Score.
    # v3.0.1 A2: Score.MinPopulation is the honest 'n/a' floor (an empty or tiny tree
    # scores 'n/a', never 100); Score.MeaningfulChangeShare makes plan verdicts honest
    # about scale - below a 5% affected share the verdict reads
    # 'no meaningful change (X of Y files affected)', never 'worsens'.
    Events          = @{ GapHours=8; MinFiles=15 }
    NearDuplicates  = @{ Enabled=$true; MaxHammingDistance=8 }
    Score = @{
        Targets = @{ MaxDepth=4; AvgDepth=3.0; OverCapShare=0.05; NearEmptyShare=0.10; ConfidentShare=0.80; DupByteShare=0.10 }
        MinPopulation         = 20     # fewer files than this -> the score reads 'n/a'
        MeaningfulChangeShare = 0.05   # < 5% of files affected -> 'no meaningful change'
    }

    Preview = @{
        NaturalSort         = $true    # StrCmpLogicalW: file (2) before file (10), like Explorer
        ShowDenied          = $true    # mutability denials grouped by reason in the preview
        WarnOneDriveSyncOut = $true    # list moves that would remove files from OneDrive sync
    }

    # v3.0.1 B3: self-supervised learning from YOUR OWN structure. Before classifying,
    # SysOrg builds a small naive Bayes model (model.json under <root>\_Index) from
    # the files already living in your curated folders: every existing subfolder of a
    # known folder in scope (e.g. Documents\Work, Documents\Personal) becomes a label;
    # filename tokens, extensions, Office/PDF title-author tokens and the first 2 KB
    # of text become features. The model is rebuilt only when its input fingerprint
    # changes, needs at least MinFilesPerLabel (5) files per label, and is strictly a
    # CONFIDENCE SIGNAL (it appears in -Explain and never moves anything by itself).
    # Learn.FromPaths adds extra training folders; GenericLabels are never used as
    # labels. Run '.\SysOrg.ps1 -Learn' to see what it learned and what it trusts.
    Learn = @{
        Enabled          = $true
        FromPaths        = @()      # e.g. @('D:\Reference\Proposals') - extra training folders
        MinFilesPerLabel = 5        # fewer examples -> the label is not trusted
        MinMargin        = 0.5      # posterior margin needed for a trusted prediction
        MaxFilesPerLabel = 500      # training cap per label (keeps the build fast)
        MaxTokensPerLabel = 2000    # keeps model.json small
        GenericLabels    = @('documents','downloads','pictures','videos','music','desktop',
                             'archive','archives','backup','misc','other','files','new folder','temp','tmp','unknown')
    }

    # v3.0.1 A4: the download-source bucket map. 'Rules.SourcesPath' may point at a
    # custom map file; empty = <AppRoot>\Rules\Sources.psd1 (shipped). The map is
    # EXTENSIBLE: add Hosts (exact host -> bucket, e.g. 'myportal.go.ke' = 'MyPortal'),
    # SecondLevelSuffixes (registrable-domain awareness) and FileNamePatterns there -
    # entries merge over the built-ins. AI sources (z.ai -> Z-AI, meta.ai -> Meta-AI,
    # claude.ai -> Claude, chatgpt.com/openai.com -> OpenAI, gemini.google.com ->
    # Gemini) are built in. A file that cannot be parsed fails closed at startup.
    # A derived bucket name shorter than 3 characters falls back to the full host label.
    Rules = @{ UserRulesPath=''; LexiconPath=''; LearnedRulesPath=''; SourcesPath=''; ApplyLearned=$false }

    Privacy = @{
        # Full download URLs (HostUrl/ReferrerUrl) are stored ONLY in the local journal sidecar
        # (Plans\<PlanId>-provenance.csv). Plan JSONs carry the source bucket name only.
        StoreFullUrlsInJournal = $true
    }

    # Folder safety audit (v1.1): every folder classified Protected / Restricted / Organizable.
    FolderAudit = @{
        Enabled                  = $true
        MaxTopLevelDepth         = 2
        SkipHiddenSystemDirs     = $true
        RespectDefenderCFA       = $true
        IncludeRestrictedInPlans = $false
    }

    Move = @{
        # $true  = cross-volume moves are copy -> SHA256 verify -> remove source
        # $false = verified copy-only between drives: every source is kept
        AllowCrossVolume = $true
    }

    MaxPlanActions        = 5000
    InventoryCacheHours   = 24

    # v3.0.1 D1: re-running an IDENTICAL scan (same drive, same files, same config)
    # reuses the existing not-yet-executed plan instead of creating a duplicate -
    # compared via a SHA256 input fingerprint (letter + root + layout + copies
    # policy + the sorted path|size|mtime of the inventory). Executed plans are
    # never silently reused: their undo journals exist, so a new plan is built.
    Plans = @{ ReuseIdentical = $true }
    ReportsFolderName     = '_Reports'
    ScheduledTaskName     = 'SysOrg Weekly Scan'
    ScheduledDrives       = @('*')          # drives in scheduled reports; '*' = every FIXED (internal) drive only, e.g. @('C','D')
}
