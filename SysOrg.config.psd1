@{
    Version = '1.0.0'

    # Destination root per drive letter. '*' = fallback for unlisted drives.
    # Token '__AUTO__' resolves to "<DriveLetter>:\_Organized".
    OrganizedRoots = @{
        C   = 'C:\Organized'
        '*' = '__AUTO__'
    }

    # Paths never scanned or modified. Prefix match unless it contains wildcards.
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
        '*\.sysorg-ignore'      # drop a folder/file named .sysorg-ignore anywhere to exclude that tree
    )

    ExcludedFilePatterns = @(
        '*.tmp', '~$*', '*.part', '*.crdownload', '*.partial'
        'desktop.ini', 'thumbs.db', '.DS_Store'
    )

    SkipHiddenSystemFiles = $true     # files with Hidden and/or System attributes are skipped
    ExcludeDestinations   = $true     # destination roots are never re-scanned as sources

    DateFolders = 'Year'              # Year | YearMonth | None  (subfolder inside each category)
    Categories  = @{}                 # optional overrides, e.g. Categories = @{ '.xyz' = 'Other' }

    # "Already organized" heuristic: a folder with >= PreserveMinFiles files where
    # >= PreserveSingleCategoryRatio map to one category is left untouched (whole subtree).
    PreserveExistingFolders     = $true
    PreserveMinFiles            = 5
    PreserveSingleCategoryRatio = 0.9
    AlwaysScanFolders           = @('downloads','desktop','documents','temp','tmp','new folder')

    ProjectDetection = @{ Enabled = $true; MinFiles = 3; MaxProjects = 200 }

    Duplicates = @{
        Policy               = 'Quarantine'   # Quarantine | ReportOnly
        QuarantineFolderName = '_Duplicates'
        MinFileSizeKB        = 256            # ignore tiny files (thousands of 1 KB dupes)
        HeaderHashKB         = 64             # fast pre-filter before full SHA256
    }

    Move = @{
        AllowCrossVolume = $true            # false = copy-only between drives (source kept)
    }

    RemoveEmptySourceDirs = $false          # SysOrg never deletes folders by default
    MaxPlanActions        = 5000
    InventoryCacheHours   = 24
    ReportsFolderName     = '_Reports'
    ScheduledTaskName     = 'SysOrg Weekly Scan'
    ScheduledDrives       = @('*')          # drives included in scheduled reports; e.g. @('C','D')
}
