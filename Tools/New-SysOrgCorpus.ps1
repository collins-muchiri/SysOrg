#Requires -Version 5.1
# Tools/New-SysOrgCorpus.ps1 - deterministic synthetic corpus generator (v3.0, Phase 0).
#
# Generates a preview-first test corpus that looks like a messy user drive:
#   - mixed file types with realistic names
#   - ~5% exact duplicates (files large enough to pass Copies.MinFileSizeKB)
#   - REAL binary fixtures: minimal EXIF JPEGs (DateTimeOriginal/Make/Model),
#     ID3v2 MP3s (artist/album/title/year), MP4 boxes with an mvhd creation
#     time and PDF info dictionaries - so the v3.0 metadata extractors parse
#     actual bytes, and tests can mock the extractors and compare against the
#     generated manifest.
#   - a manifest.csv listing every generated file with its expected metadata.
#
# Determinism: identical parameters + seed produce byte-identical corpora.
# No network, no external dependencies.

[CmdletBinding()]
param(
    [string]$Root,
    [int]$FileCount = 100000,
    [double]$DuplicatesPercent = 5,
    [int]$Seed = 42,
    [int]$DupMinKB = 300,
    [switch]$Clean,
    [switch]$NoManifest
)
$ErrorActionPreference = 'Stop'

if(-not $Root){ $Root = Join-Path (Split-Path -Parent $PSScriptRoot) 'BenchmarkCorpus' }
$Root = [System.IO.Path]::GetFullPath($Root)
if($Clean -and (Test-Path -LiteralPath $Root)){
    Remove-Item -LiteralPath $Root -Recurse -Force
    Write-Host "Removed existing corpus: $Root"
}
if(-not (Test-Path -LiteralPath $Root)){ New-Item -ItemType Directory -Path $Root -Force | Out-Null }

# --- deterministic RNG + shared word pools -----------------------------------
$rand = New-Object System.Random($Seed)
$script:CorpusRoot = $Root
$script:CorpusDupMinKb = $DupMinKb
$script:CorpusManifest = New-Object System.Collections.Generic.List[string]
$script:CorpusByKind = @{}                 # kind -> List[string] of written paths
$script:CorpusDupCopies = @{}              # source path -> copies made so far
$script:CorpusUniqueWritten = 0
$script:CorpusDupWritten = 0

function Get-RandomInt {
    # Deterministic helper over the module-seeded System.Random instance.
    param([int]$MaxExclusive)
    return $rand.Next(0, $MaxExclusive)
}
function Get-RandomBytes {
    param([int]$Count,[int]$FillerSeed)
    $buf = New-Object byte[] $Count
    $r = New-Object System.Random($FillerSeed)
    $r.NextBytes($buf)
    return $buf
}
function Get-Pick { param([string[]]$Pool) return $Pool[(Get-RandomInt $Pool.Count)] }

$people   = @('Wanjiku','Otieno','Kamau','Njeri','Achieng','Mwangi','Chebet','Kiptoo','Amina','Barasa','Okello','Wambui','Mutiso','Naliaka','Wekesa')
$orgs     = @('KRA','Safaricom','EquityBank','CoopBank','KenyaPower','Railways','CityHall','Zuku','Nation','Dstv')
$subjects = @('Invoice','Receipt','Statement','Contract','Certificate','Manual','Report','Notes','Proposal','Thesis','Syllabus','Letter','Form','Permit','Licence')
$topics   = @('PAYE','VAT','Withholding','Rent','School','Hospital','Insurance','Subscription','Delivery','Membership','Exam','Training')
$artists  = @('Sauti Sol','Nyashinski','Bahati','Akothee','Diamond','Wahu','Nameless','Femi One')
$albums   = @('Live in Nairobi','Coast Sessions','Mombasa Nights','Rift Valley','Uptown Beats','Sunday Best','Campus Tapes','Harvest')
$apps     = @('ledger-app','photo-batch','map-tools','sms-gateway','data-sync','report-kit','file-watch')
$cities   = @('Nairobi','Mombasa','Kisumu','Nakuru','Eldoret','Thika','Malindi')
$years    = @(2021,2022,2023,2024,2025)

