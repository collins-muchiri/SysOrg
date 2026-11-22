#Requires -Version 5.1
# SysOrg.Metadata.psm1 - the v3.0 metadata extractors (Phase 2.4) and date
# resolution (Phase 2.5).
#
# Every extractor is ZERO-DEPENDENCY (pure .NET + bytes), FAILS SOFT (any
# malformed/truncated/zero-byte file yields $null, never an exception), and is
# MOCKABLE: Get-SysOrgFileMetadata accepts -Extractors @{ family = scriptblock }
# so tests and future format handlers can replace the built-in implementations.
# Extractors only read; callers must already have passed the cloud-placeholder
# gates (opening a OneDrive placeholder would hydrate the cloud library).
#
# Built-in extractors:
#   exif   - minimal JPEG APP1/TIFF parser: DateTimeOriginal, Make/Model, GPS
#   id3    - ID3v2.3/v2.4 tags + ID3v1 fallback: title/artist/album/year
#   mp4    - ISO-BMFF box walk: moov/mvhd creation time (MP4 and MOV)
#   office - docProps/core.xml from the OPC zip (docx/xlsx/pptx)
#   pdf    - info dictionary: /Title, /Author, /CreationDate (no text extraction)
#   text   - first 2 KB snippet (feeds the lexicon and binary-masquerade checks)

