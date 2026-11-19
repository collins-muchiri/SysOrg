#Requires -Version 5.1
# SysOrg.Core.psm1 - configuration, logging, hashing, exclusions, collision-safe moves.

function Merge-SysOrgHashtable {
<#
.SYNOPSIS
    Recursively merges the Override hashtable into Base (in place) and returns Base.
.DESCRIPTION
    Nested hashtables are merged key-by-key so a user override like
    Duplicates = @{ MinFileSizeKB = 999 } does not lose sibling defaults
    such as Duplicates.Policy. All other value types are replaced wholesale.
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
    Validates a merged SysOrg configuration hashtable. Throws on invalid values.
.DESCRIPTION
    Fails loudly at startup instead of misbehaving at move time.
.EXAMPLE
    Test-SysOrgConfig -Config $cfg   # throws if DateFolders or Duplicates.Policy are bad
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $errors = @()
    $dateMode = Get-SysOrgSetting $Config 'DateFolders' 'Year'
    if(@('Year','YearMonth','None') -notcontains $dateMode){ $errors += "DateFolders must be Year, YearMonth, or None (got '$dateMode')." }
    $policy = Get-SysOrgSetting $Config 'Duplicates.Policy' 'Quarantine'
    if(@('Quarantine','ReportOnly') -notcontains $policy){ $errors += "Duplicates.Policy must be Quarantine or ReportOnly (got '$policy')." }
    foreach($k in @('MaxPlanActions','PreserveMinFiles','InventoryCacheHours')){
        $v = Get-SysOrgSetting $Config $k 1
        if($v -isnot [int] -or $v -lt 0){ $errors += "$k must be a non-negative integer (got '$v')." }
    }
    $ratio = Get-SysOrgSetting $Config 'PreserveSingleCategoryRatio' 0.9
    if($ratio -lt 0 -or $ratio -gt 1){ $errors += 'PreserveSingleCategoryRatio must be between 0 and 1.' }
    if($errors.Count -gt 0){ throw ('Invalid configuration: ' + ($errors -join ' ')) }
}

function Import-SysOrgConfig {
<#
.SYNOPSIS
    Loads SysOrg.config.psd1 over built-in safe defaults, with deep merge and validation.
.PARAMETER Path
    Path to the .psd1 config file. Missing file silently yields defaults.
.PARAMETER AppRoot
    Folder containing SysOrg.ps1; recorded in the config and excluded from scans.
.EXAMPLE
    $cfg = Import-SysOrgConfig -Path .\SysOrg.config.psd1 -AppRoot (Get-Location)
#>
    param([string]$Path,[string]$AppRoot)
    $defaults = @{
        OrganizedRoots         = @{ '*' = '__AUTO__' }
        ExcludedPaths          = @('C:\Windows','C:\Program Files','C:\Program Files (x86)','C:\ProgramData',
                                   'C:\Users\*\AppData','$Recycle.Bin','System Volume Information',
                                   'Recovery','OneDriveTemp','*\node_modules','*\.git')
        ExcludedFilePatterns   = @('*.tmp','~$*','*.part','*.crdownload','desktop.ini','thumbs.db')
        SkipHiddenSystemFiles  = $true
        ExcludeDestinations    = $true
        DateFolders            = 'Year'
        Categories             = @{}
        PreserveExistingFolders = $true
        PreserveMinFiles       = 5
        PreserveSingleCategoryRatio = 0.9
        AlwaysScanFolders      = @('downloads','desktop','documents','temp','tmp','new folder')
        # Default scan scope (P1-6): profile folders only; whole-drive scans need -FullDrive
        # or an explicit ScanRoots override. A drive with none of these folders is not scanned
        # at all until you either add a matching ScanRoots entry or pass -FullDrive.
        ScanRoots              = @{ '*' = @('Desktop','Documents','Downloads','Pictures','Videos','Music') }
        ProjectDetection       = @{ Enabled = $true; MinFiles = 3; MaxProjects = 200 }
        FolderAudit            = @{ Enabled=$true; MaxTopLevelDepth=2; SkipHiddenSystemDirs=$true; RespectDefenderCFA=$true; IncludeRestrictedInPlans=$false }
        Duplicates             = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=256; HeaderHashKB=64 }
        Move                   = @{ AllowCrossVolume = $true }
        MaxPlanActions         = 5000
        InventoryCacheHours    = 24
        ReportsFolderName      = '_Reports'
        ScheduledTaskName      = 'SysOrg Weekly Scan'
        ScheduledDrives        = @('*')
    }
    if($Path -and (Test-Path -LiteralPath $Path)){
        try{
            $loaded = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
            if($loaded -is [hashtable]){ [void](Merge-SysOrgHashtable -Base $defaults -Override $loaded) }
        } catch {
            Write-Warning "Config '$Path' could not be parsed ($($_.Exception.Message)). Using safe defaults."
        }
    }
    # P1-7: system locations on EVERY fixed drive, not just C:. These are always appended,
    # even when the user overrides ExcludedPaths, so they can never be opted away by accident.
    try{
        foreach($drv in [System.IO.DriveInfo]::GetDrives()){
            if($drv.DriveType -ne 'Fixed'){ continue }
            if(-not $drv.IsReady){ continue }
            $r = $drv.Name.TrimEnd('\')
            $defaults.ExcludedPaths += @(
                "$r\Windows", "$r\Program Files", "$r\Program Files (x86)", "$r\ProgramData",
                "$r\`$Recycle.Bin", "$r\System Volume Information", "$r\Recovery"
            )
        }
    } catch { Write-Verbose "Could not enumerate fixed drives for default exclusions: $($_.Exception.Message)" }
    Test-SysOrgConfig -Config $defaults
    $defaults.AppRoot = $AppRoot
    return ,$defaults
}

function Get-SysOrgSetting {
<#
.SYNOPSIS
    Dot-path lookup into a config hashtable, e.g. 'Duplicates.Policy'.
.PARAMETER Default
    Returned when the path is missing or the value is null.
.EXAMPLE
    Get-SysOrgSetting $cfg 'Duplicates.Policy' 'ReportOnly'
#>
    param($Config,[string]$Path,$Default)
    $node = $Config
    foreach($part in $Path.Split('.')){
        if($node -is [hashtable] -and $node.ContainsKey($part)){ $node = $node[$part] }
        elseif($node -is [pscustomobject] -and ($node.PSObject.Properties.Name -contains $part)){ $node = $node.$part }
        else { return $Default }
    }
    if($null -eq $node){ return $Default }
    return ,$node
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
            if($p -like $pat){ return $true }
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
    $letter = (Split-Path $Path -Qualifier).TrimEnd(':')
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

function Invoke-SysOrgSafeMove {
<#
.SYNOPSIS
    The single primitive that touches files. Every plan action routes through it.
.DESCRIPTION
    Guarantees:
      - never overwrites: destination is always a unique path (' (2)' suffixes)
      - identical content already at destination -> Status 'CollisionDuplicate'
        (size compared first, then SHA256 - P2-1 hash economy)
      - same volume  : Move-Item (atomic rename)
      - cross volume : Copy-Item -> SHA256 verify -> only then remove source;
                       on any mismatch or locked source, source is KEPT
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

        $sameVolume = ((Split-Path $Source -Qualifier) -ieq (Split-Path $final -Qualifier))
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

Export-ModuleMember -Function *-SysOrg*
