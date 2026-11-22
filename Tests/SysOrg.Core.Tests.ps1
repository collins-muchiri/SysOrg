# Tests/SysOrg.Core.Tests.ps1
# Covers: P0-3 (config merge + validation, extended for rev 2.1 policy keys),
#         W10 (Duplicates->Copies deprecation mapping), W9 (per-drive artifacts),
#         W3 (mutability engine), W7 (natural sort), P1-7 (exclusion segments),
#         P1-10 (copy-only), P2-1 (size-first collision check), P2-2 (header hash)

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1') -Force
}

Describe 'Merge-SysOrgHashtable' {
    It 'merges nested h[hashtables without losing sibling keys' {
        $base = @{ Copies = @{ Policy='NumberCopies'; MinFileSizeKB=256 }; DateFolders='Year' }
        $over = @{ Copies = @{ MinFileSizeKB=999 } }
        $merged = Merge-SysOrgHashtable -Base $base -Override $over
        $merged.Copies.MinFileSizeKB | Should -Be 999
        $merged.Copies.Policy        | Should -Be 'NumberCopies'
        $merged.DateFolders          | Should -Be 'Year'
    }
    It 'replaces non-h[hashtable values wholesale' {
        $base = @{ ExcludedPaths = @('C:\Windows') }
        $over = @{ ExcludedPaths = @('D:\Custom') }
        (Merge-SysOrgHashtable -Base $base -Override $over).ExcludedPaths | Should -Be 'D:\Custom'
    }
}