$kindRoll = @(
    @{ Kind='Document';    W=22 },
    @{ Kind='Finance';     W=12 },
    @{ Kind='Spreadsheet'; W=8  },
    @{ Kind='PhotoExif';   W=10 },
    @{ Kind='PhotoPlain';  W=8  },
    @{ Kind='Screenshot';  W=6  },
    @{ Kind='WhatsApp';    W=6  },
    @{ Kind='VideoMp4';    W=6  },
    @{ Kind='MusicMp3';    W=8  },
    @{ Kind='VoiceNote';   W=5  },
    @{ Kind='Installer';   W=3  },
    @{ Kind='Archive';     W=4  },
    @{ Kind='Code';        W=6  },
    @{ Kind='PdfInfo';     W=6  }
)
$rollTotal = 0
foreach($kr in $kindRoll){ $rollTotal += $kr.W }

function Get-CorpusKind {
    # Weighted pick; the order of $kindRoll is fixed, so the draw is deterministic.
    $n = Get-RandomInt $rollTotal
    $acc = 0
    foreach($kr in $kindRoll){ $acc += $kr.W; if($n -lt $acc){ return $kr.Kind } }
    return 'Document'
}

# --- binary fixture builders --------------------------------------------------
function New-ExifJpegBytes {
<#
.SYNOPSIS
    Minimal valid JPEG with an APP1 EXIF segment carrying Make/Model/DateTimeOriginal.
#>
    param([string]$Make,[string]$Model,[string]$DateTimeOriginal)
    function Get-TiffAsciiValue { param([string]$S)
        $b = [System.Text.Encoding]::ASCII.GetBytes($S)
        $l = New-Object System.Collections.Generic.List[byte]
        foreach($x in $b){ [void]$l.Add($x) }
        [void]$l.Add(0x00)
        return $l.ToArray()
    }
    $mk = Get-TiffAsciiValue $Make
    $md = Get-TiffAsciiValue $Model
    $dt = Get-TiffAsciiValue $DateTimeOriginal      # 19 chars + NUL = 20
    $ifd0Off = 8
    $exifIfdOff = $ifd0Off + 42                     # IFD0: count(2)+3 entries(36)+next(4)
    $makeOff  = $exifIfdOff + 22                    # Exif IFD: count(2)+1 entry(12)+next(4)
    $modelOff = $makeOff + $mk.Count
    $dtOff    = $modelOff + $md.Count
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([byte[]]@(0x49,0x49,0x2A,0x00)); $bw.Write([uint32]$ifd0Off)
    $bw.Write([uint16]3)
    $bw.Write([uint16]0x010F); $bw.Write([uint16]2); $bw.Write([uint32]$mk.Count); $bw.Write([uint32]$makeOff)
    $bw.Write([uint16]0x0110); $bw.Write([uint16]2); $bw.Write([uint32]$md.Count); $bw.Write([uint32]$modelOff)
    $bw.Write([uint16]0x8769); $bw.Write([uint16]4); $bw.Write([uint32]1);         $bw.Write([uint32]$exifIfdOff)
    $bw.Write([uint32]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]0x9003); $bw.Write([uint16]2); $bw.Write([uint32]$dt.Count); $bw.Write([uint32]$dtOff)
    $bw.Write([uint32]0)
    foreach($b in $mk){ $bw.Write([byte]$b) }
    foreach($b in $md){ $bw.Write([byte]$b) }
    foreach($b in $dt){ $bw.Write([byte]$b) }
    $bw.Flush()
    $tiff = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    $payload = New-Object System.Collections.Generic.List[byte]
    foreach($b in [System.Text.Encoding]::ASCII.GetBytes('Exif')){ [void]$payload.Add($b) }
    [void]$payload.Add(0x00); [void]$payload.Add(0x00)
    foreach($b in $tiff){ [void]$payload.Add($b) }
    $app1Len = $payload.Count + 2
    $out = New-Object System.Collections.Generic.List[byte]
    foreach($b in [byte[]]@(0xFF,0xD8,0xFF,0xE1)){ [void]$out.Add($b) }
    [void]$out.Add([byte](($app1Len -shr 8) -band 0xFF)); [void]$out.Add([byte]($app1Len -band 0xFF))
    foreach($b in $payload){ [void]$out.Add($b) }
    foreach($b in [byte[]]@(0xFF,0xD9)){ [void]$out.Add($b) }
    return $out.ToArray()
}

