# Tests/SysOrg.Metadata.Tests.ps1
# Covers v3.0 Phase 2.4 + 2.5: the metadata extractors (EXIF/ID3/MP4/Office/PDF/
# text - zero-dependency, mockable, fail-soft) and the date resolution priority.
#
# The real fixtures come from Tools/New-SysOrgCorpus.ps1 (the corpus generator
# writes actual EXIF JPEGs, ID3 MP3s, MP4 mvhd boxes and PDF info dictionaries).

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1') -Force
}

Describe 'EXIF extractor (minimal TIFF/EXIF parser)' {

    It 'reads DateTimeOriginal, Make and Model from a real corpus fixture' {
        $root = Join-Path $TestDrive ('exif-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & (Join-Path $repo 'Tools\New-SysOrgCorpus.ps1') -Root $root -FileCount 60 -Seed 31 -Clean -NoManifest | Out-Null
        $jpg = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.jpg' | Select-Object -First 1
        $jpg | Should -Not -BeNullOrEmpty
        $m = Get-SysOrgExifMetadata -Path $jpg.FullName
        $m | Should -Not -BeNullOrEmpty
        $m.Source | Should -Be 'exif'
        $m.DateTimeOriginal | Should -Match '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$'
        $m.Make | Should -Not -BeNullOrEmpty
    }

    It 'fails soft on truncated, zero-byte and non-EXIF files' {
        $zero = Join-Path $TestDrive 'zero.jpg'
        [System.IO.File]::WriteAllBytes($zero, [byte[]]@())
        Get-SysOrgExifMetadata -Path $zero | Should -BeNullOrEmpty
        $trunc = Join-Path $TestDrive 'trunc.jpg'
        [System.IO.File]::WriteAllBytes($trunc, [byte[]]@(0xFF,0xD8,0xFF,0xE1,0x00,0x40))
        Get-SysOrgExifMetadata -Path $trunc | Should -BeNullOrEmpty
        $plain = Join-Path $TestDrive 'plain.jpg'
        [System.IO.File]::WriteAllText($plain, 'just text, not a jpeg at all really')
        Get-SysOrgExifMetadata -Path $plain | Should -BeNullOrEmpty
        { Get-SysOrgExifMetadata -Path (Join-Path $TestDrive 'missing.jpg') } | Should -Not -Throw
    }
}

Describe 'ID3 extractor (v2.3 + v1 fallback)' {

    It 'reads artist/album/title/year from a real corpus MP3' {
        $root = Join-Path $TestDrive ('id3-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & (Join-Path $repo 'Tools\New-SysOrgCorpus.ps1') -Root $root -FileCount 60 -Seed 33 -Clean -NoManifest | Out-Null
        $mp3 = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.mp3' | Select-Object -First 1
        $mp3 | Should -Not -BeNullOrEmpty
        $m = Get-SysOrgId3Metadata -Path $mp3.FullName
        $m | Should -Not -BeNullOrEmpty
        $m.Source | Should -Be 'id3'
        $m.Artist | Should -Not -BeNullOrEmpty
        $m.Album | Should -Not -BeNullOrEmpty
        $m.Year | Should -Match '^(19|20)\d{2}$'
    }

    It 'reads ID3v1 fallback tags' {
        $p = Join-Path $TestDrive 'v1.mp3'
        # a real ID3v1 tag is exactly 128 bytes: TAG + 30+30+30 + 4 + 30 comment + genre
        $payload = New-Object byte[] 100
        $tagStr = 'TAG' + 'V1 Title'.PadRight(30) + 'V1 Artist'.PadRight(30) + 'V1 Album'.PadRight(30) + '2019' + (''.PadRight(30)) + [char]0xFF
        $tag = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($tagStr)
        $tag.Count | Should -Be 128
        [System.IO.File]::WriteAllBytes($p, ($payload + $tag))
        $m = Get-SysOrgId3Metadata -Path $p
        $m | Should -Not -BeNullOrEmpty
        $m.Artist | Should -Be 'V1 Artist'
        $m.Title | Should -Be 'V1 Title'
        $m.Year | Should -Be '2019'
    }

    It 'fails soft on garbage, truncation and zero bytes' {
        $zero = Join-Path $TestDrive 'zero.mp3'
        [System.IO.File]::WriteAllBytes($zero, [byte[]]@())
        Get-SysOrgId3Metadata -Path $zero | Should -BeNullOrEmpty
        $bad = Join-Path $TestDrive 'bad.mp3'
        [System.IO.File]::WriteAllBytes($bad, [byte[]]@(0x49,0x44,0x33,0x03,0x00,0x00,0x7F,0x7F,0x7F,0x7F))   # huge claimed size
        Get-SysOrgId3Metadata -Path $bad | Should -BeNullOrEmpty
        { Get-SysOrgId3Metadata -Path (Join-Path $TestDrive 'missing.mp3') } | Should -Not -Throw
    }
}

Describe 'MP4 mvhd extractor' {

    It 'reads the creation time from a real corpus MP4' {
        $root = Join-Path $TestDrive ('mp4-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & (Join-Path $repo 'Tools\New-SysOrgCorpus.ps1') -Root $root -FileCount 80 -Seed 37 -Clean -NoManifest | Out-Null
        $mp4 = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.mp4' | Select-Object -First 1
        $mp4 | Should -Not -BeNullOrEmpty
        $m = Get-SysOrgMp4Metadata -Path $mp4.FullName
        $m | Should -Not -BeNullOrEmpty
        $m.Source | Should -Be 'mp4'
        $m.CreatedUtc.Year | Should -BeGreaterOrEqual 2020
    }

    It 'fails soft on truncated and foreign bytes' {
        $trunc = Join-Path $TestDrive 'trunc.mp4'
        [System.IO.File]::WriteAllBytes($trunc, [byte[]]@(0x00,0x00,0x00,0x08,0x6D,0x6F,0x6F,0x76))   # moov box with no payload
        Get-SysOrgMp4Metadata -Path $trunc | Should -BeNullOrEmpty
        $bad = Join-Path $TestDrive 'bad.mp4'
        [System.IO.File]::WriteAllText($bad, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
        Get-SysOrgMp4Metadata -Path $bad | Should -BeNullOrEmpty
        { Get-SysOrgMp4Metadata -Path (Join-Path $TestDrive 'missing.mp4') } | Should -Not -Throw
    }
}

Describe 'Office core.xml extractor' {

    It 'reads title/creator/created from an OPC zip' {
        $p = Join-Path $TestDrive 'report.docx'
        $core = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"><dc:title>Tax Return 2024</dc:title><dc:creator>Wanjiku</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">2024-03-15T09:30:00Z</dcterms:created></cp:coreProperties>'
        $zipPath = Join-Path $TestDrive 'report.docx.zip'
        $fs = [System.IO.File]::Create($zipPath)
        $arch = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        $entry = $arch.CreateEntry('docProps/core.xml')
        $sw = New-Object System.IO.StreamWriter($entry.Open())
        $sw.Write($core); $sw.Dispose()
        $arch.Dispose(); $fs.Dispose()
        Move-Item -LiteralPath $zipPath -Destination $p -Force
        $m = Get-SysOrgOfficeMetadata -Path $p
        $m | Should -Not -BeNullOrEmpty
        $m.Source | Should -Be 'office'
        $m.Title | Should -Be 'Tax Return 2024'
        $m.Creator | Should -Be 'Wanjiku'
        $m.Created | Should -Be '2024-03-15T09:30:00Z'
    }

    It 'fails soft on non-zip and missing-entry files' {
        $bad = Join-Path $TestDrive 'bad.docx'
        [System.IO.File]::WriteAllText($bad, 'definitely not a zip archive')
        Get-SysOrgOfficeMetadata -Path $bad | Should -BeNullOrEmpty
        $noEntry = Join-Path $TestDrive 'noentry.docx'
        $fs2 = [System.IO.File]::Create($noEntry)
        $arch2 = New-Object System.IO.Compression.ZipArchive($fs2, [System.IO.Compression.ZipArchiveMode]::Create)
        $arch2.Dispose(); $fs2.Dispose()
        Get-SysOrgOfficeMetadata -Path $noEntry | Should -BeNullOrEmpty
        { Get-SysOrgOfficeMetadata -Path (Join-Path $TestDrive 'missing.docx') } | Should -Not -Throw
    }
}

Describe 'PDF info dictionary extractor' {

    It 'reads Title/Author/CreationDate from a real corpus PDF' {
        $root = Join-Path $TestDrive ('pdf-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & (Join-Path $repo 'Tools\New-SysOrgCorpus.ps1') -Root $root -FileCount 80 -Seed 41 -Clean -NoManifest | Out-Null
        $pdf = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.pdf' | Select-Object -First 1
        $pdf | Should -Not -BeNullOrEmpty
        $m = Get-SysOrgPdfMetadata -Path $pdf.FullName
        $m | Should -Not -BeNullOrEmpty
        $m.Source | Should -Be 'pdf'
        $m.Title | Should -Not -BeNullOrEmpty
        $m.Author | Should -Not -BeNullOrEmpty
        $m.Created | Should -Match '^\d{4}-\d{2}-\d{2}'
    }

    It 'fails soft on non-PDF and zero-byte files' {
        $bad = Join-Path $TestDrive 'bad.pdf'
        [System.IO.File]::WriteAllText($bad, 'not a pdf')
        Get-SysOrgPdfMetadata -Path $bad | Should -BeNullOrEmpty
        $zero = Join-Path $TestDrive 'zero.pdf'
        [System.IO.File]::WriteAllBytes($zero, [byte[]]@())
        Get-SysOrgPdfMetadata -Path $zero | Should -BeNullOrEmpty
        { Get-SysOrgPdfMetadata -Path (Join-Path $TestDrive 'missing.pdf') } | Should -Not -Throw
    }
}

Describe 'Text snippet extractor' {

    It 'returns a snippet and flags binary masquerades' {
        $txt = Join-Path $TestDrive 'notes.txt'
        Set-Content -LiteralPath $txt -Value ('invoice KRA PAYE ' * 100) -Encoding UTF8
        $m = Get-SysOrgTextSnippet -Path $txt
        $m.Binary | Should -BeFalse
        $m.Snippet | Should -Match 'invoice'
        $bin = Join-Path $TestDrive 'fake.txt'
        $bytes = New-Object byte[] 1024
        for($i=0; $i -lt 1024; $i++){ $bytes[$i] = (Get-Random -Maximum 255) }
        [System.IO.File]::WriteAllBytes($bin, $bytes)
        $m2 = Get-SysOrgTextSnippet -Path $bin
        $m2.Binary | Should -BeTrue
    }

    It 'fails soft on zero-byte and unreadable files' {
        $zero = Join-Path $TestDrive 'zero.txt'
        [System.IO.File]::WriteAllBytes($zero, [byte[]]@())
        Get-SysOrgTextSnippet -Path $zero | Should -BeNullOrEmpty
        { Get-SysOrgTextSnippet -Path (Join-Path $TestDrive 'missing.txt') } | Should -Not -Throw
    }
}

Describe 'Metadata orchestrator and mocking' {

    It 'picks the right extractor family by extension' {
        $p = Join-Path $TestDrive 'a.mp3'
        Set-Content -LiteralPath $p -Value 'garbage' -Encoding ASCII
        (Get-SysOrgFileMetadata -Path $p -Extension '.mp3') | Should -BeNullOrEmpty   # garbage ID3 -> fail soft
        $unknown = Join-Path $TestDrive 'b.xyz'
        Set-Content -LiteralPath $unknown -Value 'plain' -Encoding ASCII
        Get-SysOrgFileMetadata -Path $unknown -Extension '.xyz' | Should -BeNullOrEmpty
    }

    It 'mocked extractors replace the built-ins (the mockable interface)' {
        $p = Join-Path $TestDrive 'mock.jpg'
        Set-Content -LiteralPath $p -Value 'not really an image' -Encoding ASCII
        $mock = @{ exif = { param($Path) @{ Source='exif'; DateTimeOriginal='2024:05:06 07:08:09'; Make='MockCam'; Model='X1' } } }
        $m = Get-SysOrgFileMetadata -Path $p -Extension '.jpg' -Extractors $mock
        $m | Should -Not -BeNullOrEmpty
        $m.Make | Should -Be 'MockCam'
        $m.DateTimeOriginal | Should -Be '2024:05:06 07:08:09'
    }

    It 'a throwing mock fails soft to $null' {
        $p = Join-Path $TestDrive 'throw.jpg'
        Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
        $mock = @{ exif = { param($Path) throw 'boom' } }
        Get-SysOrgFileMetadata -Path $p -Extension '.jpg' -Extractors $mock | Should -BeNullOrEmpty
    }
}

Describe 'Date resolution (Phase 2.5)' {

    It 'prefers metadata dates over filename and filesystem dates' {
        $p = Join-Path $TestDrive 'IMG_20240101_101010.jpg'
        Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
        $meta = @{ Source='exif'; DateTimeOriginal='2023:07:15 12:30:00' }
        $r = Resolve-SysOrgFileDate -Path $p -Metadata $meta
        $r.Source | Should -Be 'exif'
        $r.Date.Year | Should -Be 2023
        $r.Date.Month | Should -Be 7
    }

    It 'falls back to an embedded filename date (IMG_20240101_101010)' {
        $p = Join-Path $TestDrive 'IMG_20240101_101010.jpg'
        Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
        $r = Resolve-SysOrgFileDate -Path $p
        $r.Source | Should -Be 'filename'
        $r.Date | Should -Be ([datetime]::new(2024,1,1,10,10,10))
        # Screenshot_2024-01-01_101010 style
        $p2 = Join-Path $TestDrive 'Screenshot_2024-02-03_040506.png'
        Set-Content -LiteralPath $p2 -Value 'x' -Encoding ASCII
        $r2 = Resolve-SysOrgFileDate -Path $p2
        $r2.Source | Should -Be 'filename'
        $r2.Date | Should -Be ([datetime]::new(2024,2,3,4,5,6))
    }

    It 'uses min(CreationTime, LastWriteTime) when nothing else is available' {
        $p = Join-Path $TestDrive 'no date here.xyz'
        Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
        $r = Resolve-SysOrgFileDate -Path $p
        $r.Source | Should -Be 'filesystem'
        $fi = Get-Item -LiteralPath $p
        $expected = $fi.CreationTime; if($fi.LastWriteTime -lt $expected){ $expected = $fi.LastWriteTime }
        ([Math]::Abs(($r.Date - $expected).TotalSeconds)) | Should -BeLessOrEqual 5
    }

    It 'ID3 year resolves to January 1st of that year' {
        $p = Join-Path $TestDrive 'song.mp3'
        Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
        $r = Resolve-SysOrgFileDate -Path $p -Metadata @{ Source='id3'; Year='2022' }
        $r.Source | Should -Be 'id3'
        $r.Date | Should -Be ([datetime]::new(2022,1,1))
    }

    It 'never throws, even on missing files' {
        { Resolve-SysOrgFileDate -Path (Join-Path $TestDrive 'missing.xyz') } | Should -Not -Throw
    }
}
