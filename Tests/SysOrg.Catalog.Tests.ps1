# Tests/SysOrg.Catalog.Tests.ps1
# Covers v3.0 Phase 4: the catalog (built after execute, updated by undo),
# Find-SysOrgFile (catalog-first with live-scan fallback), the offline Index.html,
# the _Index README and the warn-only Windows Search status check.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')  -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')   -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Catalog.psm1') -Force
}

Describe 'Catalog build and undo update (Phase 4.1)' {

    It 'builds catalog entries from a real execute round trip' {
        $work = Join-Path $TestDrive ('cat-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $doc = Join-Path $src 'Invoice KRA 2024-900.txt'
        Set-Content -LiteralPath $doc -Value 'invoice 900, amount due KES 40000, payment due' -Encoding UTF8
        $stamp = Get-Date '2024-06-15'
        $fi = Get-Item -LiteralPath $doc
        $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = @{
            AppRoot=(Join-Path $work 'app'); LayoutProfile='Findable'; OrganizedRoots=@{ '*'=(Join-Path $work 'org') }   # v3.0.1: app root never an ancestor of fixtures
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$false }; Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }; TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }; Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
            Run=@{ Parallelism=0 }
        }
        $inv = @([pscustomobject]@{ FullName=$doc; Name='Invoice KRA 2024-900.txt'; Stem='Invoice KRA 2024-900'
            Extension='.txt'; Length=(Get-Item -LiteralPath $doc).Length; LastWriteTime=$stamp; Directory=$src; Category='Documents' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        (@($plan.Actions).Count) | Should -Be 1
        $planPath = Join-Path $work 'plan.json'
        $planObj = $plan | Select-Object -Property * -ExcludeProperty Provenance
        $planObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $appRoot = Join-Path $work 'app'
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfg -AppRoot $appRoot
        $res.Summary.Moved | Should -Be 1
        $catPath = Update-SysOrgCatalog -PlanPath $planPath -UndoPath $res.UndoFile -Root (Join-Path $work 'org') -PlanId $plan.PlanId
        $catPath | Should -Not -BeNullOrEmpty
        $entries = @(Read-SysOrgCatalog -Path $catPath)
        $entries.Count | Should -Be 1
        $e = $entries[0]
        $e.OriginalPath | Should -Be $doc
        $e.CurrentPath | Should -Not -Be $doc          # the file moved
        Test-Path -LiteralPath $e.CurrentPath | Should -BeTrue
        $e.Type | Should -Be 'File'
        $e.PlanId | Should -Be $plan.PlanId
        "$($e.Category)" | Should -Match 'Findable=|Category='
    }

    It 'undo points the catalog entry back at the original path' {
        $work = Join-Path $TestDrive ('catundo-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $doc = Join-Path $src 'note2.txt'
        Set-Content -LiteralPath $doc -Value 'undo me'
        $stampU = Get-Date '2024-06-15'
        $fiU = Get-Item -LiteralPath $doc
        $fiU.CreationTime = $stampU; $fiU.LastWriteTime = $stampU
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = @{
            AppRoot=(Join-Path $work 'app'); LayoutProfile='Windows'; OrganizedRoots=@{ '*'=(Join-Path $work 'org') }   # v3.0.1: app root never an ancestor of fixtures
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$false }; Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }; TypeMap=@{}
        }
        $inv = @([pscustomobject]@{ FullName=$doc; Name='note2.txt'; Stem='note2'
            Extension='.txt'; Length=(Get-Item -LiteralPath $doc).Length; LastWriteTime=$stampU; Directory=$src; Category='Documents' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        $planPath = Join-Path $work 'plan2.json'
        ($plan | Select-Object -Property * -ExcludeProperty Provenance) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $appRoot = Join-Path $work 'app'
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfg -AppRoot $appRoot
        $orgRoot = Join-Path $work 'org'
        $catPath = Update-SysOrgCatalog -PlanPath $planPath -UndoPath $res.UndoFile -Root $orgRoot -PlanId $plan.PlanId
        @(Read-SysOrgCatalog -Path $catPath).Count | Should -Be 1
        $res2 = Undo-SysOrgPlan -PlanId $plan.PlanId -AppRoot $appRoot -Config $cfg
        $res2.Restored | Should -Be 1
        $catPath2 = Update-SysOrgCatalogOnUndo -PlanId $plan.PlanId -AppRoot $appRoot -Root $orgRoot
        $catPath2 | Should -Not -BeNullOrEmpty
        $e = @(Read-SysOrgCatalog -Path $catPath2)[0]
        $e.CurrentPath | Should -Be $doc               # back at the original
        Test-Path -LiteralPath $doc | Should -BeTrue
    }
}

Describe 'Find-SysOrgFile (Phase 4.2)' {

    BeforeAll {
        $script:catDir = Join-Path $TestDrive ('find-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $script:catDir -Force | Out-Null
        $script:catPath = Join-Path $script:catDir '_Index\catalog.ndjson'
        New-Item -ItemType Directory -Path (Split-Path $script:catPath) -Force | Out-Null
        $lines = @()
        # v3.0.1: the injected path MUST be JSON-escaped - on Windows it contains
        # backslashes, which pwsh 7 tolerates inside JSON strings but PS 5.1's
        # ConvertFrom-Json rejects as invalid escape sequences.
        $script:catEsc = $script:catDir.Replace('\','\\')
        $lines += ('{{"CurrentPath":"{0}\\Documents\\Finance\\Invoices\\2024\\inv1.pdf","OriginalPath":"C:\\dl\\inv1.pdf","Type":"File","Category":"Documents\\Finance\\Invoices","Date":"2024-03-01T10:00:00","DateSource":"plan","SourceBucket":"GitHub","Family":"inv","Hash":"AAA","SizeBytes":12000,"Confidence":0.9,"RuleId":"lexicon","PlanId":"plan-1"}}' -f $script:catEsc)
        $lines += ('{{"CurrentPath":"{0}\\Pictures\\Camera\\2024\\img1.jpg","OriginalPath":"C:\\pics\\img1.jpg","Type":"File","Category":"Pictures\\Camera","Date":"2024-05-05T11:00:00","DateSource":"exif","SourceBucket":"","Family":"","Hash":"BBB","SizeBytes":900000,"Confidence":0.8,"RuleId":"default","PlanId":"plan-1"}}' -f $script:catEsc)
        $lines += ('{{"CurrentPath":"{0}\\Documents\\Finance\\Invoices\\2024\\inv2.pdf","OriginalPath":"C:\\dl\\inv2.pdf","Type":"File","Category":"Documents\\Finance\\Invoices","Date":"2024-03-15T10:00:00","DateSource":"plan","SourceBucket":"WhatsApp","Family":"","Hash":"AAA","SizeBytes":12000,"Confidence":0.85,"RuleId":"lexicon","PlanId":"plan-1"}}' -f $script:catEsc)
        [System.IO.File]::WriteAllLines($script:catPath, $lines)
        $script:findRoot = $script:catDir
    }

    It 'filters by name, type, size, source and date range' {
        $r1 = @(Find-SysOrgFile -Root $script:findRoot -Name '*inv*')
        $r1.Count | Should -Be 2
        $r2 = @(Find-SysOrgFile -Root $script:findRoot -Type 'Pictures')
        $r2.Count | Should -Be 1
        $r2[0].CurrentPath | Should -Match 'img1\.jpg'
        $r3 = @(Find-SysOrgFile -Root $script:findRoot -Source 'WhatsApp')
        $r3.Count | Should -Be 1
        $r4 = @(Find-SysOrgFile -Root $script:findRoot -MinSizeKB 100)
        $r4.Count | Should -Be 1
        $r5 = @(Find-SysOrgFile -Root $script:findRoot -After ([datetime]'2024-04-01'))
        $r5.Count | Should -Be 1
        $r5[0].CurrentPath | Should -Match 'img1\.jpg'
        $r6 = @(Find-SysOrgFile -Root $script:findRoot -NameRegex 'inv\d+\.pdf$' -Before ([datetime]'2024-03-10'))
        $r6.Count | Should -Be 1
    }

    It 'finds duplicates-of a catalogued file via its hash' {
        $r = @(Find-SysOrgFile -Root $script:findRoot -DuplicatesOf (Join-Path $script:catDir 'Documents\Finance\Invoices\2024\inv1.pdf'))
        # inv1 itself + inv2 share hash AAA
        $r.Count | Should -Be 2
        foreach($e in $r){ "$($e.Hash)" | Should -Be 'AAA' }
    }

    It 'falls back to a live scan when no catalog exists' {
        $emptyRoot = Join-Path $TestDrive ('emptyroot-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
        $f = Join-Path $emptyRoot 'live.txt'
        Set-Content -LiteralPath $f -Value 'live scan me'
        $r = @(Find-SysOrgFile -Root $emptyRoot -Name '*live*' -Config @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; TypeMap=@{}; FolderAudit=@{ Enabled=$false }; OrganizedRoots=@{ '*'='__AUTO__' } } -Letter 'S' 3>$null)
        $r.Count | Should -BeGreaterOrEqual 1
        ($r[0].CurrentPath) | Should -Match 'live\.txt$'
    }
}

Describe 'Offline index page and README (Phase 4.3, 4.5)' {

    It 'Index.html embeds the catalog JSON and per-folder counts' {
        $root = Join-Path $TestDrive ('html-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $catPath = Join-Path $root '_Index\catalog.ndjson'
        New-Item -ItemType Directory -Path (Split-Path $catPath) -Force | Out-Null
        [System.IO.File]::WriteAllLines($catPath, @('{"CurrentPath":"X:\\_Organized\\Documents\\a.pdf","OriginalPath":"C:\\a.pdf","Type":"File","Category":"Documents","Date":"","DateSource":"","SourceBucket":"","Family":"","Hash":"H1","SizeBytes":10,"Confidence":0.8,"RuleId":"default","PlanId":"plan-1"}'))
        $html = Save-SysOrgIndexPage -Root $root
        $html | Should -Not -BeNullOrEmpty
        $text = Get-Content -LiteralPath $html -Raw
        $text | Should -Match 'SysOrg offline index'
        $text | Should -Match 'var DATA = \['
        $text | Should -Match 'filterRows'
        $text | Should -Match '_Organized'
        # no network references
        $text | Should -Not -Match 'https?://'
    }

    It 'the README explains the layout, Find and undo' {
        $root = Join-Path $TestDrive ('rme-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $rme = Save-SysOrgIndexReadme -Root $root
        $text = Get-Content -LiteralPath $rme -Raw
        $text | Should -Match 'catalog\.ndjson'
        $text | Should -Match '-Find'
        $text | Should -Match '-UndoPlan'
        $text | Should -Match 'LEFT IN PLACE'
        $text | Should -Match 'LearnedRules\.psd1'
        $text | Should -Match 'Rules\.ApplyLearned'
    }
}

Describe 'Windows Search status check (Phase 4.4, warn only)' {

    It 'never throws and always reports a status with a reason' {
        $r = Test-SysOrgSearchIndexStatus -Root 'C:\_Organized'
        @('Disabled','Unknown','Ok') | Should -Contain $r.Status
        "$($r.Reason)" | Should -Not -BeNullOrEmpty
    }
}
