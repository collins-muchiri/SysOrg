# Tests/SysOrg.Layout.Tests.ps1
# Covers v3.0 Phase 1: the Findable layout.
#   - LayoutProfile resolution (explicit wins, legacy configs keep Windows,
#     new installs default to Findable)
#   - subtype + leaf routing (the Findable tree)
#   - adaptive date granularity: split above the cap, merge back when mostly
#     near-empty, cap always wins
#   - path budget compression (deterministic, collision-free)
#   - plan integration: Findable destinations, depth <= 4, legacy profile unchanged

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')      -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Score.psm1')       -Force
    $script:fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
    $script:baseCfg = @{
        # v3.0.1: AppRoot must be a DEDICATED folder, never an ancestor of the
        # fixtures. The app root (and everything inside it) is protected by the
        # exclusion engine; on Windows $TestDrive sits under %TEMP% and every
        # fixture would have matched it, silently zeroing every plan. The same
        # check is inert on Unix-path hosts, which is why this only broke on CI.
        AppRoot        = (Join-Path $TestDrive 'app')
        LayoutProfile  = 'Findable'
        OrganizedRoots = @{ '*' = '__AUTO__' }
        Copies         = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=0; HeaderHashKB=64 }
        Families       = @{ Enabled=$false }
        Downloads      = @{ UseZoneIdentifier=$false }
        Move           = @{ AllowCrossVolume = $true }
        ExcludedPaths  = @()
        ExcludedFilePatterns = @()
        SkipHiddenSystemFiles = $true
        ExcludeDestinations = $true
        PreserveExistingFolders = $false
        DateFolders = 'Year'
        FolderAudit = @{ Enabled = $false }
        TypeMap = @{}
        Layout = @{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
        Review = @{ Mode='Report'; FolderName='_Review' }
    }
}

Describe 'LayoutProfile resolution' {

    It 'an explicit LayoutProfile always wins' {
        (Get-SysOrgLayoutProfile -Config @{ LayoutProfile='Findable'; NamingPreset='Windows' }) | Should -Be 'Findable'
        (Get-SysOrgLayoutProfile -Config @{ LayoutProfile='Windows' })  | Should -Be 'Windows'
    }

    It 'NamingPreset Compact4 maps to the Compact4 profile when no LayoutProfile is set' {
        (Get-SysOrgLayoutProfile -Config @{ NamingPreset='Compact4' }) | Should -Be 'Compact4'
    }

    It 'defaults to Windows (the v2.1 behaviour) when nothing is set' {
        (Get-SysOrgLayoutProfile -Config @{}) | Should -Be 'Windows'
    }

    It 'rejects an unknown profile' {
        { Get-SysOrgLayoutProfile -Config @{ LayoutProfile='Chaos' } } | Should -Throw '*LayoutProfile*'
    }

    It 'a fresh install (no config file) defaults to Findable; an existing config without the key keeps Windows' {
        $tmpCfg = Join-Path $TestDrive 'legacy.psd1'
        Set-Content -LiteralPath $tmpCfg -Value '@{ OrganizedRoots = @{ C = "C:\Org" } }' -Encoding UTF8
        (Import-SysOrgConfig -Path $null -AppRoot $TestDrive).LayoutProfile | Should -Be 'Findable'
        (Import-SysOrgConfig -Path $tmpCfg -AppRoot $TestDrive).LayoutProfile | Should -Be 'Windows'
        Set-Content -LiteralPath $tmpCfg -Value "@{ OrganizedRoots = @{ C = 'C:\Org' }; LayoutProfile = 'Findable' }" -Encoding UTF8
        (Import-SysOrgConfig -Path $tmpCfg -AppRoot $TestDrive).LayoutProfile | Should -Be 'Findable'
    }
}

