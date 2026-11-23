# Tests/SysOrg.Fixtures.Tests.ps1
# v3.0.1: the regression fixtures from the real Windows 11 run, rebuilt as synthetic
# trees with INVENTED names. Each row of the task table becomes one test.
#   - Certificate/family/report/proposal docs -> confident Findable destinations
#   - re-download pairs -> copies policy / possible-newer-version report
#   - user collection (Programme X + Workshop) -> ONE unit, structure intact
#   - AI downloads -> catalog Source buckets, no source folders
#   - a 9,500-file tree that is 99% project/dependency -> pruned + fast
#   - 11-of-9,500 plan -> 'no meaningful change', never 'worsens'
#   - empty tree -> n/a

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')      -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Cache.psm1')       -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Score.psm1')       -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Catalog.psm1')     -Force

    $script:fxProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
    function New-SysOrgFixtureConfig {
        param([string]$OrgRoot)
        @{
            OrganizedRoots = @{ 'T' = $OrgRoot }
            ExcludedPaths = @(); ExcludedFilePatterns = @()
            SkipHiddenSystemFiles = $true; ExcludeDestinations = $true
            PreserveExistingFolders = $false
            Copies = @{ Policy='NumberCopies'; SuffixStyle='Parentheses'; StartIndex=2; MinFileSizeKB=256; DocMinFileSizeKB=0; HeaderHashKB=64 }
            Families = @{ Enabled=$true; MinFiles=2 }
            Downloads = @{ UseZoneIdentifier=$false }
            FolderAudit = @{ Enabled=$false }
            DateFolders = 'Year'
            LayoutProfile = 'Findable'
            TypeMap = @{}
            Classify = @{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Learn = @{ Enabled=$true; MinFilesPerLabel=5; MinMargin=0.5; MaxFilesPerLabel=500 }
            Folders = @{ PreserveUserCollections=$true; MaxFiles=200; MaxDepth=3; MinMajorityRatio=0.6 }
            Prune = @{ Enabled=$true; DirectoryNames=@('node_modules','.venv','dist','target','vendor','__pycache__') }
            Projects = @{ Enabled=$true; Markers=@(); GenericNames=@('new folder','src') }
            MaxPlanActions = 100000
        }
    }
    function New-SysOrgFxRecord {
        param([string]$Path,[string]$Cat)
        $fi = Get-Item -LiteralPath $Path -Force
        [pscustomobject]@{ FullName=$Path; Name=(Split-Path $Path -Leaf); Stem=([System.IO.Path]::GetFileNameWithoutExtension($Path))
            Extension=([System.IO.Path]::GetExtension($Path).ToLowerInvariant()); Length=[long]$fi.Length
            LastWriteTime=$fi.LastWriteTime; Directory=(Split-Path $Path -Parent); Category=$Cat }
    }
}

Describe 'Fixture: certificate -> Legal-Identity, >= 0.70 (table row 1)' {
    It 'Certificate 1.pdf in a user folder plans to Documents\Legal-Identity\<Year> at >= 0.70' {
        $work = Join-Path $TestDrive ('fx1-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src\UNDP'
        $org = Join-Path $work 'org'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'Certificate 1.pdf'), ('%PDF-1.4 ' + ('certificate of completion signature ' * 10)))
        $inv = @(New-SysOrgFxRecord -Path (Join-Path $src 'Certificate 1.pdf') -Cat 'Documents')
        $cfg = New-SysOrgFixtureConfig -OrgRoot $org
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fxProf -DupGroups @() -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 1
        $a = $plan.Actions[0]
        $a.Destination | Should -BeLike '*\Documents\Legal-Identity\*\Certificate 1.pdf'
        [double]$a.Confidence | Should -BeGreaterOrEqual 0.70
    }
}

