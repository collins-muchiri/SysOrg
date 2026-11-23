# Tests/SysOrg.Speed.Tests.ps1
# Covers v3.0 Phase 3: the persistent file-state cache (round trip, corruption
# fallback, invalidation on size/mtime change), the compiled exclusion matcher
# (identical semantics to the classic checker), the head+tail pre-filter hash,
# parallel hashing with deterministic order, and the in-memory destination name sets.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')  -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Cache.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')  -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')  -Force
}

Describe 'File-state cache (Phase 3.1)' {

    It 'round trips entries through ndjson and re-reads them without the files' {
        $p = Join-Path $TestDrive 'cache\filestate.ndjson'
        $entries = @{}
        $entries['c:\x\a.jpg|100|133000000000000000'] = [pscustomobject]@{ Hash='abc123'; HeaderHash='hh1'; HeadTailHash='ht1'; Meta=@{ Source='exif'; Make='Canon' } }
        $entries['c:\x\b.mp3|200|133000000000000111'] = [pscustomobject]@{ Hash='def456'; HeaderHash=''; HeadTailHash=''; Meta=$null }
        (Save-SysOrgFileStateCache -Path $p -Entries $entries) | Should -BeTrue
        $loaded = Read-SysOrgFileStateCache -Path $p
        $loaded.Corrupted | Should -BeFalse
        $loaded.Entries.Count | Should -Be 2
        $loaded.Entries['c:\x\a.jpg|100|133000000000000000'].Hash | Should -Be 'abc123'
        $loaded.Entries['c:\x\a.jpg|100|133000000000000000'].Meta.Make | Should -Be 'Canon'
    }

    It 'a changed size or mtime produces a different key (invalidation)' {
        $k1 = Get-SysOrgFileCacheKey -Path 'C:\x\a.txt' -Length 100 -LastWriteTimeUtc ([datetime]'2024-01-01Z')
        $k2 = Get-SysOrgFileCacheKey -Path 'C:\x\a.txt' -Length 101 -LastWriteTimeUtc ([datetime]'2024-01-01Z')
        $k3 = Get-SysOrgFileCacheKey -Path 'C:\x\a.txt' -Length 100 -LastWriteTimeUtc ([datetime]'2024-01-02Z')
        $k1 | Should -Not -Be $k2
        $k1 | Should -Not -Be $k3
        (Test-SysOrgCacheEntryFresh -Entry $null) | Should -BeFalse
    }

    It 'a corrupted cache degrades to a rescan (empty entries, no crash)' {
        $p = Join-Path $TestDrive 'cache2\filestate.ndjson'
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        # mostly garbage lines (>1/3 unreadable of >8 lines); valid lines use \\ escapes
        $lines = @()
        foreach($i in 1..12){
            if($i % 3 -eq 0){ $lines += ('{"k":"c:\\x\\f' + $i + '|1|1","h":"h' + $i + '","hh":"","ht":"","m":null}') }
            else { $lines += ('GARBAGE LINE ' + $i + ' {not json') }
        }
        [System.IO.File]::WriteAllLines($p, $lines)
        $loaded = Read-SysOrgFileStateCache -Path $p
        $loaded.Corrupted | Should -BeTrue
        $loaded.Entries.Count | Should -Be 0
    }

    It 'a few malformed lines are skipped without discarding the whole cache' {
        $p = Join-Path $TestDrive 'cache3\filestate.ndjson'
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        $lines = @()
        foreach($i in 1..20){
            # valid JSON needs DOUBLED backslashes in the key; one line is deliberately garbage
            if($i -eq 7){ $lines += 'not-json-at-all' }
            else { $lines += ('{"k":"c:\\x\\f' + $i + '|1|1","h":"h' + $i + '","hh":"","ht":"","m":null}') }
        }
        [System.IO.File]::WriteAllLines($p, $lines)
        $loaded = Read-SysOrgFileStateCache -Path $p
        $loaded.Corrupted | Should -BeFalse
        $loaded.Entries.Count | Should -Be 19
        $loaded.SkippedLines | Should -Be 1
    }

    It 'metadata goes through the cache: a fresh hit never re-extracts (mocked registry)' {
        $dir = Join-Path $TestDrive 'metacache'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'a.mp3'
        Set-Content -LiteralPath $p -Value 'not a real mp3' -Encoding ASCII
        $fi = Get-Item -LiteralPath $p
        $key = Get-SysOrgFileCacheKey -Path $p -Length ([long]$fi.Length) -LastWriteTimeUtc $fi.LastWriteTimeUtc
        $cache = @{}
        $cache[$key] = [pscustomobject]@{ Hash=''; HeaderHash=''; HeadTailHash=''; Meta=@{ Source='id3'; Artist='Cached Artist'; Title='Cached Title' } }
        $new = @{}
        $m = Get-SysOrgCachedMetadata -Path $p -Family 'id3' -FileCache $cache -NewEntries $new
        $m.Artist | Should -Be 'Cached Artist'
        $new.Count | Should -Be 0    # nothing new extracted
    }

    It 'a cache miss extracts and stores the result' {
        $dir = Join-Path $TestDrive 'metacache2'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'a.txt'
        Set-Content -LiteralPath $p -Value ('invoice KRA PAYE ' * 30) -Encoding UTF8
        $cache = @{}
        $new = @{}
        $m = Get-SysOrgCachedMetadata -Path $p -Family 'text' -FileCache $cache -NewEntries $new
        $m | Should -Not -BeNullOrEmpty
        $m.Source | Should -Be 'text'
        $new.Count | Should -Be 1
        # second call: served from the new entries
        $m2 = Get-SysOrgCachedMetadata -Path $p -Family 'text' -FileCache $cache -NewEntries $new
        "$($m2['Snippet'])" | Should -Be "$($m['Snippet'])"
    }
}