Describe 'Findable subtype and leaf routing' {

    It 'routes document subtypes by name tokens' {
        (Get-SysOrgFindableSubtype -Category 'Documents' -Name 'Invoice KRA 2024-001.pdf') | Should -Be 'Finance\Invoices'
        (Get-SysOrgFindableSubtype -Category 'Documents' -Name 'Receipt supermarket.txt') | Should -Be 'Finance\Receipts'
        (Get-SysOrgFindableSubtype -Category 'Documents' -Name 'KRA PAYE return.pdf') | Should -Be 'Finance\Tax'
        (Get-SysOrgFindableSubtype -Category 'Documents' -Name 'Employment contract.pdf') | Should -Be 'Legal-Identity'
        (Get-SysOrgFindableSubtype -Category 'Documents' -Name 'Printer manual.pdf') | Should -Be 'Manuals'
        (Get-SysOrgFindableSubtype -Category 'Documents' -Name 'MSc thesis.pdf') | Should -Be 'Education'
        (Get-SysOrgFindableSubtype -Category 'Documents' -Name 'random note.txt') | Should -Be 'General'
    }

    It 'routes pictures and videos by context' {
        (Get-SysOrgFindableSubtype -Category 'Pictures' -Name 'Screenshot_2024-01-01.png') | Should -Be 'Screenshots'
        (Get-SysOrgFindableSubtype -Category 'Pictures' -Name 'photo scan old.jpg') | Should -Be 'Scans'
        (Get-SysOrgFindableSubtype -Category 'Pictures' -Name 'IMG_0001.jpg' -Source 'WhatsApp') | Should -Be 'Messaging'
        (Get-SysOrgFindableSubtype -Category 'Videos' -Name 'screen recording demo.mp4') | Should -Be 'Screen-Recordings'
        (Get-SysOrgFindableSubtype -Category 'Videos' -Name 'VID_0001.mp4') | Should -Be 'Media'
    }

    It 'routes audio by naming context (tagged music arrives in Phase 2)' {
        (Get-SysOrgFindableSubtype -Category 'Audio' -Name 'VOICE_2024-01-01-WA0001.m4a') | Should -Be 'VoiceNote'
        (Get-SysOrgFindableSubtype -Category 'Audio' -Name 'song123.mp3') | Should -Be 'UntaggedMusic'
    }

    It 'maps categories to Findable leaf bases' {
        (Get-SysOrgFindableRelBase -Category 'Documents' -Subtype 'Finance\Invoices').RelBase | Should -Be 'Documents\Finance\Invoices'
        (Get-SysOrgFindableRelBase -Category 'Audio' -Subtype 'VoiceNote').RelBase | Should -Be 'Audio-Recordings'
        (Get-SysOrgFindableRelBase -Category 'Spreadsheets' -Subtype 'Data').RelBase | Should -Be 'Data'
        (Get-SysOrgFindableRelBase -Category 'Installers' -Subtype 'InstallerApp' -Name 'setup-vlc-3.exe').RelBase | Should -Be 'Software\Installers\Vlc'
        (Get-SysOrgFindableRelBase -Category 'Fonts' -Subtype 'Fonts').RelBase | Should -Be 'Design\Fonts'
        (Get-SysOrgFindableRelBase -Category 'Pictures' -Subtype 'Messaging' -Source 'WhatsApp').RelBase | Should -Be 'Pictures\Messaging\WhatsApp'
        (Get-SysOrgFindableRelBase -Category 'Music' -Subtype 'TaggedMusic' -Artist 'Sauti Sol' -Album 'Live').RelBase | Should -Be 'Music\Sauti Sol\Live'
        (Get-SysOrgFindableRelBase -Category 'Documents' -Subtype 'General' -InDownloads $true -TypeLeaf 'Documents').RelBase | Should -Be 'Downloads\_NoSource\Documents'
    }

    It 'the Downloads provenance branch keeps its shape' {
        (Get-SysOrgFindableTypeLeaf -Category 'Spreadsheets') | Should -Be 'Data'
        (Get-SysOrgFindableTypeLeaf -Category 'Whatever') | Should -Be 'Files'
    }

    It 'exposes exactly 10 routing roots plus the app-managed exempt roots' {
        $t = Get-SysOrgFindableTopLevel
        @($t.Roots).Count | Should -Be 10
        @($t.Exempt) | Should -Contain 'Downloads'
        @($t.Exempt) | Should -Contain '_Index'
    }
}

