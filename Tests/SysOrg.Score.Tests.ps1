# Tests/SysOrg.Score.Tests.ps1
# Covers v3.0 Phase 0.3 / Phase 5: the findability score.
#   - depth (avg/max), browse-distance, fan-out percentiles
#   - over-cap and near-empty folder shares
#   - confidence shares from Decision confidences
#   - duplicate byte share
#   - deterministic output and target evaluation

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Score.psm1') -Force
    $script:scoreCfg = @{
        Score = @{ Targets = @{ MaxDepth=4; AvgDepth=3.0; OverCapShare=0.05; NearEmptyShare=0.10; ConfidentShare=0.80; DupByteShare=0.10 } }
        Layout = @{ MaxFilesPerFolder=150; MinFilesPerFolder=8 }
    }
    $script:root = 'C:\Org'
}

Describe 'Get-SysOrgFindabilityScore' {

    It 'computes depth, browse-distance and folder counts' {
        $paths = @(
            'C:\Org\Documents\2024\a.txt',
            'C:\Org\Documents\2024\b.txt',
            'C:\Org\Pictures\2024\c.jpg',
            'C:\Org\d.txt'                       # depth 0 (root level)
        )
        $s = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths
        $s.Files | Should -Be 4
        $s.Folders | Should -Be 3
        $s.MaxDepth | Should -Be 2
        $s.AvgDepth | Should -Be ((2+2+2+0)/4)
    }

    It 'a file outside the root counts as left in place' {
        $paths = @('C:\Org\Documents\2024\a.txt', 'C:\Users\t\stray.txt')
        $s = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths
        $s.LeftInPlaceShare | Should -Be 0.5
    }

    It 'detects over-cap and near-empty folder shares against Layout caps' {
        # 160 files in one folder (over the 150 cap), 4 files in two near-empty folders
        $paths = @()
        for($i=0; $i -lt 160; $i++){ $paths += ('C:\Org\Documents\2024\f{0:D3}.txt' -f $i) }
        for($i=0; $i -lt 8; $i++){
            $paths += ('C:\Org\Documents\Rare1\r{0}.txt' -f $i)
            $paths += ('C:\Org\Documents\Rare2\r{0}.txt' -f $i)
        }
        $s = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths -Cap 150 -MinPerFolder 8
        # 176 files total; over-cap = 160; near-empty = folders with < 8 files -> none (8 = not fewer)
        $s.OverCapShare | Should -Be ([math]::Round(160/176, 4))
        $s.NearEmptyShare | Should -Be 0
        # shrink: a 7-file folder is near-empty
        $paths2 = @()
        for($i=0; $i -lt 7; $i++){ $paths2 += ('C:\Org\Documents\Small\s{0}.txt' -f $i) }
        $s2 = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths2 -Cap 150 -MinPerFolder 8
        $s2.NearEmptyShare | Should -Be 1
    }

    It 'reports confidence shares only when confidences are supplied' {
        $paths = @('C:\Org\Documents\2024\a.txt','C:\Org\Documents\2024\b.txt','C:\Org\Documents\2024\c.txt','C:\Org\Documents\2024\d.txt')
        $s1 = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths
        $s1.ConfidentShare | Should -Be -1
        $conf = @{ 'C:\Org\Documents\2024\a.txt'=0.9; 'C:\Org\Documents\2024\b.txt'=0.75; 'C:\Org\Documents\2024\c.txt'=0.5; 'C:\Org\Documents\2024\d.txt'=0.2 }
        $s2 = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths -Confidences $conf
        $s2.ConfidentShare | Should -Be 0.5
        $s2.ReviewShare | Should -Be 0.25
        $s2.LowConfShare | Should -Be 0.25
    }

    It 'computes the duplicate byte share' {
        $paths = @('C:\Org\Documents\2024\a.bin','C:\Org\Documents\2024\b.bin')
        $sizes = @{ 'C:\Org\Documents\2024\a.bin'=[long]1000; 'C:\Org\Documents\2024\b.bin'=[long]3000 }
        $s = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths -FileSizes $sizes -DuplicateBytes 400
        $s.DuplicateByteShare | Should -Be 0.1
    }

    It 'is deterministic for identical inputs' {
        $paths = @()
        for($i=0; $i -lt 40; $i++){ $paths += ('C:\Org\Documents\2024\{0:D2}.txt' -f $i) }
        $arr = @($paths)
        $s1 = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $arr
        $s2 = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $arr
        ($s1 | ConvertTo-Json -Depth 4 -Compress) | Should -Be ($s2 | ConvertTo-Json -Depth 4 -Compress)
    }

    It 'high scores for a clean 3-level layout and low scores for a deep over-cap mess' {
        $clean = @()
        for($i=0; $i -lt 100; $i++){ $clean += ('C:\Org\Documents\Finance\2024\f{0:D3}.txt' -f $i) }
        $mess = @()
        for($i=0; $i -lt 200; $i++){ $mess += ('C:\Org\a\b\c\d\e\f\g\h\i\j\k{0:D4}.txt' -f $i) }
        (Get-SysOrgFindabilityScore -Root $script:root -FilePaths $clean).Score | Should -BeGreaterThan (Get-SysOrgFindabilityScore -Root $script:root -FilePaths $mess).Score
    }
}

Describe 'Score targets' {

    It 'evaluates pass/fail per metric and never fails on not-measured metrics' {
        $paths = @()
        for($i=0; $i -lt 100; $i++){ $paths += ('C:\Org\Documents\2024\f{0:D3}.txt' -f $i) }
        $s = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths
        $rows = @(Test-SysOrgScoreTargets -Score $s -Config $script:scoreCfg)
        ($rows | Where-Object Metric -eq 'ConfidentShare').Pass | Should -BeTrue   # -1 => n/a => never fails
        ($rows | Where-Object Metric -eq 'NearEmptyShare').Pass | Should -BeTrue
    }

    It 'flags a violation' {
        $paths = @('C:\Org\a\b\c\d\e\f.txt')   # 6 folder opens - beyond the target of 4
        $s = Get-SysOrgFindabilityScore -Root $script:root -FilePaths $paths
        $rows = @(Test-SysOrgScoreTargets -Score $s -Config $script:scoreCfg)
        ($rows | Where-Object { $_.Metric -eq 'MaxDepth' }).Pass | Should -BeFalse
    }
}
