@{
    Version = '2.1.1'

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
        MinFileSizeKB        = 256             # ignore tiny files (thousands of 1 KB dupes)
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

    Archives = @{
        Extract               = $false
        KeepMultipartTogether = $true   # .zip.001/.002, part1.rar/.r00 move as one unit
    }

    Preview = @{
        NaturalSort         = $true    # StrCmpLogicalW: file (2) before file (10), like Explorer
        ShowDenied          = $true    # mutability denials grouped by reason in the preview
        WarnOneDriveSyncOut = $true    # list moves that would remove files from OneDrive sync
    }

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
    ReportsFolderName     = '_Reports'
    ScheduledTaskName     = 'SysOrg Weekly Scan'
    ScheduledDrives       = @('*')          # drives in scheduled reports; '*' = every FIXED (internal) drive only, e.g. @('C','D')
}
