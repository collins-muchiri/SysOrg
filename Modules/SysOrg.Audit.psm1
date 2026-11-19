#Requires -Version 5.1
# SysOrg.Audit.psm1 - folder safety audit: which folders CANNOT be altered vs which CAN be organized.
#
# Classification:
#   Protected   = must never be altered (system locations, config exclusions, hidden/system folders,
#                 reparse points, Defender Controlled Folder Access lists, access-denied folders)
#   Restricted  = readable but NOT writable for the current user -> contents left in place,
#                 excluded from plans by default (FolderAudit.IncludeRestrictedInPlans)
#   Organizable = readable AND writable -> eligible for organization
#
# The writability probe opens directory handles with create-rights only - it never creates,
# modifies, or deletes anything.

$script:SystemFolderNames = @(
    'windows','program files','program files (x86)','programdata','perflogs',
    'recovery','$recycle.bin','system volume information','documents and settings',
    'onedrivetemp','intel','drivers','dell','hp','appdata'
)

function Initialize-SysOrgDirProbe {
<#
.SYNOPSIS
    Compiles the Win32 directory-probe helper once per session.
.EXAMPLE
    Initialize-SysOrgDirProbe
#>
    if(-not ('SysOrg.DirProbe' -as [type])){
        Add-Type -TypeDefinition @'
namespace SysOrg {
    using System;
    using System.Runtime.InteropServices;
    public static class DirProbe {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr h);
    }
}
'@
    }
}

