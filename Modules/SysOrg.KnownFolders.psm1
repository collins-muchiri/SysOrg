#Requires -Version 5.1
# SysOrg.KnownFolders.psm1 - Windows known-folder resolver (design section 3.1) and
#                            localized category recognition (section 3.5).
#
# Windows does not hardcode C:\Users\<name>\Documents: known folders can be redirected to
# another drive or into OneDrive. The real locations are resolved from the registry BEFORE
# any scope decision, so a redirected Pictures folder on D is in scope on D, not C.
# The known folders themselves are never renamed or moved.

$script:KnownFolderNameMap = @{
    'Personal'  = 'Documents'
    'My Pictures' = 'Pictures'
    'My Video'  = 'Videos'
    'My Music'  = 'Music'
    'Desktop'   = 'Desktop'
    '{F42EE2D3-909F-4907-8871-4C22FC0BF756}' = 'Documents'
    '{0DDD015D-B06C-45D5-8C4C-F59713854639}' = 'Pictures'
    '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}' = 'Videos'
    '{A0C69A99-21C8-4671-8703-7934162FCF1D}' = 'Music'
    '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'
    '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}' = 'Downloads'
}

# English canonical leaf names (section 3.5); the localized leaf names of the RESOLVED known
# folders on this OS are added on top, so a German 'Bilder' or 'Dokumente' folder is recognized.
$script:CanonicalCategoryNames = @{
    Documents = @('documents','my documents')
    Pictures  = @('pictures','my pictures')
    Videos    = @('videos','my videos')
    Music     = @('music','my music')
    Downloads = @('downloads','download')
    Desktop   = @('desktop')
}

