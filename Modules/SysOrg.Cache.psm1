#Requires -Version 5.1
# SysOrg.Cache.psm1 - the persistent file-state cache (v3.0 Phase 3.1).
#
# Cache\filestate.ndjson: one JSON object per line, written with a StreamWriter
# (never a giant ConvertTo-Json). Key = 'path|size|mtimeUtcTicks' -> SHA256,
# header hash, head+tail hash, and the content-derived METADATA (EXIF/ID3/MP4/
# Office/PDF/text) so unchanged files are never re-hashed or re-parsed.
# A cache entry is INVALID when size or mtime changed. Corruption degrades to a
# rescan: malformed lines are skipped; if more than a third of the file is
# unreadable the whole cache is discarded (never a crash).

function Get-SysOrgFileCacheKey {
<#
.SYNOPSIS
    The cache key for one file state: 'path|size|mtimeUtcTicks'.
.EXAMPLE
    Get-SysOrgFileCacheKey -Path 'C:\a.txt' -Length 10 -LastWriteTimeUtc (Get-Date).ToUniversalTime()
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[long]$Length,[datetime]$LastWriteTimeUtc)
    $p = ("$Path").Replace('/','\').ToLowerInvariant()
    $t = 0
    try { $t = $LastWriteTimeUtc.ToUniversalTime().Ticks } catch { $t = 0 }
    return ('{0}|{1}|{2}' -f $p, $Length, $t)
}

function Read-SysOrgFileStateCache {
<#
.SYNOPSIS
    Loads Cache\filestate.ndjson into a hashtable keyed by Get-SysOrgFileCacheKey.
.DESCRIPTION
    Streaming line reader; malformed lines are skipped and counted. When more than
    a third of the lines are unreadable the whole cache is treated as corrupted and
    an empty hashtable is returned (the caller falls back to a full rescan).
    Returns @{ Entries=<hashtable>; Corrupted=<bool>; SkippedLines=<int> }.
.EXAMPLE
    Read-SysOrgFileStateCache -Path 'C:\SysOrg\Cache\filestate.ndjson'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $entries = @{}
    if(-not (Test-Path -LiteralPath $Path)){
        return [pscustomobject]@{ Entries=$entries; Corrupted=$false; SkippedLines=0 }
    }
    $total = 0; $bad = 0
    try{
        $reader = $null
        try { $reader = New-Object System.IO.StreamReader($Path, $true) } catch { return [pscustomobject]@{ Entries=$entries; Corrupted=$true; SkippedLines=0 } }
        try{
            while($null -ne ($line = $reader.ReadLine())){
                $total++
                if([string]::IsNullOrWhiteSpace($line)){ continue }
                try{
                    $obj = ConvertFrom-Json $line
                    $k = "$($obj.k)"
                    if(-not [string]::IsNullOrWhiteSpace($k)){
                        $entries[$k] = [pscustomobject]@{
                            Hash="$($obj.h)"; HeaderHash="$($obj.hh)"; HeadTailHash="$($obj.ht)"; Meta=$obj.m
                        }
                    } else { $bad++ }
                } catch { $bad++ }
            }
        } finally { $reader.Dispose() }
    } catch {
        return [pscustomobject]@{ Entries=@{}; Corrupted=$true; SkippedLines=$total }
    }
    $corrupted = ($total -gt 8 -and (($bad * 3) -gt $total))
    if($corrupted){ $entries = @{} }
    return [pscustomobject]@{ Entries=$entries; Corrupted=$corrupted; SkippedLines=$bad }
}

