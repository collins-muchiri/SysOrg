# Tests/SysOrg.Startup.Tests.ps1
# v3.0.1 A6: the menu must start clean - importing the modules printed an
# 'unapproved verbs' warning for every module load (Show-, Sort-, Undo-, ...).
# SysOrg.ps1 now imports every module with -DisableNameChecking (the cheap,
# documented alternative to renaming dozens of public commands that tests and
# saved plans reference by name).

BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:cliPath = Join-Path $script:repoRoot 'SysOrg.ps1'
}

Describe 'Clean startup: -DisableNameChecking on every import (v3.0.1 A6)' {

    It 'every Import-Module line in SysOrg.ps1 carries -DisableNameChecking' {
        $lines = @(Get-Content -LiteralPath $script:cliPath)
        $imports = @($lines | Where-Object { $_.TrimStart().StartsWith('Import-Module') })
        $imports.Count | Should -BeGreaterOrEqual 12
        foreach($ln in $imports){
            ($ln -match '-DisableNameChecking') | Should -BeTrue "line lacks -DisableNameChecking: $ln"
        }
    }

    It 'importing a module WITHOUT the switch warns (documents the noise being suppressed)' {
        $core = Join-Path $script:repoRoot 'Modules\SysOrg.Core.psm1'
        $warns = @()
        $null = Import-Module $core -Force -WarningVariable warns -WarningAction SilentlyContinue 3>$null
        $unapproved = @(@($warns) | Where-Object { "$($_.Message)" -match 'unapproved verbs' })
        $unapproved.Count | Should -BeGreaterOrEqual 1
        # clean up for the next check
        Remove-Module SysOrg.Core -Force -ErrorAction SilentlyContinue
    }

    It 'importing WITH -DisableNameChecking is silent - the menu starts clean' {
        $core = Join-Path $script:repoRoot 'Modules\SysOrg.Core.psm1'
        $warns = @()
        $null = Import-Module $core -Force -DisableNameChecking -WarningVariable warns -WarningAction SilentlyContinue 3>$null
        $unapproved = @(@($warns) | Where-Object { "$($_.Message)" -match 'unapproved verbs' })
        $unapproved.Count | Should -Be 0
        Remove-Module SysOrg.Core -Force -ErrorAction SilentlyContinue
    }
}