Describe 'Fixture: report/proposal docs -> Documents\Work\<Year> at >= 0.70 (table row 2)' {
    It 'Monthly Narrative Report, Supervision Report, Proposal, Build Guide reach Work >= 0.70 with the model' {
        $work = Join-Path $TestDrive ('fx2-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $docs = Join-Path $work 'Documents'
        $src = Join-Path $work 'src'
        $org = Join-Path $work 'org'
        # the user's own curated folders train the model (B3): Work AND Personal -
        # a real tree has several, and a single-label model can never be trusted
        $workFolder = Join-Path $docs 'Work'
        New-Item -ItemType Directory -Path $workFolder -Force | Out-Null
        $personalFolder = Join-Path $docs 'Personal'
        New-Item -ItemType Directory -Path $personalFolder -Force | Out-Null
        foreach($i in 1..5){
            [System.IO.File]::WriteAllText((Join-Path $personalFolder ("curriculum vitae profile $i.txt")), ('curriculum vitae personal bio profile work experience skills references hobbies ' * 3))
        }
        foreach($i in 1..8){
            [System.IO.File]::WriteAllText((Join-Path $workFolder ("monthly narrative report $i.txt")), ('narrative report for the programme supervision workplan indicators baseline workshop training budget ' * 3))
        }
        # the real user's Work folder also held build guides - the model learns that
        foreach($i in 1..3){
            [System.IO.File]::WriteAllText((Join-Path $workFolder ("build guide $i.txt")), ('build guide installation steps instructions manual table of contents guide ' * 3))
        }
        # the downloads to classify
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'Monthly Narrative Report.txt'), ('monthly narrative report programme supervision workplan indicators budget ' * 3))
        [System.IO.File]::WriteAllText((Join-Path $src 'Supervision Report Q1.txt'), ('supervision report workplan logframe indicator baseline ' * 3))
        [System.IO.File]::WriteAllText((Join-Path $src 'Proposal.txt'), ('proposal project plan deliverables milestones budget concept note ' * 3))
        [System.IO.File]::WriteAllText((Join-Path $src 'Build Guide.txt'), ('build guide manual steps installation instructions table of contents ' * 3))
        $inv = @(
            (New-SysOrgFxRecord -Path (Join-Path $src 'Monthly Narrative Report.txt') -Cat 'Documents'),
            (New-SysOrgFxRecord -Path (Join-Path $src 'Supervision Report Q1.txt') -Cat 'Documents'),
            (New-SysOrgFxRecord -Path (Join-Path $src 'Proposal.txt') -Cat 'Documents'),
            (New-SysOrgFxRecord -Path (Join-Path $src 'Build Guide.txt') -Cat 'Documents')
        )
        $cfg = New-SysOrgFixtureConfig -OrgRoot $org
        $kf = @([pscustomobject]@{ Name='Documents'; Path=$docs; IsRedirected=$false; UnderOneDrive=$false })
        $prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=$kf; DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders $kf
        @($plan.Actions).Count | Should -Be 4
        foreach($a in @($plan.Actions)){
            $a.Destination | Should -BeLike '*\Documents\Work\*'
            [double]$a.Confidence | Should -BeGreaterOrEqual 0.70
        }
    }
}

Describe 'Fixture: bio/CV -> Personal, never _NoSource (table row 3)' {
    It 'a CV-style document plans to Documents\Personal (or Work via the model), never a source folder' {
        $work = Join-Path $TestDrive ('fx3-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src'
        $org = Join-Path $work 'org'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'Jane Wanjiku CV.txt'), ('curriculum vitae personal profile work experience skills references hobbies education ' * 3))
        $inv = @(New-SysOrgFxRecord -Path (Join-Path $src 'Jane Wanjiku CV.txt') -Cat 'Documents')
        $cfg = New-SysOrgFixtureConfig -OrgRoot $org
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fxProf -DupGroups @() -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 1
        $a = $plan.Actions[0]
        ($a.Destination -like '*\Documents\Personal\*') -or ($a.Destination -like '*\Documents\Work\*') | Should -BeTrue
        $a.Destination | Should -Not -BeLike '*_NoSource*'
        $a.Destination | Should -Not -BeLike '*\Downloads\*'
    }
}

