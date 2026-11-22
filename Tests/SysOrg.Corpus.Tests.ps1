# Tests/SysOrg.Corpus.Tests.ps1
# Covers v3.0 Phase 0.1: the synthetic corpus generator (Tools/New-SysOrgCorpus.ps1).
#   - determinism: identical parameters + seed produce byte-identical corpora
#   - real binary fixtures: EXIF JPEG, ID3 MP3, MP4 mvhd, PDF info dict
#   - duplicates: exact byte copies >= DupMinKB that the duplicate pipeline can find
#   - the manifest matches what is on disk

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1') -Force
    $script:gen = Join-Path $repo 'Tools\New-SysOrgCorpus.ps1'
}

Describe 'New-SysOrgCorpus determinism and fixtures' {

    It 'generates byte-identical corpora for identical parameters and seed' {
        $a = Join-Path $TestDrive ('corpus-a-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $b = Join-Path $TestDrive ('corpus-b-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $a -FileCount 120 -Seed 5 -Clean -NoManifest | Out-Null
        & $script:gen -Root $b -FileCount 120 -Seed 5 -Clean -NoManifest | Out-Null
        $fa = @(Get-ChildItem -LiteralPath $a -Recurse -File | ForEach-Object { $_.FullName.Substring($a.Length) } | Sort-Object)
        $fb = @(Get-ChildItem -LiteralPath $b -Recurse -File | ForEach-Object { $_.FullName.Substring($b.Length) } | Sort-Object)
        (@($fa) -join '|') | Should -Be (@($fb) -join '|')
        $diff = 0
        foreach($rel in $fa){
            $h1 = (Get-FileHash -LiteralPath (Join-Path $a $rel) -Algorithm MD5).Hash
            $h2 = (Get-FileHash -LiteralPath (Join-Path $b $rel) -Algorithm MD5).Hash
            if($h1 -ne $h2){ $diff++ }
        }
        $diff | Should -Be 0
    }

    It 'writes the expected number of unique files plus duplicate copies' {
        $root = Join-Path $TestDrive ('corpus-count-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $root -FileCount 150 -DuplicatesPercent 5 -Seed 9 -Clean -NoManifest | Out-Null
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
        # 150 unique + ~7.5 -> 8 duplicates + 1 package.json marker
        $files.Count | Should -BeGreaterOrEqual 158
        $files.Count | Should -BeLessOrEqual 160
    }

    It 'the manifest lists every generated file with its kind' {
        $root = Join-Path $TestDrive ('corpus-manifest-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $root -FileCount 60 -Seed 3 -Clean | Out-Null
        $manifest = @(Import-Csv (Join-Path $root 'manifest.csv'))
        # manifest rows = unique files + duplicate copies; every row must exist on disk
        @($manifest | Where-Object { $_.Kind -notlike 'DuplicateOf*' }).Count | Should -Be 60
        foreach($row in $manifest){
            Test-Path -LiteralPath (Join-Path $root $row.RelPath) | Should -BeTrue
            $row.Kind | Should -Not -BeNullOrEmpty
        }
        @($manifest | Where-Object { $_.Kind -like 'PhotoExif*' }).Count | Should -BeGreaterThan 0
        @($manifest | Where-Object { $_.Kind -eq 'MusicMp3' }).Count | Should -BeGreaterThan 0
    }

    It 'EXIF fixtures are real JPEGs with an APP1 Exif segment and parseable metadata' {
        $root = Join-Path $TestDrive ('corpus-exif-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $root -FileCount 80 -Seed 11 -Clean | Out-Null
        $m = @(Import-Csv (Join-Path $root 'manifest.csv')) | Where-Object { $_.Kind -eq 'PhotoExif' } | Select-Object -First 1
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $m.RelPath))
        $bytes[0] | Should -Be 0xFF
        $bytes[1] | Should -Be 0xD8
        $bytes[2] | Should -Be 0xFF
        $bytes[3] | Should -Be 0xE1
        $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(64, $bytes.Length))
        $head | Should -Match 'Exif'
        # the recorded DateTimeOriginal must appear in the TIFF payload
        $all = [System.Text.Encoding]::ASCII.GetString($bytes)
        $all | Should -Match ([regex]::Escape($m.ExifDate))
        $all | Should -Match ([regex]::Escape($m.Make))
    }

    It 'ID3 fixtures carry artist/album/title/year tags' {
        $root = Join-Path $TestDrive ('corpus-id3-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $root -FileCount 80 -Seed 13 -Clean | Out-Null
        $m = @(Import-Csv (Join-Path $root 'manifest.csv')) | Where-Object { $_.Kind -eq 'MusicMp3' } | Select-Object -First 1
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $m.RelPath))
        $bytes[0] | Should -Be 0x49   # 'I'
        $bytes[1] | Should -Be 0x44   # 'D'
        $bytes[2] | Should -Be 0x33   # '3'
        $all = [System.Text.Encoding]::ASCII.GetString($bytes)
        $all | Should -Match 'TIT2'
        $all | Should -Match 'TPE1'
        $all | Should -Match 'TALB'
        $all | Should -Match 'TYER'
        $all | Should -Match ([regex]::Escape($m.Artist))
        $all | Should -Match ([regex]::Escape($m.Album))
    }

    It 'MP4 fixtures contain ftyp/moov/mvhd boxes with a creation time' {
        $root = Join-Path $TestDrive ('corpus-mp4-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $root -FileCount 100 -Seed 17 -Clean | Out-Null
        $m = @(Import-Csv (Join-Path $root 'manifest.csv')) | Where-Object { $_.Kind -eq 'VideoMp4' } | Select-Object -First 1
        $m.MvhdCreatedUtc | Should -Not -BeNullOrEmpty
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $m.RelPath))
        $all = [System.Text.Encoding]::ASCII.GetString($bytes)
        $all | Should -Match 'ftyp'
        $all | Should -Match 'moov'
        $all | Should -Match 'mvhd'
    }

    It 'PDF fixtures carry a Title/Author/CreationDate info dictionary' {
        $root = Join-Path $TestDrive ('corpus-pdf-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $root -FileCount 100 -Seed 19 -Clean | Out-Null
        $m = @(Import-Csv (Join-Path $root 'manifest.csv')) | Where-Object { $_.Kind -eq 'PdfInfo' } | Select-Object -First 1
        $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes((Join-Path $root $m.RelPath)))
        $text | Should -Match '%PDF'
        $text | Should -Match '/Title'
        $text | Should -Match '/Author'
        $text | Should -Match ([regex]::Escape($m.PdfTitle))
        $text | Should -Match ([regex]::Escape($m.PdfAuthor))
    }

    It 'duplicate copies are exact byte copies of corpus files and cross the size floor' {
        $root = Join-Path $TestDrive ('corpus-dup-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        & $script:gen -Root $root -FileCount 150 -DuplicatesPercent 5 -Seed 23 -Clean -NoManifest | Out-Null
        # find pairs of files with identical SHA256 (the generated duplicate copies)
        $byHash = @{}
        foreach($f in (Get-ChildItem -LiteralPath $root -Recurse -File)){
            if($f.Length -lt 300KB){ continue }
            $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            if(-not $byHash.ContainsKey($h)){ $byHash[$h] = New-Object System.Collections.Generic.List[string] }
            [void]$byHash[$h].Add($f.FullName)
        }
        $groups = @($byHash.Keys | Where-Object { $byHash[$_].Count -ge 2 })
        $groups.Count | Should -BeGreaterThan 0
        foreach($h in $groups | Select-Object -First 3){
            $byHash[$h].Count | Should -BeGreaterOrEqual 2
        }
    }
}