function Save-SysOrgFileStateCache {
<#
.SYNOPSIS
    Writes the cache as ndjson with a StreamWriter (atomic-ish: temp file + replace).
.EXAMPLE
    Save-SysOrgFileStateCache -Path 'C:\SysOrg\Cache\filestate.ndjson' -Entries $ht
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][hashtable]$Entries)
    $dir = Split-Path $Path -Parent
    if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    try{
        $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 65536)
        $writer = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        try{
            foreach($k in ($Entries.Keys | Sort-Object)){
                $e = $Entries[$k]
                $hh = ''
                if($e.PSObject.Properties['HeaderHash']){ $hh = "$($e.HeaderHash)" }
                $ht = ''
                if($e.PSObject.Properties['HeadTailHash']){ $ht = "$($e.HeadTailHash)" }
                $metaJson = 'null'
                if($e.PSObject.Properties['Meta'] -and $e.Meta){
                    try { $metaJson = ($e.Meta | ConvertTo-Json -Depth 4 -Compress) } catch { $metaJson = 'null' }
                }
                # k is a path - escape it as a JSON string manually (paths contain backslashes)
                $kJson = ('"' + ($k.Replace('\','\\').Replace('"','\"')) + '"')
                $line = ('{{"k":{0},"h":"{1}","hh":"{2}","ht":"{3}","m":{4}}}' -f $kJson, "$($e.Hash)", $hh, $ht, $metaJson)
                $writer.WriteLine($line)
            }
            $writer.Flush()
        } finally { $writer.Dispose(); $fs.Dispose() }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    } catch {
        try { if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
        Write-Verbose "File-state cache write failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-SysOrgCacheEntryFresh {
<#
.SYNOPSIS
    True when a cache entry still matches the file's current size and mtime.
.DESCRIPTION
    Freshness IS the key: callers look up with Get-SysOrgFileCacheKey built from the
    file's CURRENT length and LastWriteTimeUtc - a hit means both still match, a miss
    means the file changed (or is new) and must be re-hashed/re-parsed.
.EXAMPLE
    $e = $cache[Get-SysOrgFileCacheKey -Path $p -Length $len -LastWriteTimeUtc $utc]
    (Test-SysOrgCacheEntryFresh -Entry $e) | Should -BeTrue
#>
    [CmdletBinding()]
    param([AllowNull()]$Entry)
    return ($null -ne $Entry)
}

function Get-SysOrgCachedMetadata {
<#
.SYNOPSIS
    Content-derived metadata for a file, through the file-state cache (Phase 3.1).
.DESCRIPTION
    Key = path|size|mtime: a fresh hit returns the stored metadata WITHOUT reading
    the file; a miss runs the built-in extractor for the family, stores the result
    in $NewEntries (mutated in place, saved by the caller afterwards) and returns it.
    Fail-soft both ways. $FileCache may be $null (no caching - plain extractor call).
    Requires SysOrg.Metadata.psm1 to be imported (the registry lives there).
.EXAMPLE
    Get-SysOrgCachedMetadata -Path 'C:\x\a.jpg' -Family 'exif' -FileCache $cache -NewEntries $new
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Family,
          $FileCache,[hashtable]$NewEntries)
    $len = [long]0; $utc = [datetime]::MinValue
    try{
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $len = [long]$fi.Length
        $utc = $fi.LastWriteTimeUtc
    } catch { return $null }
    $key = Get-SysOrgFileCacheKey -Path $Path -Length $len -LastWriteTimeUtc $utc
    if($FileCache -and $FileCache.ContainsKey($key)){
        $e = $FileCache[$key]
        if($e.PSObject.Properties['Meta'] -and ($null -ne $e.Meta)){
            $m = $e.Meta
            if($m -is [pscustomobject]){
                # JSON round trip: rebuild a hashtable and compare the source family
                $h = @{}
                foreach($p in $m.PSObject.Properties){ $h[$p.Name] = $p.Value }
                if("$($h['Source'])" -eq $Family){ return $h }
            } elseif($m -is [hashtable]){
                if("$($m['Source'])" -eq $Family){ return $m }
            }
        }
    }
    # cache miss: run the built-in extractor for the family
    $result = $null
    try{
        $reg = $null
        if(Get-Command Get-SysOrgExtractorRegistry -ErrorAction SilentlyContinue){ $reg = Get-SysOrgExtractorRegistry }
        if($reg -and $reg.ContainsKey($Family)){ $result = & $reg[$Family].Fn $Path }
    } catch { return $null }
    if(($null -ne $NewEntries) -and ($result -is [hashtable])){
        try { $NewEntries[$key] = [pscustomobject]@{ Hash=''; HeaderHash=''; HeadTailHash=''; Meta=$result } } catch { }
    }
    return $result
}

Export-ModuleMember -Function *-SysOrg*
