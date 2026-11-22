# Tests/SysOrg.Migrate.Tests.ps1
# Covers v3.0 Phase 5 (plan score delta, -Score wiring) and Phase 6
# (v2.1 layout -> Findable migration: previewable, whole-folder moves,
# adaptive date re-bucketing, idempotent, runtime folders untouched).

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')  -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')   -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Score.psm1')   -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')    -Force
}

Describe 'Plan score delta (Phase 5)' {

    It 'reports a before/after improvement for a plan that de-clutters folders' {
        $dir = Join-Path $TestDrive 'src-score'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $inv = @()
        $stamp = Get-Date '2024-06-15'
        # 200 photos in ONE flat folder: the plan splits them into date folders
        for($i=0; $i -lt 200; $i++){
            $p = Join-Path $dir ('IMG_202401{0:D2}_{1:D6}.jpg' -f (($i % 28) + 1), $i)
            Set-Content -LiteralPath $p -Value ('x' * 20) -Encoding ASCII
            $fi = Get-Item -LiteralPath $p
            $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
            $inv += [pscustomobject]@{ FullName=$p; Name=[IO.Path]::GetFileName($p); Stem=[IO.Path]::GetFileNameWithoutExtension($p)
                Extension='.jpg'; Length=20; LastWriteTime=$stamp; Directory=$dir; Category='Pictures' }
        }
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = @{
            AppRoot=$TestDrive; LayoutProfile='Findable'; OrganizedRoots=@{ '*'='__AUTO__' }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$false }; Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }; TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
        }
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        (@($plan.Actions).Count) | Should -Be 200
        $delta = Get-SysOrgPlanScoreDelta -Plan $plan -Config $cfg -Root $plan.DestinationRoot
        $delta.Verdict | Should -Be 'improves'
        $delta.After.Score | Should -BeGreaterThan $delta.Before.Score
        $delta.Before.OverCapShare | Should -BeGreaterThan 0    # the flat folder was over cap
        $delta.After.OverCapShare | Should -Be 0                # the split fixed it
    }
}

