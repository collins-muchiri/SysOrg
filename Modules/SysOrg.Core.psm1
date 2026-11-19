#Requires -Version 5.1
# SysOrg.Core.psm1 - configuration, logging, hashing, exclusions, collision-safe moves.

function Merge-SysOrgHashtable {
    param([hashtable]$Base,[hashtable]$Override)
    foreach($key in $Override.Keys){
        if($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Override[$key] -is [hashtable]){
            [void](Merge-SysOrgHashtable -Base $Base[$key] -Override $Override[$key])
        } else { $Base[$key] = $Override[$key] }
    }
    return $Base
}

function Import-SysOrgConfig {
    <# Loads SysOrg.config.psd1 over built-in safe defaults. #>
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
        ProjectDetection       = @{ Enabled = $true; MinFiles = 3; MaxProjects = 200 }
        FolderAudit            = @{ Enabled=$true; MaxTopLevelDepth=2; SkipHiddenSystemDirs=$true; RespectDefenderCFA=$true; IncludeRestrictedInPlans=$false }
        Duplicates             = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=256; HeaderHashKB=64 }
        Move                   = @{ AllowCrossVolume = $true }
        RemoveEmptySourceDirs  = $false
        MaxPlanActions         = 5000
        InventoryCacheHours    = 24
        ReportsFolderName      = '_Reports'
        ScheduledTaskName      = 'SysOrg Weekly Scan'
        ScheduledDrives        = @('*')
    }
    if($Path -and (Test-Path -LiteralPath $Path)){
        try{
            $loaded = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
            [void](Merge-SysOrgHashtable -Base $defaults -Override $loaded)
        } catch {
            Write-Warning "Config '$Path' could not be parsed ($($_.Exception.Message)). Using safe defaults."
        }
    }
    $defaults.AppRoot = $AppRoot
    return ,$defaults
}

function Get-SysOrgSetting {
    <# Dot-path lookup: Get-SysOrgSetting $cfg 'Duplicates.Policy' 'ReportOnly' #>
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
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level='INFO',[string]$LogFolder)
    $line = '{0} [{1,-6}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if($LogFolder){
        try{
            if(-not (Test-Path -LiteralPath $LogFolder)){ New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $LogFolder ('sysorg-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))) -Value $line -Encoding UTF8
        } catch { }
    }
    $color = @{ INFO='Gray'; WARN='Yellow'; ERROR='Red'; ACTION='Cyan' }[$Level]
    Write-Host $line -ForegroundColor $color
}

function Get-SysOrgFileHash {
    <# SHA256; -HeaderOnly hashes the first N KB (fast duplicate pre-filter). Never modifies files. #>
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
                    [void]$stream.Read($buf,0,$len)
                    $hashBytes = $sha.ComputeHash($buf)
                } else {
                    $hashBytes = $sha.ComputeHash($stream)
                }
            } finally { $stream.Dispose() }
        } finally { $sha.Dispose() }
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-','')
    } catch { return $null }
}

function Test-SysOrgExcludedPath {
    param([string]$Path,$Config)
    $p = $Path.TrimEnd('\')
    foreach($pat in @($Config.ExcludedPaths)){
        if([string]::IsNullOrWhiteSpace($pat)){ continue }
        if($pat.Contains('*') -or $pat.Contains('?')){
            if($p -like $pat){ return $true }
        } else {
            $pn = $pat.TrimEnd('\')
            if($p -ieq $pn -or $p.StartsWith($pn + '\',[StringComparison]::OrdinalIgnoreCase)){ return $true }
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
    param([string]$Path,$Config)
    $name = Split-Path $Path -Leaf
    foreach($pat in @($Config.ExcludedFilePatterns)){ if($name -like $pat){ return $true } }
    return $false
}

function Get-SysOrgDestinationRoot {
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
    param([string]$Path,$Config)
    $letter = (Split-Path $Path -Qualifier).TrimEnd(':')
    $root = Get-SysOrgDestinationRoot -Letter $letter -Config $Config
    $p = $Path.TrimEnd('\')
    if($p -ieq $root -or $p.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)){ return $true }
    return $false
}

function Get-SysOrgUniquePath {
    <# Returns a non-existing path; appends " (2)", " (3)", ... Never overwrites. #>
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
      The single primitive that touches files. Guarantees:
        - never overwrites: destination is always a unique path
        - identical content already at destination -> Status 'CollisionDuplicate' (caller quarantines)
        - same volume  : Move-Item (atomic rename)
        - cross volume : Copy-Item -> SHA256 verify -> only then remove source;
                         on any mismatch or locked source, source is KEPT
    #>
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,$Config)
    $result = [pscustomobject]@{ Status='Failed'; Source=$Source; Destination=$null; Message='' }
    try{
        if(-not (Test-Path -LiteralPath $Source)){ $result.Message='Source not found'; return $result }
        $destDir = Split-Path $Destination -Parent
        if(-not (Test-Path -LiteralPath $destDir)){ New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        if(Test-Path -LiteralPath $Destination){
            $dstHash = Get-SysOrgFileHash -Path $Destination
            $srcHash = Get-SysOrgFileHash -Path $Source
            if($dstHash -and $srcHash -and ($dstHash -eq $srcHash)){
                $result.Status='CollisionDuplicate'; $result.Destination=$Destination
                $result.Message='Identical content already exists at destination'
                return $result
            }
        }
        $final = Get-SysOrgUniquePath -Path $Destination

        $sameVolume = ((Split-Path $Source -Qualifier) -ieq (Split-Path $final -Qualifier))
        $allowCross = Get-SysOrgSetting $Config 'Move.AllowCrossVolume' $true

        if($sameVolume){
            Move-Item -LiteralPath $Source -Destination $final -ErrorAction Stop
            $result.Status='Moved'
        }
        elseif($allowCross){
            Copy-Item -LiteralPath $Source -Destination $final -ErrorAction Stop
            $copyHash = Get-SysOrgFileHash -Path $final
            $origHash = Get-SysOrgFileHash -Path $Source
            if((-not $copyHash) -or (-not $origHash) -or ($copyHash -ne $origHash)){
                Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
                $result.Message='Copy verification failed; source untouched'
                return $result
            }
            try { Remove-Item -LiteralPath $Source -Force -ErrorAction Stop }
            catch {
                $result.Status='CopiedVerified'; $result.Destination=$final
                $result.Message='Copied and verified; source is locked and was kept'
                return $result
            }
            $result.Status='Moved'
        }
        else {
            $result.Message='Cross-volume move disabled by configuration (Move.AllowCrossVolume=$false)'
            return $result
        }
        $result.Destination=$final
    } catch { $result.Message=$_.Exception.Message }
    return $result
}

function Format-SysOrgFileSize {
    param([int64]$Bytes)
    if($Bytes -ge 1GB){ return '{0:N2} GB' -f ($Bytes/1GB) }
    if($Bytes -ge 1MB){ return '{0:N1} MB' -f ($Bytes/1MB) }
    if($Bytes -ge 1KB){ return '{0:N1} KB' -f ($Bytes/1KB) }
    return "$Bytes B"
}

function New-SysOrgAppFolders {
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
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function *-SysOrg*