Describe 'Compiled exclusion matcher (Phase 3.3)' {

    BeforeAll {
        $script:cfgM = @{
            AppRoot = 'C:\SysOrgApp'
            ExcludedPaths = @('C:\Windows','C:\Users\*\AppData','C:\Program Files','$Recycle.Bin','Recovery','*\node_modules')
        }
        $script:matcher = New-SysOrgExclusionMatcher -Config $script:cfgM
    }

    It 'answers identically to the classic checker on a corpus of paths' {
        $paths = @(
            'C:\Windows\notepad.exe','C:\Windows\System32\drivers\etc\hosts',
            'C:\Users\alice\AppData\Local\Temp\x.tmp','C:\Users\alice\Documents\report.docx',
            'D:\$Recycle.Bin\x','E:\Data\Recovery\old.txt','E:\Data\Recovered\keep.txt',
            'C:\SysOrgApp\Logs\a.log','C:\SysOrgApp\plans.json',
            'C:\work\project\node_modules\lib.js','C:\work\project\src\app.js',
            'C:\Users\bob\AppData\file','C:\Users\bob\AppDataRoaming-safe\file',
            'D:\Tools\bin\tool.exe'
        )
        foreach($p in $paths){
            (Test-SysOrgExcludedPathFast -Path $p -Matcher $script:matcher) | Should -Be (Test-SysOrgExcludedPath -Path $p -Config $script:cfgM) -Because $p
        }
    }

    It 'is at least as strict as the classic checker (no new gaps)' {
        $cfgAll = @{ AppRoot='C:\App'; ExcludedPaths = @('C:\Windows','C:\Program Files','C:\Users\*\AppData','$Recycle.Bin','System Volume Information','Recovery','OneDriveTemp','*\node_modules','*\.git','*\AppData\*') }
        $m2 = New-SysOrgExclusionMatcher -Config $cfgAll
        $probe = @('C:\Windows\evil.txt','D:\x\.git\config','C:\Users\t\AppData\Roaming\y','D:\Recovery\z','C:\App\inside.bin','D:\$Recycle.Bin\f')
        foreach($p in $probe){
            if(Test-SysOrgExcludedPath -Path $p -Config $cfgAll){
                (Test-SysOrgExcludedPathFast -Path $p -Matcher $m2) | Should -BeTrue -Because $p
            }
        }
    }
}

