# Tests/SysOrg.Plan.Tests.ps1
# Covers: P0-2 (sum correctness), P1-1 (journal), P1-3 (re-execution guard + resume),
#         P1-4 (hash-mismatch undo skip), P1-10 (honest Copied counting), P2-1 (hash economy),
#         P2-5 (SkippedLongPath excluded from plans),
#         W1 (no plan without a profile), W6 (numbered copies + undo restore)

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force
    $script:fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
    $script:planCfg = @{
        AppRoot        = $TestDrive
        OrganizedRoots = @{ '*' = '__AUTO__' }
        Copies         = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=0; HeaderHashKB=64 }
        Families       = @{ Enabled=$false }
        Downloads      = @{ UseZoneIdentifier=$false }
        Move           = @{ AllowCrossVolume = $true }
        ExcludedPaths  = @()
        ExcludedFilePatterns = @()
        SkipHiddenSystemFiles = $true
        ExcludeDestinations = $true
        PreserveExistingFolders = $false
        DateFolders = 'Year'
        FolderAudit = @{ Enabled = $false }
        TypeMap = @{}
    }
}

Describe 'No plan without a profile (W1)' {
    It 'refuses to build a plan when the drive profile is missing' {
        $inv = @([pscustomobject]@{ FullName='C:\src\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\src'; Category='Documents' })
        { New-SysOrgPlan -Letter T -Inventory $inv -Config $planCfg } | Should -Throw '*profile*'
        { New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $null -Config $planCfg } | Should -Throw '*profile*'
    }
}