Describe 'Import-SysOrgConfig' {
    It 'applies a valid user config on top of defaults (nested override included)' {
        $file = Join-Path $TestDrive 'cfg-good.psd1'
        Set-Content -LiteralPath $file -Value "@{`n  OrganizedRoots = @{ C = 'X:\Org' }`n  Copies = @{ MinFileSizeKB = 999 }`n}"
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive
        $cfg.OrganizedRoots.C                | Should -Be 'X:\Org'
        $cfg.OrganizedRoots.ContainsKey('*') | Should -BeTrue      # sibling default preserved
        $cfg.Copies.MinFileSizeKB            | Should -Be 999
        $cfg.Copies.Policy                   | Should -Be 'NumberCopies'
    }
    It 'maps the deprecated Duplicates key to Copies with the v2.0 policy preserved (W10)' {
        $file = Join-Path $TestDrive 'cfg-old.psd1'
        Set-Content -LiteralPath $file -Value "@{`n  Duplicates = @{ Policy = 'Quarantine'; MinFileSizeKB = 777 }`n}"
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive
        $cfg.Copies.Policy        | Should -Be 'Quarantine'
        $cfg.Copies.MinFileSizeKB | Should -Be 777
        ($cfg -is [hashtable] -and -not $cfg.ContainsKey('Duplicates')) | Should -BeTrue
    }
    It 'fails closed: throws when the config file exists but cannot be parsed (v2.1.1)' {
        $file = Join-Path $TestDrive 'cfg-bad.psd1'
        Set-Content -LiteralPath $file -Value '@{ DateFolders = (Get-Date) }'
        { Import-SysOrgConfig -Path $file -AppRoot $TestDrive } | Should -Throw '*could not be parsed*'
    }
    It 'degraded mode (-AllowDegradedMode) continues with safe defaults after a loud warning (v2.1.1)' {
        $file = Join-Path $TestDrive 'cfg-bad2.psd1'
        Set-Content -LiteralPath $file -Value '@{ DateFolders = (Get-Date) }'
        $warned = $null
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive -AllowDegradedMode -WarningVariable warned -WarningAction SilentlyContinue
        $cfg.DateFolders | Should -Be 'Year'
        ($warned -join ' ') | Should -Match 'SAFE DEFAULTS'
    }
    It 'the non-overridable protection floor survives a user override of ExcludedPaths (v2.1.1)' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'the env-based floor paths (SystemRoot, Program Files) are Windows-specific; the portable part is asserted below'; return }
        $file = Join-Path $TestDrive 'cfg-floor.psd1'
        Set-Content -LiteralPath $file -Value "@{`n  ExcludedPaths = @('D:\Private')`n}"
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive
        Test-SysOrgExcludedPath -Path (Join-Path $env:SystemRoot 'evil.dll') -Config $cfg | Should -BeTrue
        Test-SysOrgExcludedPath -Path (Join-Path $env:ProgramFiles 'evil.dll') -Config $cfg | Should -BeTrue
        Test-SysOrgExcludedPath -Path (Join-Path $env:ProgramData 'evil.dll') -Config $cfg | Should -BeTrue
        Test-SysOrgExcludedPath -Path 'C:\$Recycle.Bin\x' -Config $cfg | Should -BeTrue
        Test-SysOrgExcludedPath -Path 'C:\System Volume Information\x' -Config $cfg | Should -BeTrue
        Test-SysOrgExcludedPath -Path 'D:\Private\keep.txt' -Config $cfg | Should -BeTrue   # the user rule is kept
    }
    It 'the per-drive floor names survive a hostile ExcludedPaths override (portable part)' {
        $file = Join-Path $TestDrive 'cfg-floor2.psd1'
        Set-Content -LiteralPath $file -Value "@{`n  ExcludedPaths = @('D:\Private')`n}"
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive
        (@($cfg.ExcludedPaths) | Where-Object { $_ -ieq '$Recycle.Bin' -or $_ -like '*\$Recycle.Bin' }) | Should -Not -BeNullOrEmpty
        (@($cfg.ExcludedPaths) | Where-Object { $_ -ieq 'System Volume Information' -or $_ -like '*\System Volume Information' }) | Should -Not -BeNullOrEmpty
    }
    It 'BlockedExtensions and ProtectedArtifacts merge additively: built-ins cannot be removed (v2.1.1)' {
        $file = Join-Path $TestDrive 'cfg-add.psd1'
        Set-Content -LiteralPath $file -Value "@{`n  Policy = @{`n    SystemDrive = @{ BlockedExtensions = @('.foo') }`n    DataDrives = @{ BlockedExtensions = @() }`n    ProtectedArtifacts = @('MyStuff')`n  }`n}"
        $warned = $null
        $cfg = Import-SysOrgConfig -Path $file -AppRoot $TestDrive -WarningVariable warned -WarningAction SilentlyContinue
        $cfg.Policy.SystemDrive.BlockedExtensions | Should -Contain '.foo'
        $cfg.Policy.SystemDrive.BlockedExtensions | Should -Contain '.dll'
        $cfg.Policy.SystemDrive.BlockedExtensions | Should -Contain '.lnk'
        $cfg.Policy.DataDrives.BlockedExtensions | Should -Contain '.dll'
        $cfg.Policy.SystemDrive.Scope | Should -Be 'KnownFolders'    # sibling defaults preserved by the deep merge
        $cfg.Policy.ProtectedArtifacts | Should -Contain 'MyStuff'
        $cfg.Policy.ProtectedArtifacts | Should -Contain 'Windows'
        ($warned -join ' ') | Should -Match 'cannot remove built-in entries'
    }
    It 'appends Policy.ProtectedArtifacts for every fixed drive (W9: WindowsApps included)' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'DriveInfo fixed-drive enumeration is Windows-specific'; return }
        $cfg = Import-SysOrgConfig -Path $null -AppRoot $TestDrive
        $cfg.ExcludedPaths | Where-Object { $_ -ieq 'C:\Windows' } | Should -Not -BeNullOrEmpty
        $fixed = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' })
        $fixed.Count | Should -BeGreaterThan 0
        foreach($drv in $fixed){
            $r = $drv.Name.TrimEnd('\')
            Test-SysOrgExcludedPath -Path ($r + '\WindowsApps') -Config $cfg | Should -BeTrue
            Test-SysOrgExcludedPath -Path ($r + '\XboxGames') -Config $cfg | Should -BeTrue
        }
    }
}