Describe 'Head+tail hash and parallel hashing (Phase 3.4/3.5)' {

    It 'identical files share the head+tail hash; different tails separate' {
        $a = Join-Path $TestDrive 'a.bin'
        $b = Join-Path $TestDrive 'b.bin'
        $c = Join-Path $TestDrive 'c.bin'
        $payload = New-Object byte[] (300KB)
        for($i=0; $i -lt $payload.Length; $i++){ $payload[$i] = ($i % 251) }
        [System.IO.File]::WriteAllBytes($a, $payload)
        [System.IO.File]::WriteAllBytes($b, $payload)               # exact copy
        $mod = [byte[]]$payload.Clone(); $mod[299KB - 10] = 0xEE    # different tail only
        [System.IO.File]::WriteAllBytes($c, $mod)
        $ha = Get-SysOrgFileHashHeadTail -Path $a
        $hb = Get-SysOrgFileHashHeadTail -Path $b
        $hc = Get-SysOrgFileHashHeadTail -Path $c
        $ha | Should -Be $hb
        $ha | Should -Not -Be $hc
    }

    It 'parallel hashing returns results in INPUT order' {
        $paths = @()
        foreach($i in 1..20){
            $p = Join-Path $TestDrive ('par-{0:D2}.bin' -f $i)
            [System.IO.File]::WriteAllBytes($p, [byte[]]@(1,2,3,$i))
            $paths += $p
        }
        $par = @(Invoke-SysOrgParallelHash -Paths $paths -Parallelism 3)
        $par.Count | Should -Be 20
        for($i=0; $i -lt 20; $i++){
            $seq = Get-SysOrgFileHash -Path $paths[$i]
            $par[$i] | Should -Be $seq
        }
    }

    It 'falls back to sequential hashing when parallelism is 1' {
        $p = Join-Path $TestDrive 'one.bin'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(9,9,9))
        $par = @(Invoke-SysOrgParallelHash -Paths @($p) -Parallelism 1)
        $par[0] | Should -Be (Get-SysOrgFileHash -Path $p)
    }

    It 'the parallelism resolver honors Run.Parallelism and HDD throttling' {
        (Get-SysOrgParallelism -Config @{ Run = @{ Parallelism = 7 } }) | Should -Be 7
        $hddProf = [pscustomobject]@{ Drive=[pscustomobject]@{ MediaType='HDD' } }
        (Get-SysOrgParallelism -Config @{} -DriveProfile $hddProf) | Should -Be 1
        $ssdProf = [pscustomobject]@{ Drive=[pscustomobject]@{ MediaType='SSD' } }
        (Get-SysOrgParallelism -Config @{} -DriveProfile $ssdProf) | Should -BeGreaterOrEqual 1
    }
}