function New-Id3Bytes {
<#
.SYNOPSIS
    Minimal ID3v2.3 tag (TIT2/TPE1/TALB/TYER) + one MPEG frame header + filler.
#>
    param([string]$Artist,[string]$Album,[string]$Title,[string]$Year)
    function Get-Id3Frame { param([string]$Id,[string]$Text)
        $body = [byte[]](0x00) + [System.Text.Encoding]::ASCII.GetBytes(($Text -replace '[^\x20-\x7E]','_'))
        $size = $body.Count
        $out = New-Object System.Collections.Generic.List[byte]
        foreach($c in [System.Text.Encoding]::ASCII.GetBytes($Id)){ [void]$out.Add($c) }
        [void]$out.Add([byte](($size -shr 24) -band 0xFF)); [void]$out.Add([byte](($size -shr 16) -band 0xFF))
        [void]$out.Add([byte](($size -shr 8) -band 0xFF));  [void]$out.Add([byte]($size -band 0xFF))
        [void]$out.Add(0x00); [void]$out.Add(0x00)
        foreach($b in $body){ [void]$out.Add($b) }
        return $out.ToArray()
    }
    $frames = @()
    $frames += Get-Id3Frame 'TIT2' $Title
    $frames += Get-Id3Frame 'TPE1' $Artist
    $frames += Get-Id3Frame 'TALB' $Album
    $frames += Get-Id3Frame 'TYER' $Year
    $tagSize = 0
    foreach($f in $frames){ $tagSize += $f.Count }
    $out = New-Object System.Collections.Generic.List[byte]
    foreach($b in [byte[]]@(0x49,0x44,0x33,0x03,0x00,0x00)){ [void]$out.Add($b) }   # 'ID3', v2.3, no flags
    [void]$out.Add([byte](($tagSize -shr 21) -band 0x7F)); [void]$out.Add([byte](($tagSize -shr 14) -band 0x7F))
    [void]$out.Add([byte](($tagSize -shr 7) -band 0x7F));  [void]$out.Add([byte]($tagSize -band 0x7F))
    foreach($f in $frames){ foreach($b in $f){ [void]$out.Add($b) } }
    foreach($b in [byte[]]@(0xFF,0xFB,0x90,0x00)){ [void]$out.Add($b) }             # MPEG frame header
    foreach($b in (Get-RandomBytes 512 -FillerSeed ($Seed + $tagSize))){ [void]$out.Add($b) }
    return $out.ToArray()
}

