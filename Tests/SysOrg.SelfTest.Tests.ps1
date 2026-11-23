# ---------------------------------------------------------------------------
# v3.0.2 A3: -SelfTest. Builds a temporary synthetic tree under the system temp
# area and runs the WHOLE pipeline (scan -> duplicates -> projects -> plan ->
# preview -> save -> execute -> undo -> verify) on the host under test, with a
# [PASS]/[FAIL] verdict per step. Real user folders are never touched - every
# path lives under a fresh 'SysOrgSelfTest-<guid>' directory. This test extracts
# the REAL Invoke-SysOrgSelfTest from SysOrg.ps1 (the same code the menu entry
# and the -SelfTest switch run) and requires the verdict SELF-TEST PASSED.
# ---------------------------------------------------------------------------
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Drives.psm1')      -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')      -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1')    -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1')    -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Cache.psm1')       -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Catalog.psm1')     -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force -DisableNameChecking
    $sysAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'SysOrg.ps1'), [ref]$null, [ref]$null)
    $fd = $sysAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Name -eq 'Invoke-SysOrgSelfTest' } | Select-Object -First 1
    if(-not $fd){ throw 'SysOrg.ps1 no longer defines Invoke-SysOrgSelfTest' }
    Invoke-Expression $fd.Extent.Text
}

Describe 'v3.0.2 A3: the self-test runs the whole pipeline and passes' {

    It 'reports [PASS] for every step and finishes with SELF-TEST PASSED' {
        $out = Invoke-SysOrgSelfTest 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        $text | Should -Match 'SELF-TEST PASSED'
        $text | Should -Not -Match '\[FAIL\]'
        $passCount = ([regex]::Matches($text, '\[PASS\]')).Count
        $passCount | Should -BeGreaterThan 5 -Because 'scan, duplicates, projects, plan, preview, execute, undo and verify all report individually'
        $text | Should -Match '\[PASS\] scan \(inventory walk\)'
        $text | Should -Match '\[PASS\] execute into the temporary destination'
        $text | Should -Match '\[PASS\] undo \(restore to original locations\)'
        $text | Should -Match '\[PASS\] verify the restore byte-for-byte'
    }

    It 'cleans up its temporary tree on success' {
        $tempRootsBefore = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'SysOrgSelfTest-*' -ErrorAction SilentlyContinue)
        $null = Invoke-SysOrgSelfTest 2>&1 | Out-Null
        $tempRootsAfter = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Directory -Filter 'SysOrgSelfTest-*' -ErrorAction SilentlyContinue)
        # the 'app' copy dirs from the smoke test and log dirs may linger; only the
        # self-test tree must be gone - allow at most what existed before
        @($tempRootsAfter).Count | Should -BeLessOrEqual @($tempRootsBefore).Count
    }
}

Describe 'v3.0.2 A3: the self-test reports FAIL honestly when the pipeline is broken' {

    It 'marks the broken step [FAIL], keeps the temp tree and reports SELF-TEST FAILED' {
        $env:SYSORG_FAULT_PLANBUILD = 'selftest-fault'
        try {
            $out = Invoke-SysOrgSelfTest 2>&1 3>&1 4>&1 5>&1 6>&1
            $text = (($out | ForEach-Object { "$_" }) -join "`n")
            $text | Should -Match 'SELF-TEST FAILED'
            $text | Should -Match '\[FAIL\] plan build'
            $text | Should -Match 'Synthetic plan-build fault'
            $text | Should -Match 'KEPT for inspection'
        } finally {
            Remove-Item Env:SYSORG_FAULT_PLANBUILD -ErrorAction SilentlyContinue
        }
    }
}
