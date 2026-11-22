# Tests/SysOrg.Scan.Tests.ps1
# Covers: P1-5 (cloud placeholder skip), P1-8 (.sysorg-ignore tree exclusion),
#         P1-9 (cache keyed to config content), P2-5 (reparse + long paths),
#         W2 (known-folder scan scope via mocked resolver),
#         W4 (TypeMap override, PerceivedType fallback),
#         W5 (type-first name families), downloads provenance buckets.
# Note: imports the Audit module too - the inventory safety gates live there.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force
    $script:scanCfg = @{
        ExcludedPaths          = @()
        ExcludedFilePatterns   = @()
        SkipHiddenSystemFiles  = $true
        ExcludeDestinations    = $true
        OrganizedRoots         = @{ '*' = '__AUTO__' }
        PreserveExistingFolders = $true
        AlwaysScanFolders      = @()
        TypeMap                = @{}
        Copies                 = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=1; HeaderHashKB=64 }
        Families               = @{ Enabled=$true; MinFiles=2; WithinTypeOnly=$true; CrossTypeLink='SameName'; KeepDates=$true; StripVersionSuffix=$true }
        Downloads              = @{ Roots=@('Downloads'); GroupBy='SourceFirst'; UseZoneIdentifier=$false; UnknownSourceFolder='_NoSource' }
        FolderAudit            = @{ Enabled=$true; SkipHiddenSystemDirs=$true; RespectDefenderCFA=$false }
        ScanRoots              = @{ '*' = @('Desktop','Documents','Downloads','Pictures','Videos','Music') }
    }
    # Drive qualifier of TestDrive; on non-Windows hosts (local test runs) there
    # is no qualifier, so fall back to a placeholder letter - it is only used for
    # cache-file naming and scope messages, never for addressing.
    $script:letter = if($env:OS -eq 'Windows_NT'){ (Split-Path $TestDrive -Qualifier).TrimEnd(':').ToUpper() } else { 'S' }
}