function New-Mp4MvhdBytes {
<#
.SYNOPSIS
    Minimal MP4: ftyp + moov/mvhd (version 0, creation time seconds since 1904 UTC) + mdat.
#>
    param([datetime]$CreationUtc)
    function ConvertTo-Be4 { param([uint32]$V)
        return [byte[]]@((($V -shr 24) -band 0xFF),(($V -shr 16) -band 0xFF),(($V -shr 8) -band 0xFF),($V -band 0xFF))
    }
    $epoch = [datetime]'1904-01-01T00:00:00Z'
    $secs = [uint32][Math]::Floor((($CreationUtc.ToUniversalTime() - $epoch).TotalSeconds))
    $mvhd = New-Object System.Collections.Generic.List[byte]
    foreach($b in [byte[]]@(0x00,0x00,0x00,0x00)){ [void]$mvhd.Add($b) }   # version 0 + flags
    foreach($b in (ConvertTo-Be4 $secs)){ [void]$mvhd.Add($b) }            # creation
    foreach($b in (ConvertTo-Be4 $secs)){ [void]$mvhd.Add($b) }            # modification
    foreach($b in (ConvertTo-Be4 ([uint32]1000))){ [void]$mvhd.Add($b) }   # timescale
    foreach($b in (ConvertTo-Be4 ([uint32]60000))){ [void]$mvhd.Add($b) }  # duration
    foreach($b in [byte[]]@(0x00,0x01,0x00,0x00)){ [void]$mvhd.Add($b) }   # rate 1.0
    foreach($b in [byte[]]@(0x01,0x00,0x00,0x00,0x00,0x00)){ [void]$mvhd.Add($b) }  # volume+reserved
    foreach($b in (New-Object byte[] 44)){ [void]$mvhd.Add($b) }           # reserved/pre_defined block
    foreach($b in (ConvertTo-Be4 ([uint32]2))){ [void]$mvhd.Add($b) }      # next_track_ID
    function Add-Box { param([System.Collections.Generic.List[byte]]$Out,[string]$Type,[byte[]]$Payload)
        $size = 8 + $Payload.Count
        foreach($b in (ConvertTo-Be4 ([uint32]$size))){ [void]$Out.Add($b) }
        foreach($b in [System.Text.Encoding]::ASCII.GetBytes($Type)){ [void]$Out.Add($b) }
        foreach($b in $Payload){ [void]$Out.Add($b) }
    }
    $moov = New-Object System.Collections.Generic.List[byte]
    foreach($b in [byte[]]@(0x00,0x00,0x00,0x00)){ [void]$moov.Add($b) }
    foreach($b in [System.Text.Encoding]::ASCII.GetBytes('mvhd')){ [void]$moov.Add($b) }
    foreach($b in $mvhd){ [void]$moov.Add($b) }
    $moovPayload = $moov.ToArray()
    $out = New-Object System.Collections.Generic.List[byte]
    Add-Box -Out $out -Type 'ftyp' -Payload ([byte[]]@(0x00,0x00,0x00,0x00) + [System.Text.Encoding]::ASCII.GetBytes('isom') + [byte[]]@(0x00,0x00,0x02,0x00) + [System.Text.Encoding]::ASCII.GetBytes('isomiso2'))
    Add-Box -Out $out -Type 'moov' -Payload $moovPayload
    Add-Box -Out $out -Type 'mdat' -Payload (Get-RandomBytes 2048 -FillerSeed $Seed)
    return $out.ToArray()
}

function New-PdfInfoBytes {
<#
.SYNOPSIS
    Minimal one-page PDF with an info dictionary (Title/Author/CreationDate).
#>
    param([string]$Title,[string]$Author,[string]$CreationDate)
    $nl = "`n"
    $txt = '%PDF-1.4' + $nl
    $txt += '1 0 obj' + $nl + '<< /Type /Catalog /Pages 2 0 R >>' + $nl + 'endobj' + $nl
    $txt += '2 0 obj' + $nl + '<< /Type /Pages /Kids [3 0 R] /Count 1 >>' + $nl + 'endobj' + $nl
    $txt += '3 0 obj' + $nl + '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>' + $nl + 'endobj' + $nl
    $txt += ('4 0 obj' + $nl + '<< /Title (' + ($Title -replace '[\(\)\\]',' ') + ') /Author (' + ($Author -replace '[\(\)\\]',' ') + ') /CreationDate (D:' + $CreationDate + ') >>' + $nl + 'endobj' + $nl)
    $txt += 'trailer' + $nl + '<< /Root 1 0 R /Info 4 0 R /Size 5 >>' + $nl + '%EOF'
    return [System.Text.Encoding]::ASCII.GetBytes($txt)
}

