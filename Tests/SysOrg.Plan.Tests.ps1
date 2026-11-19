# Tests/SysOrg.Plan.Tests.ps1
# Covers: P0-2 (sum correctness), P1-1 (journal), P1-3 (re-execution guard + resume),
#         P1-4 (hash-mismatch undo skip), P1-10 (honest Copied counting), P2-1 (hash economy),
#         P2-5 (SkippedLongPath excluded from plans)

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1') -Force
    $script:planCfg = @{
        AppRoot        = $TestDrive
        OrganizedRoots = @{ '*' = '__AUTO__' }
        Duplicates     = @{ QuarantineFolderName = '_Duplicates' }
        Move           = @{ AllowCrossVolume = $true }
        ExcludedPaths  = @()
        ExcludedFilePatterns = @()
        SkipHiddenSystemFiles = $true
        ExcludeDestinations = $true
        PreserveExistingFolders = $true
        AlwaysScanFolders = @()
        ProjectDetection = @{ Enabled = $true; MinFiles = 3; MaxProjects = 200 }
        FolderAudit = @{ Enabled = $false }
        Categories = @{}
    }
}

Describe 'Execute, re-execution guard and resume (P1-3)' {
    It 'refuses to re-execute a plan that already has an undo journal' {
        $src = Join-Path $TestDrive 'work2\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v1'
        $dest = Join-Path $TestDrive 'org2\Documents\2026\doc.txt'
        $plan = [pscustomobject]@{ PlanId='plan-test-0002'
            Actions=@([pscustomobject]@{ Action='Move'; Source=$src; Destination=$dest; Reason='Category=Documents'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'plan2.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 1
        { Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive } |
            Should -Throw '*already has an undo journal*'
    }
    It '-Force resumes: journaled sources are skipped and the journal is preserved' {
        $planPath = Join-Path $TestDrive 'plan2.json'
        $undoPath = Join-Path $TestDrive ('Undo\undo-plan-test-0002.csv')
        # @() : Import-Csv returns a SCALAR for a single data row, and PSCustomObject
        # has no intrinsic .Count on Windows PowerShell 5.1 (PS 7 does).
        @(Import-Csv -LiteralPath $undoPath).Count | Should -Be 1
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive -Force
        $res.Summary.Resumed | Should -Be 1
        $res.Summary.Moved   | Should -Be 0
        @(Import-Csv -LiteralPath $undoPath).Count | Should -Be 1   # journal unchanged, no duplicate header
    }
    It 'resume after a simulated crash: pre-seeded journal skips that source and completes the rest' {
        $srcA = Join-Path $TestDrive 'work3\a.txt'; $srcB = Join-Path $TestDrive 'work3\b.txt'
        New-Item -ItemType Directory -Path (Split-Path $srcA) -Force | Out-Null
        Set-Content -LiteralPath $srcA -Value 'aa'; Set-Content -LiteralPath $srcB -Value 'bb'
        $dstA = Join-Path $TestDrive 'org3\Documents\2026\a.txt'
        $dstB = Join-Path $TestDrive 'org3\Documents\2026\b.txt'
        $planId = 'plan-test-0003'
        $plan = [pscustomobject]@{ PlanId=$planId
            Actions=@(
                [pscustomobject]@{ Action='Move'; Source=$srcA; Destination=$dstA; Reason='Category=Documents'; SizeBytes=2 },
                [pscustomobject]@{ Action='Move'; Source=$srcB; Destination=$dstB; Reason='Category=Documents'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'plan3.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        # simulate a crashed first run: action A already executed and journaled
        New-Item -ItemType Directory -Path (Split-Path $dstA) -Force | Out-Null
        Move-Item -LiteralPath $srcA -Destination $dstA
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Action,OriginalSource,CurrentLocation,ContentHash',
            ('"2026-01-01T00:00:00","{0}","Move","{1}","{2}",""' -f $planId, $srcA, $dstA)
        ) -Encoding UTF8
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive -Force
        $res.Summary.Resumed | Should -Be 1
        $res.Summary.Moved   | Should -Be 1
        Test-Path -LiteralPath $srcB | Should -BeFalse
        @(Import-Csv -LiteralPath $undoPath).Count | Should -Be 2
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot $TestDrive -Config $planCfg
        $u.Restored | Should -Be 2
        Test-Path -LiteralPath $srcA | Should -BeTrue
        Test-Path -LiteralPath $srcB | Should -BeTrue
    }
}

Describe 'Undo content verification (P1-4)' {
    It 'skips restoring a file whose content changed since the move' {
        $planId = 'plan-test-0004'
        $current = Join-Path $TestDrive 'org4\Documents\2026\gone.txt'
        $original = Join-Path $TestDrive 'work4\gone.txt'
        New-Item -ItemType Directory -Path (Split-Path $current) -Force | Out-Null
        Set-Content -LiteralPath $current -Value 'original-content'
        $hash = (Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash
        Set-Content -LiteralPath $current -Value 'USER EDITED THIS LATER'   # content changed since move
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Action,OriginalSource,CurrentLocation,ContentHash',
            ('"2026-01-01T00:00:00","{0}","Move","{1}","{2}","{3}"' -f $planId, $original, $current, $hash)
        ) -Encoding UTF8
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot $TestDrive -Config $planCfg
        $u.SkippedChanged | Should -Be 1
        $u.Restored | Should -Be 0
        (Get-Content -LiteralPath $current | Out-String).Trim() | Should -Be 'USER EDITED THIS LATER'
    }
}

Describe 'Duplicate groups and sums (P0-2)' {
    It 'reports non-zero WastedBytes for a known duplicate fixture' {
        $root = Join-Path $TestDrive ('dupfix-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'first.txt')  -Value ('D' * 20)
        Set-Content -LiteralPath (Join-Path $root 'second.txt') -Value ('D' * 20)
        Set-Content -LiteralPath (Join-Path $root 'unique.txt') -Value 'different'
        $inv = @(
            [pscustomobject]@{ FullName=(Join-Path $root 'first.txt');  Name='first.txt';  Stem='first';  Extension='.txt'; Length=20
                LastWriteTime=(Get-Date '2026-01-01'); Directory=$root; Category='Documents' },
            [pscustomobject]@{ FullName=(Join-Path $root 'second.txt'); Name='second.txt'; Stem='second'; Extension='.txt'; Length=20
                LastWriteTime=(Get-Date '2026-01-02'); Directory=$root; Category='Documents' }
        )
        # MinFileSizeKB=0: the fixture files are 20 bytes, so any positive
        # KB threshold would filter them out before duplicate grouping.
        $dupCfg = @{ Duplicates = @{ Policy='Quarantine'; MinFileSizeKB=0; HeaderHashKB=64 } }
        $groups = @(Find-SysOrgDuplicates -Inventory $inv -Config $dupCfg)
        $groups.Count | Should -Be 1
        $groups[0].WastedBytes | Should -Be 20
        $groups[0].KeepPath | Should -Be (Join-Path $root 'first.txt')
        $groups[0].Duplicates.Count | Should -Be 1
        $groups[0].Duplicates[0] | Should -Be (Join-Path $root 'second.txt')
    }
    It 'Show-SysOrgPlan computes totals without parse errors (P0-1/P0-2 regression guard)' {
        $plan = [pscustomobject]@{ PlanId='plan-show-1'; Drive='T:'; DestinationRoot='T:\_Organized'; Mode='test'
            Actions=@([pscustomobject]@{ Action='Move'; Source='C:\x\a.txt'; Destination='T:\_Organized\Documents\a.txt'; Reason='Category=Documents'; SizeBytes=123 })
            Skipped=@() }
        { Show-SysOrgPlan -Plan $plan } | Should -Not -Throw
    }
}

Describe 'Plan construction' {
    It 'excludes SkippedLongPath records from plan actions (P2-5)' {
        $normal = [pscustomobject]@{ FullName='C:\src\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\src'; Category='Documents' }
        $long   = [pscustomobject]@{ FullName=('C:\' + ('x' * 280)); Name='x' * 279; Stem='x'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\deep'; Category='SkippedLongPath' }
        $inv = @($normal, $long)
        $clusters = Get-SysOrgProjectClusters -Inventory $inv -Config $planCfg
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -ClusterResult $clusters -DupGroups @() -Config $planCfg
        @($plan.Actions).Count | Should -Be 1
        $plan.Actions[0].Source | Should -Be 'C:\src\note.txt'
        @($plan.Skipped | Where-Object { $_.Source -eq $long.FullName }).Count | Should -Be 1
    }
    It 'quarantine actions carry the scan-time hash for reuse at execution (P2-1)' {
        $dup = [pscustomobject]@{ FullName='C:\src\copy.bin'; Name='copy.bin'; Stem='copy'; Extension='.bin'
            Length=1024; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\src'; Category='Other' }
        $inv = @($dup)
        $dupGroups = @([pscustomobject]@{ Hash='ABCD1234ABCD1234'; KeepPath='C:\keep\copy.bin'
            Duplicates=@('C:\src\copy.bin'); WastedBytes=1024 })
        $qCfg = @{ Duplicates = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates' }; OrganizedRoots=@{ '*'='__AUTO__' } }
        $clusters = Get-SysOrgProjectClusters -Inventory $inv -Config $qCfg
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -ClusterResult $clusters -DupGroups $dupGroups -Config $qCfg
        @($plan.Actions).Count | Should -Be 1
        $plan.Actions[0].Action | Should -Be 'Quarantine'
        $plan.Actions[0].Hash | Should -Be 'ABCD1234ABCD1234'
    }
}