function Get-SysOrgExifMetadata {
<#
.SYNOPSIS
    Minimal EXIF reader for JPEG files (TIFF IFD0 + ExifIFD + GPS IFD).
.DESCRIPTION
    Parses the APP1 'Exif' segment manually - no Windows-only imaging APIs, so the
    same code runs on Windows PowerShell 5.1 and PowerShell 7 on any OS. Returns
    Source='exif', DateTimeOriginal, Make, Model, GpsLat, GpsLon. Fail soft: any
    structural surprise (truncated file, wrong offsets, bad types) returns $null.
.EXAMPLE
    Get-SysOrgExifMetadata -Path 'C:\pics\IMG_0001.jpg'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{
        $bytes = $null
        try{
            $fs = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
            try{
                if($fs.Length -lt 12){ return $null }
                # read a bounded header window (APP1 segment; 1 MB is far more than enough)
                $len = [int][Math]::Min(1048576, $fs.Length)
                $bytes = New-Object byte[] $len
                $read = 0
                while($read -lt $len){
                    $n = $fs.Read($bytes, $read, $len - $read)
                    if($n -le 0){ break }
                    $read += $n
                }
            } finally { $fs.Dispose() }
        } catch { return $null }
        if($read -lt 12){ return $null }
        if(($bytes[0] -ne 0xFF) -or ($bytes[1] -ne 0xD8)){ return $null }   # not a JPEG

        # walk JPEG segments to find APP1 with 'Exif'
        $pos = 2
        $app1Start = -1; $app1Len = 0
        while(($pos + 4) -le $read){
            if($bytes[$pos] -ne 0xFF){ break }
            $marker = $bytes[$pos + 1]
            if($marker -eq 0xD8 -or $marker -eq 0x01 -or ($marker -ge 0xD0 -and $marker -le 0xD7)){ $pos += 2; continue }
            if($marker -eq 0xD9 -or $marker -eq 0xDA){ break }   # EOI / start of scan
            $segLen = ([int]$bytes[$pos + 2] -shl 8) + [int]$bytes[$pos + 3]
            if($marker -eq 0xE1){
                # 'Exif' + 0x00 0x00 inside the APP1 payload?
                if(($pos + 10) -le $read){
                    $tag = [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 4, 4)
                    if($tag -eq 'Exif'){ $app1Start = $pos + 10; $app1Len = $segLen - 8; break }
                }
            }
            $pos += (2 + $segLen)
        }
        if($app1Start -lt 0){ return $null }

        # ---- TIFF parsing over the APP1 payload ----
        $tiff = $app1Start
        if(($tiff + 8) -gt $read){ return $null }
        $bo = [System.Text.Encoding]::ASCII.GetString($bytes, $tiff, 2)
        $le = $true
        if($bo -eq 'II'){ $le = $true } elseif($bo -eq 'MM'){ $le = $false } else { return $null }
        # NOTE: -shl on a BYTE operand stays byte-sized in PowerShell (overflow to 0) -
        # every shift below casts to [int] first.
        $u16 = { param([byte[]]$B,[int]$O,[bool]$L) if($L){ return (([int]$B[$O + 1] -shl 8) -bor [int]$B[$O]) } else { return (([int]$B[$O] -shl 8) -bor [int]$B[$O + 1]) } }
        $u32 = { param([byte[]]$B,[int]$O,[bool]$L) if($L){ return ([int](([int]$B[$O + 3] -shl 24) -bor ([int]$B[$O + 2] -shl 16) -bor ([int]$B[$O + 1] -shl 8) -bor [int]$B[$O])) } else { return ([int](([int]$B[$O] -shl 24) -bor ([int]$B[$O + 1] -shl 16) -bor ([int]$B[$O + 2] -shl 8) -bor [int]$B[$O + 3])) } }
        function Get-SysOrgTiffAscii {
            param([byte[]]$B,[int]$Base,[int]$Off,[int]$Count,[bool]$L,$u32Ref)
            $abs = $Base + (& $u32Ref $B ($Base + $Off + 8) $L)
            if(($abs + $Count) -gt $B.Length -or $abs -lt 0){ return '' }
            $vals = New-Object System.Collections.Generic.List[byte]
            for($i=0; $i -lt $Count - 1; $i++){ [void]$vals.Add($B[$abs + $i]) }
            return ([System.Text.Encoding]::ASCII.GetString($vals.ToArray())).Trim()
        }
        $ifd0Off = & $u32 $bytes ($tiff + 4) $le
        $ifd0 = $tiff + $ifd0Off
        if(($ifd0 + 2) -gt $read){ return $null }
        $out = @{ Source='exif'; DateTimeOriginal=''; Make=''; Model=''; GpsLat=$null; GpsLon=$null }
        $exifIfdRel = -1; $gpsIfdRel = -1
        $nEntries = & $u16 $bytes $ifd0 $le
        if($nEntries -le 0 -or $nEntries -gt 512){ return $null }
        for($i=0; $i -lt $nEntries; $i++){
            $e = $ifd0 + 2 + ($i * 12)
            if(($e + 12) -gt $read){ break }
            $tag = & $u16 $bytes $e $le
            if($tag -eq 0x010F){ $out.Make = (Get-SysOrgTiffAscii -B $bytes -Base $tiff -Off ($e - $tiff) -Count (& $u32 $bytes ($e + 4) $le) -L $le -u32Ref $u32) }
            elseif($tag -eq 0x0110){ $out.Model = (Get-SysOrgTiffAscii -B $bytes -Base $tiff -Off ($e - $tiff) -Count (& $u32 $bytes ($e + 4) $le) -L $le -u32Ref $u32) }
            elseif($tag -eq 0x8769){ $exifIfdRel = & $u32 $bytes ($e + 8) $le }
            elseif($tag -eq 0x8825){ $gpsIfdRel = & $u32 $bytes ($e + 8) $le }
        }
        if($exifIfdRel -ge 0){
            $ifdExif = $tiff + $exifIfdRel
            if(($ifdExif + 2) -le $read){
                $n2 = & $u16 $bytes $ifdExif $le
                for($i=0; $i -lt $n2; $i++){
                    $e = $ifdExif + 2 + ($i * 12)
                    if(($e + 12) -gt $read){ break }
                    $tag = & $u16 $bytes $e $le
                    if($tag -eq 0x9003 -or $tag -eq 0x9004){
                        $cnt = & $u32 $bytes ($e + 4) $le
                        $v = (Get-SysOrgTiffAscii -B $bytes -Base $tiff -Off ($e - $tiff) -Count $cnt -L $le -u32Ref $u32)
                        if("$v" -match '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}'){ $out.DateTimeOriginal = $v; break }
                    }
                }
            }
        }
        if($gpsIfdRel -ge 0){
            $ifdGps = $tiff + $gpsIfdRel
            if(($ifdGps + 2) -le $read){
                $latRef = 'N'; $lonRef = 'E'; $latR = $null; $lonR = $null
                $n3 = & $u16 $bytes $ifdGps $le
                for($i=0; $i -lt $n3; $i++){
                    $e = $ifdGps + 2 + ($i * 12)
                    if(($e + 12) -gt $read){ break }
                    $tag = & $u16 $bytes $e $le
                    $voff = $tiff + (& $u32 $bytes ($e + 8) $le)
                    if($tag -eq 0x0001){ $latRef = [System.Text.Encoding]::ASCII.GetString($bytes, $voff, 1) }
                    elseif($tag -eq 0x0003){ $lonRef = [System.Text.Encoding]::ASCII.GetString($bytes, $voff, 1) }
                    elseif($tag -eq 0x0002 -or $tag -eq 0x0004){
                        try{
                            $d1 = & $u32 $bytes $voff $le; $d2 = & $u32 $bytes ($voff + 8) $le; $d3 = & $u32 $bytes ($voff + 16) $le
                            $val = 0.0
                            if($d2 -gt 0){ $val += $d1 / [double]$d2 }
                            if($d3 -gt 0){ $val += $d3 / 60.0 }
                            if($tag -eq 0x0002){ $latR = $val } else { $lonR = $val }
                        } catch { }
                    }
                }
                if($null -ne $latR){ if($latRef -eq 'S'){ $latR = -$latR }; $out.GpsLat = [Math]::Round($latR, 5) }
                if($null -ne $lonR){ if($lonRef -eq 'W'){ $lonR = -$lonR }; $out.GpsLon = [Math]::Round($lonR, 5) }
            }
        }
        $hasAnything = $false
        foreach($k in @('DateTimeOriginal','Make','Model')){ if("$($out[$k])" -ne ''){ $hasAnything = $true } }
        if($null -ne $out.GpsLat){ $hasAnything = $true }
        if(-not $hasAnything){ return $null }
        return $out
    } catch { return $null }
}

