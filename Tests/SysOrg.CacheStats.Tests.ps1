# ---------------------------------------------------------------------------
# v3.0.2 C1: cache-statistics honesty. The real run printed
# 'Inventory cache: age 0h -  file(s) reused, 1572 changed' for 1,570 scanned
# files: the Reused counter was never set and Changed lumped in two placeholder
# files that were counted BEFORE the filters rejected them. Now the four
# counters (reused / changed / new / removed) always exist and reused + changed
# + new adds up to the files scanned, a rebuild is STATED ('cache rebuilt:
# <reason>'), and the cache format is versioned.
# ---------------------------------------------------------------------------
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')  -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Cache.psm1')  -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Catalog.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')  -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')  -Force -DisableNameChecking
}

Describe 'inventory cache statistics add up (v3.0.2 C1)' {

    It 'scanning the same unchanged tree twice reports >= 95% reused and sums to scanned' {
        $tree = Join-Path $TestDrive ('c1tree-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $cache = Join-Path $TestDrive ('c1cache-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        1..20 | ForEach-Object { Set-Content -LiteralPath (Join-Path $tree "doc $_.txt") -Value ("content " + $_) }
        $cfg = @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true }; TypeMap=@{} }

        $stats1 = @{}
        $inv1 = @(Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache -CacheStatsOut $stats1)
        @($inv1).Count | Should -Be 20
        $stats1.Reused | Should -Be 0
        ($stats1.Changed + $stats1.New) | Should -Be 20
        ($stats1.Reused + $stats1.Changed + $stats1.New) | Should -Be $stats1.Scanned
        # the versioned inventory cache must actually be persisted
        $cacheFile = @(Get-ChildItem -LiteralPath $cache -Filter 'inventory-*.json' -File)
        @($cacheFile).Count | Should -Be 1
        (Get-Content -LiteralPath $cacheFile[0].FullName -Raw | ConvertFrom-Json).PSObject.Properties['ScannerVersion'] | Should -Not -BeNullOrEmpty

        $stats2 = @{}
        $inv2 = @(Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache -CacheStatsOut $stats2)
        @($inv2).Count | Should -Be 20
        $stats2.Reused | Should -BeGreaterOrEqual 19 -Because 'an unchanged tree must reuse at least 95% of its records'
        $stats2.Removed | Should -Be 0
        ($stats2.Reused + $stats2.Changed + $stats2.New) | Should -Be $stats2.Scanned
        ($stats2.Reused + $stats2.Changed + $stats2.New) | Should -Be 20
    }

    It 'a deleted file is counted as removed, not as changed' {
        $tree = Join-Path $TestDrive ('c1del-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $cache = Join-Path $TestDrive ('c1delcache-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        1..5 | ForEach-Object { Set-Content -LiteralPath (Join-Path $tree "f$_.txt") -Value "v$_" }
        $cfg = @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true }; TypeMap=@{} }
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache
        Remove-Item -LiteralPath (Join-Path $tree 'f3.txt') -Force
        $stats = @{}
        $inv = @(Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache -CacheStatsOut $stats)
        @($inv).Count | Should -Be 4
        $stats.Removed | Should -Be 1
        $stats.Reused | Should -Be 4
        ($stats.Reused + $stats.Changed + $stats.New) | Should -Be $stats.Scanned
    }

    It 'a changed file counts as changed, an added file as new' {
        $tree = Join-Path $TestDrive ('c1chg-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $cache = Join-Path $TestDrive ('c1chgcache-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'v1'
        Set-Content -LiteralPath (Join-Path $tree 'b.txt') -Value 'keep'
        $cfg = @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true }; TypeMap=@{} }
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache
        Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'v2 now much longer content'
        Set-Content -LiteralPath (Join-Path $tree 'c.txt') -Value 'added'
        $stats = @{}
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache -CacheStatsOut $stats
        $stats.Changed | Should -Be 1
        $stats.New | Should -Be 1
        $stats.Reused | Should -Be 1
    }
}

Describe 'cache rebuild reasons are stated (v3.0.2 C1)' {

    It 'a cache written by a different scanner version is rebuilt with a stated reason' {
        $tree = Join-Path $TestDrive ('c1ver-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $cache = Join-Path $TestDrive ('c1vercache-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'v'
        $cfg = @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true }; TypeMap=@{} }
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache
        # rewrite the cache with a FOREIGN version marker
        $cacheFile = @(Get-ChildItem -LiteralPath $cache -Filter 'inventory-*.json' -File)[0]
        $j = Get-Content -LiteralPath $cacheFile.FullName -Raw | ConvertFrom-Json
        $j.ScannerVersion = '0.0.0-foreign'
        @{ ScannerVersion='0.0.0-foreign'; Records=$j.Records } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cacheFile.FullName -Encoding UTF8
        $stats = @{}
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache -CacheStatsOut $stats
        "$($stats.RebuiltReason)" | Should -Match 'scanner version changed'
        # and the rebuilt cache carries the CURRENT version again
        (Get-Content -LiteralPath $cacheFile.FullName -Raw | ConvertFrom-Json).ScannerVersion | Should -Not -Be '0.0.0-foreign'
    }

    It 'a legacy bare-array cache is accepted but flagged as a version rebuild' {
        $tree = Join-Path $TestDrive ('c1legacy-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $cache = Join-Path $TestDrive ('c1legacycache-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'v'
        $cfg = @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true }; TypeMap=@{} }
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache
        $cacheFile = @(Get-ChildItem -LiteralPath $cache -Filter 'inventory-*.json' -File)[0]
        # degrade to the pre-3.0.2 format (bare record array; -InputObject keeps a
        # single-element array an array on both PowerShell versions)
        $legacyJson = ConvertTo-Json -InputObject (Get-Content -LiteralPath $cacheFile.FullName -Raw | ConvertFrom-Json).Records -Depth 4
        Set-Content -LiteralPath $cacheFile.FullName -Value $legacyJson -Encoding UTF8
        $stats = @{}
        $inv = @(Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg -CacheFolder $cache -CacheStatsOut $stats)
        "$($stats.RebuiltReason)" | Should -Match 'pre-3.0.2 cache format'
        @($inv).Count | Should -Be 1 -Because 'legacy records are still usable after validation'
    }

    It 'a changed config is reported as "config changed"' {
        $tree = Join-Path $TestDrive ('c1cfg-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $cache = Join-Path $TestDrive ('c1cfgcache-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $appDir = Join-Path $TestDrive ('c1cfgapp-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'v'
        Set-Content -LiteralPath (Join-Path $appDir 'SysOrg.config.psd1') -Value "@{ TypeMap = @{} }"
        $cfg1 = @{ AppRoot=$appDir; ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true }; TypeMap=@{} }
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg1 -CacheFolder $cache
        # change the config on disk -> different config hash -> different cache name
        Set-Content -LiteralPath (Join-Path $appDir 'SysOrg.config.psd1') -Value "@{ TypeMap = @{}; DateFolders = 'None' }"
        $stats = @{}
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config $cfg1 -CacheFolder $cache -CacheStatsOut $stats
        "$($stats.RebuiltReason)" | Should -Be 'config changed'
    }
}
