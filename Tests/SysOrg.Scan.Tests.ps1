# Tests/SysOrg.Scan.Tests.ps1
# Covers: P1-5 (cloud placeholder skip), P1-8 (.sysorg-ignore tree exclusion),
#         P1-9 (cache keyed to config content), P2-5 (reparse + long paths), P2-6 (stable clustering)
# Note: imports the Audit module too - the inventory safety gates live there.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')  -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')  -Force
    $script:scanCfg = @{
        ExcludedPaths          = @()
        ExcludedFilePatterns   = @()
        SkipHiddenSystemFiles  = $true
        ExcludeDestinations    = $true
        OrganizedRoots         = @{ '*' = '__AUTO__' }
        PreserveExistingFolders = $true
        AlwaysScanFolders      = @()
        ProjectDetection       = @{ Enabled = $true; MinFiles = 3; MaxProjects = 200 }
        Duplicates             = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=1; HeaderHashKB=64 }
        FolderAudit            = @{ Enabled=$true; SkipHiddenSystemDirs=$true; RespectDefenderCFA=$false }
        Categories             = @{}
    }
    $script:letter = (Split-Path $TestDrive -Qualifier).TrimEnd(':')
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
        $root = Join-Path $TestDrive ('cloud-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $p1 = Join-Path $root 'offline.txt'
        $p2 = Join-Path $root 'recall.txt'
        $p3 = Join-Path $root 'normal.txt'
        Set-Content -LiteralPath $p1 -Value 'a'; Set-Content -LiteralPath $p2 -Value 'b'; Set-Content -LiteralPath $p3 -Value 'c'
        $f1 = Get-Item -LiteralPath $p1
        $f1.Attributes = ($f1.Attributes -bor [System.IO.FileAttributes]::Offline)
        $f2 = Get-Item -LiteralPath $p2
        $f2.Attributes = [System.IO.FileAttributes](([int]$f2.Attributes) -bor 0x400000)   # RecallOnDataAccess
        (($f1.Attributes -band [System.IO.FileAttributes]::Offline) -ne 0) | Should -BeTrue
        ((([int]$f2.Attributes) -band 0x400000) -ne 0) | Should -BeTrue
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $names = @($inv | ForEach-Object { $_.Name })
        $names.Count | Should -Be 1
        $names[0] | Should -Be 'normal.txt'
    }
    It 'does not descend into directory junctions (P2-5)' {
        $root  = Join-Path $TestDrive ('junc-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'real') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'real\a.txt') -Value 'a'
        # mklink /J works on PowerShell 5.1 without elevation
        $null = cmd /c mklink /J "`"$(Join-Path $root 'link')`" `"$(Join-Path $root 'real')`""
        Test-Path -LiteralPath (Join-Path $root 'link') | Should -BeTrue
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        @($inv | Where-Object { $_.Name -eq 'a.txt' }).Count | Should -Be 1   # found once, not through the junction
    }
    It 'long paths are recorded as SkippedLongPath and not categorized normally (P2-5)' {
        $root = Join-Path $TestDrive ('deep-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $deep = $root
        while($deep.Length -lt 280){ $deep = Join-Path $deep ('dddddddddd') }
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        # create via the \\?\ namespace: Set-Content would throw PathTooLong on 5.1
        [System.IO.File]::WriteAllText(('\\?\' + (Join-Path $deep 'waydown.txt')), 'd')
        Set-Content -LiteralPath (Join-Path $root 'shallow.txt') -Value 's'
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $shallow = @($inv | Where-Object { $_.Name -eq 'shallow.txt' })
        $shallow.Count | Should -Be 1
        $shallow[0].Category | Should -Be 'Documents'
        # whatever the environment can enumerate beyond 260 chars must be recorded, not planned
        $deepRecords = @($inv | Where-Object { $_.FullName -like "$deep*" })
        foreach($r in $deepRecords){ $r.Category | Should -Be 'SkippedLongPath' }
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
        Set-Content -LiteralPath (Join-Path $cfgRoot 'SysOrg.config.psd1') -Value '@{ Version = "1.2.0" }'
        $cfg = @{ AppRoot = $cfgRoot; ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true
                  ExcludeDestinations=$true; OrganizedRoots=@{ '*'='__AUTO__' }; PreserveExistingFolders=$true
                  AlwaysScanFolders=@(); ProjectDetection=@{Enabled=$true;MinFiles=3;MaxProjects=200}
                  Duplicates=@{Policy='Quarantine';QuarantineFolderName='_Duplicates';MinFileSizeKB=1}
                  FolderAudit=@{Enabled=$true;RespectDefenderCFA=$false}; Categories=@{} }
        $null = Get-SysOrgInventory -Letter $letter -Config $cfg -Roots $scanR -CacheFolder $cacheF -NoCache
        $first = @(Get-ChildItem -LiteralPath $cacheF -File)
        $first.Count | Should -Be 1
        $first[0].Name | Should -Match '^inventory-.*-custom-[0-9A-F]{8}\.json$'
        # edit the config -> different hash tag -> new cache file
        Add-Content -LiteralPath (Join-Path $cfgRoot 'SysOrg.config.psd1') -Value '# edited'
        $null = Get-SysOrgInventory -Letter $letter -Config $cfg -Roots $scanR -CacheFolder $cacheF -NoCache
        $two = @(Get-ChildItem -LiteralPath $cacheF -File)
        $two.Count | Should -Be 2
        $two[0].Name | Should -Not -Be $two[1].Name
        # third run without -NoCache reuses the fresh cache and creates no third file
        $null = Get-SysOrgInventory -Letter $letter -Config $cfg -Roots $scanR -CacheFolder $cacheF
        @(Get-ChildItem -LiteralPath $cacheF -File).Count | Should -Be 2
    }
}

Describe 'Get-SysOrgProjectClusters (P2-6)' {
    It 'clusters files sharing the same distinctive tokens regardless of word order' {
        $root = Join-Path $TestDrive ('clust-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $files = @('Report Q3 2025 Final.txt','Final Q3 Report 2025.docx','final report 2025 q3.pdf')
        foreach($n in $files){ Set-Content -LiteralPath (Join-Path $root $n) -Value 'x' }
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $c = Get-SysOrgProjectClusters -Inventory $inv -Config $scanCfg
        $keys = @($files | ForEach-Object { $c.Lookup[(Join-Path $root $_)] })
        @($keys | Where-Object { $_ }).Count | Should -Be 3
        @($keys | Select-Object -Unique).Count | Should -Be 1
    }
    It 'falls back to the "cluster" slug for non-ASCII stems' {
        $root = Join-Path $TestDrive ('slug-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $stem = [string]::Concat([char]0x6587, [char]0x6863)   # CJK stem -> empty ASCII slug
        foreach($ext in @('.docx','.pdf','.txt')){ Set-Content -LiteralPath (Join-Path $root ($stem + $ext)) -Value 'x' }
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $c = Get-SysOrgProjectClusters -Inventory $inv -Config $scanCfg
        @($c.Clusters).Count | Should -Be 1
        $c.Clusters[0].Key | Should -Match 'cluster$'
    }
}

Describe 'Classification' {
    It 'maps common extensions to categories' {
        $root = Join-Path $TestDrive ('cat-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'a.pdf') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'b.jpg') -Value 'x'
        Set-Content -LiteralPath (Join-Path $root 'c.py')  -Value 'x'
        $inv = @(Get-SysOrgInventory -Letter $letter -Config $scanCfg -Roots $root)
        $map = @{}
        foreach($r in $inv){ $map[$r.Name] = $r.Category }
        $map['a.pdf'] | Should -Be 'Documents'
        $map['b.jpg'] | Should -Be 'Images'
        $map['c.py']  | Should -Be 'Code'
    }
}