Describe 'v2.1 -> Findable layout migration (Phase 6)' {

    It 'moves whole folders, re-buckets dates, and never touches runtime folders' {
        $work = Join-Path $TestDrive ('mig-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $root = Join-Path $work 'org'
        # a v2.1-shaped tree: Documents\2024 (200 txt files), Pictures\2024 (camera jpgs), Documents\Other
        $d1 = Join-Path $root 'Documents\2024'
        New-Item -ItemType Directory -Path $d1 -Force | Out-Null
        $stamp = Get-Date '2024-06-15'
        for($i=0; $i -lt 20; $i++){
            $p = Join-Path $d1 ('Invoice KRA 2024-{0:D3}.txt' -f $i)
            Set-Content -LiteralPath $p -Value ('invoice ' + $i) -Encoding ASCII
            $fi = Get-Item -LiteralPath $p; $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
        }
        $d2 = Join-Path $root 'Documents\Other'
        New-Item -ItemType Directory -Path $d2 -Force | Out-Null
        $noteP = Join-Path $d2 'random note.txt'
        Set-Content -LiteralPath $noteP -Value 'hello'
        $fiN = Get-Item -LiteralPath $noteP; $fiN.CreationTime = $stamp; $fiN.LastWriteTime = $stamp
        $idx = Join-Path $root '_Index'
        New-Item -ItemType Directory -Path $idx -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $idx 'catalog.ndjson') -Value '{"keep":"me"}'
        $cfg = @{
            AppRoot=$TestDrive; LayoutProfile='Findable'; OrganizedRoots=@{ '*'=$root }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$false }; Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }
            TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
            Run=@{ Parallelism=0 }
        }
        $plan = New-SysOrgLayoutMigrationPlan -Letter T -Config $cfg -TargetProfile 'Findable'
        $plan.PlanId | Should -BeLike 'migrate-*'
        (@($plan.Actions).Count) | Should -BeGreaterThan 0
        # the _Index file is never planned and never skipped-as-moved
        (@($plan.Actions) | Where-Object { "$($_.Source)" -like '*_Index*' }).Count | Should -Be 0
        # whole-folder unit moves where every file shares one target
        $folderMoves = @(@($plan.Actions) | Where-Object { "$($_.Kind)" -eq 'Folder' })
        $folderMoves.Count | Should -Be 2   # Documents\2024 -> Finance\Invoices\2024 AND Documents\Other -> General\2024
        (@($folderMoves) | Where-Object { "$($_.Destination)" -like '*Documents\Finance\Invoices\2024' }).Count | Should -Be 1
        (@($folderMoves) | Where-Object { "$($_.Destination)" -like '*Documents\General\2024' }).Count | Should -Be 1
        foreach($a in @($plan.Actions)){
            "$($a.Destination)" | Should -BeLike "$root*"
        }
    }

    It 'is idempotent: migrating an already-Findable tree produces zero actions' {
        $work = Join-Path $TestDrive ('mig2-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $root = Join-Path $work 'org'
        $d1 = Join-Path $root 'Documents\Finance\Invoices\2024'
        New-Item -ItemType Directory -Path $d1 -Force | Out-Null
        $stamp = Get-Date '2024-06-15'
        for($i=0; $i -lt 5; $i++){
            $p = Join-Path $d1 ('Invoice KRA 2024-{0:D3}.txt' -f $i)
            Set-Content -LiteralPath $p -Value ('invoice ' + $i) -Encoding ASCII
            $fi = Get-Item -LiteralPath $p; $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
        }
        $cfg = @{
            AppRoot=$TestDrive; LayoutProfile='Findable'; OrganizedRoots=@{ '*'=$root }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$false }; Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }
            TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
            Run=@{ Parallelism=0 }
        }
        $plan = New-SysOrgLayoutMigrationPlan -Letter T -Config $cfg -TargetProfile 'Findable'
        (@($plan.Actions).Count) | Should -Be 0
        (@($plan.Skipped) | Where-Object { $_.Reason -like 'Already in its Findable place*' }).Count | Should -BeGreaterThan 0
    }

    It 'executes and undoes a layout migration through the normal executor' {
        $work = Join-Path $TestDrive ('mig3-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $root = Join-Path $work 'org'
        $d1 = Join-Path $root 'Photo\2024'
        New-Item -ItemType Directory -Path $d1 -Force | Out-Null
        $stamp = Get-Date '2024-06-15'
        for($i=0; $i -lt 4; $i++){
            $p = Join-Path $d1 ('photo-{0:D3}.png' -f $i)
            Set-Content -LiteralPath $p -Value ('x' * 10) -Encoding ASCII
            $fi = Get-Item -LiteralPath $p; $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
        }
        $cfg = @{
            AppRoot=(Join-Path $work 'app'); LayoutProfile='Findable'; OrganizedRoots=@{ '*'=$root }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$false }; Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }
            TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
            Run=@{ Parallelism=0 }
        }
        $plan = New-SysOrgLayoutMigrationPlan -Letter T -Config $cfg -TargetProfile 'Findable'
        (@($plan.Actions).Count) | Should -BeGreaterThan 0
        $planPath = Join-Path $work 'migplan.json'
        ($plan | Select-Object -Property * -ExcludeProperty Provenance) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfg -AppRoot (Join-Path $work 'app')
        ($res.Summary.Moved + $res.Summary.FolderMoves) | Should -BeGreaterThan 0
        # everything moved somewhere under Documents (png -> Pictures\Camera or Data...)
        (Get-ChildItem -LiteralPath $d1 -ErrorAction SilentlyContinue | Measure-Object).Count | Should -Be 0
        $res2 = Undo-SysOrgPlan -PlanId $plan.PlanId -AppRoot (Join-Path $work 'app') -Config $cfg
        $res2.Restored | Should -BeGreaterThan 0
        (Get-ChildItem -LiteralPath $d1 | Measure-Object).Count | Should -Be 4
    }
}
