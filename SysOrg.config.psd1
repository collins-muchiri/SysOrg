@{
    Version = '1.2.0'

    # Destination root per drive letter. '*' = fallback for unlisted drives.
    # Token '__AUTO__' resolves to "<DriveLetter>:\_Organized".
    OrganizedRoots = @{
        C   = 'C:\Organized'
        '*' = '__AUTO__'
    }

    # Paths never scanned or modified. Prefix match unless it contains wildcards.
    # Root-less single names (e.g. 'Recovery') match ANY path segment on ANY drive.
    # NOTE: every fixed drive also automatically gets Windows, Program Files,
    # Program Files (x86), ProgramData, $Recycle.Bin, System Volume Information
    # and Recovery appended at startup - they cannot be opted away by accident.
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

    # Default scan scope (v1.2): scans start in these existing folders instead of the
    # whole drive. Per-drive overrides possible, e.g. ScanRoots = @{ 'D' = @('Downloads') }.
    # Whole-drive scans require the -FullDrive switch (CLI) on top of this config.
    ScanRoots = @{
        '*' = @('Desktop','Documents','Downloads','Pictures','Videos','Music')
    }

    DateFolders = 'Year'              # Year | YearMonth | None  (subfolder inside each category)
    Categories  = @{}                 # optional overrides, e.g. Categories = @{ '.xyz' = 'Other' }

    # "Already organized" heuristic: a folder with >= PreserveMinFiles files where
    # >= PreserveSingleCategoryRatio map to one category is left untouched (whole subtree).
    PreserveExistingFolders     = $true
    PreserveMinFiles            = 5
    PreserveSingleCategoryRatio = 0.9
    AlwaysScanFolders           = @('downloads','desktop','documents','temp','tmp','new folder')

    ProjectDetection = @{ Enabled = $true; MinFiles = 3; MaxProjects = 200 }

    # Folder safety audit: every folder is classified as
    #   Protected   = cannot be altered (system locations, config exclusions, hidden/system,
    #                 reparse points, Defender Controlled Folder Access, access-denied)
    #   Restricted  = readable but not writable for the current user (left in place)
    #   Organizable = readable and writable (eligible for organization)
    FolderAudit = @{
        Enabled                  = $true    # gate scans on folder-level checks
        MaxTopLevelDepth         = 2        # depth of the console safety map (menu option 2 / -AuditDrive)
        SkipHiddenSystemDirs     = $true    # hidden/system folders are treated as cannot-alter
        RespectDefenderCFA       = $true    # honor Windows Defender Controlled Folder Access lists
        IncludeRestrictedInPlans = $false   # true = also propose moves out of read-only folders
    }

    Duplicates = @{
        Policy               = 'Quarantine'   # Quarantine | ReportOnly
        QuarantineFolderName = '_Duplicates'
        MinFileSizeKB        = 256            # ignore tiny files (thousands of 1 KB dupes)
        HeaderHashKB         = 64             # fast pre-filter before full SHA256
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
    ScheduledDrives       = @('*')          # drives included in scheduled reports; e.g. @('C','D')
}