function Test-SysOrgDirAccess {
<#
.SYNOPSIS
    NON-DESTRUCTIVE read/write access probe for a folder.
.DESCRIPTION
    Opens the directory with GENERIC_READ (enumerate) and separately with
    FILE_ADD_FILE|FILE_ADD_SUBDIR (create rights). No file or folder is ever
    created - only the requested access right is evaluated against the folder ACL.
    Long paths and UNC paths are addressed via the \\?\ namespace.
.EXAMPLE
    Test-SysOrgDirAccess -Path C:\Users   # -> Readable/Writable booleans + error codes
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Initialize-SysOrgDirProbe

    $p = $Path.TrimEnd('\')
    if($p -match '^[A-Za-z]:$'){ $np = '\\?\' + $p + '\' }
    elseif($p -like '\\?\*'){ $np = $p }
    elseif($p -like '\\*\*'){ $np = '\\?\UNC\' + $p.Substring(2) }
    else { $np = '\\?\' + $p }

    $shareRw       = [uint32]7                # FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE
    $openExisting  = [uint32]3
    $backupSem     = [uint32]0x02000000       # FILE_FLAG_BACKUP_SEMANTICS (required to open directories)
    $accRead       = [uint32](([int64]0x80000000) -bor 0x0001)   # GENERIC_READ | FILE_LIST_DIRECTORY
    $accWrite      = [uint32]0x0006                              # FILE_ADD_FILE | FILE_ADD_SUBDIR

    $res = [pscustomobject]@{ Readable=$false; Writable=$false; ReadError=0; WriteError=0 }

    $h = [SysOrg.DirProbe]::CreateFileW($np, $accRead, $shareRw, [IntPtr]::Zero, $openExisting, $backupSem, [IntPtr]::Zero)
    if(-not $h.Equals([IntPtr](-1))){ $res.Readable = $true; [void][SysOrg.DirProbe]::CloseHandle($h) }
    else { $res.ReadError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() }

    $h = [SysOrg.DirProbe]::CreateFileW($np, $accWrite, $shareRw, [IntPtr]::Zero, $openExisting, $backupSem, [IntPtr]::Zero)
    if(-not $h.Equals([IntPtr](-1))){ $res.Writable = $true; [void][SysOrg.DirProbe]::CloseHandle($h) }
    else { $res.WriteError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() }

    return $res
}

function Get-SysOrgDefenderProtectedFolders {
<#
.SYNOPSIS
    Returns Windows Defender Controlled Folder Access protected folders (cannot alter).
.DESCRIPTION
    Empty unless Controlled Folder Access is enabled (mode >= 1) and the
    FolderAudit.RespectDefenderCFA setting is $true.
.EXAMPLE
    $cfa = Get-SysOrgDefenderProtectedFolders -Config $cfg
#>
    param($Config)
    if(-not (Get-SysOrgSetting $Config 'FolderAudit.RespectDefenderCFA' $true)){ return @() }
    try{
        $mp = Get-MpPreference -ErrorAction Stop
        $mode = 0
        if($mp.PSObject.Properties['EnableControlledFolderAccess']){ $mode = [int]$mp.EnableControlledFolderAccess }
        if($mode -lt 1){ return @() }
        $list = @()
        foreach($propName in @('EnableControlledFolderAccessProtectedFolders','ControlledFolderAccessProtectedFolders')){
            $prop = $mp.PSObject.Properties[$propName]
            if($prop -and $prop.Value){ $list = @($prop.Value | Where-Object { $_ }); break }
        }
        return ,$list
    } catch { Write-Verbose "Defender CFA folders unavailable: $($_.Exception.Message)"; return @() }
}

function Get-SysOrgFolderProtectionReason {
<#
.SYNOPSIS
    Returns the reason a folder must never be altered, or $null when no static rule matches.
.DESCRIPTION
    Checks, in order: SysOrg destination roots, config ExcludedPaths, drive roots,
    system folder names, Defender Controlled Folder Access lists, reparse points
    (junctions/symlinks/OneDrive roots) and hidden/system attributes.
.EXAMPLE
    Get-SysOrgFolderProtectionReason -Path C:\Windows -Config $cfg -CfaFolders @()
#>
    param([Parameter(Mandatory)][string]$Path,$Config,[string[]]$CfaFolders)
    $p = $Path.TrimEnd('\')
    $isRoot = ($p -match '^[A-Za-z]:$') -or ($p -match '^[A-Za-z]:\\$')

    if(Test-SysOrgDestinationPath -Path $p -Config $Config){ return 'SysOrg destination root' }
    if(Test-SysOrgExcludedPath -Path $p -Config $Config){
        $leaf = (Split-Path $p -Leaf).ToLowerInvariant()
        if($script:SystemFolderNames -contains $leaf){ return 'System location (never alter)' }
        return 'Excluded by configuration'
    }
    if($isRoot){ return $null }

    $leaf = (Split-Path $p -Leaf).ToLowerInvariant()
    $letter = (Split-Path $p -Qualifier).TrimEnd(':').ToUpper()
    if(($letter -eq 'C') -and ($script:SystemFolderNames -contains $leaf)){ return 'System location (never alter)' }
    if($script:SystemFolderNames -contains $leaf){ return 'Protected folder name (never alter)' }

    if($CfaFolders){
        foreach($c in $CfaFolders){
            $c2 = [string]$c
            if($c2){
                $c2 = $c2.TrimEnd('\')
                if($p -ieq $c2 -or $p.StartsWith($c2 + '\',[StringComparison]::OrdinalIgnoreCase)){ return 'Defender Controlled Folder Access' }
            }
        }
    }
    try{
        $di = New-Object System.IO.DirectoryInfo($p)
        if(($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint){ return 'Reparse point (junction/symlink/OneDrive)' }
        if((Get-SysOrgSetting $Config 'FolderAudit.SkipHiddenSystemDirs' $true) -and
           ((($di.Attributes -band [System.IO.FileAttributes]::Hidden) -eq [System.IO.FileAttributes]::Hidden) -or
            (($di.Attributes -band [System.IO.FileAttributes]::System)  -eq [System.IO.FileAttributes]::System))){ return 'Hidden or system folder' }
    } catch { return 'Inaccessible' }
    return $null
}

function Get-SysOrgFolderAudit {
<#
.SYNOPSIS
    Walks a drive (to MaxDepth) and classifies every folder:
    Protected (cannot alter) / Restricted (read-only) / Organizable.
.DESCRIPTION
    Protected folders are never descended into. The writability probe never
    creates, modifies or deletes anything.
.EXAMPLE
    $audit = Get-SysOrgFolderAudit -Letter C -Config $cfg -MaxDepth 2
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Letter,$Config,[int]$MaxDepth=2)

    $root = ('{0}:\' -f $Letter)
    if(-not (Test-Path -LiteralPath $root)){ throw "Drive $root not found." }
    $cfa = Get-SysOrgDefenderProtectedFolders -Config $Config
    Initialize-SysOrgDirProbe

    $folders = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    [void]$stack.Push(@{ Path=$root.TrimEnd('\'); Depth=0 })

    while($stack.Count -gt 0){
        $item = $stack.Pop()
        $dir = [string]$item.Path; $depth = [int]$item.Depth

        $reason = Get-SysOrgFolderProtectionReason -Path $dir -Config $Config -CfaFolders $cfa
        if($reason){
            $folders.Add([pscustomobject]@{ Path=$dir; Depth=$depth; Status='Protected'; Reason=$reason })
            continue
        }
        $acc = Test-SysOrgDirAccess -Path $dir
        if(-not $acc.Readable){
            $folders.Add([pscustomobject]@{ Path=$dir; Depth=$depth; Status='Protected'; Reason=('Access denied reading folder (error {0})' -f $acc.ReadError) })
            continue
        }
        if($acc.Writable){
            $folders.Add([pscustomobject]@{ Path=$dir; Depth=$depth; Status='Organizable'; Reason='Readable and writable' })
        } else {
            $folders.Add([pscustomobject]@{ Path=$dir; Depth=$depth; Status='Restricted'; Reason=('Readable, not writable (error {0}) - left in place' -f $acc.WriteError) })
        }
        if($depth -lt $MaxDepth){
            try { $kids = [System.IO.Directory]::GetDirectories($dir) } catch { Write-Verbose "Could not list children of $dir - $($_.Exception.Message)"; $kids = @() }
            foreach($k in $kids){ [void]$stack.Push(@{ Path=$k; Depth=($depth+1) }) }
        }
    }

    $summary = @{
        Protected   = @($folders | Where-Object { $_.Status -eq 'Protected' }).Count
        Restricted  = @($folders | Where-Object { $_.Status -eq 'Restricted' }).Count
        Organizable = @($folders | Where-Object { $_.Status -eq 'Organizable' }).Count
    }
    return [pscustomobject]@{ DriveLetter=$Letter; MaxDepth=$MaxDepth; Folders=$folders; Summary=$summary }
}

function Write-SysOrgFolderAuditReport {
<#
.SYNOPSIS
    Writes the full safety map to <ReportFolder>\SysOrg-FolderAudit-<drive>-<stamp>.txt.
.EXAMPLE
    Write-SysOrgFolderAuditReport -Audit $audit -ReportFolder C:\Organized\_Reports
#>
    param($Audit,[string]$ReportFolder)
    if(-not (Test-Path -LiteralPath $ReportFolder)){ New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $file = Join-Path $ReportFolder ('SysOrg-FolderAudit-{0}-{1}.txt' -f $Audit.DriveLetter, (Get-Date -Format 'yyyyMMdd-HHmm'))

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("SysOrg folder safety audit - drive $($Audit.DriveLetter): - $(Get-Date)")
    $lines.Add("Legend: Protected = never altered | Restricted = readable, not writable (left in place) | Organizable = eligible")
    $lines.Add(("Summary: Protected={0}  Restricted={1}  Organizable={2}  (audit depth {3})" -f $Audit.Summary.Protected, $Audit.Summary.Restricted, $Audit.Summary.Organizable, $Audit.MaxDepth))
    $lines.Add('')
    $lines.Add('--- CANNOT BE ALTERED (Protected) ---')
    foreach($f in ($Audit.Folders | Where-Object { $_.Status -eq 'Protected' } | Sort-Object Depth, Path)){
        $lines.Add(('  [' + $f.Reason + '] ' + $f.Path))
    }
    $lines.Add('')
    $lines.Add('--- READ-ONLY FOR CURRENT USER (Restricted, excluded from plans by default) ---')
    foreach($f in ($Audit.Folders | Where-Object { $_.Status -eq 'Restricted' } | Sort-Object Depth, Path)){
        $lines.Add(('  ' + $f.Path))
    }
    $lines.Add('')
    $lines.Add('--- CAN BE ORGANIZED (Organizable) ---')
    foreach($f in ($Audit.Folders | Where-Object { $_.Status -eq 'Organizable' } | Sort-Object Depth, Path)){
        $lines.Add(('  ' + $f.Path))
    }
    $lines | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

Export-ModuleMember -Function *-SysOrg*