Describe 'Test-SysOrgConfig' {
    It 'accepts a valid configuration' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='NumberCopies'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Not -Throw
    }
    It 'rejects an unknown DateFolders value' {
        $cfg = @{ DateFolders='Decade'; Copies=@{Policy='NumberCopies'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*DateFolders*'
    }
    It 'rejects an unknown Copies.Policy value' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='Delete'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*Copies.Policy*'
    }
    It 'rejects FullDrive scope under Policy.SystemDrive (W10: whole-C is not supported)' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='NumberCopies'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9
                  Policy=@{ SystemDrive=@{ Scope='FullDrive' } } }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*SystemDrive.Scope*'
    }
    It 'rejects Copies.StartIndex below 2' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='NumberCopies'; StartIndex=1}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*StartIndex*'
    }
    It 'rejects a MainFolders value that does not match the naming preset' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='NumberCopies'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9
                  NamingPreset='Compact4'; MainFolders=@('Documents','Pictures','Videos','Music','Downloads') }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*MainFolders*'
    }
    It 'rejects a non-integer MaxPlanActions' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='NumberCopies'}; MaxPlanActions='many'
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*MaxPlanActions*'
    }
    It 'rejects an out-of-range PreserveSingleCategoryRatio' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='NumberCopies'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=1.5 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*PreserveSingleCategoryRatio*'
    }
}

Describe 'Sort-SysOrgNatural (W7)' {
    It 'orders file (2) before file (10), exactly like Explorer' {
        $sorted = Sort-SysOrgNatural -Values @('file (10).txt','file (2).txt')
        @($sorted)[0] | Should -Be 'file (2).txt'
        @($sorted)[1] | Should -Be 'file (10).txt'
    }
    It 'orders Track 2 before Track 11' {
        $sorted = Sort-SysOrgNatural -Values @('Track 11','Track 2')
        @($sorted)[0] | Should -Be 'Track 2'
    }
    It 'is deterministic for single elements and empty input' {
        @(Sort-SysOrgNatural -Values @()).Count | Should -Be 0
        Sort-SysOrgNatural -Values @('only.txt') | Should -Be 'only.txt'
    }
}

Describe 'Get-SysOrgCopyName (W6)' {
    It 'numbers copies with parentheses starting at the StartIndex' {
        Get-SysOrgCopyName -Stem 'Report' -Extension '.docx' -Index 2 | Should -Be 'Report (2).docx'
        Get-SysOrgCopyName -Stem 'Report' -Extension '.docx' -Index 3 | Should -Be 'Report (3).docx'
    }
    It 'DashCopy style uses Explorer paste naming' {
        Get-SysOrgCopyName -Stem 'Report' -Extension '.docx' -Index 2 -Style 'DashCopy' | Should -Be 'Report - Copy.docx'
        Get-SysOrgCopyName -Stem 'Report' -Extension '.docx' -Index 3 -Style 'DashCopy' | Should -Be 'Report - Copy (2).docx'
    }
}

Describe 'Get-SysOrgFolderMap (W4)' {
    It 'Windows preset uses the known-folder names' {
        $map = Get-SysOrgFolderMap -Config @{ NamingPreset='Windows' }
        $map['Pictures']   | Should -Be 'Pictures'
        $map['Music']      | Should -Be 'Music'
        $map['Archives']   | Should -Be 'Documents\Archives'
        $map['Installers'] | Should -Be 'Downloads\Installers'
    }
    It 'Compact4 preset restores the rev 2.0 roots' {
        $map = Get-SysOrgFolderMap -Config @{ NamingPreset='Compact4' }
        $map['Pictures'] | Should -Be 'Photo'
        $map['Videos']   | Should -Be 'Video'
        $map['Music']    | Should -Be 'Video\Audio'
    }
}

