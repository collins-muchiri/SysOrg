# Tests/SysOrg.Core.Tests.ps1
# Covers: P0-3 (config merge + validation), P1-7 (exclusion segments),
#         P1-10 (copy-only), P2-1 (size-first collision check), P2-2 (header hash)

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1') -Force
}

Describe 'Merge-SysOrgHashtable' {
    It 'merges nested hashtables without losing sibling keys' {
        $base = @{ Duplicates = @{ Policy='Quarantine'; MinFileSizeKB=256 }; DateFolders='Year' }
        $over = @{ Duplicates = @{ MinFileSizeKB=999 } }
        $merged = Merge-SysOrgHashtable -Base $base -Override $over
        $merged.Duplicates.MinFileSizeKB | Should -Be 999
        $merged.Duplicates.Policy        | Should -Be 'Quarantine'
        $merged.DateFolders              | Should -Be 'Year'
    }
    It 'replaces non-hashtable values wholesale' {
        $base = @{ ExcludedPaths = @('C:\Windows') }
        $over = @{ ExcludedPaths = @('D:\Custom') }
        (Merge-SysOrgHashtable -Base $base -Override $over).ExcludedPaths | Should -Be 'D:\Custom'
    }
}

Describe 'Import-SysOrgConfig' {
    It 'applies a valid user config on top of defaults (nested override included)' {
        $file = Join-Path $TestDrive 'cfg-good.psd1'
        Set-Content -LiteralPath $file -Value "@{`n  OrganizedRoots = @{ C = 'X:\Org' }`n  Duplicates = @{ MinFileSizeKB = 999 }`n}"
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive
        $cfg.OrganizedRoots.C                | Should -Be 'X:\Org'
        $cfg.OrganizedRoots.ContainsKey('*') | Should -BeTrue      # sibling default preserved
        $cfg.Duplicates.MinFileSizeKB        | Should -Be 999
        $cfg.Duplicates.Policy               | Should -Be 'Quarantine'
    }
    It 'falls back to defaults when the config file cannot be parsed' {
        $file = Join-Path $TestDrive 'cfg-bad.psd1'
        Set-Content -LiteralPath $file -Value '@{ DateFolders = (Get-Date) }'
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive
        $cfg.DateFolders | Should -Be 'Year'
    }
    It 'appends system locations for every fixed drive (C:\Windows always present)' {
        $cfg = Import-SysOrgConfig -Path $null -AppRoot $TestDrive
        $cfg.ExcludedPaths | Where-Object { $_ -ieq 'C:\Windows' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-SysOrgConfig' {
    It 'accepts a valid configuration' {
        $cfg = @{ DateFolders='Year'; Duplicates=@{Policy='Quarantine'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Not -Throw
    }
    It 'rejects an unknown DateFolders value' {
        $cfg = @{ DateFolders='Decade'; Duplicates=@{Policy='Quarantine'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*DateFolders*'
    }
    It 'rejects an unknown Duplicates.Policy value' {
        $cfg = @{ DateFolders='Year'; Duplicates=@{Policy='Delete'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*Duplicates.Policy*'
    }
    It 'rejects a non-integer MaxPlanActions' {
        $cfg = @{ DateFolders='Year'; Duplicates=@{Policy='Quarantine'}; MaxPlanActions='many'
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*MaxPlanActions*'
    }
    It 'rejects an out-of-range PreserveSingleCategoryRatio' {
        $cfg = @{ DateFolders='Year'; Duplicates=@{Policy='Quarantine'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=1.5 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*PreserveSingleCategoryRatio*'
    }
}

Describe 'Get-SysOrgUniquePath' {
    It 'returns the input when the path is free' {
        $p = Join-Path $TestDrive 'free.txt'
        Get-SysOrgUniquePath -Path $p | Should -Be $p
    }
    It 'appends (2) when the path is taken' {
        $p = Join-Path $TestDrive 'taken.txt'
        Set-Content -LiteralPath $p -Value 'a'
        Get-SysOrgUniquePath -Path $p | Should -Be (Join-Path $TestDrive 'taken (2).txt')
    }
    It 'appends (3) when (2) is also taken' {
        $p = Join-Path $TestDrive 'twice.txt'
        Set-Content -LiteralPath $p -Value 'a'
        Set-Content -LiteralPath (Join-Path $TestDrive 'twice (2).txt') -Value 'b'
        Get-SysOrgUniquePath -Path $p | Should -Be (Join-Path $TestDrive 'twice (3).txt')
    }
}

Describe 'Invoke-SysOrgSafeMove' {
    BeforeAll {
        $script:moveCfg = @{ Move = @{ AllowCrossVolume = $true } }
    }
    It 'never overwrites different content - target gets " (2)" suffix' {
        $s = Join-Path $TestDrive 'src.txt'; $d = Join-Path $TestDrive 'dst.txt'
        Set-Content -LiteralPath $s -Value 'new'
        Set-Content -LiteralPath $d -Value 'old'
        $r = Invoke-SysOrgSafeMove -Source $s -Destination $d -Config $moveCfg
        $r.Status | Should -Be 'Moved'
        $r.Destination | Should -Be (Join-Path $TestDrive 'dst (2).txt')
        Get-Content -LiteralPath $d | Should -Be 'old'
    }
    It 'flags identical content as CollisionDuplicate and keeps the source' {
        $s = Join-Path $TestDrive 'same1.txt'; $d = Join-Path $TestDrive 'same2.txt'
        Set-Content -LiteralPath $s -Value 'x'
        Set-Content -LiteralPath $d -Value 'x'
        (Invoke-SysOrgSafeMove -Source $s -Destination $d -Config $moveCfg).Status | Should -Be 'CollisionDuplicate'
        Test-Path -LiteralPath $s | Should -BeTrue
    }
    It 'does not treat different content of equal length as a duplicate' {
        $s = Join-Path $TestDrive 'eq1.txt'; $d = Join-Path $TestDrive 'eq2.txt'
        Set-Content -LiteralPath $s -Value 'aaa'
        Set-Content -LiteralPath $d -Value 'bbb'
        $r = Invoke-SysOrgSafeMove -Source $s -Destination $d -Config $moveCfg
        $r.Status | Should -Be 'Moved'
        $r.Destination | Should -Be (Join-Path $TestDrive 'eq2 (2).txt')
    }
    It 'copy-only mode (AllowCrossVolume=$false) copies, verifies and keeps the source' -Skip:(-not (Test-Path 'D:\')) {
        $crossDir = Join-Path 'D:\' ('SysOrgTest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        try{
            if((Split-Path $TestDrive -Qualifier) -ieq (Split-Path $crossDir -Qualifier)){ return } # no cross-volume point available on this machine
            New-Item -ItemType Directory -Path $crossDir -Force | Out-Null
            $cfgCopyOnly = @{ Move = @{ AllowCrossVolume = $false } }
            $s = Join-Path $TestDrive 'cross.txt'
            Set-Content -LiteralPath $s -Value ('C' * 4096)
            $r = Invoke-SysOrgSafeMove -Source $s -Destination (Join-Path $crossDir 'cross.txt') -Config $cfgCopyOnly
            $r.Status | Should -Be 'CopiedVerified'
            Test-Path -LiteralPath $s | Should -BeTrue                     # source kept
            (Get-Item -LiteralPath $s).Length | Should -Be (Get-Item -LiteralPath $r.Destination).Length
        } finally {
            if(Test-Path -LiteralPath $crossDir){ Remove-Item -LiteralPath $crossDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Test-SysOrgExcludedPath segment matching (P1-7)' {
    BeforeAll {
        $script:exCfg = @{ ExcludedPaths = @('Recovery','$Recycle.Bin','System Volume Information','D:\Windows','C:\Users\*\AppData') }
    }
    It 'protects D:\Recovery via root-less segment match' {
        Test-SysOrgExcludedPath -Path 'D:\Recovery' -Config $exCfg | Should -BeTrue
    }
    It 'protects E:\$Recycle.Bin via root-less segment match' {
        Test-SysOrgExcludedPath -Path 'E:\$Recycle.Bin' -Config $exCfg | Should -BeTrue
    }
    It 'does not exclude a user folder that merely contains the word (Recovery-notes)' {
        Test-SysOrgExcludedPath -Path 'D:\Projects\Recovery-notes' -Config $exCfg | Should -BeFalse
    }
    It 'honors absolute rules on other drives (D:\Windows)' {
        Test-SysOrgExcludedPath -Path 'D:\Windows\System32' -Config $exCfg | Should -BeTrue
    }
    It 'honors wildcard rules (AppData under any user)' {
        Test-SysOrgExcludedPath -Path 'C:\Users\alice\AppData\Local\Temp' -Config $exCfg | Should -BeTrue
    }
}

Describe 'Get-SysOrgFileHash (P2-2)' {
    It 'header hash equals the SHA256 of the first HeaderKB bytes' {
        $p = Join-Path $TestDrive 'prefix.bin'
        $bytes = New-Object byte[] (300000)
        $rnd = New-Object System.Random 42
        $rnd.NextBytes($bytes)
        [System.IO.File]::WriteAllBytes($p, $bytes)
        $fs = [System.IO.File]::OpenRead($p)
        $buf = New-Object byte[] 65536
        [void]$fs.Read($buf,0,65536); $fs.Dispose()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $expect = ([System.BitConverter]::ToString($sha.ComputeHash($buf))).Replace('-','')
        $sha.Dispose()
        Get-SysOrgFileHash -Path $p -HeaderOnly -HeaderKB 64 | Should -Be $expect
    }
    It 'header hash of a file smaller than HeaderKB equals the full-file hash' {
        $p = Join-Path $TestDrive 'small.txt'
        Set-Content -LiteralPath $p -Value 'abc'
        (Get-SysOrgFileHash -Path $p -HeaderOnly -HeaderKB 64) | Should -Be (Get-SysOrgFileHash -Path $p)
    }
}

Describe 'Execute and undo round trip' {
    It 'restores a moved file to its original path' {
        $src = Join-Path $TestDrive 'work\report.pdf'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'pdf'
        $dest = Join-Path $TestDrive 'org\Documents\2026\report.pdf'
        $plan = [pscustomobject]@{
            PlanId  = 'plan-test-0001'
            Actions = @([pscustomobject]@{ Action='Move'; Source=$src; Destination=$dest; Reason='Category=Documents'; SizeBytes=3 })
        }
        $planPath = Join-Path $TestDrive 'plan.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $cfgRound = @{ AppRoot=$TestDrive; OrganizedRoots=@{ '*'='__AUTO__' }
                      Duplicates=@{ QuarantineFolderName='_Duplicates' }; Move=@{ AllowCrossVolume=$true } }
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfgRound -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 1
        Test-Path -LiteralPath $src | Should -BeFalse
        $u = Undo-SysOrgPlan -PlanId 'plan-test-0001' -AppRoot $TestDrive -Config $cfgRound
        $u.Restored | Should -Be 1
        Test-Path -LiteralPath $src | Should -BeTrue
    }
}