Describe 'Duplicate pipeline through the cache (Phase 3.5)' {

    It 'finds the same duplicate groups with and without the cache' {
        $dir = Join-Path $TestDrive 'dups'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $payload = New-Object byte[] (320KB)
        for($i=0; $i -lt $payload.Length; $i++){ $payload[$i] = (($i * 7) % 251) }
        $f1 = Join-Path $dir 'orig.zip';  [System.IO.File]::WriteAllBytes($f1, $payload)
        $f2 = Join-Path $dir 'orig - Copy.zip'; [System.IO.File]::WriteAllBytes($f2, $payload)
        $f3 = Join-Path $dir 'different.zip'; $p2 = [byte[]]$payload.Clone(); $p2[0] = 0x99; [System.IO.File]::WriteAllBytes($f3, $p2)
        $inv = @(
            [pscustomobject]@{ FullName=$f1; Name='orig.zip'; Stem='orig'; Extension='.zip'; Length=(320KB); LastWriteTime=(Get-Date '2024-01-01'); Directory=$dir; Category='Archives' },
            [pscustomobject]@{ FullName=$f2; Name='orig - Copy.zip'; Stem='orig - Copy'; Extension='.zip'; Length=(320KB); LastWriteTime=(Get-Date '2024-02-01'); Directory=$dir; Category='Archives' },
            [pscustomobject]@{ FullName=$f3; Name='different.zip'; Stem='different'; Extension='.zip'; Length=(320KB); LastWriteTime=(Get-Date '2024-03-01'); Directory=$dir; Category='Archives' }
        )
        $g1 = @(Find-SysOrgDuplicates -Inventory $inv -Config @{ Copies = @{ MinFileSizeKB=256; HeaderHashKB=64 } })
        $g2 = @(Find-SysOrgDuplicates -Inventory $inv -Config @{ Copies = @{ MinFileSizeKB=256; HeaderHashKB=64 } } -FileCache @{} -NewEntries @{} -Parallelism 2)
        (@($g1).Count) | Should -Be 1
        (@($g2).Count) | Should -Be 1
        $g2[0].KeepPath | Should -Be $f1   # oldest wins
        $g2[0].Duplicates | Should -Contain $f2
        $g2[0].Hash | Should -Not -BeNullOrEmpty
        # the second run, now WITH the populated cache, still finds the group without re-hashing
        $cache = @{}
        $new = @{}
        $null = Find-SysOrgDuplicates -Inventory $inv -Config @{ Copies = @{ MinFileSizeKB=256; HeaderHashKB=64 } } -FileCache $cache -NewEntries $new -Parallelism 2
        (@($cache.Keys).Count) | Should -BeGreaterThan 0
        $g3 = @(Find-SysOrgDuplicates -Inventory $inv -Config @{ Copies = @{ MinFileSizeKB=256; HeaderHashKB=64 } } -FileCache $cache -NewEntries @{} -Parallelism 2)
        (@($g3).Count) | Should -Be 1
        $g3[0].KeepPath | Should -Be $f1
        $g3[0].Hash | Should -Be $g2[0].Hash
    }
}