Describe 'Test-SysOrgFileMutable (W3)' {
    BeforeAll {
        $script:sysProf = [pscustomobject]@{
            Letter='C'; Role='System'; ProposedScope='KnownFolders'
            KnownFolders=@(
                [pscustomobject]@{ Name='Documents'; Path='C:\Users\t\Documents'; IsRedirected=$false; UnderOneDrive=$false },
                [pscustomobject]@{ Name='Downloads'; Path='C:\Users\t\Downloads'; IsRedirected=$false; UnderOneDrive=$false }
            )
            DownloadRoots=@('C:\Users\t\Downloads')
        }
        $script:mutCfg = @{ ExcludedPaths=@(); Policy=@{
            SystemDrive=@{ Scope='KnownFolders'; WritablePaths=@()
                BlockedExtensions=@('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url')
                AllowInstallersInDownloads=$true }
            DataDrives=@{ Scope='FullDrive'; WritablePaths=@()
                BlockedExtensions=@('.dll','.sys','.drv','.ocx','.cpl','.scr')
                AllowInstallersInDownloads=$true } } }
    }
    It '.dll inside Documents is denied (system drive)' {
        $r = Test-SysOrgFileMutable -Path 'C:\Users\t\Documents\library.dll' -Extension '.dll' -DriveProfile $sysProf -Config $mutCfg
        $r.Allowed | Should -BeFalse
        $r.Reason  | Should -Be 'Blocked extension .dll'
    }
    It '.exe inside Downloads is allowed (installer exception)' {
        (Test-SysOrgFileMutable -Path 'C:\Users\t\Downloads\setup.exe' -Extension '.exe' -DriveProfile $sysProf -Config $mutCfg).Allowed | Should -BeTrue
    }
    It '.exe inside Documents is denied (installers are movable only inside download roots)' {
        $r = Test-SysOrgFileMutable -Path 'C:\Users\t\Documents\tool.exe' -Extension '.exe' -DriveProfile $sysProf -Config $mutCfg
        $r.Allowed | Should -BeFalse
        $r.Reason  | Should -Be 'Installer outside download roots'
    }
    It 'a file outside the known folders is denied with the scope reason (W3 fixture)' {
        $r = Test-SysOrgFileMutable -Path 'C:\Loose\notes.txt' -Extension '.txt' -DriveProfile $sysProf -Config $mutCfg
        $r.Allowed | Should -BeFalse
        $r.Reason  | Should -Be 'Outside writable scope on system drive'
    }
    It 'WritablePaths extend the writable scope' {
        $cfg2 = @{ ExcludedPaths=@(); Policy=@{
            SystemDrive=@{ Scope='KnownFolders'; WritablePaths=@('C:\Work\Exports')
                BlockedExtensions=@('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url'); AllowInstallersInDownloads=$true }
            DataDrives=@{ Scope='FullDrive'; WritablePaths=@(); BlockedExtensions=@('.dll'); AllowInstallersInDownloads=$true } } }
        (Test-SysOrgFileMutable -Path 'C:\Work\Exports\notes.txt' -Extension '.txt' -DriveProfile $sysProf -Config $cfg2).Allowed | Should -BeTrue
    }
    It 'data drives default to FullDrive' {
        $dataProf = [pscustomobject]@{ Letter='D'; Role='Data'; KnownFolders=@(); DownloadRoots=@() }
        (Test-SysOrgFileMutable -Path 'D:\Anywhere\notes.txt' -Extension '.txt' -DriveProfile $dataProf -Config $mutCfg).Allowed | Should -BeTrue
    }
    It '-Container checks a folder path itself' {
        (Test-SysOrgFileMutable -Path 'C:\Users\t\Documents\Repo' -Extension '' -DriveProfile $sysProf -Config $mutCfg -Container).Allowed | Should -BeTrue
        (Test-SysOrgFileMutable -Path 'C:\Loose\Repo' -Extension '' -DriveProfile $sysProf -Config $mutCfg -Container).Allowed | Should -BeFalse
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
    It 'reattaches the Zone.Identifier stream after a verified cross-volume copy (rev 2.0 D7)' -Skip:($env:OS -ne 'Windows_NT' -or -not (Test-Path 'D:\')) {
        $crossDir = Join-Path 'D:\' ('SysOrgTest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        try{
            if((Split-Path $TestDrive -Qualifier) -ieq (Split-Path $crossDir -Qualifier)){ return }
            New-Item -ItemType Directory -Path $crossDir -Force | Out-Null
            $s = Join-Path $TestDrive 'zoned.exe'
            Set-Content -LiteralPath $s -Value ('Z' * 2048)
            Set-Content -LiteralPath $s -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`nZoneId=3`nHostUrl=https://example.org/file"
            $r = Invoke-SysOrgSafeMove -Source $s -Destination (Join-Path $crossDir 'zoned.exe') -Config $moveCfg
            $r.Status | Should -Be 'Moved'
            $destStream = Get-Content -LiteralPath $r.Destination -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
            ($destStream -join ' ') | Should -Match 'HostUrl=https://example.org/file'
        } finally {
            if(Test-Path -LiteralPath $crossDir){ Remove-Item -LiteralPath $crossDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Invoke-SysOrgSafeMoveFolder' {
    It 'moves a folder without overwriting an occupied destination' {
        $src = Join-Path $TestDrive 'proj\repo'
        New-Item -ItemType Directory -Path (Join-Path $src 'deep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'deep\a.txt') -Value 'a'
        $occupied = Join-Path $TestDrive 'moved\repo'
        New-Item -ItemType Directory -Path $occupied -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $occupied 'keep.txt') -Value 'keep'
        $r = Invoke-SysOrgSafeMoveFolder -Source $src -Destination $occupied -Config @{ Move=@{ AllowCrossVolume=$true } }
        $r.Status | Should -Be 'Moved'
        $r.Destination | Should -Be (Join-Path $TestDrive 'moved\repo (2)')
        Test-Path -LiteralPath (Join-Path $r.Destination 'deep\a.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $occupied 'keep.txt') | Should -BeTrue
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

Describe 'Resolve-SysOrgWritablePath (v2.1.1)' {
    It 'resolves a relative path to a full canonical path' {
        Push-Location $TestDrive
        try{
            New-Item -ItemType Directory -Path 'rel-sub' -Force | Out-Null
            $r = Resolve-SysOrgWritablePath -Path 'rel-sub'
            [System.IO.Path]::IsPathRooted($r) | Should -BeTrue
            ("$r").Replace('/','\').ToLowerInvariant() | Should -Be (("$TestDrive").Replace('/','\').TrimEnd('\').ToLowerInvariant() + '\rel-sub')
        } finally { Pop-Location }
    }
    It 'throws for a path that does not exist' {
        { Resolve-SysOrgWritablePath -Path (Join-Path $TestDrive 'no-such-dir-xyz') } | Should -Throw '*does not exist*'
    }
    It 'canonicalizes an existing absolute path' {
        $d = Join-Path $TestDrive 'abs-sub'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Resolve-SysOrgWritablePath -Path $d | Should -Be ([System.IO.Path]::GetFullPath($d))
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
            PlanId  = 'plan-20260101-093000'
            Actions = @([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src; Destination=$dest; Reason='Category=Documents'; SizeBytes=3 })
        }
        $planPath = Join-Path $TestDrive 'plan.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $cfgRound = @{ AppRoot=$TestDrive; OrganizedRoots=@{ '*'='__AUTO__' }
                      Copies=@{ QuarantineFolderName='_Duplicates' }; Move=@{ AllowCrossVolume=$true } }
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfgRound -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 1
        Test-Path -LiteralPath $src | Should -BeFalse
        $u = Undo-SysOrgPlan -PlanId 'plan-20260101-093000' -AppRoot $TestDrive -Config $cfgRound
        $u.Restored | Should -Be 1
        Test-Path -LiteralPath $src | Should -BeTrue
    }
}

Describe 'Folder-move safety (v2.1.1)' {
    It 'refuses a folder that contains a junction (Windows) or symlink (POSIX) and keeps the source' {
        $src = Join-Path $TestDrive 'linked\repo'
        New-Item -ItemType Directory -Path (Join-Path $src 'real') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'real\a.txt') -Value 'a'
        $created = $false
        try{
            if($env:OS -eq 'Windows_NT'){
                $null = New-Item -ItemType Junction -Path (Join-Path $src 'link') -Target (Join-Path $src 'real') -ErrorAction Stop
                $created = $true
            } else {
                $null = New-Item -ItemType SymbolicLink -Path (Join-Path $src 'linkdir') -Target (Join-Path $src 'real') -ErrorAction Stop
                $created = $true
            }
        } catch {
            if(-not $created){ Set-ItResult -Inconclusive -Because 'link creation is not permitted on this host'; return }
        }
        $dst = Join-Path $TestDrive 'linked\moved\repo'
        $r = Invoke-SysOrgSafeMoveFolder -Source $src -Destination $dst -Config @{ Move=@{ AllowCrossVolume=$true } }
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'reparse point|junction or symlink'
        Test-Path -LiteralPath $src | Should -BeTrue                       # source kept
        Test-Path -LiteralPath $dst | Should -BeFalse                      # nothing moved
        (Test-SysOrgFolderHasReparsePoint -Path $src).HasLink | Should -BeTrue
    }
    It 'moves a clean folder normally (no false positives from the reparse walk)' {
        $src = Join-Path $TestDrive 'clean\repo'
        New-Item -ItemType Directory -Path (Join-Path $src 'deep\nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'deep\nested\a.txt') -Value 'a'
        Set-Content -LiteralPath (Join-Path $src 'b.txt') -Value 'b'
        (Test-SysOrgFolderHasReparsePoint -Path $src).HasLink | Should -BeFalse
        $r = Invoke-SysOrgSafeMoveFolder -Source $src -Destination (Join-Path $TestDrive 'clean\moved\repo') -Config @{ Move=@{ AllowCrossVolume=$true } }
        $r.Status | Should -Be 'Moved'
        Test-Path -LiteralPath (Join-Path $r.Destination 'deep\nested\a.txt') | Should -BeTrue
    }
    It 'verification mismatch (mocked) keeps the source on a cross-volume move' -Skip:(-not (Test-Path 'D:\')) {
        if((Split-Path $TestDrive -Qualifier) -ieq 'D:'){ Set-ItResult -Inconclusive -Because 'no second volume available on this machine'; return }
        $crossDir = Join-Path 'D:\' ('SysOrgTest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        try{
            New-Item -ItemType Directory -Path $crossDir -Force | Out-Null
            $src = Join-Path $TestDrive 'vfail\repo'
            New-Item -ItemType Directory -Path $src -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src 'data.bin') -Value ('V' * 2048)
            # destination-side hashes are stubbed so verification must fail
            Mock Get-SysOrgFileHash -ModuleName SysOrg.Core {
                param($Path)
                if("$Path" -like "$crossDir*"){ return 'FAKE-DEST-HASH' }
                return 'REAL-SRC-HASH'
            }
            $r = Invoke-SysOrgSafeMoveFolder -Source $src -Destination (Join-Path $crossDir 'repo') -Config @{ Move=@{ AllowCrossVolume=$true } }
            $r.Status | Should -Be 'Failed'
            $r.Message | Should -Match 'SHA256 mismatch|count mismatch'
            Test-Path -LiteralPath (Join-Path $src 'data.bin') | Should -BeTrue   # source kept
        } finally {
            if(Test-Path -LiteralPath $crossDir){ Remove-Item -LiteralPath $crossDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