function Test-SysOrgKnownFolderPath {
<#
.SYNOPSIS
    Sanity-checks a resolved known folder path (v2.1.1).
.DESCRIPTION
    Rejects paths that must never be treated as an organizable known folder: a drive
    root, the user-profile root, or a parent of the Windows or Program Files folders.
    A bad registry redirect (or a malicious one) could otherwise point the writable
    scope, the scan scope or plan logic at system locations. Returns $true when the
    path is acceptable.
.EXAMPLE
    Test-SysOrgKnownFolderPath -Path 'C:\'          # -> False (drive root)
    Test-SysOrgKnownFolderPath -Path 'C:\Users\t\Documents'   # -> True
#>
    param([AllowEmptyString()][string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){ return $false }
    $p = ("$Path").Replace('/','\').TrimEnd('\')
    if($p -match '^[A-Za-z]:$'){ return $false }        # drive root ('C:')
    if($p -match '^[A-Za-z]:\\$'){ return $false }      # drive root ('C:\')
    $up = $env:USERPROFILE
    if($up){
        $upN = $up.Replace('/','\').TrimEnd('\')
        if($p -ieq $upN){ return $false }               # the profile root itself
    }
    foreach($sysEnv in @('SystemRoot','ProgramFiles')){
        $sys = [Environment]::GetEnvironmentVariable($sysEnv)
        if($sys){
            $sysN = $sys.Replace('/','\').TrimEnd('\')
            if($p -ieq $sysN -or $sysN.StartsWith($p + '\',[StringComparison]::OrdinalIgnoreCase)){ return $false }
        }
    }
    return $true
}

function Get-SysOrgKnownFolders {
<#
.SYNOPSIS
    Resolves the real locations of the user's known folders from the registry.
.DESCRIPTION
    Reads HKCU\...\Explorer\User Shell Folders (REG_EXPAND_SZ values are expanded) and maps
    both the legacy names and the known-folder GUIDs. GUID entries win over legacy duplicates.
    When the registry is unavailable (non-Windows test hosts), the profile-folder fallback is
    used. Each result carries IsRedirected (the folder does NOT live under USERPROFILE) and
    UnderOneDrive (moves INTO it sync to the cloud; moves OUT of it remove files from sync).
.EXAMPLE
    Get-SysOrgKnownFolders | Format-Table Name,Path,IsRedirected,UnderOneDrive -AutoSize
#>
    [CmdletBinding()]
    param()
    $out = @{}
    try{
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $props = Get-ItemProperty -Path $key -ErrorAction Stop
        foreach($p in $props.PSObject.Properties){
            if($script:KnownFolderNameMap.ContainsKey($p.Name)){
                $n = $script:KnownFolderNameMap[$p.Name]
                $path = [Environment]::ExpandEnvironmentVariables([string]$p.Value)
                if($path -and (-not $out.ContainsKey($n) -or $p.Name.StartsWith('{'))){ $out[$n] = $path }
            }
        }
    } catch { Write-Verbose "Known folders registry unavailable: $($_.Exception.Message)" }
    # Fallback (and fill-in) from the user profile so the resolver always returns usable paths.
    $userProfile = $env:USERPROFILE
    if($userProfile){
        foreach($pair in @(@('Documents','Documents'),@('Pictures','Pictures'),@('Videos','Videos'),
                           @('Music','Music'),@('Desktop','Desktop'),@('Downloads','Downloads'))){
            if(-not $out.ContainsKey($pair[0])){
                $p2 = Join-Path $userProfile $pair[1]
                if(Test-Path -LiteralPath $p2){ $out[$pair[0]] = $p2 }
            }
        }
    }
    $profilePrefix = $null
    if($userProfile){ $profilePrefix = $userProfile.TrimEnd('\') + '\' }
    $result = @()
    foreach($k in $out.Keys){
        $path = ([string]$out[$k]).TrimEnd('\')
        if(-not $path){ continue }
        # v2.1.1: sanity check - a known folder redirected to a drive root, the profile
        # root, or a parent of a system folder is ignored with a warning.
        if(-not (Test-SysOrgKnownFolderPath -Path $path)){
            Write-Warning ("Known folder '{0}' resolves to '{1}', which is unsafe (drive root, profile root, or a parent of a system folder) - it is ignored for scoping." -f $k, $path)
            continue
        }
        $redirected = $false
        $underOD = $false
        if($profilePrefix){ $redirected = -not $path.StartsWith($profilePrefix,[StringComparison]::OrdinalIgnoreCase) }
        # v2.1.1: central OneDrive check (env vars + per-account registry) instead of $env:OneDrive only
        $underOD = Test-SysOrgUnderOneDrive -Path $path
        $result += [pscustomobject]@{
            Name = $k; Path = $path
            IsRedirected  = $redirected
            UnderOneDrive = $underOD
        }
    }
    return ($result | Sort-Object Name)
}

function Get-SysOrgCategoryNames {
<#
.SYNOPSIS
    Builds the category-name recognition table: canonical English names + the localized
    leaf names of the resolved known folders on this OS (design section 3.5).
.EXAMPLE
    $names = Get-SysOrgCategoryNames -KnownFolders (Get-SysOrgKnownFolders)
    $names['Pictures']    # e.g. { pictures, my pictures, bilder }
#>
    param($KnownFolders)
    $map = @{}
    foreach($k in $script:CanonicalCategoryNames.Keys){
        $set = New-Object System.Collections.Generic.HashSet[string]
        foreach($n in $script:CanonicalCategoryNames[$k]){ [void]$set.Add($n.ToLowerInvariant()) }
        $map[$k] = $set
    }
    foreach($kf in @($KnownFolders)){
        if(-not $map.ContainsKey("$($kf.Name)")){ continue }
        $leaf = ''
        try { $leaf = (Split-Path ([string]$kf.Path) -Leaf).ToLowerInvariant() } catch { $leaf = '' }
        if($leaf){ [void]$map["$($kf.Name)"].Add($leaf) }
    }
    return $map
}

function Test-SysOrgCategoryFolderName {
<#
.SYNOPSIS
    Returns the category a folder name represents (Documents/Pictures/Videos/Music/
    Downloads/Desktop), or $null when the name is not category-like.
.DESCRIPTION
    Used to preserve existing, intact category structures: a German 'Bilder' folder is
    recognized as Pictures-like and left untouched instead of being treated as clutter.
.EXAMPLE
    Test-SysOrgCategoryFolderName -Name 'D:\Bilder' -CategoryNames $names   # -> 'Pictures'
#>
    param([Parameter(Mandatory)][string]$Name,$CategoryNames)
    $leaf = ''
    try { $leaf = (Split-Path ("$Name".TrimEnd('\')) -Leaf).ToLowerInvariant() } catch { $leaf = "$Name".ToLowerInvariant() }
    if(-not $leaf){ return $null }
    foreach($k in $CategoryNames.Keys){
        if($CategoryNames[$k].Contains($leaf)){ return $k }
    }
    return $null
}

Export-ModuleMember -Function *-SysOrg*
