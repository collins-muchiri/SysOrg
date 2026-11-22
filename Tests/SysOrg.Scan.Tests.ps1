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