Describe 'Get-SysOrgInventory exclusions' {
    It 'a .sysorg-ignore marker excludes its entire tree (P1-8)' {
        $root = Join-Path $TestDrive ('marker-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'keep')            -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'ignored\sub')     -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'keep\a.txt')                -Value 'a'
        Set-Content -LiteralPath (Join-Path $root 'ignored\.sysorg-ignore')    -Value ''
        Set-Content -LiteralPath (Join-Path $root 'ignored\x.txt')             -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'ignored\sub\y.txt')         -Value 'y'
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $inv.Count | Should -Be 1
        $inv[0].Name | Should -Be 'a.txt'
        @($inv | Where-Object { $_.FullName -like '*ignored*' }).Count | Should -Be 0
    }
    It 'cloud placeholders (Offline, RecallOnDataAccess) are never recorded (P1-5)' {
        # Cross-version assertions on the raw-int helper (production surface):
        Test-SysOrgCloudPlaceholderAttributes -Attributes 0x400020 | Should -BeTrue    # Archive | RecallOnDataAccess
        Test-SysOrgCloudPlaceholderAttributes -Attributes 0x20     | Should -BeFalse   # Archive only
        Test-SysOrgCloudPlaceholderAttributes -Attributes 0x1000   | Should -BeTrue    # Offline
        if($env:OS -ne 'Windows_NT'){
            Set-ItResult -Inconclusive -Because 'Linux file APIs ignore Offline attribute writes; Windows CI covers the real-file inventory path'
            return
        }
        $root = Join-Path $TestDrive ('cloud-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $p1 = Join-Path $root 'offline.txt'
        $p3 = Join-Path $root 'normal.txt'
        Set-Content -LiteralPath $p1 -Value 'a'; Set-Content -LiteralPath $p3 -Value 'c'
        $f1 = Get-Item -LiteralPath $p1
        $f1.Attributes = ($f1.Attributes -bor [System.IO.FileAttributes]::Offline)
        (($f1.Attributes -band [System.IO.FileAttributes]::Offline) -ne 0) | Should -BeTrue
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $names = @($inv | ForEach-Object { $_.Name })
        $names.Count | Should -Be 1
        $names[0] | Should -Be 'normal.txt'
    }
    It 'does not descend into directory junctions (P2-5)' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only: NTFS junctions'; return }
        $root  = Join-Path $TestDrive ('junc-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'real') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'real\a.txt') -Value 'a'
        $null = New-Item -ItemType Junction -Path (Join-Path $root 'link') -Target (Join-Path $root 'real')
        Test-Path -LiteralPath (Join-Path $root 'link') | Should -BeTrue
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        @($inv | Where-Object { $_.Name -eq 'a.txt' }).Count | Should -Be 1   # found once, not through the junction
    }
    It 'long paths are recorded as SkippedLongPath and not categorized normally (P2-5)' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only: \\?\ long-path namespace'; return }
        $root = Join-Path $TestDrive ('deep-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $deep = $root
        try {
            while($deep.Length -lt 280){ $deep = Join-Path $deep ('dddddddddd') }
            [void][System.IO.Directory]::CreateDirectory(('\\?\' + $deep))
            [System.IO.File]::WriteAllText(('\\?\' + (Join-Path $deep 'waydown.txt')), 'd')
            Set-Content -LiteralPath (Join-Path $root 'shallow.txt') -Value 's'
            $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
            $shallow = @($inv | Where-Object { $_.Name -eq 'shallow.txt' })
            $shallow.Count | Should -Be 1
            $shallow[0].Category | Should -Be 'Documents'
            $deepRecords = @($inv | Where-Object { $_.FullName -like "$deep*" })
            foreach($r in $deepRecords){ $r.Category | Should -Be 'SkippedLongPath' }
        } finally {
            if($deep -ne $root){ [void][System.IO.Directory]::Delete(('\\?\' + $deep), $true) }
        }
    }
    It 'the mocked known folder on this drive is added to the scan scope (W2 redirection)' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'drive-qualifier matching needs a Windows path shape'; return }
        # Mocked User Shell Folders equivalent: Pictures resolved to <TestDrive>\bilder.
        # On a real machine this is exactly what a redirected Pictures folder looks like.
        $bilder = Join-Path $TestDrive 'bilder'
        New-Item -ItemType Directory -Path $bilder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bilder 'redirected.jpg') -Value 'p'
        $mockKf = @([pscustomobject]@{ Name='Pictures'; Path=$bilder; IsRedirected=$true; UnderOneDrive=$false })
        $rootsInfo = Get-SysOrgScanRoots -Letter $letter -Config $scanCfg -DefaultScope -KnownFolders $mockKf
        @($rootsInfo.Initial | Where-Object { $_ -ieq $bilder }).Count | Should -Be 1
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -DefaultScope -KnownFolders $mockKf)
        @($inv | Where-Object { $_.Name -eq 'redirected.jpg' }).Count | Should -Be 1
    }
}

Describe 'Inventory cache keying (P1-9)' {
    It 'cache file name changes when the config file changes' {
        $cfgRoot = Join-Path $TestDrive ('cfgroot-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $cacheF  = Join-Path $TestDrive ('cache-'  + [guid]::NewGuid().ToString('N').Substring(0,6))
        $scanR   = Join-Path $TestDrive ('scan-'   + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $cfgRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $scanR  -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $scanR 'a.txt') -Value 'a'
        Set-Content -LiteralPath (Join-Path $cfgRoot 'SysOrg.config.psd1') -Value '@{ Version = "2.1.0" }'
        $cfg = @{ AppRoot = $cfgRoot; ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true
                  ExcludeDestinations=$true; OrganizedRoots=@{ '*'='__AUTO__' }; PreserveExistingFolders=$true
                  AlwaysScanFolders=@(); TypeMap=@{}
                  Copies=@{Policy='Quarantine';QuarantineFolderName='_Duplicates';MinFileSizeKB=1}
                  Families=@{Enabled=$false}; Downloads=@{UseZoneIdentifier=$false}
                  FolderAudit=@{Enabled=$true;RespectDefenderCFA=$false}; ScanRoots=@{} }
        $null = Get-SysOrgInventory -Letter $letter -Config $cfg -Roots $scanR -CacheFolder $cacheF -NoCache
        $first = @(Get-ChildItem -LiteralPath $cacheF -File)
        $first.Count | Should -Be 1
        $first[0].Name | Should -Match '^inventory-.*-custom-[0-9A-F]{8}\.json$'
        Add-Content -LiteralPath (Join-Path $cfgRoot 'SysOrg.config.psd1') -Value '# edited'
        $null = Get-SysOrgInventory -Letter $letter -Config $cfg -Roots $scanR -CacheFolder $cacheF -NoCache
        $two = @(Get-ChildItem -LiteralPath $cacheF -File)
        $two.Count | Should -Be 2
        $two[0].Name | Should -Not -Be $two[1].Name
        $null = Get-SysOrgInventory -Letter $letter -Config $cfg -Roots $scanR -CacheFolder $cacheF
        @(Get-ChildItem -LiteralPath $cacheF -File).Count | Should -Be 2
    }
}

Describe 'Classification (W4)' {
    It 'maps common extensions to ROUTING categories' {
        $root = Join-Path $TestDrive ('cat-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'a.pdf') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'b.jpg') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'c.py')  -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'd.mp3') -Value 'x'
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $map = @{}
        foreach($r in $inv){ $map[$r.Name] = $r.Category }
        $map['a.pdf'] | Should -Be 'Documents'
        $map['b.jpg'] | Should -Be 'Pictures'
        $map['c.py']  | Should -Be 'Code'
        $map['d.mp3'] | Should -Be 'Music'
    }
    It 'TypeMap override wins, and SKIP is honored' {
        $cfg2 = @{ TypeMap = @{ '.xyz' = 'Pictures'; '.sys2' = 'SKIP' } }
        Get-SysOrgCategory -Extension '.xyz' -Config $cfg2  | Should -Be 'Pictures'
        Get-SysOrgCategory -Extension '.sys2' -Config $cfg2 | Should -Be 'SKIP'
    }
    It 'an unmapped extension routes by the PerceivedType registry fallback (W4)' {
        Mock Get-SysOrgPerceivedSub -ModuleName SysOrg.Scan { 'image' }
        Get-SysOrgCategory -Extension '.foobar' -Config @{ TypeMap=@{} } | Should -Be 'Pictures'
        Mock Get-SysOrgPerceivedSub -ModuleName SysOrg.Scan { 'SKIP' }
        Get-SysOrgCategory -Extension '.quuxfile' -Config @{ TypeMap=@{} } | Should -Be 'SKIP'
    }
}

Describe 'Get-SysOrgNameFamilies (W5)' {
    It 'groups same-name files within one type partition, order-independent (P2-6)' {
        $inv = @(
            [pscustomobject]@{ FullName='C:\x\Orion Design Brief.txt';  Name='Orion Design Brief.txt';  Stem='Orion Design Brief';  Extension='.txt'; Category='Documents' }
            [pscustomobject]@{ FullName='C:\x\Brief Design Orion.docx'; Name='Brief Design Orion.docx'; Stem='Brief Design Orion'; Extension='.docx'; Category='Documents' }
            [pscustomobject]@{ FullName='C:\x\Design Brief Orion.pdf';  Name='Design Brief Orion.pdf';  Stem='Design Brief Orion';  Extension='.pdf';  Category='Documents' }
        )
        $pk = @{}; foreach($f in $inv){ $pk[$f.FullName] = 'Documents' }
        $fam = Get-SysOrgNameFamilies -Inventory $inv -PartitionLookup $pk -Config $scanCfg
        @($fam.Families).Count | Should -Be 1
        $fam.Families[0].Members | Should -Be 3
        $fam.Families[0].Partition | Should -Be 'Documents'
        foreach($f in $inv){ $fam.Lookup[$f.FullName].Name | Should -Not -BeNullOrEmpty }
    }
    It 'keeps IMG_1234 / IMG_1235 separate (no false family)' {
        $inv = @(
            [pscustomobject]@{ FullName='C:\p\IMG_1234.jpg'; Name='IMG_1234.jpg'; Stem='IMG_1234'; Extension='.jpg'; Category='Pictures' }
            [pscustomobject]@{ FullName='C:\p\IMG_1235.jpg'; Name='IMG_1235.jpg'; Stem='IMG_1235'; Extension='.jpg'; Category='Pictures' }
        )
        $pk = @{}; foreach($f in $inv){ $pk[$f.FullName] = 'Pictures' }
        $fam = Get-SysOrgNameFamilies -Inventory $inv -PartitionLookup $pk -Config $scanCfg
        @($fam.Families).Count | Should -Be 0
        $fam.Lookup.Count | Should -Be 0
    }
    It 'normalizes copy markers and version suffixes: Report / Report final v2 / Report - Copy (rev 2.0 table)' {
        $inv = @(
            [pscustomobject]@{ FullName='C:\d\Report.docx';          Name='Report.docx';          Stem='Report';          Extension='.docx'; Category='Documents' }
            [pscustomobject]@{ FullName='C:\d\Report final v2.docx'; Name='Report final v2.docx'; Stem='Report final v2'; Extension='.docx'; Category='Documents' }
            [pscustomobject]@{ FullName='C:\d\Report - Copy.docx';   Name='Report - Copy.docx';   Stem='Report - Copy';   Extension='.docx'; Category='Documents' }
        )
        $pk = @{}; foreach($f in $inv){ $pk[$f.FullName] = 'Documents' }
        $fam = Get-SysOrgNameFamilies -Inventory $inv -PartitionLookup $pk -Config $scanCfg
        @($fam.Families).Count | Should -Be 1
        $fam.Families[0].Name | Should -Be 'Report'
    }
    It 'KeepDates=$false merges date-differing siblings; $true keeps them separate' {
        $mk = { param($name,$stem)
            [pscustomobject]@{ FullName=('C:\d\' + $name); Name=$name; Stem=$stem; Extension='.pdf'; Category='Documents' } }
        $inv = @(& $mk 'Invoice 2025-01.pdf' 'Invoice 2025-01'; & $mk 'Invoice 2025-02.pdf' 'Invoice 2025-02')
        $pk = @{}; foreach($f in $inv){ $pk[$f.FullName] = 'Documents' }
        $sep = Get-SysOrgNameFamilies -Inventory $inv -PartitionLookup $pk -Config $scanCfg
        @($sep.Families).Count | Should -Be 0
        $cfgNoDates = @{ Families = @{ Enabled=$true; MinFiles=2; KeepDates=$false; WithinTypeOnly=$true; CrossTypeLink='SameName' } }
        $merged = Get-SysOrgNameFamilies -Inventory $inv -PartitionLookup $pk -Config $cfgNoDates
        @($merged.Families).Count | Should -Be 1
    }
}

Describe 'Get-SysOrgMultipartSets (rev 2.0 D5)' {
    It 'groups zip/7z numbered parts and rar sets; singletons are ignored' {
        $inv = @(
            [pscustomobject]@{ FullName='C:\a\Trip.zip.001'; Name='Trip.zip.001'; Stem='Trip.zip'; Extension='.001'; Category='Archives' }
            [pscustomobject]@{ FullName='C:\a\Trip.zip.002'; Name='Trip.zip.002'; Stem='Trip.zip'; Extension='.001'; Category='Archives' }
            [pscustomobject]@{ FullName='C:\a\Movie.part1.rar'; Name='Movie.part1.rar'; Stem='Movie.part1'; Extension='.rar'; Category='Archives' }
            [pscustomobject]@{ FullName='C:\a\Movie.part2.rar'; Name='Movie.part2.rar'; Stem='Movie.part2'; Extension='.rar'; Category='Archives' }
            [pscustomobject]@{ FullName='C:\a\Lonely.zip'; Name='Lonely.zip'; Stem='Lonely'; Extension='.zip'; Category='Archives' }
        )
        $mp = Get-SysOrgMultipartSets -Inventory $inv -Config $scanCfg
        @($mp.Sets).Count | Should -Be 2
        $mp.Map['C:\a\Trip.zip.001'] | Should -Be $mp.Map['C:\a\Trip.zip.002']
        $mp.Map.ContainsKey('C:\a\Lonely.zip') | Should -BeFalse
        foreach($s in @($mp.Sets)){ @($s.Members).Count | Should -Be 2 }
    }
}

Describe 'Get-SysOrgSourceBucket (downloads provenance)' {
    It 'maps known hosts exactly' {
        Get-SysOrgSourceBucket -HostUrl 'https://github.com/x/y/releases/download/1/f.zip' | Should -Be 'GitHub'
        Get-SysOrgSourceBucket -HostUrl 'https://cdn.whatsapp.net/x' | Should -Be 'WhatsApp'
        Get-SysOrgSourceBucket -ReferrerUrl 'https://t.me/durov' | Should -Be 'Telegram'
    }
    It 'falls back to the registrable domain, then filename heuristics' {
        Get-SysOrgSourceBucket -HostUrl 'https://cdn.example.org/file.zip' | Should -Be 'Example'
        Get-SysOrgSourceBucket -FileName 'WhatsApp Image 2024-01-01 at 10.00.00.jpeg' | Should -Be 'WhatsApp'
        Get-SysOrgSourceBucket -FileName 'IMG-20240101-WA0001.jpg' | Should -Be 'WhatsApp'
        Get-SysOrgSourceBucket -FileName 'Screenshot 2024-05-01 090000.png' | Should -Be 'Screenshots'
        Get-SysOrgSourceBucket | Should -BeNullOrEmpty
    }
}

Describe 'Known-folder sanity check (v2.1.1)' {
    It 'rejects a drive root, an empty path and the profile root' {
        Test-SysOrgKnownFolderPath -Path 'C:\' | Should -BeFalse
        Test-SysOrgKnownFolderPath -Path 'C:'  | Should -BeFalse
        Test-SysOrgKnownFolderPath -Path ''    | Should -BeFalse
        if($env:USERPROFILE){ Test-SysOrgKnownFolderPath -Path $env:USERPROFILE | Should -BeFalse }
    }
    It 'accepts a normal subfolder' {
        $d = Join-Path $TestDrive 'kf-ok'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Test-SysOrgKnownFolderPath -Path $d | Should -BeTrue
    }
    It 'rejects a known folder redirected to C:\ (drive root)' {
        # exactly the audit scenario: a redirected known folder pointing at the drive root
        Test-SysOrgKnownFolderPath -Path 'C:\' | Should -BeFalse
    }
    It 'rejects a folder that is a parent of the Windows or Program Files folders (env override)' {
        $oldPf = $env:ProgramFiles
        try{
            $env:ProgramFiles = (Join-Path $TestDrive 'sysroot\Program Files')
            Test-SysOrgKnownFolderPath -Path (Join-Path $TestDrive 'sysroot') | Should -BeFalse
            Test-SysOrgKnownFolderPath -Path (Join-Path $TestDrive 'sysroot\Program Files') | Should -BeFalse
        } finally { $env:ProgramFiles = $oldPf }
    }
}

Describe 'Get-SysOrgSourceBucket hardening (v2.1.1)' {
    It 'handles multi-label public suffixes' {
        Get-SysOrgSourceBucket -HostUrl 'https://www.kra.go.ke/portal' | Should -Be 'Kra'
        Get-SysOrgSourceBucket -HostUrl 'https://safaricom.co.ke/x'     | Should -Be 'Safaricom'
        Get-SysOrgSourceBucket -HostUrl 'https://example.co.uk/f.zip'   | Should -Be 'Example'
        Get-SysOrgSourceBucket -HostUrl 'https://unza.zm'               | Should -Be 'Unza'
    }
    It 'IP-address and localhost hosts fall through to the filename heuristics' {
        Get-SysOrgSourceBucket -HostUrl 'https://192.168.1.1/f.zip' | Should -BeNullOrEmpty
        Get-SysOrgSourceBucket -HostUrl 'http://localhost:8080/f.zip' | Should -BeNullOrEmpty
        Get-SysOrgSourceBucket -HostUrl 'https://192.168.1.1/f.zip' -FileName 'WhatsApp Image 2024-01-01.jpg' | Should -Be 'WhatsApp'
        Get-SysOrgSourceBucket -HostUrl 'http://localhost/x' -FileName 'Screenshot 2024-05-01 090000.png' | Should -Be 'Screenshots'
    }
    It 'reserved device names come out safe' {
        Get-SysOrgSourceBucket -HostUrl 'https://nul.com/file.zip'    | Should -Be '_Nul'
        Get-SysOrgSourceBucket -HostUrl 'https://con.info/x'          | Should -Be '_Con'
        Get-SysOrgSourceBucket -HostUrl 'https://con.example.org/x'   | Should -Be 'Example'   # registrable domain is example.org
    }
    It 'keeps the existing known-host mappings and normal buckets' {
        Get-SysOrgSourceBucket -HostUrl 'https://github.com/x/y/releases/download/1/f.zip' | Should -Be 'GitHub'
        Get-SysOrgSourceBucket -HostUrl 'https://cdn.example.org/file.zip' | Should -Be 'Example'
    }
}

Describe 'Extension map hardening (v2.1.1)' {
    It 'no extension appears in more than one category' {
        $map = & (Get-Module SysOrg.Scan) { $script:CategoryMap }
        $seen = @{}
        $dups = @()
        foreach($cat in $map.Keys){
            foreach($e in $map[$cat]){
                if($seen.ContainsKey($e)){ $dups += ("{0} in {1} and {2}" -f $e, $seen[$e], $cat) }
                else { $seen[$e] = $cat }
            }
        }
        $dups | Should -BeNullOrEmpty
    }
    It "'.ts' routes the same way (Code) in 20 repeated calls" {
        $results = @(1..20 | ForEach-Object { Get-SysOrgCategory -Extension '.ts' -Config @{} })
        @($results | Select-Object -Unique).Count | Should -Be 1
        $results[0] | Should -Be 'Code'
    }
    It 'a real MPEG transport stream routes to Videos via content sniffing' {
        $root = Join-Path $TestDrive ('tsniff-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $bytes = New-Object byte[] 372   # two 188-byte packets + slack
        $bytes[0] = 0x47; $bytes[188] = 0x47
        [System.IO.File]::WriteAllBytes((Join-Path $root 'stream.ts'), $bytes)
        Set-Content -LiteralPath (Join-Path $root 'script.ts') -Value 'const x = 1'   # TypeScript -> Code
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $map = @{}
        foreach($r in $inv){ $map[$r.Name] = $r.Category }
        $map['stream.ts'] | Should -Be 'Videos'
        $map['script.ts'] | Should -Be 'Code'
    }
    It 'Test-SysOrgMpegTransportStream rejects short, empty and wrong-content files' {
        $root = Join-Path $TestDrive ('tsneg-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $short = Join-Path $root 'short.ts'
        [System.IO.File]::WriteAllBytes($short, ([byte[]]@(0x47,1,2)))
        Test-SysOrgMpegTransportStream -Path $short | Should -BeFalse
        $wrong = Join-Path $root 'wrong.ts'
        $bytes = New-Object byte[] 372
        $bytes[0] = 0x41; $bytes[188] = 0x47
        [System.IO.File]::WriteAllBytes($wrong, $bytes)
        Test-SysOrgMpegTransportStream -Path $wrong | Should -BeFalse
        Test-SysOrgMpegTransportStream -Path (Join-Path $root 'missing.ts') | Should -BeFalse
    }
}
Describe 'Project folder detection and preview stats (v2.1.1)' {
    BeforeAll {
        $script:projCfg = @{ Projects=@{ Enabled=$true; Markers=@() }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                             ExcludeDestinations=$false; TypeMap=@{}; FolderAudit=@{ Enabled=$false } }
        $script:projProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; KnownFolders=@(); DownloadRoots=@() }
    }
    It 'a thesis folder with only a Makefile is NOT a project' {
        $root = Join-Path $TestDrive ('thesis-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'thesis') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'thesis\Makefile') -Value 'all:'
        Set-Content -LiteralPath (Join-Path $root 'thesis\chapter1.txt') -Value 'text'
        @(Get-SysOrgProjectFolders -Roots @($root) -Config $projCfg -DriveProfile $projProf).Count | Should -Be 0
    }
    It 'a lone .gitignore or lock file is not a project; two distinct markers are' {
        $root = Join-Path $TestDrive ('two-m-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'lone')    -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'lone\.gitignore') -Value ''
        New-Item -ItemType Directory -Path (Join-Path $root 'real')    -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'real\Makefile')     -Value 'all:'
        Set-Content -LiteralPath (Join-Path $root 'real\CMakeLists.txt') -Value 'proj()'
        $found = @(Get-SysOrgProjectFolders -Roots @($root) -Config $projCfg -DriveProfile $projProf)
        @($found | Where-Object { $_.Name -eq 'lone' }).Count | Should -Be 0
        @($found | Where-Object { $_.Name -eq 'real' }).Count | Should -Be 1
    }
    It 'a VCS marker alone still qualifies (.git)' {
        $root = Join-Path $TestDrive ('vcs-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'app\.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'app\readme.md') -Value 'r'
        $found = @(Get-SysOrgProjectFolders -Roots @($root) -Config $projCfg -DriveProfile $projProf)
        $found.Count | Should -Be 1
        $found[0].Name | Should -Be 'app'
    }
    It 'folder-move preview stats: file count, non-code count, blocked extensions outside build dirs' {
        $root = Join-Path $TestDrive ('stats-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $repo = Join-Path $root 'app'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git')    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo 'bin')     -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'main.py')           -Value 'print(1)'
        Set-Content -LiteralPath (Join-Path $repo 'readme.md')         -Value 'r'
        Set-Content -LiteralPath (Join-Path $repo 'native.dll')        -Value 'dll'        # blocked, outside build dirs
        Set-Content -LiteralPath (Join-Path $repo 'bin\link.dll')      -Value 'dll'        # blocked, INSIDE build dirs
        $statsCfg = @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); TypeMap=@{}
                       Policy=@{ DataDrives=@{ BlockedExtensions=@('.dll','.sys') } } }
        $stats = Get-SysOrgFolderMoveStats -Path $repo -Config $statsCfg -DriveProfile $projProf
        $stats.Files    | Should -Be 4     # main.py, readme.md, native.dll, bin\link.dll
        $stats.NonCode  | Should -Be 3     # readme.md + the two .dll files (main.py is Code)
        $stats.BlockedCount | Should -Be 1 # only native.dll (bin\ is a build-output dir)
        @($stats.BlockedSamples)[0] | Should -Match 'native\.dll$'
    }
}

Describe 'Source buckets: AI map, registrable domains, short labels, extensibility (v3.0.1 A4)' {

    BeforeAll {
        $script:repoRoot = Split-Path $PSScriptRoot -Parent
    }

    It 'maps the AI and chat sources' {
        Get-SysOrgSourceBucket -HostUrl 'https://z.ai/x'                  | Should -Be 'Z-AI'
        Get-SysOrgSourceBucket -HostUrl 'https://chat.z.ai/f/abc'         | Should -Be 'Z-AI'
        Get-SysOrgSourceBucket -HostUrl 'https://meta.ai/r/xyz'           | Should -Be 'Meta-AI'
        Get-SysOrgSourceBucket -HostUrl 'https://claude.ai/chat'          | Should -Be 'Claude'
        Get-SysOrgSourceBucket -HostUrl 'https://chatgpt.com/g/g-1'       | Should -Be 'OpenAI'
        Get-SysOrgSourceBucket -HostUrl 'https://openai.com/api'          | Should -Be 'OpenAI'
        Get-SysOrgSourceBucket -HostUrl 'https://gemini.google.com/app'   | Should -Be 'Gemini'
        Get-SysOrgSourceBucket -HostUrl 'https://cdn.z.ai/f.bin'          | Should -Be 'Z-AI'   # prefix-stripped hosts resolve too
    }

    It 'still maps the established sources and public-suffix registrable domains' {
        Get-SysOrgSourceBucket -HostUrl 'https://github.com/a/b/releases/download/1/f.zip' | Should -Be 'GitHub'
        Get-SysOrgSourceBucket -HostUrl 'https://www.kra.go.ke/portal' | Should -Be 'Kra'
        Get-SysOrgSourceBucket -HostUrl 'https://safaricom.co.ke/x'    | Should -Be 'Safaricom'
        Get-SysOrgSourceBucket -HostUrl 'https://example.co.uk/f.zip'  | Should -Be 'Example'
        Get-SysOrgSourceBucket -ReferrerUrl 'https://t.me/durov'       | Should -Be 'Telegram'
    }

    It 'a bucket label shorter than 3 characters falls back to the full host label' {
        Get-SysOrgSourceBucket -HostUrl 'https://q.io/f.bin' | Should -Be 'q.io'
        Get-SysOrgSourceBucket -HostUrl 'https://ab.co/f.bin' | Should -Be 'ab.co'
        Get-SysOrgSourceBucket -HostUrl 'https://example.org/f.bin' | Should -Be 'Example'   # 7-char label is untouched
    }

    It 'loads the SHIPPED Rules\Sources.psd1 and keeps every built-in host' {
        $map = Get-SysOrgSourceMap -AppRoot $script:repoRoot
        $map.SourceFile | Should -Not -BeNullOrEmpty
        $map.Hosts['z.ai'] | Should -Be 'Z-AI'
        $map.Hosts['github.com'] | Should -Be 'GitHub'
        $map.SecondLevelSuffixes['go.ke'] | Should -BeTrue
        $map.FileNamePatterns.Count | Should -BeGreaterOrEqual 5
    }

    It 'an extension file MERGES over the built-ins without losing them' {
        $extApp = Join-Path $TestDrive ('sources-app-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $extApp 'Rules') -Force | Out-Null
        @'
@{
    Hosts = @{ 'myportal.go.ke' = 'MyPortal'; 'github.com' = 'CodeHost' }
    SecondLevelSuffixes = @{ 'or.tz' = $true }
    FileNamePatterns = @( @{ Pattern = '^mchanga'; Bucket = 'Mchanga' } )
}
'@ | Set-Content -LiteralPath (Join-Path $extApp 'Rules\Sources.psd1') -Encoding UTF8
        $map = Get-SysOrgSourceMap -AppRoot $extApp
        $map.Hosts['myportal.go.ke'] | Should -Be 'MyPortal'
        $map.Hosts['github.com']     | Should -Be 'CodeHost'    # override wins
        $map.Hosts['z.ai']           | Should -Be 'Z-AI'        # built-in kept
        $map.SecondLevelSuffixes['or.tz'] | Should -BeTrue
        $map.SecondLevelSuffixes['go.ke'] | Should -BeTrue
        Get-SysOrgSourceBucket -HostUrl 'https://myportal.go.ke/x' -AppRoot $extApp | Should -Be 'MyPortal'
        Get-SysOrgSourceBucket -HostUrl 'https://sub.myportal.or.tz/x' -AppRoot $extApp | Should -Be 'MyPortal'
        Get-SysOrgSourceBucket -FileName 'MCHANGA-payout.pdf' -AppRoot $extApp | Should -Be 'Mchanga'
        Get-SysOrgSourceBucket -FileName 'WhatsApp Image 2024-01-01.jpg' -AppRoot $extApp | Should -Be 'WhatsApp'
    }

    It 'a broken Sources file fails closed with a clear message' {
        $badApp = Join-Path $TestDrive ('sources-bad-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $badApp 'Rules') -Force | Out-Null
        $broken = '@{ Hosts = @{ ''x'' = ''Unbalanced }'
        $broken | Set-Content -LiteralPath (Join-Path $badApp 'Rules\Sources.psd1') -Encoding UTF8
        { Get-SysOrgSourceMap -AppRoot $badApp } | Should -Throw '*could not be parsed*'
        { Get-SysOrgSourceBucket -HostUrl 'https://x.org/f' -AppRoot $badApp } | Should -Throw
    }

    It 'a Sources file with the wrong shape fails closed' {
        $shapeApp = Join-Path $TestDrive ('sources-shape-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $shapeApp 'Rules') -Force | Out-Null
        '@(1,2,3)' | Set-Content -LiteralPath (Join-Path $shapeApp 'Rules\Sources.psd1') -Encoding UTF8
        # a bare array is either refused by the data-file parser or by the shape check -
        # both fail closed with the file name in the message
        { Get-SysOrgSourceMap -AppRoot $shapeApp } | Should -Throw '*Sources.psd1*'
    }
}

Describe 'Family folder names: word-boundary truncation and common prefixes (v3.0.1 A5)' {

    It 'prefers the longest common word-prefix of the members over the longest stem' {
        $members = @(
            [pscustomobject]@{ Stem='Peer Education Support Supervision Report January' }
            [pscustomobject]@{ Stem='Peer Education Support Supervision Report February' }
            [pscustomobject]@{ Stem='Peer Education Support Supervision Report March' }
        )
        $name = Get-SysOrgFamilyFolderName -Members $members -MaxNameLength 60
        $name | Should -Be 'Peer Education Support Supervision Report'
    }

    It 'truncates an over-limit family name on a WORD boundary with a 4-char hash suffix' {
        $longName = 'Peer Education Support Supervision Report January February March April May June July August September October'
        $name = Get-SysOrgTruncatedFolderName -Name $longName -MaxLength 60
        $name.Length | Should -BeLessOrEqual 60
        $name | Should -Match '-[0-9a-f]{4}$'
        # never cut mid-word: what precedes the hash suffix ends a complete word
        $stem = $name.Substring(0, $name.Length - 5)
        $stem | Should -Match '\S$'
        $stem | Should -Not -Match '\s$'
        ($longName.ToLowerInvariant().StartsWith(($stem -replace '\s+',' ').ToLowerInvariant() + ' ')) | Should -BeTrue
        # the canonical example shape from the spec
        $name | Should -BeLike 'Peer Education Support*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
    }

    It 'is deterministic: same input -> same name; different inputs -> different suffixes' {
        $a = Get-SysOrgTruncatedFolderName -Name 'Quarterly Narrative Report For The Donor Funded Water Programme In The County Sub-Counties Phase One' -MaxLength 60
        $b = Get-SysOrgTruncatedFolderName -Name 'Quarterly Narrative Report For The Donor Funded Water Programme In The County Sub-Counties Phase One' -MaxLength 60
        $c = Get-SysOrgTruncatedFolderName -Name 'Quarterly Narrative Report For The Donor Funded Water Programme In The County Sub-Counties Phase Two' -MaxLength 60
        $a | Should -Be $b
        $a | Should -Not -Be $c
    }

    It 'falls back to the most-frequent stem when members share no common word' {
        $members = @(
            [pscustomobject]@{ Stem='invoice' }
            [pscustomobject]@{ Stem='receipt' }
            [pscustomobject]@{ Stem='receipt' }
        )
        (Get-SysOrgFamilyFolderName -Members $members -MaxNameLength 60) | Should -Be 'receipt'
    }

    It 'a single word longer than the limit is cut to the budget (documented last resort)' {
        $word = 'x' * 80
        $name = Get-SysOrgTruncatedFolderName -Name $word -MaxLength 60
        $name.Length | Should -BeLessOrEqual 60
        $name | Should -Match '-[0-9a-f]{4}$'
    }

    It 'names within the limit pass through sanitized and unchanged' {
        (Get-SysOrgTruncatedFolderName -Name 'Quarterly Narrative Report' -MaxLength 60) | Should -Be 'Quarterly Narrative Report'
        (Get-SysOrgCommonWordPrefix -Stems @('report')) | Should -Be 'report'
        (Get-SysOrgCommonWordPrefix -Stems @('alpha','beta')) | Should -BeNullOrEmpty
    }

    It 'a long family name can never push the full destination path past the 200-char budget' {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\SysOrg.Layout.psm1') -Force
        # the Findable layout enforces the path budget on the whole path
        $longFam = Get-SysOrgTruncatedFolderName -Name 'Peer Education Support Supervision Report January February March April May June July August September October November' -MaxLength 60
        $p = Compress-SysOrgFindablePath -Path ('C:\Organized\Documents\Work\2026\' + $longFam + '\a very long file name that also needs shortening eventually report.pdf') -Budget 200
        $p.Length | Should -BeLessOrEqual 200
    }
}

Describe 'Family folder name casing (v3.0.1 A5 regression)' {
    It 'keeps the members original casing: Report family stays Report, not report' {
        $members = @(
            [pscustomobject]@{ Stem='Report' }
            [pscustomobject]@{ Stem='Report - Copy' }
            [pscustomobject]@{ Stem='Report final v2' }
        )
        (Get-SysOrgFamilyFolderName -Members $members -MaxNameLength 60) | Should -Be 'Report'
        $members2 = @(
            [pscustomobject]@{ Stem='Peer Education Support Supervision Report January' }
            [pscustomobject]@{ Stem='peer education support supervision report FEBRUARY' }
        )
        # casing comes from the most frequent member carrying the prefix (natural tie-break)
        (Get-SysOrgFamilyFolderName -Members $members2 -MaxNameLength 60) | Should -Be 'Peer Education Support Supervision Report'
    }
}

Describe 'User collections detection (v3.0.1 B2)' {

    BeforeAll {
        function New-SysOrgB2Record {
            param([string]$Dir,[string]$Name,[string]$Ext,[string]$Cat)
            # string concat, NOT Join-Path: these are synthetic Windows-shaped paths and
            # pwsh on non-Windows hosts resolves drive-qualified Join-Path against providers
            [pscustomobject]@{ FullName=("$Dir\$Name"); Name=$Name; Stem=([System.IO.Path]::GetFileNameWithoutExtension($Name))
                Extension=$Ext; Length=[long]10; LastWriteTime=(Get-Date '2026-01-01'); Directory=$Dir; Category=$Cat }
        }
    }

    It 'detects a UNDP collection with a nested Workshop subfolder as ONE unit (outer wins)' {
        $root = 'C:\Users\t\Documents'
        $inv = @()
        foreach($i in 1..8){ $inv += New-SysOrgB2Record -Dir "$root\UNDP\Workshop" -Name "report $i.docx" -Ext '.docx' -Cat 'Documents' }
        foreach($i in 1..4){ $inv += New-SysOrgB2Record -Dir "$root\UNDP" -Name "summary $i.docx" -Ext '.docx' -Cat 'Documents' }
        $c = @(Get-SysOrgUserCollections -Inventory $inv -Roots @($root) -Config @{} -KnownFolders @())
        $c.Count | Should -Be 1
        $c[0].Name | Should -Be 'UNDP'
        $c[0].Files | Should -Be 12
        $c[0].MajorityCategory | Should -Be 'Documents'
        $c[0].MajorityRatio | Should -Be 1.0
    }

    It 'generic names, bare dates and camera defaults are never collections' {
        $root = 'C:\Users\t\Documents'
        $inv = @()
        foreach($d in @('New folder','2024','2024-06','IMG_0001','Screenshots','WhatsApp Video')){
            foreach($i in 1..6){ $inv += New-SysOrgB2Record -Dir "$root\$d" -Name "file$i.txt" -Ext '.txt' -Cat 'Documents' }
        }
        $c = @(Get-SysOrgUserCollections -Inventory $inv -Roots @($root) -Config @{} -KnownFolders @())
        $c.Count | Should -Be 0
    }

    It 'respects the bounds: subtrees over Folders.MaxFiles and folders beyond Folders.MaxDepth disqualify' {
        $root = 'C:\Users\t\Documents'
        $big = @(); foreach($i in 1..201){ $big += New-SysOrgB2Record -Dir "$root\Huge" -Name "f$i.txt" -Ext '.txt' -Cat 'Documents' }
        @(Get-SysOrgUserCollections -Inventory $big -Roots @($root) -Config @{} -KnownFolders @()).Count | Should -Be 0
        # a folder whose FILE-BEARING candidates sit beyond MaxDepth under excluded
        # (generic/date) ancestors is never a collection
        $deep = @(); foreach($i in 1..5){ $deep += New-SysOrgB2Record -Dir "$root\New folder\2024\06\15" -Name "f$i.txt" -Ext '.txt' -Cat 'Documents' }
        @(Get-SysOrgUserCollections -Inventory $deep -Roots @($root) -Config @{} -KnownFolders @()).Count | Should -Be 0
        # a folder at depth 2 within the bound IS a unit even under excluded ancestors
        $mid = @(); foreach($i in 1..5){ $mid += New-SysOrgB2Record -Dir "$root\New folder\2024\UNDP" -Name "r$i.docx" -Ext '.docx' -Cat 'Documents' }
        $c = @(Get-SysOrgUserCollections -Inventory $mid -Roots @($root) -Config @{} -KnownFolders @())
        ($c | Where-Object Name -eq 'UNDP').Count | Should -Be 1
        # a folder containing ONLY subfolders is still the outer unit (structure intact)
        $nested = @(); foreach($i in 1..5){ $nested += New-SysOrgB2Record -Dir "$root\Programme X\Workshop" -Name "r$i.docx" -Ext '.docx' -Cat 'Documents' }
        $c2 = @(Get-SysOrgUserCollections -Inventory $nested -Roots @($root) -Config @{} -KnownFolders @())
        ($c2 | Where-Object Name -eq 'Programme X').Count | Should -Be 1
    }

    It 'reports mixed-content candidates with their honest majority ratio' {
        $root = 'C:\Users\t\Documents'
        $inv = @()
        foreach($i in 1..5){ $inv += New-SysOrgB2Record -Dir "$root\Mixed" -Name "doc$i.docx" -Ext '.docx' -Cat 'Documents' }
        foreach($i in 1..5){ $inv += New-SysOrgB2Record -Dir "$root\Mixed" -Name "pic$i.jpg" -Ext '.jpg' -Cat 'Images' }
        $c = @(Get-SysOrgUserCollections -Inventory $inv -Roots @($root) -Config @{} -KnownFolders @())
        ($c | Where-Object Name -eq 'Mixed').MajorityRatio | Should -Be 0.5
    }

    It 'PreserveUserCollections=$false disables detection' {
        $root = 'C:\Users\t\Documents'
        $inv = @(); foreach($i in 1..6){ $inv += New-SysOrgB2Record -Dir "$root\UNDP" -Name "r$i.docx" -Ext '.docx' -Cat 'Documents' }
        @(Get-SysOrgUserCollections -Inventory $inv -Roots @($root) -Config @{ Folders=@{ PreserveUserCollections=$false } } -KnownFolders @()).Count | Should -Be 0
    }
}