Describe 'Execute, re-execution guard and resume (P1-3)' {
    It 'refuses to re-execute a plan that already has an undo journal' {
        $src = Join-Path $TestDrive 'work2\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v1'
        $dest = Join-Path $TestDrive 'org2\Documents\2026\doc.txt'
        $plan = [pscustomobject]@{ PlanId='plan-20260101-093002'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src; Destination=$dest; Reason='Category=Documents'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'plan2.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 1
        { Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive } |
            Should -Throw '*already has an undo journal*'
    }
    It '-Force resumes: journaled sources are skipped and the journal is preserved' {
        $planPath = Join-Path $TestDrive 'plan2.json'
        $undoPath = Join-Path $TestDrive ('Undo\undo-plan-20260101-093002.csv')
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
        $planId = 'plan-20260101-093003'
        $plan = [pscustomobject]@{ PlanId=$planId
            Actions=@(
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcA; Destination=$dstA; Reason='Category=Documents'; SizeBytes=2 },
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcB; Destination=$dstB; Reason='Category=Documents'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'plan3.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        # simulate a crashed first run: action A already executed and journaled
        New-Item -ItemType Directory -Path (Split-Path $dstA) -Force | Out-Null
        Move-Item -LiteralPath $srcA -Destination $dstA
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash',
            ('"2026-01-01T00:00:00","{0}","File","Move","{1}","{2}",""' -f $planId, $srcA, $dstA)
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
        $planId = 'plan-20260101-093004'
        $current = Join-Path $TestDrive 'org4\Documents\2026\gone.txt'
        $original = Join-Path $TestDrive 'work4\gone.txt'
        New-Item -ItemType Directory -Path (Split-Path $current) -Force | Out-Null
        Set-Content -LiteralPath $current -Value 'original-content'
        $hash = (Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash
        Set-Content -LiteralPath $current -Value 'USER EDITED THIS LATER'   # content changed since move
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash',
            ('"2026-01-01T00:00:00","{0}","File","Move","{1}","{2}","{3}"' -f $planId, $original, $current, $hash)
        ) -Encoding UTF8
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot $TestDrive -Config $planCfg
        $u.SkippedChanged | Should -Be 1
        $u.Restored | Should -Be 0
        (Get-Content -LiteralPath $current | Out-String).Trim() | Should -Be 'USER EDITED THIS LATER'
    }
}

Describe 'Duplicate groups and sums (P0-2, W6 keeper rule)' {
    It 'reports non-zero WastedBytes; keeper is the OLDEST write time (rev 2.1 rule)' {
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
        $groups = @(Find-SysOrgDuplicates -Inventory $inv -Config $planCfg)
        $groups.Count | Should -Be 1
        $groups[0].WastedBytes | Should -Be 20
        $groups[0].KeepPath | Should -Be (Join-Path $root 'first.txt')   # oldest = keeper
        $groups[0].Duplicates.Count | Should -Be 1
        $groups[0].Duplicates[0] | Should -Be (Join-Path $root 'second.txt')
    }
    It 'Show-SysOrgPlan computes totals without parse errors (P0-1/P0-2 regression guard)' {
        $plan = [pscustomobject]@{ PlanId='plan-show-1'; Drive='T:'; DestinationRoot='T:\_Organized'; DestinationStyle='OrganizedRoot'; Mode='test'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\x\a.txt'; Destination='T:\_Organized\Documents\a.txt'; DestRoot='T:\_Organized'; Reason='Category=Documents'; SizeBytes=123 })
            Skipped=@() }
        { Show-SysOrgPlan -Plan $plan -Config $planCfg } | Should -Not -Throw
    }
}

Describe 'Plan construction' {
    It 'excludes SkippedLongPath records from plan actions (P2-5)' {
        $normal = [pscustomobject]@{ FullName='C:\src\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\src'; Category='Documents' }
        $long   = [pscustomobject]@{ FullName=('C:\' + ('x' * 280)); Name='x' * 279; Stem='x'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\deep'; Category='SkippedLongPath' }
        $inv = @($normal, $long)
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -DupGroups @() -Config $planCfg
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
        $qCfg = @{ Copies = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=0; HeaderHashKB=64 }
                   OrganizedRoots=@{ '*'='__AUTO__' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                   SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                   Families=@{Enabled=$false}; Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false} }
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -DupGroups $dupGroups -Config $qCfg
        @($plan.Actions).Count | Should -Be 1
        $plan.Actions[0].Action | Should -Be 'Quarantine'
        $plan.Actions[0].Hash | Should -Be 'ABCD1234ABCD1234'
    }
    It 'NumberCopies: the keeper keeps its name and copies are numbered in the keeper folder (W6)' {
        $root = Join-Path $TestDrive ('ncfix-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Data.bin') -Value ('X' * 1200)
        Set-Content -LiteralPath (Join-Path $root 'Data (2).bin') -Value ('X' * 1200)
        Set-Content -LiteralPath (Join-Path $root 'Data (3).bin') -Value ('X' * 1200)
        $inv = @(
            [pscustomobject]@{ FullName=(Join-Path $root 'Data.bin'); Name='Data.bin'; Stem='Data'; Extension='.bin'; Length=1200
                LastWriteTime=(Get-Date '2026-01-01'); Directory=$root; Category='Other' },
            [pscustomobject]@{ FullName=(Join-Path $root 'Data (2).bin'); Name='Data (2).bin'; Stem='Data (2)'; Extension='.bin'; Length=1200
                LastWriteTime=(Get-Date '2026-01-02'); Directory=$root; Category='Other' },
            [pscustomobject]@{ FullName=(Join-Path $root 'Data (3).bin'); Name='Data (3).bin'; Stem='Data (3)'; Extension='.bin'; Length=1200
                LastWriteTime=(Get-Date '2026-01-03'); Directory=$root; Category='Other' }
        )
        $ncCfg = @{ Copies = @{ Policy='NumberCopies'; StartIndex=2; MinFileSizeKB=1; HeaderHashKB=64 }
                    OrganizedRoots=@{ '*'='__AUTO__' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                    SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                    Families=@{Enabled=$false}; Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}
                    DateFolders='None'; MaxPlanActions=5000 }
        $dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $ncCfg)
        $dups.Count | Should -Be 1
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -DupGroups $dups -Config $ncCfg
        @($plan.Actions).Count | Should -Be 3
        $plan.Copies.Policy | Should -Be 'NumberCopies'
        $plan.Copies.Numbered | Should -Be 2
        $keeper = @($plan.Actions | Where-Object { $_.Destination -like '*Data.bin' })
        $keeper.Count | Should -Be 1
        $keeper[0].Source | Should -Be (Join-Path $root 'Data.bin')   # oldest = keeper keeps its name
        $numbered = @($plan.Actions | Where-Object { $_.CopyIndex })
        @($numbered | Where-Object { $_.Destination -like '*Data (2).bin' }).Count | Should -Be 1
        @($numbered | Where-Object { $_.Destination -like '*Data (3).bin' }).Count | Should -Be 1
        ($numbered | ForEach-Object { Split-Path $_.Destination -Parent } | Select-Object -Unique).Count | Should -Be 1   # same folder as the keeper
    }
    It 'mutability denials appear in Skipped with reasons and never in Actions (W3)' {
        $sysProf = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='System'; ProposedScope='KnownFolders'
            KnownFolders=@([pscustomobject]@{ Name='Documents'; Path='C:\Users\t\Documents'; IsRedirected=$false; UnderOneDrive=$false })
            DownloadRoots=@('C:\Users\t\Downloads') }
        $ok   = [pscustomobject]@{ FullName='C:\Users\t\Documents\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\Users\t\Documents'; Category='Documents' }
        $dll  = [pscustomobject]@{ FullName='C:\Users\t\Documents\lib.dll'; Name='lib.dll'; Stem='lib'; Extension='.dll'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\Users\t\Documents'; Category='Other' }
        $out  = [pscustomobject]@{ FullName='C:\Loose\notes.txt'; Name='notes.txt'; Stem='notes'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\Loose'; Category='Documents' }
        $mCfg = @{ OrganizedRoots=@{ 'C'='C:\Organized' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                   SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                   Copies=@{Policy='NumberCopies';StartIndex=2;MinFileSizeKB=1}; Families=@{Enabled=$false}
                   Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; DateFolders='Year'
                   Policy=@{ SystemDrive=@{ Scope='KnownFolders'; WritablePaths=@()
                        BlockedExtensions=@('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url'); AllowInstallersInDownloads=$true }
                        DataDrives=@{ Scope='FullDrive' } } }
        $plan = New-SysOrgPlan -Letter C -Inventory @($ok,$dll,$out) -DriveProfile $sysProf -DupGroups @() -Config $mCfg -KnownFolders @($sysProf.KnownFolders)
        @($plan.Actions).Count | Should -Be 1
        $srcs = @($plan.Actions | ForEach-Object { $_.Source })
        $srcs -contains $ok.FullName | Should -BeTrue
        $srcs -contains $dll.FullName | Should -BeFalse
        $srcs -contains $out.FullName | Should -BeFalse
        $dllSkip = @($plan.Skipped | Where-Object { $_.Source -eq $dll.FullName })
        $dllSkip.Count | Should -Be 1
        $dllSkip[0].Reason | Should -Be 'Blocked extension .dll'
        $outSkip = @($plan.Skipped | Where-Object { $_.Source -eq $out.FullName })
        $outSkip[0].Reason | Should -Be 'Outside writable scope on system drive'
        $plan.Mutability.Allowed | Should -Be 1
    }
}

Describe 'Executor re-validation (v2.1.1)' {
    It 'refuses a hand-edited plan whose destination points outside the plan root' {
        $src = Join-Path $TestDrive 'rv1\note.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v'
        $plan = [pscustomobject]@{
            PlanId = 'plan-20260101-093101'
            DestinationRoot = (Join-Path $TestDrive 'rv1-org')
            DestinationStyle = 'OrganizedRoot'
            Actions = @([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src
                Destination='C:\Windows\evil.txt'; Reason='Category=Documents'; SizeBytes=1 })
        }
        $planPath = Join-Path $TestDrive 'rv1.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $cfgRv = @{ ExcludedPaths=@('C:\Windows'); ExcludedFilePatterns=@(); Move=@{ AllowCrossVolume=$true }
                    Copies=@{ QuarantineFolderName='_Duplicates' }; FolderAudit=@{ Enabled=$false } }
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfgRv -AppRoot $TestDrive
        $res.Summary.Failed | Should -Be 1
        $res.Summary.Moved  | Should -Be 0
        Test-Path -LiteralPath $src | Should -BeTrue   # nothing was touched
    }
    It 'refuses an action whose source path contains an ".." segment' {
        $plan = [pscustomobject]@{
            PlanId = 'plan-20260101-093102'
            DestinationRoot = (Join-Path $TestDrive 'rv2-org')
            Actions = @([pscustomobject]@{ Action='Move'; Kind='File'
                Source=(Join-Path $TestDrive 'rv2\sub\..\target.txt')
                Destination=(Join-Path (Join-Path $TestDrive 'rv2-org') 'target.txt'); Reason='test'; SizeBytes=1 })
        }
        $planPath = Join-Path $TestDrive 'rv2.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $cfgRv2 = @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); Move=@{ AllowCrossVolume=$true }
                     Copies=@{ QuarantineFolderName='_Duplicates' }; FolderAudit=@{ Enabled=$false } }
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfgRv2 -AppRoot $TestDrive
        $res.Summary.Failed | Should -Be 1
        $res.Summary.Moved  | Should -Be 0
    }
    It 'rejects an invalid PlanId before touching the journal' {
        $plan = [pscustomobject]@{
            PlanId = 'plan-..-evil'
            Actions = @([pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\x\a.txt'; Destination='C:\y\a.txt'; Reason='test' })
        }
        $planPath = Join-Path $TestDrive 'rv3.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        { Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive } | Should -Throw '*not valid*'
        { Undo-SysOrgPlan -PlanId 'plan-../evil' -AppRoot $TestDrive -Config $planCfg } | Should -Throw '*not valid*'
    }
    It 'skips an action whose source changed after planning and counts it as Skipped' {
        $src = Join-Path $TestDrive 'rv4\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v1'
        $plan = [pscustomobject]@{
            PlanId = 'plan-20260101-093104'
            DestinationRoot = (Join-Path $TestDrive 'rv4-org')
            DestinationStyle = 'OrganizedRoot'
            Actions = @([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src
                Destination=(Join-Path (Join-Path $TestDrive 'rv4-org') 'Documents\doc.txt')
                Reason='Category=Documents'; SizeBytes=2
                PlannedLength=99999
                PlannedLastWriteTimeUtc='2020-01-01T00:00:00.0000000Z' })
        }
        $planPath = Join-Path $TestDrive 'rv4.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive
        $res.Summary.Skipped | Should -Be 1
        $res.Summary.Moved   | Should -Be 0
        Test-Path -LiteralPath $src | Should -BeTrue
    }
    It 'accepts an action whose planned size and timestamp still match the file' {
        $src = Join-Path $TestDrive 'rv5\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v1'
        $fi = Get-Item -LiteralPath $src
        $plan = [pscustomobject]@{
            PlanId = 'plan-20260101-093105'
            DestinationRoot = (Join-Path $TestDrive 'rv5-org')
            DestinationStyle = 'OrganizedRoot'
            Actions = @([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src
                Destination=(Join-Path (Join-Path $TestDrive 'rv5-org') 'Documents\doc.txt')
                Reason='Category=Documents'; SizeBytes=2
                PlannedLength=[int64]$fi.Length
                PlannedLastWriteTimeUtc=$fi.LastWriteTimeUtc.ToString('o') })
        }
        $planPath = Join-Path $TestDrive 'rv5.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive
        $res.Summary.Moved   | Should -Be 1
        $res.Summary.Skipped | Should -Be 0
    }
    It 'refuses a tampered journal row that points into a protected path' {
        $planId = 'plan-20260101-093106'
        $current = Join-Path $TestDrive 'rv6\innocent.txt'
        New-Item -ItemType Directory -Path (Split-Path $current) -Force | Out-Null
        Set-Content -LiteralPath $current -Value 'keep me'
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash',
            ('"2026-01-01T00:00:00","{0}","File","Move","C:\Windows\evil.txt","{1}",""' -f $planId, $current)
        ) -Encoding UTF8
        $cfgTam = @{ ExcludedPaths=@('C:\Windows'); ExcludedFilePatterns=@(); Move=@{ AllowCrossVolume=$true } }
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot $TestDrive -Config $cfgTam
        $u.Failed   | Should -Be 1
        $u.Restored | Should -Be 0
        Test-Path -LiteralPath $current | Should -BeTrue        # untouched
        Test-Path -LiteralPath 'C:\Windows\evil.txt' -ErrorAction SilentlyContinue | Should -BeFalse
    }
    It 'verifies the plan integrity hash: tampering refuses without -Force, executes with -Force' {
        $src = Join-Path $TestDrive 'rv7\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v1'
        $plan = [pscustomobject]@{
            PlanId = 'plan-20260101-093107'
            DestinationRoot = (Join-Path $TestDrive 'rv7-org')
            DestinationStyle = 'OrganizedRoot'
            Actions = @([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src
                Destination=(Join-Path (Join-Path $TestDrive 'rv7-org') 'Documents\doc.txt')
                Reason='Category=Documents'; SizeBytes=[int64](Get-Item -LiteralPath $src).Length
                PlannedLength=[int64](Get-Item -LiteralPath $src).Length
                PlannedLastWriteTimeUtc=(Get-Item -LiteralPath $src).LastWriteTimeUtc.ToString('o') })
        }
        $plansFolder = Join-Path $TestDrive 'rv7-plans'
        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $plansFolder
        # sanity: the saved plan carries the integrity hash
        $saved = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
        $saved.IntegrityHash | Should -Not -BeNullOrEmpty
        # tamper with the destination, keep everything else
        $saved.Actions[0].Destination = (Join-Path (Join-Path $TestDrive 'rv7-org') 'Documents\doc-renamed.txt')
        $tamperedPath = Join-Path $TestDrive 'rv7-tampered.json'
        $saved | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tamperedPath
        { Invoke-SysOrgPlan -PlanPath $tamperedPath -Config $planCfg -AppRoot $TestDrive } | Should -Throw '*integrity*'
        $res = Invoke-SysOrgPlan -PlanPath $tamperedPath -Config $planCfg -AppRoot $TestDrive -Force
        $res.Summary.Moved | Should -Be 1
        Test-Path -LiteralPath (Join-Path (Join-Path $TestDrive 'rv7-org') 'Documents\doc-renamed.txt') | Should -BeTrue
    }
}