function Get-SysOrgId3Metadata {
<#
.SYNOPSIS
    ID3v2.3/v2.4 tag reader with an ID3v1 fallback (title/artist/album/year).
.DESCRIPTION
    Parses the tag header (syncsafe size), the text frames TIT2/TPE1/TALB/TYER/TDRC
    with the documented encodings (ISO-8859-1, UTF-16 BOM, UTF-16BE, UTF-8), and
    falls back to the ID3v1 tail tag. Fail soft: non-MP3 bytes, truncated tags or
    absurd frame sizes return $null.
.EXAMPLE
    Get-SysOrgId3Metadata -Path 'C:\music\track.mp3'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{
        $fs = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
        try{
            if($fs.Length -lt 10){ return $null }
            $out = @{ Source='id3'; Title=''; Artist=''; Album=''; Year='' }
            $buf = New-Object byte[] 10
            $got = 0
            while($got -lt 10){ $n = $fs.Read($buf, $got, 10 - $got); if($n -le 0){ break }; $got += $n }
            if(($buf[0] -eq 0x49) -and ($buf[1] -eq 0x44) -and ($buf[2] -eq 0x33)){
                $major = $buf[3]
                if($major -lt 2 -or $major -gt 4){ return $null }
                $size = (([int]$buf[6] -band 0x7F) -shl 21) -bor (([int]$buf[7] -band 0x7F) -shl 14) -bor (([int]$buf[8] -band 0x7F) -shl 7) -bor [int]$buf[9]
                if($size -le 0 -or $size -gt 10485760){ return $null }
                $tag = New-Object byte[] $size
                $got = 0
                while($got -lt $size){ $n = $fs.Read($tag, $got, $size - $got); if($n -le 0){ break }; $got += $n }
                $pos = 0
                $idLen = 4
                if($major -eq 2){ $idLen = 3 }
                while(($pos + $idLen + 6) -le $tag.Length){
                    $fid = [System.Text.Encoding]::ASCII.GetString($tag, $pos, $idLen)
                    if($fid -notmatch '^[A-Z0-9]+$'){ break }
                    $fsize = 0
                    if($major -eq 2){ $fsize = (([int]$tag[$pos + 3] -shl 16) -bor ([int]$tag[$pos + 4] -shl 8) -bor [int]$tag[$pos + 5]) }
                    elseif($major -eq 4){ $fsize = (([int]$tag[$pos + 4] -band 0x7F) -shl 21) -bor (([int]$tag[$pos + 5] -band 0x7F) -shl 14) -bor (([int]$tag[$pos + 6] -band 0x7F) -shl 7) -bor ([int]$tag[$pos + 7] -band 0x7F) }
                    else { $fsize = (([int]$tag[$pos + 4] -shl 24) -bor ([int]$tag[$pos + 5] -shl 16) -bor ([int]$tag[$pos + 6] -shl 8) -bor [int]$tag[$pos + 7]) }
                    if($fsize -le 0 -or ($pos + $idLen + 6 + $fsize) -gt $tag.Length){ break }
                    $bodyStart = $pos + $idLen + 6
                    $text = ''
                    if(($fid -in @('TIT2','TPE1','TALB','TYER','TDRC','TIT1','TIT3')) -and ($fsize -gt 1)){
                        $enc = $tag[$bodyStart]
                        $raw = New-Object byte[] ($fsize - 1)
                        [Array]::Copy($tag, $bodyStart + 1, $raw, 0, $fsize - 1)
                        try{
                            switch($enc){
                                0 { $text = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($raw) }
                                1 { $text = [System.Text.Encoding]::Unicode.GetString($raw) }
                                2 { $text = [System.Text.Encoding]::BigEndianUnicode.GetString($raw) }
                                3 { $text = [System.Text.Encoding]::UTF8.GetString($raw) }
                                default { $text = '' }
                            }
                        } catch { $text = '' }
                        $text = ("$text".Split([char]0))[0].Trim()
                    }
                    if($fid -in @('TIT2','TT2')){ $out.Title = $text }
                    elseif($fid -in @('TPE1','TP1')){ $out.Artist = $text }
                    elseif($fid -in @('TALB','TAL')){ $out.Album = $text }
                    elseif($fid -eq 'TYER'){ $out.Year = $text }
                    elseif($fid -eq 'TDRC'){ $out.Year = ("$text".Substring(0, [Math]::Min(4, "$text".Length))) }
                    $pos = $bodyStart + $fsize
                }
            }
            if("$($out.Year)" -eq '' -or "$($out.Artist)" -eq ''){
                # ID3v1 fallback: last 128 bytes, 'TAG'
                try{
                    $tail = New-Object byte[] 128
                    $fs.Seek(-128, 'End') | Out-Null
                    $got = 0
                    while($got -lt 128){ $n = $fs.Read($tail, $got, 128 - $got); if($n -le 0){ break }; $got += $n }
                    if($got -eq 128 -and $tail[0] -eq 0x54 -and $tail[1] -eq 0x41 -and $tail[2] -eq 0x47){
                        $lat1 = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
                        $v1title = ($lat1.GetString($tail, 3, 30)).Trim([char]0, ' ')
                        $v1artist = ($lat1.GetString($tail, 33, 30)).Trim([char]0, ' ')
                        $v1album = ($lat1.GetString($tail, 63, 30)).Trim([char]0, ' ')
                        $v1year = ($lat1.GetString($tail, 93, 4)).Trim([char]0, ' ')
                        if("$($out.Title)" -eq ''){ $out.Title = $v1title }
                        if("$($out.Artist)" -eq ''){ $out.Artist = $v1artist }
                        if("$($out.Album)" -eq ''){ $out.Album = $v1album }
                        if("$($out.Year)" -eq ''){ $out.Year = $v1year }
                    }
                } catch { }
            }
            if("$($out.Artist)$($out.Title)$($out.Album)$($out.Year)" -eq ''){ return $null }
            return $out
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Get-SysOrgMp4Metadata {
<#
.SYNOPSIS
    MP4/MOV box walk for the moov/mvhd creation time.
.DESCRIPTION
    Walks top-level ISO-BMFF boxes (bounded to 512 top-level boxes and 64 MB of
    moov payload), finds moov/mvhd, and converts the creation seconds (Mac epoch
    1904-01-01) to UTC. Handles both version 0 (u32) and version 1 (u64) mvhd.
    Fail soft on truncated or foreign bytes.
.EXAMPLE
    Get-SysOrgMp4Metadata -Path 'C:\vid\VID_0001.mp4'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{
        $fs = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
        try{
            $len = $fs.Length
            if($len -lt 16){ return $null }
            $maxRead = [int64][Math]::Min($len, 64MB)
            $buf = New-Object byte[] ([int]$maxRead)
            $got = 0
            while($got -lt $buf.Length){ $n = $fs.Read($buf, $got, $buf.Length - $got); if($n -le 0){ break }; $got += $n }
            $pos = 0
            $boxes = 0
            $out = $null
            while(($pos + 8) -le $got -and $boxes -lt 512){
                $boxes++
                $size = ([int]$buf[$pos] -shl 24) -bor ([int]$buf[$pos + 1] -shl 16) -bor ([int]$buf[$pos + 2] -shl 8) -bor [int]$buf[$pos + 3]
                $type = [System.Text.Encoding]::ASCII.GetString($buf, $pos + 4, 4)
                if($size -lt 8){ break }
                if($type -eq 'moov'){
                    # walk children of moov
                    $cpos = $pos + 8
                    $cend = [Math]::Min($pos + $size, $got)
                    while(($cpos + 8) -le $cend){
                        $csize = ([int]$buf[$cpos] -shl 24) -bor ([int]$buf[$cpos + 1] -shl 16) -bor ([int]$buf[$cpos + 2] -shl 8) -bor [int]$buf[$cpos + 3]
                        $ctype = [System.Text.Encoding]::ASCII.GetString($buf, $cpos + 4, 4)
                        if($csize -lt 8){ break }
                        if($ctype -eq 'mvhd'){
                            $v = $buf[$cpos + 8]
                            $epoch = [datetime]'1904-01-01T00:00:00Z'
                            try{
                                if($v -eq 1){
                                    $tsPos = $cpos + 8 + 4 + 8
                                    $ts = [int64](([int64]$buf[$tsPos] -shl 24) -bor ([int64]$buf[$tsPos + 1] -shl 16) -bor ([int64]$buf[$tsPos + 2] -shl 8) -bor [int64]$buf[$tsPos + 3])
                                    $cPos2 = $tsPos + 4
                                    $secs = [int64](([int64]$buf[$cPos2] -shl 56) -bor ([int64]$buf[$cPos2 + 1] -shl 48) -bor ([int64]$buf[$cPos2 + 2] -shl 40) -bor ([int64]$buf[$cPos2 + 3] -shl 32) -bor ([int64]$buf[$cPos2 + 4] -shl 24) -bor ([int64]$buf[$cPos2 + 5] -shl 16) -bor ([int64]$buf[$cPos2 + 6] -shl 8) -bor [int64]$buf[$cPos2 + 7])
                                } else {
                                    $tsPos = $cpos + 12
                                    $ts = [int64](([int64]$buf[$tsPos] -shl 24) -bor ([int64]$buf[$tsPos + 1] -shl 16) -bor ([int64]$buf[$tsPos + 2] -shl 8) -bor [int64]$buf[$tsPos + 3])
                                    $cPos2 = $tsPos + 4
                                    $secs = [int64](([int64]$buf[$cPos2] -shl 24) -bor ([int64]$buf[$cPos2 + 1] -shl 16) -bor ([int64]$buf[$cPos2 + 2] -shl 8) -bor [int64]$buf[$cPos2 + 3])
                                }
                                if($ts -le 0){ return $null }
                                $created = $epoch.AddSeconds([double]$secs)
                                return @{ Source='mp4'; CreatedUtc=$created; Title='' }
                            } catch { return $null }
                        }
                        $cpos += $csize
                    }
                    break
                }
                $pos += $size
            }
            return $null
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Get-SysOrgOfficeMetadata {
<#
.SYNOPSIS
    Office (docx/xlsx/pptx) core properties from docProps/core.xml via the OPC zip.
.DESCRIPTION
    Uses System.IO.Compression.ZipFile.OpenRead (available on PowerShell 5.1 and 7),
    reads ONLY the core.xml entry, and extracts dc:title, dc:creator and
    dcterms:created. Fail soft: not-a-zip, missing entry or malformed XML -> $null.
.EXAMPLE
    Get-SysOrgOfficeMetadata -Path 'C:\docs\report.docx'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{
        $zip = $null
        try { $zip = [System.IO.Compression.ZipFile]::OpenRead($Path) } catch { return $null }
        try{
            if($null -eq $zip){ return $null }
            $entry = $null
            foreach($e in $zip.Entries){ if("$($e.FullName)" -ieq 'docProps/core.xml'){ $entry = $e; break } }
            if(-not $entry){ return $null }
            $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
            $xml = $reader.ReadToEnd()
            $reader.Dispose()
            $out = @{ Source='office'; Title=''; Creator=''; Created='' }
            $m = [regex]::Match($xml, '<dc:title[^>]*>([^<]+)</dc:title>')
            if($m.Success){ $out.Title = $m.Groups[1].Value.Trim() }
            $m = [regex]::Match($xml, '<dc:creator[^>]*>([^<]+)</dc:creator>')
            if($m.Success){ $out.Creator = $m.Groups[1].Value.Trim() }
            $m = [regex]::Match($xml, '<dcterms:created[^>]*>([^<]+)</dcterms:created>')
            if($m.Success){ $out.Created = $m.Groups[1].Value.Trim() }
            if("$($out.Title)$($out.Creator)$($out.Created)" -eq ''){ return $null }
            return $out
        } finally { if($zip){ $zip.Dispose() } }
    } catch { return $null }
}

function Get-SysOrgPdfMetadata {
<#
.SYNOPSIS
    PDF info dictionary: /Title, /Author, /CreationDate (no text extraction).
.DESCRIPTION
    Scans the first 4 KB and last 2 KB for the info dictionary entries. Escaped
    parentheses inside values are stripped of their escapes; a value that cannot be
    read is left empty. Fail soft on non-PDF or unreadable files.
.EXAMPLE
    Get-SysOrgPdfMetadata -Path 'C:\docs\tax return.pdf'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{
        $fs = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
        try{
            if($fs.Length -lt 8){ return $null }
            $headLen = [int][Math]::Min(4096, $fs.Length)
            $head = New-Object byte[] $headLen
            $got = 0
            while($got -lt $headLen){ $n = $fs.Read($head, $got, $headLen - $got); if($n -le 0){ break }; $got += $n }
            $text = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($head, 0, $got)
            if($fs.Length -gt $headLen){
                $tailLen = [int][Math]::Min(2048, ($fs.Length - $headLen))
                $fs.Seek($fs.Length - $tailLen, 'Begin') | Out-Null
                $tail = New-Object byte[] $tailLen
                $got = 0
                while($got -lt $tailLen){ $n = $fs.Read($tail, $got, $tailLen - $got); if($n -le 0){ break }; $got += $n }
                $text += [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($tail, 0, $got)
            }
            if(-not $text.Contains('%PDF')){ return $null }
            $out = @{ Source='pdf'; Title=''; Author=''; Created='' }
            $m = [regex]::Match($text, '/Title\s*\(((?:[^()\\]|\\.)*)\)')
            if($m.Success){ $out.Title = ($m.Groups[1].Value -replace '\\([()\\])','$1').Trim() }
            $m = [regex]::Match($text, '/Author\s*\(((?:[^()\\]|\\.)*)\)')
            if($m.Success){ $out.Author = ($m.Groups[1].Value -replace '\\([()\\])','$1').Trim() }
            $m = [regex]::Match($text, '/CreationDate\s*\(D:(\d{4,14})')
            if($m.Success){
                $d = $m.Groups[1].Value
                $fmt = 'yyyy'
                if($d.Length -ge 8){ $fmt = 'yyyyMMdd' }
                try{
                    $dt = [datetime]::ParseExact($d.Substring(0, [Math]::Min(14, $d.Length)), 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
                    $out.Created = $dt.ToString('yyyy-MM-ddTHH:mm:ss')
                } catch {
                    try { $dt = [datetime]::ParseExact($d.Substring(0,8), 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture); $out.Created = $dt.ToString('yyyy-MM-dd') } catch { }
                }
            }
            if("$($out.Title)$($out.Author)$($out.Created)" -eq ''){ return $null }
            return $out
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Get-SysOrgTextSnippet {
<#
.SYNOPSIS
    Reads the first 2 KB of a text-ish file for lexicon scoring.
.DESCRIPTION
    Returns Source='text', Snippet, Binary. Binary is $true when the snippet holds
    more than 30% non-printable bytes - the pipeline treats that as a possible
    extension mismatch signal. Fail soft: unreadable files return $null.
.EXAMPLE
    Get-SysOrgTextSnippet -Path 'C:\docs\notes.txt'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{
        $fs = [System.IO.File]::Open($Path,'Open','Read','ReadWrite')
        try{
            if($fs.Length -lt 1){ return $null }
            $len = [int][Math]::Min(2048, $fs.Length)
            $buf = New-Object byte[] $len
            $got = 0
            while($got -lt $len){ $n = $fs.Read($buf, $got, $len - $got); if($n -le 0){ break }; $got += $n }
            $ctrl = 0
            for($i=0; $i -lt $got; $i++){
                $b = $buf[$i]
                if(($b -lt 9) -or ($b -eq 11) -or ($b -eq 12) -or (($b -ge 14) -and ($b -le 31)) -or ($b -ge 127)){ $ctrl++ }
            }
            $binary = (($ctrl * 100) / [Math]::Max(1, $got)) -gt 30
            $snippet = [System.Text.Encoding]::UTF8.GetString($buf, 0, $got)
            return @{ Source='text'; Snippet=$snippet; Binary=[bool]$binary }
        } finally { $fs.Dispose() }
    } catch { return $null }
}

# extractor registry: family -> (extension set, built-in scriptblock)
$script:SysOrgExtractorRegistry = @{
    exif   = @{ Extensions=@('.jpg','.jpeg'); Fn={ param($Path) Get-SysOrgExifMetadata -Path $Path } }
    id3    = @{ Extensions=@('.mp3'); Fn={ param($Path) Get-SysOrgId3Metadata -Path $Path } }
    mp4    = @{ Extensions=@('.m4a','.mp4','.mov','.m4v'); Fn={ param($Path) Get-SysOrgMp4Metadata -Path $Path } }
    office = @{ Extensions=@('.docx','.xlsx','.pptx'); Fn={ param($Path) Get-SysOrgOfficeMetadata -Path $Path } }
    pdf    = @{ Extensions=@('.pdf'); Fn={ param($Path) Get-SysOrgPdfMetadata -Path $Path } }
    text   = @{ Extensions=@('.txt','.md','.csv','.tsv','.log'); Fn={ param($Path) Get-SysOrgTextSnippet -Path $Path } }
}

function Get-SysOrgFileMetadata {
<#
.SYNOPSIS
    Orchestrates the metadata extractors for one file (mockable interface).
.DESCRIPTION
    Picks the extractor family by extension (falling back to 'text' for unknown
    text-like categories is deliberate: the snippet also detects binary masquerades).
    -Extractors overrides the built-ins: @{ exif = { param($Path) @{...} }, id3 = ... }.
    Every call is fail-soft: a throwing extractor yields $null and never breaks the
    pipeline. Callers must have passed the cloud-placeholder gates first.
.EXAMPLE
    Get-SysOrgFileMetadata -Path 'C:\x\a.jpg' -Extension '.jpg'
    Get-SysOrgFileMetadata -Path 'C:\x\a.jpg' -Extension '.jpg' -Extractors @{ exif = { param($p) @{ Source='exif'; DateTimeOriginal='2024:01:01 10:00:00' } } }
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [AllowEmptyString()][string]$Extension,
          [hashtable]$Extractors)
    $ext = "$Extension".ToLowerInvariant()
    $family = $null
    foreach($k in $script:SysOrgExtractorRegistry.Keys){
        if($script:SysOrgExtractorRegistry[$k].Extensions -contains $ext){ $family = $k; break }
    }
    if(-not $family){ return $null }
    $result = $null
    try{
        if($Extractors -and $Extractors.ContainsKey($family)){
            $result = @(& $Extractors[$family] $Path)
            if($result.Count -gt 0){ $result = $result[0] } else { $result = $null }
        } else {
            $result = & $script:SysOrgExtractorRegistry[$family].Fn $Path
        }
    } catch { return $null }
    if($result -is [hashtable]){
        if(-not $result.ContainsKey('Source')){ $result['Source'] = $family }
        return $result
    }
    return $null
}

function Get-SysOrgMetadataSummary {
<#
.SYNOPSIS
    One-line summary of a metadata result for the Decision signals.
.EXAMPLE
    Get-SysOrgMetadataSummary -Metadata @{ Source='id3'; Artist='A'; Album='B' }   # -> 'Artist=A; Album=B'
#>
    param([hashtable]$Metadata)
    if(-not $Metadata){ return '' }
    $parts = @()
    foreach($k in @('Title','Artist','Album','Year','DateTimeOriginal','CreatedUtc','Created','Make','Model','Creator','Snippet')){
        if($Metadata.ContainsKey($k) -and "$($Metadata[$k])" -ne ''){
            $v = "$($Metadata[$k])"
            if($v.Length -gt 40){ $v = $v.Substring(0,40) + '...' }
            $parts += ('{0}={1}' -f $k, $v)
        }
    }
    return ($parts -join '; ')
}

function Resolve-SysOrgFileDate {
<#
.SYNOPSIS
    Stage 7: resolves the best date for a file (v3.0 Phase 2.5).
.DESCRIPTION
    Priority: metadata date (EXIF DateTimeOriginal > MP4 mvhd creation > Office
    created > PDF creation > ID3 year) > date embedded in the filename
    (IMG_20240101_101010, Screenshot_2024-01-01_101010, 2024-01-01, WA patterns)
    > filesystem min(CreationTime, LastWriteTime). The chosen source is recorded
    so the Decision signals can show which date won. Never throws.
.EXAMPLE
    Resolve-SysOrgFileDate -Path 'C:\pics\IMG_20240101_101010.jpg' -Metadata $meta
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [hashtable]$Metadata,
          [hashtable]$DateOverride)
    try{
        if($DateOverride -and $DateOverride.ContainsKey('Date') -and $DateOverride['Date']){
            return [pscustomobject]@{ Date=[datetime]$DateOverride['Date']; Source="$($DateOverride['Source'])" }
        }
        # 1) metadata dates, in priority order
        if($Metadata){
            if($Metadata.ContainsKey('DateTimeOriginal') -and "$($Metadata['DateTimeOriginal'])"){
                try{
                    $dt = [datetime]::ParseExact("$($Metadata['DateTimeOriginal'])", 'yyyy:MM:dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                    return [pscustomobject]@{ Date=$dt; Source='exif' }
                } catch { }
            }
            if($Metadata.ContainsKey('CreatedUtc') -and "$($Metadata['CreatedUtc'])"){
                try { return [pscustomobject]@{ Date=[datetime]::Parse("$($Metadata['CreatedUtc'])", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind); Source='mp4' } } catch { }
            }
            if($Metadata.ContainsKey('Created') -and "$($Metadata['Created'])"){
                try { return [pscustomobject]@{ Date=[datetime]::Parse("$($Metadata['Created'])", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind); Source='office' } } catch { }
            }
            if($Metadata.ContainsKey('Year') -and "$($Metadata['Year'])" -match '^(19|20)\d{2}$'){
                # NOTE: $Matches[0] is the full year; group 1 would only be the century
                return [pscustomobject]@{ Date=[datetime]::new([int]$Matches[0], 1, 1); Source='id3' }
            }
        }
        # 2) dates embedded in the filename
        $stem = ([System.IO.Path]::GetFileNameWithoutExtension($Path))
        # NOTE: '\b' does NOT fire between an underscore and a digit (both are word
        # characters), so the boundaries use digit lookarounds instead.
        $patterns = @(
            @{ Re='(?:IMG|VID|DSC|DJI)[-_]?(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})'; Fmt='ymdhms' },
            @{ Re='(?<![0-9])(\d{4})[-_.](\d{2})[-_.](\d{2})[T _](\d{2})[.\-]?(\d{2})[.\-]?(\d{2})(?![0-9])'; Fmt='ymdhms' },
            @{ Re='(?<![0-9])(\d{4})-(\d{2})-(\d{2})(?![0-9])'; Fmt='ymd' },
            @{ Re='(?<![0-9])(\d{4})(\d{2})(\d{2})(?![0-9])'; Fmt='ymd' }
        )
        foreach($p in $patterns){
            if($stem -match $p.Re){
                try{
                    $y = [int]$Matches[1]
                    if($p.Fmt -eq 'ymd'){
                        $mo = [int]$Matches[2]; $d = [int]$Matches[3]
                        if($y -ge 1990 -and $y -le 2100 -and $mo -ge 1 -and $mo -le 12 -and $d -ge 1 -and $d -le 31){
                            return [pscustomobject]@{ Date=[datetime]::new($y, $mo, $d); Source='filename' }
                        }
                    } else {
                        $mo = [int]$Matches[2]; $d = [int]$Matches[3]; $hh = [int]$Matches[4]; $mm = [int]$Matches[5]; $ss = [int]$Matches[6]
                        if($y -ge 1990 -and $y -le 2100 -and $mo -ge 1 -and $mo -le 12 -and $d -ge 1 -and $d -le 31 -and $hh -lt 24 -and $mm -lt 60 -and $ss -lt 60){
                            return [pscustomobject]@{ Date=[datetime]::new($y, $mo, $d, $hh, $mm, $ss); Source='filename' }
                        }
                    }
                } catch { }
            }
        }
        # 3) filesystem: min(CreationTime, LastWriteTime)
        try{
            $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $d = $fi.CreationTime
            if($fi.LastWriteTime -lt $d){ $d = $fi.LastWriteTime }
            return [pscustomobject]@{ Date=$d; Source='filesystem' }
        } catch {
            return [pscustomobject]@{ Date=(Get-Date); Source='filesystem' }
        }
    } catch {
        return [pscustomobject]@{ Date=(Get-Date); Source='filesystem' }
    }
}

Export-ModuleMember -Function *-SysOrg*