Describe 'C1 speed work: caching semantics and timing output (v3.0.1)' {

    It 'the mutability policy cache returns verdicts IDENTICAL to the uncached path' {
        $prof = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='System'; ProposedScope='KnownFolders'
            KnownFolders=@([pscustomobject]@{ Name='Documents'; Path='C:\Users\t\Documents' })
            DownloadRoots=@('C:\Users\t\Downloads') }
        $prof2 = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='System'; ProposedScope='KnownFolders'
            KnownFolders=@([pscustomobject]@{ Name='Documents'; Path='C:\Users\t\Documents' })
            DownloadRoots=@('C:\Users\t\Downloads') }
        $cfg = @{ ExcludedPaths=@('C:\Protected'); ExcludedFilePatterns=@()
                  Policy=@{ SystemDrive=@{ Scope='KnownFolders'; WritablePaths=@(); BlockedExtensions=@('.dll'); AllowInstallersInDownloads=$true }
                            DataDrives=@{ Scope='FullDrive' } } }
        $cases = @(
            @{ Path='C:\Users\t\Documents\a.txt'; Ext='.txt' }     # allowed
            @{ Path='C:\Users\t\Documents\b.dll'; Ext='.dll' }     # blocked
            @{ Path='C:\Loose\c.txt'; Ext='.txt' }                 # outside writable scope
            @{ Path='C:\Protected\d.txt'; Ext='.txt' }             # excluded path
            @{ Path='C:\Users\t\Downloads\e.exe'; Ext='.exe' }     # installer in downloads
            @{ Path='C:\Users\t\Documents\f.exe'; Ext='.exe' }     # installer outside downloads
        )
        $cache = @{}
        foreach($c in $cases){
            $a = Test-SysOrgFileMutable -Path $c.Path -Extension $c.Ext -DriveProfile $prof -Config $cfg
            $b = Test-SysOrgFileMutable -Path $c.Path -Extension $c.Ext -DriveProfile $prof2 -Config $cfg -PolicyCache $cache -ExMatcher (New-SysOrgExclusionMatcher -Config $cfg)
            "$($a.Allowed):$($a.Reason)" | Should -Be "$($b.Allowed):$($b.Reason)"
        }
        $cache.Count | Should -BeGreaterOrEqual 1
    }

    It 'the compiled file-exclusion matcher matches exactly like the -like loop' {
        $cfg = @{ ExcludedFilePatterns = @('*.tmp','~$*','*.part','*.crdownload','*.partial','desktop.ini','thumbs.db','.DS_Store') }
        foreach($n in @('a.tmp','x.thumbs.db','~doc.docx','photo.part','setup.crdownload','file.partial','desktop.ini','.DS_Store','keep.txt','photo.jpg')){
            (Test-SysOrgExcludedFile -Path ("C:\x\" + $n) -Config $cfg) | Should -Be (Test-SysOrgExcludedFileFast -Path ("C:\x\" + $n) -Config $cfg)
        }
    }

    It 'the category override map is reference-cached and per-config' {
        $c1 = @{ TypeMap = @{ '.heic' = 'Pictures' } }
        $c2 = @{ TypeMap = @{ '.heic' = 'Documents'; '.xyz' = 'Documents' } }   # overrides the built-in mapping
        (Get-SysOrgCategory -Extension '.heic' -Config $c1) | Should -Be 'Pictures'
        (Get-SysOrgCategory -Extension '.heic' -Config $c2) | Should -Be 'Documents'   # per-config override wins over the built-in
        (Get-SysOrgCategory -Extension '.xyz' -Config $c2) | Should -Be 'Documents'
    }

    It 'the lexicon is cached per file mtime: same file -> same result, edited file -> reloaded' {
        $app = Join-Path $TestDrive ('c1app-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $app 'Rules') -Force | Out-Null
        $lexPath = Join-Path $app 'Rules\Lexicon.psd1'
        "@{ Version='t1'; Multiplier = @{ Filename = 2.0; Metadata = 1.5; Content = 0.8 }; Confidence = @{ Divider = 1.5 }; Entries = @( @{ Subtype='Work'; Filename=@('alpha'); Content=@() } ) }" |
            Set-Content -LiteralPath $lexPath -Encoding UTF8
        $cfg = @{ Rules = @{ LexiconPath = $lexPath } }
        $l1 = Get-SysOrgLexicon -Config $cfg -AppRoot $app
        "$($l1.Version)" | Should -Be 't1'
        $l2 = Get-SysOrgLexicon -Config $cfg -AppRoot $app
        $l2.Version | Should -Be 't1'                 # cached
        Start-Sleep -Milliseconds 60
        "@{ Version='t2'; Multiplier = @{ Filename = 2.0; Metadata = 1.5; Content = 0.8 }; Confidence = @{ Divider = 1.5 }; Entries = @( @{ Subtype='Work'; Filename=@('alpha'); Content=@() } ) }" |
            Set-Content -LiteralPath $lexPath -Encoding UTF8
        $l3 = Get-SysOrgLexicon -Config $cfg -AppRoot $app
        "$($l3.Version)" | Should -Be 't2'            # mtime changed -> reloaded
    }

    It 'the timing summary is deterministic and alphabetical' {
        $s = Get-SysOrgTimingSummary -Timings @{ plan=7.19; enumerate=1.99; duplicates=4.58 }
        $s | Should -Be 'Timing: duplicates 4.58s, enumerate 1.99s, plan 7.19s'
        (Get-SysOrgTimingSummary -Timings @{}) | Should -BeNullOrEmpty
        (Get-SysOrgTimingSummary -Timings $null) | Should -BeNullOrEmpty
    }
}