# --- corpus layout ------------------------------------------------------------
$u = Join-Path $Root 'Users\Alice'
$projSrc = Join-Path $Root 'Users\Alice\Projects\my-app\src'
$dirs = @(
    (Join-Path $u 'Documents'), (Join-Path $u 'Documents\Old'),
    (Join-Path $u 'Downloads'), (Join-Path $u 'Pictures'), (Join-Path $u 'Pictures\DCIM\100CANON'),
    (Join-Path $u 'Videos'), (Join-Path $u 'Music'), (Join-Path $u 'Desktop'),
    (Join-Path $u 'Backup'), $projSrc, (Join-Path $u 'Mixed')
)
foreach($d in $dirs){ if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$pkg = Join-Path (Split-Path -Parent $projSrc) 'package.json'
if(-not (Test-Path -LiteralPath $pkg)){ Set-Content -LiteralPath $pkg -Value '{"name":"my-app"}' -Encoding ASCII }

[void]$script:CorpusManifest.Add('RelPath,Kind,Stem,Artist,Album,Title,Year,ExifDate,Make,Model,PdfTitle,PdfAuthor,PdfCreated,MimeType,MvhdCreatedUtc')

function Add-CorpusFile {
    # Writes one file, records it in the manifest, registers it per kind for the
    # duplicate pass. Serial numbering makes every name collision-free.
    param([string]$Folder,[string]$Name,[byte[]]$Bytes,[string]$Kind,[hashtable]$Meta,[bool]$DupCandidate)
    $p = Join-Path $Folder $Name
    [System.IO.File]::WriteAllBytes($p, $Bytes)
    $script:CorpusUniqueWritten++
    $rel = $p.Substring($script:CorpusRoot.Length).TrimStart('\','/')
    $m = $Meta
    if(-not $m){ $m = @{} }
    [void]$script:CorpusManifest.Add(('"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}","{8}","{9}","{10}","{11}","{12}","{13}","{14}"' -f `
        $rel, $Kind, [System.IO.Path]::GetFileNameWithoutExtension($Name),
        "$($m['Artist'])", "$($m['Album'])", "$($m['Title'])", "$($m['Year'])", "$($m['ExifDate'])",
        "$($m['Make'])", "$($m['Model'])", "$($m['PdfTitle'])", "$($m['PdfAuthor'])", "$($m['PdfCreated'])", "$($m['MimeType'])", "$($m['MvhdCreatedUtc'])"))
    if($DupCandidate){
        $regKind = $Kind
        if(-not $script:CorpusByKind.ContainsKey($regKind)){ $script:CorpusByKind[$regKind] = New-Object System.Collections.Generic.List[string] }
        [void]$script:CorpusByKind[$regKind].Add($p)
    }
}

Write-Host ("Generating {0} unique files (seed {1}) into {2} ..." -f $FileCount, $Seed, $Root)

$y = $years[(Get-RandomInt $years.Count)]
$month = (Get-RandomInt 12) + 1
$day = (Get-RandomInt 28) + 1
$camDate = '{0:D4}{1:D2}{2:D2}' -f $y, $month, $day

for($i = 0; $i -lt $FileCount; $i++){
    $kind = Get-CorpusKind
    # A per-file serial keeps every generated name unique across the whole run
    # (realistic corpora carry serial numbers; collisions would silently drop files).
    $serial = $i + 1
    $n1 = (Get-RandomInt 9000) + 1000
    switch($kind){
        'Document' {
            $stem = '{0} {1} {2}' -f (Get-Pick $subjects), (Get-Pick $topics), ('{0:D6}' -f $serial)
            $folder = Get-Pick @((Join-Path $u 'Documents'), (Join-Path $u 'Documents\Old'), (Join-Path $u 'Desktop'))
            $body = ('{0} {1} {2} {3} reference {4}. Account {5}. Issued by {6} {7}.' -f `
                (Get-Pick $subjects), (Get-Pick $topics), $n1, (Get-Pick $cities), $y, (Get-RandomInt 999999), (Get-Pick $orgs), (Get-Pick $cities))
            Add-CorpusFile -Folder $folder -Name ($stem + '.txt') -Bytes ([System.Text.Encoding]::UTF8.GetBytes($body)) -Kind $Kind -Meta @{} -DupCandidate:$false
        }
        'Finance' {
            $n = Get-RandomInt 500
            $stem = '{0} {1} {2}-{3}' -f (Get-Pick @('Invoice','Receipt','Statement')), (Get-Pick $orgs), $y, ('{0:D6}' -f $serial)
            $body = ('{0} for {1}. Amount KES {2}. PIN P0{3}XXXXXXX. Payment due {4}-12-01.' -f `
                $stem, (Get-Pick $topics), ((Get-RandomInt 90000) + 1000), (Get-RandomInt 9), $y)
            Add-CorpusFile -Folder (Join-Path $u 'Documents') -Name ($stem + '.txt') -Bytes ([System.Text.Encoding]::UTF8.GetBytes($body)) -Kind $Kind -Meta @{} -DupCandidate:$false
        }
        'Spreadsheet' {
            $stem = '{0}-{1}-data' -f ((Get-Pick $subjects).ToLower()), ('{0:D6}' -f $serial)
            $lines = New-Object System.Collections.Generic.List[string]
            [void]$lines.Add('date,item,amount,ref')
            for($r = 0; $r -lt 40; $r++){ [void]$lines.Add(('2024-0{0}-1{1},item {2},{3},R{4}' -f ((Get-RandomInt 8)+1), (Get-RandomInt 9), $r, (Get-RandomInt 5000), (Get-RandomInt 99999))) }
            Add-CorpusFile -Folder (Join-Path $u 'Documents') -Name ($stem + '.csv') -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))) -Kind $Kind -Meta @{} -DupCandidate:$false
        }
        'PhotoExif' {
            $camDate = '{0:D4}{1:D2}{2:D2}' -f $years[(Get-RandomInt $years.Count)], ((Get-RandomInt 12)+1), ((Get-RandomInt 28)+1)
            $dtOrig = '{0}:{1}:{2} {3:D2}:{4:D2}:{5:D2}' -f $camDate.Substring(0,4), $camDate.Substring(4,2), $camDate.Substring(6,2), (Get-RandomInt 24), (Get-RandomInt 60), (Get-RandomInt 60)
            $meta = @{ ExifDate=$dtOrig; Make=(Get-Pick @('Canon','Nikon','Apple','Samsung')); Model=(Get-Pick @('EOS 90D','D7500','iPhone 13','SM-G991B')); MimeType='image/jpeg' }
            $bytes = New-ExifJpegBytes -Make $meta.Make -Model $meta.Model -DateTimeOriginal $dtOrig
            $bytes = $bytes + (Get-RandomBytes ((Get-RandomInt 40) * 1KB + 8192) -FillerSeed ($Seed + $i))
            Add-CorpusFile -Folder (Get-Pick @((Join-Path $u 'Pictures'), (Join-Path $u 'Pictures\DCIM\100CANON'), (Join-Path $u 'Downloads'))) -Name ('IMG_{0}_{1}.jpg' -f $camDate, ('{0:D6}' -f $serial)) -Bytes $bytes -Kind $Kind -Meta $meta -DupCandidate:$true
        }
        'PhotoPlain' {
            $bytes = [byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A) + (Get-RandomBytes ((Get-RandomInt 30) * 1KB + 4096) -FillerSeed ($Seed + $i))
            Add-CorpusFile -Folder (Join-Path $u 'Pictures') -Name ('photo-{0}.png' -f ('{0:D8}' -f $serial)) -Bytes $bytes -Kind $Kind -Meta @{} -DupCandidate:$true
        }
        'Screenshot' {
            $bytes = [byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A) + (Get-RandomBytes ((Get-RandomInt 20) * 1KB + 4096) -FillerSeed ($Seed + $i))
            $name = 'Screenshot_{0}-{1:D2}-{2:D2}_{3:D6}.png' -f $y, $month, $day, $serial
            Add-CorpusFile -Folder (Get-Pick @((Join-Path $u 'Pictures'), (Join-Path $u 'Desktop'), (Join-Path $u 'Downloads'))) -Name $name -Bytes $bytes -Kind $Kind -Meta @{} -DupCandidate:$false
        }
        'WhatsApp' {
            $bytes = [byte[]]@(0xFF,0xD8,0xFF,0xE0) + (Get-RandomBytes ((Get-RandomInt 25) * 1KB + 4096) -FillerSeed ($Seed + $i))
            $name = 'WhatsApp Image {0}-{1:D2}-{2:D2} at {3:D6}.jpg' -f $y, $month, $day, $serial
            Add-CorpusFile -Folder (Join-Path $u 'Downloads') -Name $name -Bytes $bytes -Kind $Kind -Meta @{ MimeType='image/jpeg' } -DupCandidate:$false
        }
        'VideoMp4' {
            $created = [datetime]::SpecifyKind([datetime]::new($y, $month, $day, (Get-RandomInt 24), (Get-RandomInt 60), 0), 'Utc')
            $bytes = (New-Mp4MvhdBytes -CreationUtc $created) + (Get-RandomBytes ((Get-RandomInt 80) * 1KB + 16384) -FillerSeed ($Seed + $i))
            Add-CorpusFile -Folder (Get-Pick @((Join-Path $u 'Videos'), (Join-Path $u 'Downloads'))) -Name ('VID_{0}_{1}.mp4' -f $camDate, ('{0:D6}' -f $serial)) -Bytes $bytes -Kind $Kind -Meta @{ MvhdCreatedUtc=$created.ToString('o'); MimeType='video/mp4' } -DupCandidate:$true
        }
        'MusicMp3' {
            $artist = (Get-Pick $artists); $album = (Get-Pick $albums); $title = ('Track {0:D6}' -f $serial)
            $yy = $years[(Get-RandomInt $years.Count)]
            $bytes = New-Id3Bytes -Artist $artist -Album $album -Title $title -Year ([string]$yy)
            Add-CorpusFile -Folder (Join-Path $u 'Music') -Name ('{0} - {1} - {2}.mp3' -f $artist, $album, $title) -Bytes $bytes -Kind $Kind -Meta @{ Artist=$artist; Album=$album; Title=$title; Year=$yy; MimeType='audio/mpeg' } -DupCandidate:$false
        }
        'VoiceNote' {
            $bytes = [byte[]]@(0xFF,0xFB,0x90,0x00) + (Get-RandomBytes ((Get-RandomInt 15) * 1KB + 4096) -FillerSeed ($Seed + $i))
            $name = 'VOICE_{0:D4}-{1:D2}-{2:D2}-WA{3:D6}.m4a' -f $y, $month, $day, $serial
            Add-CorpusFile -Folder (Join-Path $u 'Downloads') -Name $name -Bytes $bytes -Kind $Kind -Meta @{} -DupCandidate:$false
        }
        'Installer' {
            $bytes = [byte[]]@(0x4D,0x5A,0x90,0x00) + (Get-RandomBytes ((Get-RandomInt 60) * 1KB + 32768) -FillerSeed ($Seed + $i))
            Add-CorpusFile -Folder (Join-Path $u 'Downloads') -Name ('setup-{0}-{1:D6}.exe' -f (Get-Pick $apps), $serial) -Bytes $bytes -Kind $Kind -Meta @{} -DupCandidate:$false
        }
        'Archive' {
            $bytes = [byte[]]@(0x50,0x4B,0x03,0x04) + (Get-RandomBytes ((Get-RandomInt 50) * 1KB + 32768) -FillerSeed ($Seed + $i))
            Add-CorpusFile -Folder (Get-Pick @((Join-Path $u 'Downloads'), (Join-Path $u 'Mixed'))) -Name ('{0}-{1:D6}-bundle.zip' -f (Get-Pick $apps), $serial) -Bytes $bytes -Kind $Kind -Meta @{} -DupCandidate:$true
        }
        'Code' {
            $stem = '{0}-{1:D5}' -f (Get-Pick $apps), $serial
            $body = ('function {0}() {{ return {1}; }}' -f $stem, $n1)
            $ext = Get-Pick @('.js','.py','.ts','.json')
            $folder = if($ext -eq '.json'){ (Join-Path $u 'Documents') } else { $projSrc }
            Add-CorpusFile -Folder $folder -Name ($stem + $ext) -Bytes ([System.Text.Encoding]::UTF8.GetBytes($body)) -Kind $Kind -Meta @{} -DupCandidate:$false
        }
        'PdfInfo' {
            $title = '{0} {1} {2}' -f (Get-Pick $subjects), (Get-Pick $topics), ('{0:D6}' -f $serial)
            $author = (Get-Pick $people)
            $created = '{0:D4}{1:D2}{2:D2}{3:D2}{4:D2}{5:D2}' -f $y, $month, $day, (Get-RandomInt 24), (Get-RandomInt 60), (Get-RandomInt 60)
            $bytes = New-PdfInfoBytes -Title $title -Author $author -CreationDate $created
            Add-CorpusFile -Folder (Get-Pick @((Join-Path $u 'Documents'), (Join-Path $u 'Downloads'), (Join-Path $u 'Desktop'))) -Name ($title + '.pdf') -Bytes $bytes -Kind $Kind -Meta @{ PdfTitle=$title; PdfAuthor=$author; PdfCreated=$created; MimeType='application/pdf' } -DupCandidate:$true
        }
    }
    if(($i % 2000) -eq 0 -and $i -gt 0){ Write-Host ("  {0} / {1}" -f $i, $FileCount) }
}

# --- duplicates: exact byte copies of eligible kinds ----------------------------
# Dup sources are files of binary types (PhotoExif/PhotoPlain/VideoMp4/Archive/PdfInfo).
# A source below DupMinKB is padded with appended filler (harmless for every fixture
# type: parsers stop at the structure they need) so duplicates actually cross the
# Copies.MinFileSizeKB threshold the duplicate pipeline uses.
$dupCount = [int][Math]::Ceiling($FileCount * ($DuplicatesPercent / 100.0))
$dupKinds = @('PhotoExif','PhotoPlain','VideoMp4','Archive','PdfInfo')
$dupPool = New-Object System.Collections.Generic.List[string]
foreach($k in $dupKinds){ if($script:CorpusByKind.ContainsKey($k)){ foreach($p in $script:CorpusByKind[$k]){ [void]$dupPool.Add($p) } } }
if($dupPool.Count -gt 0 -and $dupCount -gt 0){
    Write-Host ("Adding {0} exact duplicates ({1}% of {2}; sources padded to >= {3} KB where needed) ..." -f $dupCount, $DuplicatesPercent, $FileCount, $DupMinKb)
    for($d = 0; $d -lt $dupCount; $d++){
        $src = $dupPool[(Get-RandomInt $dupPool.Count)]
        $srcLen = (Get-Item -LiteralPath $src).Length
        $minBytes = $script:CorpusDupMinKb * 1KB
        if($srcLen -lt $minBytes){
            # append deterministic filler so the duplicate pipeline actually hashes it
            $fs = [System.IO.File]::Open($src, 'Append', 'Write', 'Read')
            try { $pad = Get-RandomBytes ([int]($minBytes - $srcLen)) -FillerSeed ($Seed + 777 + $d); $fs.Write($pad, 0, $pad.Count) } finally { $fs.Dispose() }
        }
        $srcBytes = [System.IO.File]::ReadAllBytes($src)
        $leaf = Split-Path $src -Leaf
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        $ext = [System.IO.Path]::GetExtension($leaf)
        $copiesMade = 0
        if($script:CorpusDupCopies.ContainsKey($src)){ $copiesMade = [int]$script:CorpusDupCopies[$src] }
        $script:CorpusDupCopies[$src] = $copiesMade + 1
        $copyName = if($copiesMade -eq 0){ '{0} - Copy{1}' -f $stem, $ext } else { '{0} - Copy ({1}){2}' -f $stem, ($copiesMade + 1), $ext }
        $destFolder = Get-Pick @((Join-Path $u 'Backup'), (Join-Path $u 'Mixed'), (Split-Path $src -Parent))
        $p = Join-Path $destFolder $copyName
        [System.IO.File]::WriteAllBytes($p, $srcBytes)
        $script:CorpusDupWritten++
        $rel = $p.Substring($script:CorpusRoot.Length).TrimStart('\','/')
        [void]$script:CorpusManifest.Add(('"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}","{8}","{9}","{10}","{11}","{12}","{13}","{14}"' -f `
            $rel, ('DuplicateOf:' + (Split-Path $src -Leaf)), $stem, '', '', '', '', '', '', '', '', '', '', '', ''))
    }
}

if(-not $NoManifest){
    $manifestPath = Join-Path $Root 'manifest.csv'
    [System.IO.File]::WriteAllLines($manifestPath, $script:CorpusManifest)
    Write-Host ("Manifest written: {0}" -f $manifestPath)
}
$stats = Get-ChildItem -LiteralPath $Root -Recurse -File | Measure-Object -Property Length -Sum
Write-Host ("Corpus ready: {0} files on disk, {1:N1} MB, root {2}" -f $stats.Count, ($stats.Sum/1MB), $Root)
Write-Host ("  unique written: {0}   duplicate copies: {1}" -f $script:CorpusUniqueWritten, $script:CorpusDupWritten)