Describe 'Adaptive date granularity' {

    It 'small leaves stay at Year granularity' {
        $recs = @()
        for($i=0; $i -lt 30; $i++){
            $recs += [pscustomobject]@{ Key='Documents\General'; FileKey="f$i"; Date=[datetime]::new(2024,1,(($i % 28)+1)); Family=$false }
        }
        $seg = Add-SysOrgFindableDateSegments -Records $recs -Cap 150 -MinPerFolder 8
        $seg['documents\general']['f0'] | Should -Be '2024'
        $seg['documents\general']['f29'] | Should -Be '2024'
    }

    It 'a leaf above the cap with well-populated months splits to YYYY-MM' {
        $recs = @()
        # 2 months x 100 files: no month over the cap, no mostly-near-empty split
        for($i=0; $i -lt 100; $i++){ $recs += [pscustomobject]@{ Key='Data'; FileKey="a$i"; Date=[datetime]::new(2024,3,((($i % 28)+1))); Family=$false } }
        for($i=0; $i -lt 100; $i++){ $recs += [pscustomobject]@{ Key='Data'; FileKey="b$i"; Date=[datetime]::new(2024,4,((($i % 28)+1))); Family=$false } }
        $seg = Add-SysOrgFindableDateSegments -Records $recs -Cap 150 -MinPerFolder 8
        $seg['data']['a0'] | Should -Be '2024-03'
        $seg['data']['b0'] | Should -Be '2024-04'
    }

    It 'a split that would leave most buckets near-empty merges back to Year' {
        $recs = @()
        # 10 years x 20 files = 200 > 150; months would be 120 buckets of ~2 -> merge to years
        for($y=2015; $y -le 2024; $y++){
            for($i=0; $i -lt 20; $i++){
                $recs += [pscustomobject]@{ Key='Archives'; FileKey=('{0}-{1}' -f $y,$i); Date=[datetime]::new($y,((($i % 12)+1)),5); Family=$false }
            }
        }
        $seg = Add-SysOrgFindableDateSegments -Records $recs -Cap 150 -MinPerFolder 8
        $seg['archives']['2015-0'] | Should -Be '2015'
        $seg['archives']['2024-19'] | Should -Be '2024'
    }

    It 'a month still above the cap splits to YYYY-MM-DD (the cap wins)' {
        $recs = @()
        for($i=0; $i -lt 200; $i++){ $recs += [pscustomobject]@{ Key='Pictures\Camera'; FileKey="p$i"; Date=[datetime]::new(2024,3,((($i % 28)+1))); Family=$false } }
        $seg = Add-SysOrgFindableDateSegments -Records $recs -Cap 150 -MinPerFolder 8
        $seg['pictures\camera']['p0'] | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'family leaves keep related files together (no date segment) when under the cap' {
        $recs = @()
        for($i=0; $i -lt 40; $i++){ $recs += [pscustomobject]@{ Key='Documents\Work'; FileKey="w$i"; Date=[datetime]::new(2024,1,1); Family=$true } }
        $seg = Add-SysOrgFindableDateSegments -Records $recs -Cap 150 -MinPerFolder 8
        $seg['documents\work']['w0'] | Should -Be ''
    }

    It 'is deterministic for identical inputs' {
        $recs = @()
        for($i=0; $i -lt 200; $i++){ $recs += [pscustomobject]@{ Key='Pictures\Camera'; FileKey="p$i"; Date=[datetime]::new(2024,3,((($i % 28)+1))); Family=$false } }
        $arr = @($recs)
        $s1 = Add-SysOrgFindableDateSegments -Records $arr -Cap 150 -MinPerFolder 8
        $s2 = Add-SysOrgFindableDateSegments -Records $arr -Cap 150 -MinPerFolder 8
        ($s1 | ConvertTo-Json -Depth 4 -Compress) | Should -Be ($s2 | ConvertTo-Json -Depth 4 -Compress)
    }
}

Describe 'Path budget compression' {

    It 'short paths pass through unchanged' {
        $p = 'C:\Org\Documents\General\2024\note.txt'
        (Compress-SysOrgFindablePath -Path $p -Budget 200) | Should -Be $p
    }

    It 'long paths come back inside the budget and stay deterministic' {
        $longName = 'x' * 180
        $p = "C:\Org\Documents\Finance\Invoices\$longName\2024\report.pdf"
        $c1 = Compress-SysOrgFindablePath -Path $p -Budget 200
        $c2 = Compress-SysOrgFindablePath -Path $p -Budget 200
        $c1.Length | Should -BeLessOrEqual 200
        $c1 | Should -Be $c2
    }

    It 'different long names never collapse into the same shortened segment' {
        $a = Compress-SysOrgFindablePath -Path ("C:\Org\Documents\" + ('a' * 120) + "\2024\file.txt") -Budget 60
        $b = Compress-SysOrgFindablePath -Path ("C:\Org\Documents\" + ('b' * 120) + "\2024\file.txt") -Budget 60
        $a | Should -Not -Be $b
        (Split-Path $a -Parent) | Should -Not -Be (Split-Path $b -Parent)
    }

    It 'shortens the file name stem last and preserves the extension' {
        $p = 'C:\Org\D\' + ('n' * 180) + '.pdf'
        $c = Compress-SysOrgFindablePath -Path $p -Budget 80
        $c.Length | Should -BeLessOrEqual 80
        $c | Should -Match '\.pdf$'
        $c | Should -Not -Match 'nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn'
    }
}

Describe 'Findable plan integration' {

    It 'plans Findable destinations with depth <= 4 below the root and only Findable roots' {
        $work = Join-Path $TestDrive ('findable-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $inv = @()
        $kindMap = @(
            @{ N='Invoice KRA 2024-001.pdf'; C='Documents' },
            @{ N='photo holiday.jpg';        C='Pictures' },
            @{ N='screen recording.mp4';     C='Videos' },
            @{ N='VOICE_2024-WA1.m4a';       C='Audio' },
            @{ N='export-data.csv';          C='Spreadsheets' },
            @{ N='bundle.zip';               C='Archives' },
            @{ N='widget.js';                C='Code' },
            @{ N='logo.psd';                 C='Images' },
            @{ N='Roboto.ttf';               C='Fonts' },
            @{ N='random note.txt';          C='Documents' }
        )
        $i = 0
        foreach($k in $kindMap){
            for($c = 0; $c -lt 3; $c++){
                $i++
                $dir = Join-Path $work 'src'
                # keep name patterns realistic; voice notes must START with 'VOICE'
                $name = if($k.C -eq 'Audio'){ ('VOICE_2024-0{0}-WA1.m4a' -f $c) } else { ("{0}-{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($k.N), $c, [System.IO.Path]::GetExtension($k.N)) }
                $fp = Join-Path $dir $name
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Set-Content -LiteralPath $fp -Value ('x' * 30) -Encoding ASCII
                # the v3.0 pipeline reads the REAL file: min(Creation,LastWrite) needs both set
                $stamp = Get-Date '2024-06-15'
                $fi = Get-Item -LiteralPath $fp
                $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
                $inv += [pscustomobject]@{ FullName=$fp; Name=$name
                    Stem=[System.IO.Path]::GetFileNameWithoutExtension($name); Extension=[System.IO.Path]::GetExtension($name)
                    Length=30; LastWriteTime=$stamp; Directory=$dir; Category=$k.C }
            }
        }
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        (@($plan.Actions).Count) | Should -Be 30
        $tops = New-Object System.Collections.Generic.HashSet[string]
        $maxDepth = 0
        foreach($a in @($plan.Actions)){
            $rel = "$($a.Destination)"
            $rel = $rel.Substring($plan.DestinationRoot.Length).TrimStart('\')
            $segs = @($rel.Split('\') | Where-Object { "$_" -ne '' })
            [void]$tops.Add($segs[0])
            $maxDepth = [Math]::Max($maxDepth, $segs.Count - 1)   # depth of the file's folder
            if($segs.Count -gt 1){ $maxDepth = [Math]::Max($maxDepth, $segs.Count - 1) }
        }
        $allowed = @(Get-SysOrgFindableTopLevel)
        foreach($t in $tops){ (@($allowed.Roots) + @($allowed.Exempt)) | Should -Contain $t }
        # folder depth (excluding the file name) must respect Layout.MaxDepth = 4
        foreach($a in @($plan.Actions)){
            $rel = "$($a.Destination)".Substring($plan.DestinationRoot.Length).TrimStart('\')
            $segs = @($rel.Split('\') | Where-Object { "$_" -ne '' })
            ($segs.Count - 1) | Should -BeLessOrEqual 4
        }
        # spot checks of the tree shape
        $dests = @(@($plan.Actions) | ForEach-Object { "$($_.Destination)".Substring($plan.DestinationRoot.Length).TrimStart('\') })
        @($dests | Where-Object { $_ -like 'Documents\Finance\Invoices\2024\*' }).Count | Should -Be 3
        @($dests | Where-Object { $_ -like 'Pictures\Camera\2024\*' }).Count | Should -Be 3
        @($dests | Where-Object { $_ -like 'Audio-Recordings\2024\*' }).Count | Should -Be 3
        @($dests | Where-Object { $_ -like 'Data\2024\*' }).Count | Should -Be 3
        @($dests | Where-Object { $_ -like 'Design\Fonts\*' }).Count | Should -Be 3
        @($dests | Where-Object { $_ -like 'Documents\General\2024\*' }).Count | Should -Be 3
    }

    It 'installers inside download roots use the Downloads provenance branch' {
        $work = Join-Path $TestDrive ('findable-dl-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $work 'src') -Force | Out-Null
        $prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@((Join-Path $work 'src')); Artifacts=@(); TopLevelDirs=@() }
        $inv = @([pscustomobject]@{ FullName=(Join-Path $work 'src\setup-vlc-3.0.exe'); Name='setup-vlc-3.0.exe'; Stem='setup-vlc-3.0'
            Extension='.exe'; Length=10; LastWriteTime=(Get-Date '2024-06-15'); Directory=(Join-Path $work 'src'); Category='Installers' })
        New-Item -ItemType Directory -Path (Join-Path $work 'src') -Force | Out-Null
        $exePath = Join-Path $work 'src\setup-vlc-3.0.exe'
        Set-Content -LiteralPath $exePath -Value 'MZ fake installer' -Encoding ASCII
        $stampExe = Get-Date '2024-06-15'
        $fiExe = Get-Item -LiteralPath $exePath
        $fiExe.CreationTime = $stampExe; $fiExe.LastWriteTime = $stampExe
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $prof -Config $script:baseCfg
        (@($plan.Actions).Count) | Should -Be 1
        "$(@($plan.Actions)[0].Destination)" | Should -BeLike '*Downloads\_NoSource\Software\2024\setup-vlc-3.0.exe'
    }

    It 'the legacy Windows profile plans exactly like v2.1 (no Findable tree)' {
        $legacyCfg = @{} + $script:baseCfg
        $legacyCfg.LayoutProfile = 'Windows'
        $dir = Join-Path $TestDrive 'src-legacy'
        $inv = @([pscustomobject]@{ FullName=(Join-Path $dir 'Invoice KRA.pdf'); Name='Invoice KRA.pdf'; Stem='Invoice KRA'
            Extension='.pdf'; Length=10; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Documents' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $legacyCfg
        "$(@($plan.Actions)[0].Destination)" | Should -BeLike '*\Documents\2024\Invoice KRA.pdf'
        "$(@($plan.Actions)[0].Destination)" | Should -Not -BeLike '*Finance*'
    }

    It 'the same input produces an identical plan (determinism, modulo the plan id stamp)' {
        $dir = Join-Path $TestDrive 'src-det'
        $inv = @()
        foreach($n in @('a.txt','b.pdf','c.jpg','d.mp3','e.zip','f.csv')){
            $inv += [pscustomobject]@{ FullName=(Join-Path $dir $n); Name=$n
                Stem=[System.IO.Path]::GetFileNameWithoutExtension($n); Extension=[System.IO.Path]::GetExtension($n)
                Length=10; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Documents' }
        }
        $p1 = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        $p2 = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        (@($p1.Actions) | ForEach-Object { "$($_.Source)->$($_.Destination)" }) -join '|' |
            Should -Be ((@($p2.Actions) | ForEach-Object { "$($_.Source)->$($_.Destination)" }) -join '|')
    }

    It 'keeps the destination inside the 200-character budget' {
        $dir = Join-Path $TestDrive 'src-long'
        $longName = ('very long invoice name ' * 10).Trim() + '.pdf'
        $inv = @([pscustomobject]@{ FullName=(Join-Path $dir $longName); Name=$longName; Stem=$longName
            Extension='.pdf'; Length=10; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Documents' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        foreach($a in @($plan.Actions)){
            "$($a.Destination)".Length | Should -BeLessOrEqual 200
        }
    }
}

Describe 'Findable plan: full pipeline integration (Phase 2.9)' {

    BeforeAll {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\SysOrg.Metadata.psm1') -Force
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\SysOrg.Classify.psm1') -Force
    }

    It 'a tax document routes via the lexicon with confidence on the action' {
        $dir = Join-Path $TestDrive 'src-lex'
        $txt = Join-Path $dir 'KRA PAYE return 2024.txt'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath $txt -Value 'KENYA PAYE tax return for 2024. VAT and withholding tax. itax pin P051234456X.' -Encoding UTF8
        $stamp = Get-Date '2024-06-15'
        $fi = Get-Item -LiteralPath $txt
        $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
        $inv = @([pscustomobject]@{ FullName=$txt; Name='KRA PAYE return 2024.txt'; Stem='KRA PAYE return 2024'
            Extension='.txt'; Length=90; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Documents' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        (@($plan.Actions).Count) | Should -Be 1
        $a = @($plan.Actions)[0]
        "$($a.Destination)" | Should -BeLike '*Documents\Finance\Tax\2024\KRA PAYE return 2024.txt'
        $a.RuleId | Should -Be 'lexicon'
        $a.Confidence | Should -BeGreaterOrEqual 0.70
        $a.ReviewFlag | Should -BeFalse
    }

    It 'an unplaceable file is left in place and listed as needing a decision' {
        $dir = Join-Path $TestDrive 'src-mystery'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'blob.bin'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(1,2,3,4,5,6,7,8,9,10,11,12))
        $stampB1 = Get-Date '2024-06-15'
        $fiB1 = Get-Item -LiteralPath $p
        $fiB1.CreationTime = $stampB1; $fiB1.LastWriteTime = $stampB1
        $inv = @([pscustomobject]@{ FullName=$p; Name='blob.bin'; Stem='blob'
            Extension='.bin'; Length=12; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Other' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        (@($plan.Actions).Count) | Should -Be 0
        @($plan.NeedsDecision).Count | Should -Be 1
        $plan.NeedsDecision[0].Disposition | Should -Be 'left in place'
        (@($plan.Skipped) | Where-Object { $_.Reason -like 'Needs a decision*' }).Count | Should -Be 1
    }

    It 'Review.Mode=Move files unplaceable files under _Review\<Year> (still previewed)' {
        $cfg2 = @{} + $script:baseCfg
        $cfg2.Review = @{ Mode='Move'; FolderName='_Review' }
        $dir = Join-Path $TestDrive 'src-mystery2'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'blob2.bin'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(1,2,3,4,5,6,7,8,9,10,11,12))
        $stampB = Get-Date '2024-06-15'
        $fiB = Get-Item -LiteralPath $p
        $fiB.CreationTime = $stampB; $fiB.LastWriteTime = $stampB
        $inv = @([pscustomobject]@{ FullName=$p; Name='blob2.bin'; Stem='blob2'
            Extension='.bin'; Length=12; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Other' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $cfg2
        (@($plan.Actions).Count) | Should -Be 1
        "$(@($plan.Actions)[0].Destination)" | Should -BeLike '*_Review\*\blob2.bin'
    }

    It 'a user rule wins over the built-in pipeline and its template expands' {
        $rulesPath = Join-Path $TestDrive 'UserRules2.psd1'
        Set-Content -LiteralPath $rulesPath -Value "@{ Rules = @( @{ Name='tax-pdf'; Priority=1; When=@{ NameRegex='(?i)kra' }; Destination='Documents\Work\{Year}' } ) }" -Encoding UTF8
        $cfg2 = @{} + $script:baseCfg
        $cfg2.Rules = @{ UserRulesPath=$rulesPath; LexiconPath=''; ApplyLearned=$false; LearnedRulesPath='' }
        $dir = Join-Path $TestDrive 'src-rule'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'KRA payment slip.txt'
        Set-Content -LiteralPath $p -Value 'payment received' -Encoding UTF8
        $stampRule = Get-Date '2024-06-15'
        $fiRule = Get-Item -LiteralPath $p
        $fiRule.CreationTime = $stampRule; $fiRule.LastWriteTime = $stampRule
        $inv = @([pscustomobject]@{ FullName=$p; Name='KRA payment slip.txt'; Stem='KRA payment slip'
            Extension='.txt'; Length=20; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Documents' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $cfg2
        (@($plan.Actions).Count) | Should -Be 1
        "$(@($plan.Actions)[0].Destination)" | Should -BeLike '*Documents\Work\2024\KRA payment slip.txt'
        (@($plan.Actions)[0].RuleId) | Should -Be 'user:tax-pdf'
    }

    It 'tagged music routes to Music\<Artist>\<Album> without a date segment' {
        $dir = Join-Path $TestDrive 'src-music'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'song.mp3'
        [System.IO.File]::WriteAllBytes($p, [System.Text.Encoding]::ASCII.GetBytes('ID3' + [char]3 + [char]0 + 'some mp3 bytes here for the test file'))
        $stampM = Get-Date '2024-06-15'
        $fiM = Get-Item -LiteralPath $p
        $fiM.CreationTime = $stampM; $fiM.LastWriteTime = $stampM
        $inv = @([pscustomobject]@{ FullName=$p; Name='song.mp3'; Stem='song'
            Extension='.mp3'; Length=40; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Audio' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        (@($plan.Actions).Count) | Should -Be 1
        # no ID3 artist -> _Untagged with a date segment
        "$(@($plan.Actions)[0].Destination)" | Should -BeLike '*Music\_Untagged\2024\song.mp3'
    }

    It 'a 20-photo burst routes to Pictures\Events\<range>' {
        $dir = Join-Path $TestDrive 'src-event'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $inv = @()
        $base = [datetime]::new(2024,6,1,9,0,0)
        for($i=0; $i -lt 20; $i++){
            $p = Join-Path $dir ('IMG_{0:D4}.jpg' -f $i)
            Set-Content -LiteralPath $p -Value ('x' * 30) -Encoding ASCII
            $stampI = $base.AddMinutes($i)
            $fiI = Get-Item -LiteralPath $p
            $fiI.CreationTime = $stampI; $fiI.LastWriteTime = $stampI
            $inv += [pscustomobject]@{ FullName=$p; Name=('IMG_{0:D4}.jpg' -f $i); Stem=('IMG_{0:D4}' -f $i)
                Extension='.jpg'; Length=30; LastWriteTime=$base.AddMinutes($i); Directory=$dir; Category='Pictures' }
        }
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        (@($plan.Actions).Count) | Should -Be 20
        "$(@($plan.Actions)[0].Destination)" | Should -BeLike '*Pictures\Events\2024-06-01 to 06-01\IMG_*.jpg'
    }

    It 'an invalid user-rules file fails the whole plan (fail closed)' {
        $bad = Join-Path $TestDrive 'BadRulesPlan.psd1'
        Set-Content -LiteralPath $bad -Value "@{ Rules = @( @{ Name='r'; Priority=1; When=@{ NameRegex='(' }; Destination='X' } ) }" -Encoding UTF8
        $cfg2 = @{} + $script:baseCfg
        $cfg2.Rules = @{ UserRulesPath=$bad; LexiconPath=''; ApplyLearned=$false; LearnedRulesPath='' }
        $dir = Join-Path $TestDrive 'src-badrules'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'note.txt'
        Set-Content -LiteralPath $p -Value 'hi' -Encoding ASCII
        $inv = @([pscustomobject]@{ FullName=$p; Name='note.txt'; Stem='note'
            Extension='.txt'; Length=2; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Documents' })
        { New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $cfg2 } | Should -Throw '*NameRegex*'
    }
}