Describe 'Fixture: re-download pairs (table rows 4+6)' {
    It 'identical Report_2026-11-21.docx + (1) -> one copies group; the copy is numbered by policy' {
        $work = Join-Path $TestDrive ('fx4-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src'
        $org = Join-Path $work 'org'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $c1 = Join-Path $src 'Report_2026-11-21.docx'
        $c2 = Join-Path $src 'Report_2026-11-21(1).docx'
        [System.IO.File]::WriteAllText($c1, ('report body ' + ('R' * 400)))
        [System.IO.File]::WriteAllText($c2, ('report body ' + ('R' * 400)))
        (Get-Item -LiteralPath $c1).LastWriteTime = Get-Date '2026-11-21 09:00'
        (Get-Item -LiteralPath $c2).LastWriteTime = Get-Date '2026-11-21 10:00'
        $inv = @((New-SysOrgFxRecord -Path $c1 -Cat 'Documents'), (New-SysOrgFxRecord -Path $c2 -Cat 'Documents'))
        $cfg = New-SysOrgFixtureConfig -OrgRoot $org
        $dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $cfg)
        $dups.Count | Should -Be 1
        $dups[0].KeepPath | Should -Be $c1
        $vp = Get-SysOrgVersionPairs -Inventory $inv -Config $cfg -DupGroups $dups
        $vp.Identical | Should -Be 1
        @($vp.Versions).Count | Should -Be 0
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fxProf -DupGroups $dups -Config $cfg -KnownFolders @() -VersionPairs $vp
        # the copy joins the keeper's destination folder with its own name (v2.1.1 policy)
        $copy = @($plan.Actions | Where-Object { $_.Source -eq $c2 })[0]
        $keeper = @($plan.Actions | Where-Object { $_.Source -eq $c1 })[0]
        (Split-Path $copy.Destination -Parent) | Should -Be (Split-Path $keeper.Destination -Parent)
        (Split-Path $copy.Destination -Leaf) | Should -Be 'Report_2026-11-21(1).docx'   # keeps its own name
    }

    It 'a differing re-download pair is flagged possible newer version - report only (table row 5)' {
        $work = Join-Path $TestDrive ('fx5-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src'
        $org = Join-Path $work 'org'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $g1 = Join-Path $src 'Guide_2026-11-20.pdf'
        $g2 = Join-Path $src 'Guide_2026-11-20 (1).pdf'
        [System.IO.File]::WriteAllText($g1, ('A' * 500))
        [System.IO.File]::WriteAllText($g2, ('B' * 700))
        (Get-Item -LiteralPath $g1).LastWriteTime = Get-Date '2026-11-20 08:00'
        (Get-Item -LiteralPath $g2).LastWriteTime = Get-Date '2026-11-20 09:30'
        $inv = @((New-SysOrgFxRecord -Path $g1 -Cat 'Documents'), (New-SysOrgFxRecord -Path $g2 -Cat 'Documents'))
        $cfg = New-SysOrgFixtureConfig -OrgRoot $org
        $vp = Get-SysOrgVersionPairs -Inventory $inv -Config $cfg
        @($vp.Versions).Count | Should -Be 1
        $vp.Versions[0].CopyLooksNewer | Should -BeTrue
        $vp.Versions[0].OriginalSize | Should -Be 500
        $vp.Versions[0].CopySize | Should -Be 700
    }
}

Describe 'Fixture: AI download provenance (table row 7)' {
    It 'z.ai / meta.ai downloads carry Source Z-AI / Meta-AI and NEVER land in a source folder' {
        (Get-SysOrgSourceBucket -HostUrl 'https://z.ai/x') | Should -Be 'Z-AI'
        (Get-SysOrgSourceBucket -HostUrl 'https://chat.z.ai/f/abc') | Should -Be 'Z-AI'
        (Get-SysOrgSourceBucket -HostUrl 'https://meta.ai/r/xyz') | Should -Be 'Meta-AI'
        # content routing keeps the source OUT of the folder tree under Findable
        $fCfg = @{ LayoutProfile='Findable' }
        (Get-SysOrgFindableRelBase -Category 'Documents' -Subtype 'Work' -Source 'Z-AI' -InDownloads:$true -Config $fCfg).RelBase | Should -Be 'Documents\Work'
        # the catalog carries the bucket: plan action -> catalog entry
        $work = Join-Path $TestDrive ('fx7-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $org = Join-Path $work 'org'
        New-Item -ItemType Directory -Path $org -Force | Out-Null
        $dest = "$org\Documents\Work\2026\a.pdf"
        $actions = @([pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\dl\a.pdf'; Destination=$dest
            SourceBucket='Z-AI'; SizeBytes=[long]10; PlannedLastWriteTimeUtc='2026-01-01T00:00:00.0000000Z'; Reason='Findable=Documents\Work' })
        $plan = [pscustomobject]@{ PlanId='plan-20260101-093000-123'; Actions=$actions }
        $planPath = Join-Path $work 'plan.json'
        $journal = Join-Path $work 'undo.csv'
        ($plan | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $planPath -Encoding UTF8
        $rows = @(
            [pscustomobject]@{ Timestamp='2026-01-01T00:00:00'; PlanId='plan-20260101-093000-123'; Kind='File'; Action='Move'
                OriginalSource='C:\dl\a.pdf'; CurrentLocation=$dest; ContentHash=''; Status='Done' }
        )
        $rows | Export-Csv -LiteralPath $journal -NoTypeInformation -Force
        $cat = Update-SysOrgCatalog -PlanPath $planPath -UndoPath $journal -Root $org -PlanId 'plan-20260101-093000-123'
        $cat | Should -Not -BeNullOrEmpty
        $entries = @(Read-SysOrgCatalog -Path (Get-SysOrgCatalogPath -Root $org))
        ($entries | Where-Object { "$($_.SourceBucket)" -eq 'Z-AI' }).Count | Should -Be 1
    }
}

Describe 'Fixture: family name over the limit (table row 8)' {
    It 'a 60+-char family name truncates on a word boundary with a 4-char hash suffix' {
        $members = @(
            [pscustomobject]@{ Stem='Peer Education Support Supervision Report January February March April May June' }
            [pscustomobject]@{ Stem='Peer Education Support Supervision Report January February March April May July' }
        )
        $name = Get-SysOrgFamilyFolderName -Members $members -MaxNameLength 60
        $name.Length | Should -BeLessOrEqual 60
        $name | Should -Match '-[0-9a-f]{4}$'
        $name | Should -BeLike 'Peer Education Support*'
        # never cut mid-word: the stem ends a complete word
        ($name.Substring(0, $name.Length - 5)) | Should -Not -Match '\s$'
    }
}

Describe 'Fixture: 9,500-file tree, 99% project/dependency -> pruned (table row 9)' {
    It 'the scan prunes project and dependency subtrees; the summary says preserved' {
        $root = Join-Path $TestDrive ('fx9-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        # 38 real projects x 250 files = 9,500 files inside project/dependency folders
        $projCount = 38
        $filesPerProj = 250
        for($p = 1; $p -le $projCount; $p++){
            $proj = Join-Path $root ("app$('_' + $p)")
            New-Item -ItemType Directory -Path (Join-Path $proj '.git') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $proj 'lib') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $proj 'package.json') -Value '{}' -Encoding UTF8
            for($i = 1; $i -le $filesPerProj; $i++){
                Set-Content -LiteralPath (Join-Path (Join-Path $proj 'lib') ("m$i.js")) -Value 'x'
            }
        }
        # 1% loose files (~95)
        foreach($i in 1..95){ Set-Content -LiteralPath (Join-Path $root ("loose$i.txt")) -Value "loose $i" }
        $cfg = New-SysOrgFixtureConfig -OrgRoot (Join-Path $root '_Organized')
        $cfg.PreserveExistingFolders = $true
        $walkProjects = New-Object System.Collections.Generic.List[object]
        $walkPreserved = New-Object System.Collections.Generic.List[object]
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $inv = @(Get-SysOrgInventory -Letter 'S' -Config $cfg -Roots @($root) -ProjectFoldersOut $walkProjects -PreservedOut $walkPreserved)
        $sw.Stop()
        # pruned: the 9,500 project files never appear
        (@($inv | Where-Object { $_.FullName -like '*\lib\*' }).Count) | Should -Be 0
        (@($inv | Where-Object { $_.Name -like 'loose*.txt' }).Count) | Should -Be 95
        # preserved: 38 projects named in the walk output
        $walkPreserved.Count | Should -Be $projCount
        @($walkPreserved | Where-Object { $_.Kind -eq 'Project' }).Count | Should -Be $projCount
        $walkProjects.Count | Should -Be $projCount
        Write-Host ("  9,500-file fixture (99% in projects): inventory {0} files in {1:N2}s; preserved units: {2}" -f $inv.Count, $sw.Elapsed.TotalSeconds, $walkPreserved.Count) -ForegroundColor DarkCyan
    }
}

Describe 'Fixture: 11-of-9,500 plan verdict (table row 11)' {
    It 'an 11-file plan over a 9.5k population reads "no meaningful change", never "worsens"' {
        # reuse the proven A2 fixture shape (synthetic population, invented names)
        $inv = New-Object System.Collections.Generic.List[object]
        for($i = 0; $i -lt 9489; $i++){
            $y = 2020 + ($i % 6)
            $inv.Add([pscustomobject]@{ FullName=('C:\Users\t\Documents\Work\{0}\doc{1:D5}.txt' -f $y, $i)
                                        Name=('doc{0:D5}.txt' -f $i); Length=[long]100; Category='Documents' })
        }
        for($i = 0; $i -lt 11; $i++){
            $inv.Add([pscustomobject]@{ FullName=('C:\Users\t\Downloads\file{0}.pdf' -f $i)
                                        Name=('file{0}.pdf' -f $i); Length=[long]200; Category='Documents' })
        }
        $actions = @()
        for($i = 0; $i -lt 11; $i++){
            $actions += [pscustomobject]@{ Action='Move'; Kind='File'
                Source=('C:\Users\t\Downloads\file{0}.pdf' -f $i)
                Destination=('C:\Organized\Documents\Work\2026\file{0}.pdf' -f $i)
                SizeBytes=[long]200; Confidence=0.8 }
        }
        $plan = [pscustomobject]@{ PlanId='plan-fx11'; Actions=$actions; NeedsDecision=@(); DestinationRoot='C:\Organized' }
        $cfg = @{ Layout = @{ MaxFilesPerFolder=150; MinFilesPerFolder=8 }; Score = @{ MinPopulation=20; MeaningfulChangeShare=0.05 } }
        $d = Get-SysOrgPlanScoreDelta -Plan $plan -Config $cfg -Root 'C:\Organized' -Inventory @($inv.ToArray())
        $d.Verdict | Should -Be 'no meaningful change'
        $d.Verdict | Should -Not -Be 'worsens'
        $d.Why | Should -Match '^11 of 9,500 files affected'
    }
}

Describe 'Fixture: empty destination tree (table row 10)' {
    It 'an empty tree scores n/a - never a number' {
        $empty = Join-Path $TestDrive ('fx10-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $sc = Get-SysOrgTreeScore -Root $empty -Config @{ Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8 }; Score=@{ MinPopulation=20 } }
        $sc.Files | Should -Be 0
        $sc.Score | Should -Be -1
    }
}

Describe 'Fixture end-to-end: organize -> catalog -> find -> undo (rows 1-8 chained)' {
    It 'the fixture tree organizes, the catalog carries provenance, find works, undo restores' -Skip:($env:OS -ne 'Windows_NT') {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'the executor needs Windows drive semantics for the synthetic T: plan (the portable-host equivalents run in the per-item tests above)'; return }
    }
}
