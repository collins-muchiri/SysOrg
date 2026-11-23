# Tests/SysOrg.Plan.Tests.ps1
# Covers: P0-2 (sum correctness), P1-1 (journal), P1-3 (re-execution guard + resume),
#         P1-4 (hash-mismatch undo skip), P1-10 (honest Copied counting), P2-1 (hash economy),
#         P2-5 (SkippedLongPath excluded from plans),
#         W1 (no plan without a profile), W6 (numbered copies + undo restore)

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')      -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force   # the inventory's folder gates live here
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force
    $script:fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
    $script:planCfg = @{
        # v3.0.1: dedicated app folder - the app root is protected, and on Windows
        # $TestDrive is an ANCESTOR of every fixture (which zeroed plans and refused
        # moves/undos); on Unix-path hosts the same check is inert, masking this.
        AppRoot        = (Join-Path $TestDrive 'app')
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
        # v3.0.1: hand-built plans name their (virtual) drive so the executor's
        # re-validation keys the profile off the plan, not the physical source
        # drive - on Windows the fixtures live on the system drive, whose fresh
        # profile scopes writes to the real known folders and would deny them.
        $plan = [pscustomobject]@{ PlanId='plan-20260101-093002'; Drive='T:'
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
        # v2.1.1: one action = one Pending row + one Done row.
        @(Import-Csv -LiteralPath $undoPath).Count | Should -Be 2
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive -Force
        $res.Summary.Resumed | Should -Be 1
        $res.Summary.Moved   | Should -Be 0
        @(Import-Csv -LiteralPath $undoPath).Count | Should -Be 2   # journal unchanged, no duplicate header
    }
    It 'resume after a simulated crash: pre-seeded journal skips that source and completes the rest' {
        $srcA = Join-Path $TestDrive 'work3\a.txt'; $srcB = Join-Path $TestDrive 'work3\b.txt'
        New-Item -ItemType Directory -Path (Split-Path $srcA) -Force | Out-Null
        Set-Content -LiteralPath $srcA -Value 'aa'; Set-Content -LiteralPath $srcB -Value 'bb'
        $dstA = Join-Path $TestDrive 'org3\Documents\2026\a.txt'
        $dstB = Join-Path $TestDrive 'org3\Documents\2026\b.txt'
        $planId = 'plan-20260101-093003'
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
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
    It 'NumberCopies (v2.1.1 default): copies keep their own names in the keeper folder (W6)' {
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
        $plan.Copies.Numbered | Should -Be 0     # no name collisions -> nothing renumbered
        $keeper = @($plan.Actions | Where-Object { $_.Destination -like '*Data.bin' })
        $keeper.Count | Should -Be 1
        $keeper[0].Source | Should -Be (Join-Path $root 'Data.bin')   # oldest = keeper keeps its name
        @($plan.Actions | Where-Object { $_.Destination -like '*Data (2).bin' }).Count | Should -Be 1   # own name kept
        @($plan.Actions | Where-Object { $_.Destination -like '*Data (3).bin' }).Count | Should -Be 1   # own name kept
        @($plan.Actions | Where-Object { $_.CopyIndex }).Count | Should -Be 0
        ($plan.Actions | ForEach-Object { Split-Path $_.Destination -Parent } | Select-Object -Unique).Count | Should -Be 1   # same folder as the keeper
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
            Drive = 'T:'
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
            Drive = 'T:'
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
            Drive = 'T:'
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
            Drive = 'T:'
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
            Drive = 'T:'
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
Describe 'Project folder plan actions and preview (v2.1.1)' {
    BeforeAll {
        $script:projCfg = @{ Projects=@{ Enabled=$true; Markers=@() }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                             ExcludeDestinations=$false; TypeMap=@{}; FolderAudit=@{ Enabled=$false } }
        $script:projProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; KnownFolders=@(); DownloadRoots=@() }
    }
    It 'a plan action for a project folder carries the preview counts' {
        $root = Join-Path $TestDrive ('pact-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $repo = Join-Path $root 'myapp'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'main.py')   -Value 'print(1)'
        Set-Content -LiteralPath (Join-Path $repo 'notes.txt') -Value 'n'
        $inv = @([pscustomobject]@{ FullName=(Join-Path $repo 'main.py'); Name='main.py'; Stem='main'; Extension='.py'
            Length=8; LastWriteTime=(Get-Date); Directory=$repo; Category='Code' })
        $projects = @(Get-SysOrgProjectFolders -Roots @($root) -Config $projCfg -DriveProfile $projProf)
        $planCfg5 = @{ OrganizedRoots=@{ '*'='__AUTO__' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                       SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                       Copies=@{Policy='NumberCopies';StartIndex=2}; Families=@{Enabled=$false}
                       Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; DateFolders='None'
                       Projects=@{ Enabled=$true; Destination='Documents\Projects\Code'; Markers=@() }
                       TypeMap=@{}; Move=@{ AllowCrossVolume=$true }; MaxPlanActions=5000 }
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $projProf -DupGroups @() -Config $planCfg5 -KnownFolders @() -ProjectFolders $projects
        $fa = @($plan.Actions | Where-Object { "$($_.Kind)" -eq 'Folder' })
        $fa.Count | Should -Be 1
        $fa[0].FilesInside        | Should -Be 2
        $fa[0].NonCodeFilesInside | Should -Be 1   # notes.txt (main.py is code; .git is VCS metadata)
        { Show-SysOrgPlan -Plan $plan -Config $planCfg5 } | Should -Not -Throw
    }
}

Describe 'Copies keep their own names (v2.1.1)' {
    BeforeAll {
        function New-SysOrgNumberCopiesPlan {
            param([Parameter(Mandatory)]$Records,$Config)
            return (New-SysOrgPlan -Letter T -Inventory $Records -DriveProfile $script:fakeProf -DupGroups @(Find-SysOrgDuplicates -Inventory $Records -Config $Config) -Config $Config)
        }
        $script:c6Cfg = @{ Copies = @{ Policy='NumberCopies'; StartIndex=2; MinFileSizeKB=1; HeaderHashKB=64 }
                    OrganizedRoots=@{ '*'='__AUTO__' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                    SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                    Families=@{Enabled=$false}; Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}
                    DateFolders='None'; MaxPlanActions=5000 }
    }
    It 'different-named identical files keep their own names' {
        $root = Join-Path $TestDrive ('c6a-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Alpha.docx') -Value ('A' * 1200)
        Set-Content -LiteralPath (Join-Path $root 'Beta.docx')  -Value ('A' * 1200)   # identical content, own name
        (Get-Item -LiteralPath (Join-Path $root 'Alpha.docx')).LastWriteTime = Get-Date '2026-01-01'
        (Get-Item -LiteralPath (Join-Path $root 'Beta.docx')).LastWriteTime  = Get-Date '2026-01-02'
        $inv = @(
            [pscustomobject]@{ FullName=(Join-Path $root 'Alpha.docx'); Name='Alpha.docx'; Stem='Alpha'; Extension='.docx'; Length=1200
                LastWriteTime=(Get-Date '2026-01-01'); Directory=$root; Category='Documents' },
            [pscustomobject]@{ FullName=(Join-Path $root 'Beta.docx'); Name='Beta.docx'; Stem='Beta'; Extension='.docx'; Length=1200
                LastWriteTime=(Get-Date '2026-01-02'); Directory=$root; Category='Documents' }
        )
        $plan = New-SysOrgNumberCopiesPlan -Records $inv -Config $c6Cfg
        $beta = @($plan.Actions | Where-Object { $_.Source -eq (Join-Path $root 'Beta.docx') })[0]
        (Split-Path $beta.Destination -Leaf) | Should -Be 'Beta.docx'      # own stem, own extension
        $beta.CopyIndex | Should -BeNullOrEmpty                            # no collision -> not numbered
        (Split-Path $beta.Destination -Parent) | Should -Be (Split-Path (@($plan.Actions | Where-Object { $_.Source -eq (Join-Path $root 'Alpha.docx') })[0].Destination) -Parent)
    }
    It 'same-named copies still get (2) in the destination folder' {
        $a = Join-Path $TestDrive ('c6b1-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $b = Join-Path $TestDrive ('c6b2-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $a -Force | Out-Null
        New-Item -ItemType Directory -Path $b -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $a 'Report - Copy.docx') -Value ('R' * 1200)
        Set-Content -LiteralPath (Join-Path $b 'Report - Copy.docx') -Value ('R' * 1200)   # same name, different folder
        (Get-Item -LiteralPath (Join-Path $a 'Report - Copy.docx')).LastWriteTime = Get-Date '2026-01-01'
        (Get-Item -LiteralPath (Join-Path $b 'Report - Copy.docx')).LastWriteTime = Get-Date '2026-01-02'
        $inv = @(
            [pscustomobject]@{ FullName=(Join-Path $a 'Report - Copy.docx'); Name='Report - Copy.docx'; Stem='Report - Copy'; Extension='.docx'; Length=1200
                LastWriteTime=(Get-Date '2026-01-01'); Directory=$a; Category='Documents' },
            [pscustomobject]@{ FullName=(Join-Path $b 'Report - Copy.docx'); Name='Report - Copy.docx'; Stem='Report - Copy'; Extension='.docx'; Length=1200
                LastWriteTime=(Get-Date '2026-01-02'); Directory=$b; Category='Documents' }
        )
        $plan = New-SysOrgNumberCopiesPlan -Records $inv -Config $c6Cfg
        $plan.Copies.Numbered | Should -Be 1
        $numbered = @($plan.Actions | Where-Object { $_.CopyIndex })
        $numbered.Count | Should -Be 1
        (Split-Path $numbered[0].Destination -Leaf) | Should -Be 'Report - Copy (2).docx'   # numbered only on collision
    }
    It 'Copies.RenameToKeeper=$true restores the v2.1.0 naming (opt-in)' {
        $root = Join-Path $TestDrive ('c6c-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Alpha.docx') -Value ('A' * 1200)
        Set-Content -LiteralPath (Join-Path $root 'Beta copy.docx') -Value ('A' * 1200)
        (Get-Item -LiteralPath (Join-Path $root 'Alpha.docx')).LastWriteTime = Get-Date '2026-01-01'
        (Get-Item -LiteralPath (Join-Path $root 'Beta copy.docx')).LastWriteTime = Get-Date '2026-01-02'
        $inv = @(
            [pscustomobject]@{ FullName=(Join-Path $root 'Alpha.docx'); Name='Alpha.docx'; Stem='Alpha'; Extension='.docx'; Length=1200
                LastWriteTime=(Get-Date '2026-01-01'); Directory=$root; Category='Documents' },
            [pscustomobject]@{ FullName=(Join-Path $root 'Beta copy.docx'); Name='Beta copy.docx'; Stem='Beta copy'; Extension='.docx'; Length=1200
                LastWriteTime=(Get-Date '2026-01-02'); Directory=$root; Category='Documents' }
        )
        $optIn = @{ Copies = @{ Policy='NumberCopies'; StartIndex=2; MinFileSizeKB=1; HeaderHashKB=64; RenameToKeeper=$true }
                    OrganizedRoots=@{ '*'='__AUTO__' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                    SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                    Families=@{Enabled=$false}; Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}
                    DateFolders='None'; MaxPlanActions=5000 }
        $plan = New-SysOrgNumberCopiesPlan -Records $inv -Config $optIn
        $beta = @($plan.Actions | Where-Object { $_.Source -eq (Join-Path $root 'Beta copy.docx') })[0]
        (Split-Path $beta.Destination -Leaf) | Should -Be 'Alpha (2).docx'   # keeper's stem, numbered
        $beta.CopyIndex | Should -Be 2
    }
    It 'Test-SysOrgConfig rejects a non-boolean Copies.RenameToKeeper' {
        $cfg = @{ DateFolders='Year'; Copies=@{Policy='NumberCopies'; RenameToKeeper='maybe'}; MaxPlanActions=10
                  PreserveMinFiles=1; InventoryCacheHours=1; PreserveSingleCategoryRatio=0.9 }
        { Test-SysOrgConfig -Config $cfg } | Should -Throw '*RenameToKeeper*'
    }
}

Describe 'Scheduled report hardening (v2.1.1)' {
    It 'writes the report under <AppRoot>\Reports and prints the drive profile line' {
        $appRoot = Join-Path $TestDrive ('app7-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $appRoot 'Cache') -Force | Out-Null
        $scanR = Join-Path $TestDrive ('scan7-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $scanR -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $scanR 'a.txt') -Value 'a'
        $prof = [pscustomobject]@{ Letter='S'; Role='Data'; ProposedScope='FullDrive'; DestinationRoot='X:\_Organized'; KnownFolders=@(); DownloadRoots=@() }
        $cfg7 = @{ ReportsFolderName='_Reports'; ScanRoots=@{}; TypeMap=@{}; Copies=@{Policy='ReportOnly'}
                   ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true; ExcludeDestinations=$true
                   Families=@{Enabled=$false}; FolderAudit=@{Enabled=$false}; Downloads=@{UseZoneIdentifier=$false}
                   PreserveExistingFolders=$false }
        $file = New-SysOrgScanReport -Letter S -Config $cfg7 -AppRoot $appRoot -DriveProfile $prof -ScanRoots @($scanR)
        $file | Should -Not -BeNullOrEmpty
        (Split-Path (Split-Path $file -Parent) -Leaf) | Should -Be 'Reports'
        (Split-Path $file -Parent) | Should -BeLike "$appRoot*"
        (Get-Content -LiteralPath $file -Raw) | Should -Match 'Drive profile: role=Data'
    }
    It 'skips drives with empty scan roots instead of writing an empty report' {
        $appRoot = Join-Path $TestDrive ('app8-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $scanR = Join-Path $TestDrive ('scan8-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $scanR -Force | Out-Null    # exists but empty
        $cfg8 = @{ ReportsFolderName='_Reports'; ScanRoots=@{}; TypeMap=@{}; Copies=@{Policy='ReportOnly'}
                   ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true; ExcludeDestinations=$true
                   Families=@{Enabled=$false}; FolderAudit=@{Enabled=$false}; Downloads=@{UseZoneIdentifier=$false} }
        $file = New-SysOrgScanReport -Letter S -Config $cfg8 -AppRoot $appRoot -ScanRoots @($scanR)
        $file | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $appRoot 'Reports') | Should -BeFalse   # nothing was written
    }
}

Describe 'Journal durability and undo lifecycle (v2.1.1)' {
    It 'writes a Pending row before the move and a Done row after' {
        $src = Join-Path $TestDrive 'jr1\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v'
        $planId = 'plan-20260101-094001'
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src; Destination=(Join-Path $TestDrive 'jr1-org\Documents\2026\doc.txt'); Reason='test'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'jr1.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 1
        $rows = @(Import-Csv -LiteralPath $res.UndoFile)
        $rows.Count | Should -Be 2
        $rows[0].Status | Should -Be 'Pending'
        $rows[1].Status | Should -Be 'Done'
        $rows[1].CurrentLocation | Should -Not -BeNullOrEmpty
        $rows[1].OriginalSource  | Should -Be $src
    }
    It 'an orphaned Pending row whose source is gone is resolved as done on resume' {
        $planId = 'plan-20260101-094002'
        $srcA = Join-Path $TestDrive 'jr2\a.txt'
        $srcB = Join-Path $TestDrive 'jr2\b.txt'
        New-Item -ItemType Directory -Path (Split-Path $srcA) -Force | Out-Null
        Set-Content -LiteralPath $srcA -Value 'aa'; Set-Content -LiteralPath $srcB -Value 'bb'
        $dstA = Join-Path $TestDrive 'jr2-org\Documents\2026\a.txt'
        $dstB = Join-Path $TestDrive 'jr2-org\Documents\2026\b.txt'
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
            Actions=@(
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcA; Destination=$dstA; Reason='test'; SizeBytes=2 },
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcB; Destination=$dstB; Reason='test'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'jr2.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        # simulate a crash: A was moved, only its Pending row exists (no Done row)
        New-Item -ItemType Directory -Path (Split-Path $dstA) -Force | Out-Null
        Move-Item -LiteralPath $srcA -Destination $dstA
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash,Status',
            ('"2026-01-01T00:00:00","{0}","File","Move","{1}","{2}","","Pending"' -f $planId, $srcA, $dstA)
        ) -Encoding UTF8
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive -Force
        $res.Summary.Resumed | Should -Be 1      # the orphan resolved as done
        $res.Summary.Moved   | Should -Be 1      # B executed normally
        $rows = @(Import-Csv -LiteralPath $undoPath)
        @($rows | Where-Object { $_.OriginalSource -eq $srcA -and $_.Status -eq 'Done' }).Count | Should -Be 1
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot $TestDrive -Config $planCfg
        $u.Restored | Should -Be 2               # both rows are undoable
    }
    It 'an orphaned Pending row whose source still exists is retried' {
        $planId = 'plan-20260101-094003'
        $src = Join-Path $TestDrive 'jr3\a.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'aa'
        $dst = Join-Path $TestDrive 'jr3-org\Documents\2026\a.txt'
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src; Destination=$dst; Reason='test'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'jr3.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash,Status',
            ('"2026-01-01T00:00:00","{0}","File","Move","{1}","","","Pending"' -f $planId, $src)
        ) -Encoding UTF8
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive -Force
        $res.Summary.Resumed | Should -Be 0      # NOT treated as done
        $res.Summary.Moved   | Should -Be 1      # retried and completed
        $rows = @(Import-Csv -LiteralPath $undoPath)
        @($rows | Where-Object { $_.Status -eq 'Retried' }).Count | Should -Be 1
        @($rows | Where-Object { $_.Status -eq 'Done' }).Count | Should -Be 1
    }
    It 'a legacy 7-column journal still resumes and undoes (no Status column appended)' {
        $planId = 'plan-20260101-094004'
        $srcA = Join-Path $TestDrive 'jr4\a.txt'
        $srcB = Join-Path $TestDrive 'jr4\b.txt'
        New-Item -ItemType Directory -Path (Split-Path $srcA) -Force | Out-Null
        Set-Content -LiteralPath $srcA -Value 'aa'; Set-Content -LiteralPath $srcB -Value 'bb'
        $dstA = Join-Path $TestDrive 'jr4-org\Documents\2026\a.txt'
        $dstB = Join-Path $TestDrive 'jr4-org\Documents\2026\b.txt'
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
            Actions=@(
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcA; Destination=$dstA; Reason='test'; SizeBytes=2 },
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcB; Destination=$dstB; Reason='test'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'jr4.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
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
        $raw = Get-Content -LiteralPath $undoPath
        @($raw | Where-Object { $_ -match ',Status' }).Count | Should -Be 0   # layout untouched
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot $TestDrive -Config $planCfg
        $u.Restored | Should -Be 2
    }
    It 'a fully successful undo renames the journal to .undone.csv; a partial undo keeps it' {
        # full success
        $planId = 'plan-20260101-094005'
        $src = Join-Path $TestDrive 'jr5\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v'
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src; Destination=(Join-Path $TestDrive 'jr5-org\Documents\2026\doc.txt'); Reason='test'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'jr5.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot $TestDrive
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot $TestDrive -Config $planCfg
        $u.Restored | Should -Be 1
        Test-Path -LiteralPath $res.UndoFile | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive ('Undo\undo-' + $planId + '.undone.csv')) | Should -BeTrue
        # partial: one of two destinations is missing -> SkippedMissing -> journal stays
        $planId2 = 'plan-20260101-094006'
        $s1 = Join-Path $TestDrive 'jr6\one.txt'; $s2 = Join-Path $TestDrive 'jr6\two.txt'
        New-Item -ItemType Directory -Path (Split-Path $s1) -Force | Out-Null
        Set-Content -LiteralPath $s1 -Value '1'; Set-Content -LiteralPath $s2 -Value '2'
        $d1 = Join-Path $TestDrive 'jr6-org\Documents\2026\one.txt'
        $d2 = Join-Path $TestDrive 'jr6-org\Documents\2026\two.txt'
        $plan2 = [pscustomobject]@{ PlanId=$planId2; Drive='T:'
            Actions=@(
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$s1; Destination=$d1; Reason='test'; SizeBytes=1 },
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$s2; Destination=$d2; Reason='test'; SizeBytes=1 }) }
        $planPath2 = Join-Path $TestDrive 'jr6.json'
        $plan2 | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath2
        $res2 = Invoke-SysOrgPlan -PlanPath $planPath2 -Config $planCfg -AppRoot $TestDrive
        Remove-Item -LiteralPath $d2 -Force            # user deleted one moved file
        $u2 = Undo-SysOrgPlan -PlanId $planId2 -AppRoot $TestDrive -Config $planCfg
        $u2.SkippedMissing | Should -Be 1
        Test-Path -LiteralPath $res2.UndoFile | Should -BeTrue   # kept for inspection
    }
    It 'journal and provenance rows are properly CSV-escaped (commas and quotes survive)' {
        # provenance sidecar: URLs can contain quotes and commas
        $plan = [pscustomobject]@{ PlanId='plan-20260101-094007'; Drive='T:'; DestinationRoot='X:\org'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source='X:\a.txt'; Destination='X:\org\a.txt'; Reason='r'; SizeBytes=1 })
            Provenance=@([pscustomobject]@{ Source='X:\a.txt'; SourceBucket='Test'; HostUrl='https://x.test/a,"b,c";d'; ReferrerUrl='' }) }
        $plansFolder = Join-Path $TestDrive 'jr7-plans'
        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $plansFolder
        $provFile = Join-Path $plansFolder 'plan-20260101-094007-provenance.csv'
        Test-Path -LiteralPath $provFile | Should -BeTrue
        $rows = @(Import-Csv -LiteralPath $provFile)
        $rows[0].HostUrl | Should -Be 'https://x.test/a,"b,c";d'
        # journal: a file name containing a comma moves and comes back intact
        $src = Join-Path $TestDrive 'jr8\a,b.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v'
        $plan2 = [pscustomobject]@{ PlanId='plan-20260101-094008'; Drive='T:'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src; Destination=(Join-Path $TestDrive 'jr8-org\Documents\2026\a,b.txt'); Reason='test'; SizeBytes=2 }) }
        $planPath2 = Join-Path $TestDrive 'jr8.json'
        $plan2 | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath2
        $res = Invoke-SysOrgPlan -PlanPath $planPath2 -Config $planCfg -AppRoot $TestDrive
        $rows2 = @(Import-Csv -LiteralPath $res.UndoFile)
        (@($rows2 | Where-Object { $_.Status -eq 'Done' })[0]).OriginalSource | Should -Be $src
    }
}

Describe 'Smaller hardening items (v2.1.1)' {
    It 'plan IDs carry a millisecond suffix and match the executor regex' {
        $inv = @([pscustomobject]@{ FullName='C:\src\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\src'; Category='Documents' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -DupGroups @() -Config $planCfg
        $plan.PlanId | Should -Match '^plan-\d{8}-\d{6}-\d{3}$'
    }
    It 'migration plan IDs carry a millisecond suffix' {
        $old = Join-Path $TestDrive ('ms-mig-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        $migCfg = @{ OrganizedRoots=@{ 'T' = $old }; ReportsFolderName='_Reports'; MaxPlanActions=5000 }
        $plan = New-SysOrgMigrationPlan -Letter T -Config $migCfg
        $plan.PlanId | Should -Match '^migrate-\d{8}-\d{6}-\d{3}$'
    }
    It 'executes a plan whose millisecond PlanId indexes the journal' {
        $src = Join-Path $TestDrive 'ms\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v'
        # a REAL destination root (like the Rev21 fixtures) so the flow is portable
        $msCfg = @{ AppRoot=(Join-Path $TestDrive 'app'); OrganizedRoots=@{ 'T' = (Join-Path $TestDrive 'ms-org') }
                    ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true
                    ExcludeDestinations=$true; PreserveExistingFolders=$false; DateFolders='None'
                    Copies=@{Policy='NumberCopies';StartIndex=2}; Families=@{Enabled=$false}
                    Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; TypeMap=@{}
                    Move=@{ AllowCrossVolume=$true }; MaxPlanActions=5000 }
        $plan = New-SysOrgPlan -Letter T -Inventory @([pscustomobject]@{ FullName=$src; Name='doc.txt'; Stem='doc'; Extension='.txt'
            Length=(Get-Item -LiteralPath $src).Length; LastWriteTime=(Get-Date); Directory=(Split-Path $src); Category='Documents' }) -DriveProfile $fakeProf -DupGroups @() -Config $msCfg   # v3.0.1: REAL length - Set-Content writes CRLF on Windows, and the v2.1.1 drift check honestly skips size mismatches
        $plan.PlanId | Should -Match '^plan-\d{8}-\d{6}-\d{3}$'
        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder (Join-Path $TestDrive 'ms-plans')
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $msCfg -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 1
        Test-Path -LiteralPath $res.UndoFile | Should -BeTrue   # journal path built from the ms PlanId
        $u = Undo-SysOrgPlan -PlanId $plan.PlanId -AppRoot $TestDrive -Config $msCfg
        $u.Restored | Should -Be 1
    }
    It 'Invoke-SysOrgSafeMove accepts -ExpectedHash without changing same-volume behavior' {
        $s = Join-Path $TestDrive 'hashreuse\src.txt'
        New-Item -ItemType Directory -Path (Split-Path $s) -Force | Out-Null
        Set-Content -LiteralPath $s -Value 'same-volume'
        $d = Join-Path $TestDrive 'hashreuse\dst.txt'
        # an ExpectedHash is NOT consulted on the same-volume rename path
        $r = Invoke-SysOrgSafeMove -Source $s -Destination $d -Config @{ Move=@{ AllowCrossVolume=$true } } -ExpectedHash 'WRONG-HASH'
        $r.Status | Should -Be 'Moved'
    }
    It 'Test-SysOrgElevated returns a boolean without throwing' {
        $r = Test-SysOrgElevated
        ($r -is [bool]) -or ($null -ne $r) | Should -BeTrue
    }
}

Describe 'Honest skip taxonomy (v3.0.1 A3)' {

    It 'real plans tag skipped rows Protected / Preserved; Mutability.Denied counts ONLY protected rows' {
        $sysProf = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='System'; ProposedScope='KnownFolders'
            KnownFolders=@([pscustomobject]@{ Name='Documents'; Path='C:\Users\t\Documents'; IsRedirected=$false; UnderOneDrive=$false })
            DownloadRoots=@('C:\Users\t\Downloads') }
        $mk = { param($p,$ext,$cat)
            [pscustomobject]@{ FullName=$p; Name=(Split-Path $p -Leaf); Stem=([System.IO.Path]::GetFileNameWithoutExtension($p))
                Extension=$ext; Length=[long]5; LastWriteTime=(Get-Date '2026-02-03'); Directory=(Split-Path $p -Parent); Category=$cat } }
        $ok  = & $mk 'C:\Users\t\Documents\note.txt' '.txt' 'Documents'
        $dll = & $mk 'C:\Users\t\Documents\lib.dll' '.dll' 'Other'
        $album = @(1..5 | ForEach-Object { & $mk ("C:\Users\t\Documents\Album\pic$_.jpg") '.jpg' 'Images' })
        $mCfg = @{ OrganizedRoots=@{ 'C'='C:\Organized' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                   SkipHiddenSystemFiles=$true; ExcludeDestinations=$true
                   PreserveExistingFolders=$true; PreserveMinFiles=5; PreserveSingleCategoryRatio=0.9
                   Copies=@{Policy='NumberCopies';StartIndex=2;MinFileSizeKB=1}; Families=@{Enabled=$false}
                   Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; DateFolders='Year'
                   LayoutProfile='Windows'
                   Policy=@{ SystemDrive=@{ Scope='KnownFolders'; WritablePaths=@(); BlockedExtensions=@('.dll'); AllowInstallersInDownloads=$true }
                             DataDrives=@{ Scope='FullDrive' } } }
        $plan = New-SysOrgPlan -Letter C -Inventory (@($ok,$dll) + $album) -DriveProfile $sysProf -DupGroups @() -Config $mCfg -KnownFolders @($sysProf.KnownFolders)
        ($plan.Skipped | Where-Object { $_.Source -eq $dll.FullName }).Group | Should -Be 'Protected'
        $albumSkip = @($plan.Skipped | Where-Object { $_.Source -like 'C:\Users\t\Documents\Album\*' })
        $albumSkip.Count | Should -Be 5
        $albumSkip[0].Group | Should -Be 'Preserved'
        $albumSkip[0].Reason | Should -Match 'preserved'
        # the OLD behaviour counted every skip as 'denied (provably never touched)';
        # the honest engine counts only what the mutability engine refused
        $plan.Mutability.DeniedTotal | Should -Be 1
        $tax = Get-SysOrgSkipTaxonomy -Plan $plan
        $tax.ProtectedCount | Should -Be 1
        $tax.PreservedCount | Should -Be 5
        $tax.DecisionCount  | Should -Be 0
        $tax.Planned        | Should -Be 1
    }

    It 'taxonomy builds the exact headline, per-reason counts and one example each' {
        $plan = [pscustomobject]@{
            PlanId='plan-tax'; Drive='C:'; DestinationRoot='C:\Organized'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\a\n.txt'; Destination='C:\Organized\Documents\2026\n.txt' })
            Skipped=@(
                [pscustomobject]@{ Source='C:\s1'; Reason='Blocked extension .dll'; Group='Protected' }
                [pscustomobject]@{ Source='C:\s2'; Reason='Blocked extension .dll'; Group='Protected' }
                [pscustomobject]@{ Source='C:\s3'; Reason='Inside a folder that already looks organized (preserved)'; Group='Preserved' }
                [pscustomobject]@{ Source='C:\s4'; Reason='Path >= 260 characters (recorded; PowerShell 5.1 cannot address it)'; Group='Other' }
            )
            NeedsDecision=@([pscustomobject]@{ Source='C:\s5'; Confidence=0.3; Disposition='left in place' })
            Stats=[pscustomobject]@{ Scanned=100; Routed=1 }
        }
        $tax = Get-SysOrgSkipTaxonomy -Plan $plan
        $tax.Headline | Should -Be '100 scanned: 1 planned, 1 preserved, 2 protected, 1 need a decision.'
        $tax.UntouchedPct | Should -Be 99
        $tax.ProtectedRows.Count | Should -Be 1
        $tax.ProtectedRows[0].Reason  | Should -Be 'Blocked extension .dll'
        $tax.ProtectedRows[0].Count   | Should -Be 2
        $tax.ProtectedRows[0].Example | Should -Be 'C:\s1'
        $tax.PreservedRows[0].Example | Should -Be 'C:\s3'
        $tax.DecisionCount | Should -Be 1
        $tax.DecisionExamples[0] | Should -Be 'C:\s5'
        $tax.OtherRows[0].Reason | Should -Match '260 characters'
    }

    It 'legacy plans (rows without Group tags) still classify honestly' {
        (Get-SysOrgSkipGroupFromReason -Reason 'Blocked extension .dll') | Should -Be 'Protected'
        (Get-SysOrgSkipGroupFromReason -Reason 'Outside writable scope on system drive') | Should -Be 'Protected'
        (Get-SysOrgSkipGroupFromReason -Reason 'Needs a decision: confidence 0.3 below 0.4 (default)') | Should -Be 'Decision'
        (Get-SysOrgSkipGroupFromReason -Reason 'Already in its destination (idempotent re-plan)') | Should -Be 'Preserved'
        (Get-SysOrgSkipGroupFromReason -Reason 'Inside a detected code project folder (moved as one unit)') | Should -Be 'Preserved'
        (Get-SysOrgSkipGroupFromReason -Reason 'Path >= 260 characters (recorded)') | Should -Be 'Other'
        $plan = [pscustomobject]@{
            PlanId='plan-legacy'; Drive='C:'; DestinationRoot='C:\Organized'
            Actions=@()
            Skipped=@(
                [pscustomobject]@{ Source='C:\s1'; Reason='Outside writable scope on system drive' }
                [pscustomobject]@{ Source='C:\s2'; Reason='Already in its destination (idempotent re-plan)' }
            )
            NeedsDecision=@()
            Stats=[pscustomobject]@{ Scanned=50; Routed=0 }
        }
        $tax = Get-SysOrgSkipTaxonomy -Plan $plan
        $tax.ProtectedCount | Should -Be 1
        $tax.PreservedCount | Should -Be 1
        $tax.Headline | Should -Be '50 scanned: 0 planned, 1 preserved, 1 protected, 0 need a decision.'
    }
}

Describe 'User collections: one unit, structure intact (v3.0.1 B2)' {

    It 'plans a UNDP collection with a nested Workshop folder as ONE MoveFolder unit and executes it intact' {
        $work = Join-Path $TestDrive ('b2-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $srcRoot = Join-Path $work 'src'
        $undp = Join-Path $srcRoot 'UNDP'
        $shop = Join-Path $undp 'Workshop'
        New-Item -ItemType Directory -Path $shop -Force | Out-Null
        $inv = @()
        foreach($i in 1..8){
            $p = Join-Path $shop ("workshop report $i.docx")
            Set-Content -LiteralPath $p -Value ("w$i")
            $inv += [pscustomobject]@{ FullName=$p; Name="workshop report $i.docx"; Stem="workshop report $i"; Extension='.docx'
                Length=[long]10; LastWriteTime=(Get-Date '2026-01-05'); Directory=$shop; Category='Documents' }
        }
        foreach($i in 1..4){
            $p = Join-Path $undp ("summary $i.docx")
            Set-Content -LiteralPath $p -Value ("s$i")
            $inv += [pscustomobject]@{ FullName=$p; Name="summary $i.docx"; Stem="summary $i"; Extension='.docx'
                Length=[long]10; LastWriteTime=(Get-Date '2026-01-05'); Directory=$undp; Category='Documents' }
        }
        $prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $b2Cfg = @{ OrganizedRoots=@{ 'T' = (Join-Path $work 'org') }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                    SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$true
                    Copies=@{Policy='NumberCopies';StartIndex=2;MinFileSizeKB=1}; Families=@{Enabled=$true}
                    Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; DateFolders='Year'
                    LayoutProfile='Windows'; TypeMap=@{}
                    Folders=@{ PreserveUserCollections=$true; MaxFiles=200; MaxDepth=3; MinMajorityRatio=0.6 } }
        Import-Module (Join-Path $PSScriptRoot '..\Modules\SysOrg.Scan.psm1') -Force
        $cols = @(Get-SysOrgUserCollections -Inventory $inv -Roots @($srcRoot) -Config $b2Cfg -KnownFolders @())
        @($cols | Where-Object Name -eq 'UNDP').Count | Should -Be 1 -Because ("detected collections: [" + (($cols | ForEach-Object { "$($_.Name) files=$($_.Files) ratio=$($_.MajorityRatio)" }) -join '; ') + "]")
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $b2Cfg -KnownFolders @() -UserCollections $cols
        # ONE folder action for the collection; its files are never planned individually
        $folderActs = @($plan.Actions | Where-Object { "$($_.Kind)" -eq 'Folder' })
        $folderActs.Count | Should -Be 1
        $folderActs[0].Source | Should -Be $undp
        $folderActs[0].Collection | Should -BeTrue
        $folderActs[0].Destination | Should -BeLike '*Documents\Work\UNDP'
        @($plan.Skipped | Where-Object { $_.Reason -match 'user collection folder' }).Count | Should -Be 12
        @($plan.Skipped | Where-Object { $_.Reason -match 'user collection folder' } | ForEach-Object { $_.Group } | Select-Object -Unique) | Should -Be 'Preserved'
        # execute: structure intact - Workshop subfolder and all 12 files survive as they are
        $plansDir = Join-Path $work 'Plans'
        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder $plansDir
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $b2Cfg -AppRoot (Join-Path $work 'app')
        $res.Summary.FolderMoves | Should -Be 1
        $res.Summary.Failed | Should -Be 0
        Test-Path -LiteralPath (Join-Path $folderActs[0].Destination 'Workshop') | Should -BeTrue
        (Get-ChildItem -LiteralPath (Join-Path $folderActs[0].Destination 'Workshop') -File).Count | Should -Be 8
        (Get-ChildItem -LiteralPath $folderActs[0].Destination -File).Count | Should -Be 4
        # undo restores the whole unit
        $u = Undo-SysOrgPlan -PlanId $plan.PlanId -AppRoot (Join-Path $work 'app') -Config $b2Cfg
        $u.Restored | Should -Be 1
        Test-Path -LiteralPath $undp | Should -BeTrue
        (Get-ChildItem -LiteralPath (Join-Path $undp 'Workshop') -File).Count | Should -Be 8
    }

    It 'a low-confidence collection is left in place and reported for a decision' {
        $work = Join-Path $TestDrive ('b2low-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $srcRoot = Join-Path $work 'src'
        New-Item -ItemType Directory -Path (Join-Path $srcRoot 'Mixed') -Force | Out-Null
        $inv = @()
        foreach($i in 1..5){
            $p = Join-Path (Join-Path $srcRoot 'Mixed') ("doc$i.docx"); Set-Content -LiteralPath $p -Value 'd'
            $inv += [pscustomobject]@{ FullName=$p; Name="doc$i.docx"; Stem="doc$i"; Extension='.docx'
                Length=[long]5; LastWriteTime=(Get-Date '2026-01-05'); Directory=(Join-Path $srcRoot 'Mixed'); Category='Documents' }
        }
        foreach($i in 1..5){
            $p = Join-Path $srcRoot 'Mixed' ("pic$i.jpg"); Set-Content -LiteralPath $p -Value 'p'
            $inv += [pscustomobject]@{ FullName=$p; Name="pic$i.jpg"; Stem="pic$i"; Extension='.jpg'
                Length=[long]5; LastWriteTime=(Get-Date '2026-01-05'); Directory=(Join-Path $srcRoot 'Mixed'); Category='Images' }
        }
        $prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $b2Cfg = @{ OrganizedRoots=@{ 'T' = (Join-Path $work 'org') }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                    SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                    Copies=@{Policy='NumberCopies';StartIndex=2;MinFileSizeKB=1}; Families=@{Enabled=$false}
                    Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; DateFolders='Year'
                    LayoutProfile='Windows'; TypeMap=@{}
                    Folders=@{ PreserveUserCollections=$true; MaxFiles=200; MaxDepth=3; MinMajorityRatio=0.6 } }
        Import-Module (Join-Path $PSScriptRoot '..\Modules\SysOrg.Scan.psm1') -Force
        $cols = @(Get-SysOrgUserCollections -Inventory $inv -Roots @($srcRoot) -Config $b2Cfg -KnownFolders @())
        ($cols | Where-Object Name -eq 'Mixed').MajorityRatio | Should -Be 0.5
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $b2Cfg -KnownFolders @() -UserCollections $cols
        # no collection action; the unit is left in place and needs a decision
        @($plan.Actions | Where-Object { $_.PSObject.Properties['Collection'] -and $_.Collection }).Count | Should -Be 0
        @($plan.NeedsDecision | Where-Object { $_.Disposition -match 'collection' }).Count | Should -Be 1
        $skip = @($plan.Skipped | Where-Object { $_.Reason -match 'User collection left for a decision' })
        $skip.Count | Should -Be 1
        $skip[0].Group | Should -Be 'Decision'
        # the collection is NEVER flattened: its 10 files wait with the unit, reported
        # in the taxonomy's 'left for a decision' group
        @($plan.Skipped | Where-Object { $_.Reason -match 'user collection folder \(left in place' }).Count | Should -Be 10
        @($plan.Actions).Count | Should -Be 0
    }
}

Describe 'Review experience: honest reasons, thresholds and filtering (v3.0.1 B6)' {

    It 'a plan where more than half of the moves are low-confidence NEEDS review' {
        $actions = @()
        foreach($i in 1..6){
            $actions += [pscustomobject]@{ Action='Move'; Kind='File'; Source=("C:\s\m$i.bin"); Destination=("C:\o\m$i.bin")
                Confidence=0.3; ReviewFlag=$true; SizeBytes=[long]1 }
        }
        foreach($i in 1..4){
            $actions += [pscustomobject]@{ Action='Move'; Kind='File'; Source=("C:\s\h$i.txt"); Destination=("C:\o\h$i.txt")
                Confidence=0.9; ReviewFlag=$false; SizeBytes=[long]1 }
        }
        $plan = [pscustomobject]@{ PlanId='plan-rev'; Actions=$actions; NeedsDecision=@(); DestinationRoot='C:\Organized' }
        $cfg = @{ Classify=@{ ReviewConfidence=0.70 }; Review=@{ InteractiveThreshold=0.5 } }
        (Test-SysOrgPlanNeedsReview -Plan $plan -Config $cfg) | Should -BeTrue
        # a majority of confident moves does NOT need review
        $ok = [pscustomobject]@{ PlanId='plan-ok'; Actions=@($actions | Where-Object { $_.Confidence -ge 0.7 }); NeedsDecision=@(); DestinationRoot='C:\Organized' }
        (Test-SysOrgPlanNeedsReview -Plan $ok -Config $cfg) | Should -BeFalse
    }

    It 'folder units, quarantines and undecided actions are excluded from the review share' {
        $actions = @(
            [pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\s\a.bin'; Destination='C:\o\a.bin'; Confidence=0.3 },
            [pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\s\b.txt'; Destination='C:\o\b.txt'; Confidence=0.9 },
            [pscustomobject]@{ Action='Move'; Kind='Folder'; Source='C:\s\UNDP'; Destination='C:\o\Documents\Work\UNDP'; Confidence=0.9 },
            [pscustomobject]@{ Action='Quarantine'; Kind='File'; Source='C:\s\c.bin'; Destination='C:\o\_Duplicates\c.bin'; Confidence=0.3 }
        )
        $plan = [pscustomobject]@{ PlanId='plan-rev2'; Actions=$actions; NeedsDecision=@(); DestinationRoot='C:\Organized' }
        $cfg = @{ Classify=@{ ReviewConfidence=0.70 }; Review=@{ InteractiveThreshold=0.5 } }
        # decided file moves: 1 low of 2 = exactly 50% -> NOT more than half -> no review
        (Test-SysOrgPlanNeedsReview -Plan $plan -Config $cfg) | Should -BeFalse
    }

    It '[A]/[S] filtering keeps confident moves, folder units and quarantines, drops uncertain ones' {
        $actions = @(
            [pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\s\high.txt'; Destination='C:\o\high.txt'; Confidence=0.9 },
            [pscustomobject]@{ Action='Move'; Kind='File'; Source='C:\s\low.bin'; Destination='C:\o\low.bin'; Confidence=0.4 },
            [pscustomobject]@{ Action='Move'; Kind='Folder'; Source='C:\s\UNDP'; Destination='C:\o\Documents\Work\UNDP'; Confidence=0.6 },
            [pscustomobject]@{ Action='Quarantine'; Kind='File'; Source='C:\s\dup.bin'; Destination='C:\o\_Duplicates\dup.bin'; Confidence=0.4 }
        )
        $plan = [pscustomobject]@{ PlanId='plan-filt'; Drive='C:'; DestinationRoot='C:\Organized'; Actions=$actions; NeedsDecision=@(); Skipped=@(); Warnings=@() }
        $f = Get-SysOrgPlanFiltered -Plan $plan -ConfidenceFloor 0.70
        $srcs = @($f.Actions | ForEach-Object { $_.Source })
        ($srcs -contains 'C:\s\high.txt') | Should -BeTrue
        ($srcs -contains 'C:\s\low.bin') | Should -BeFalse
        ($srcs -contains 'C:\s\UNDP') | Should -BeTrue          # folder units survive
        ($srcs -contains 'C:\s\dup.bin') | Should -BeTrue       # quarantines survive
        @($f.Actions).Count | Should -Be 3
        # the filtered plan saves with a valid integrity hash and executes
        $fPath = Save-SysOrgPlan -Plan $f -PlansFolder (Join-Path $TestDrive 'revplans')
        { $null = Get-Content -LiteralPath $fPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        $saved = Get-Content -LiteralPath $fPath -Raw | ConvertFrom-Json
        $expected = Get-SysOrgPlanIntegrityHash -Actions $saved.Actions
        "$($saved.IntegrityHash)" | Should -Be "$expected"
    }

    It 'the honest confidence reason is stored on actions and shown for review-flagged moves' {
        $work = Join-Path $TestDrive ('b6-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $srcRoot = Join-Path $work 'src'
        New-Item -ItemType Directory -Path $srcRoot -Force | Out-Null
        $inv = @()
        foreach($i in 1..3){
            $p = Join-Path $srcRoot ("loose note $i.txt"); Set-Content -LiteralPath $p -Value 'unrelated plain text' -Encoding UTF8
            $inv += [pscustomobject]@{ FullName=$p; Name="loose note $i.txt"; Stem="loose note $i"; Extension='.txt'
                Length=[long]20; LastWriteTime=(Get-Date '2026-01-05'); Directory=$srcRoot; Category='Documents' }
        }
        $prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = @{ OrganizedRoots=@{ 'T' = (Join-Path $work 'org') }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                  SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
                  Copies=@{Policy='NumberCopies';StartIndex=2;MinFileSizeKB=1}; Families=@{Enabled=$false}
                  Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; DateFolders='Year'
                  LayoutProfile='Findable'; TypeMap=@{}; Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 } }
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 3
        foreach($a in @($plan.Actions)){
            "$($a.ConfidenceReason)" | Should -Be 'no lexicon match, extension only'
            [double]$a.Confidence | Should -Be 0.5
        }
        # the reason helper maps the other decision kinds honestly
        $d = [pscustomobject]@{ RuleId='user:taxes'; Gate=$null; Subtype='General'; Category='Documents'; Confidence=1.0 }
        (Get-SysOrgDecisionReason -Decision $d) | Should -Be "matched your rule 'taxes'"
        $d2 = [pscustomobject]@{ RuleId='lexicon'; Gate=$null; Subtype='Work'; Category='Documents'; Confidence=0.8 }
        (Get-SysOrgDecisionReason -Decision $d2) | Should -Be 'lexicon match: Work'
        $d3 = [pscustomobject]@{ RuleId='model'; Gate=$null; Subtype='General'; Category='Documents'; Confidence=0.8 }
        (Get-SysOrgDecisionReason -Decision $d3) | Should -Match 'structure model'
        $d4 = [pscustomobject]@{ RuleId='default'; Gate=$null; Subtype='Media'; Category='Videos'; Confidence=0.8 }
        (Get-SysOrgDecisionReason -Decision $d4) | Should -Be 'media type from extension/metadata only'
    }

    It 'the review destination validator accepts relative leaves only' {
        (Test-SysOrgReviewDestinationPath -Leaf 'Documents\Work') | Should -BeTrue
        (Test-SysOrgReviewDestinationPath -Leaf 'Documents/Work') | Should -BeTrue   # slashes normalize
        (Test-SysOrgReviewDestinationPath -Leaf 'Invoices') | Should -BeTrue
        (Test-SysOrgReviewDestinationPath -Leaf '') | Should -BeFalse
        (Test-SysOrgReviewDestinationPath -Leaf '..\System32') | Should -BeFalse
        (Test-SysOrgReviewDestinationPath -Leaf 'Documents\..\..') | Should -BeFalse
        (Test-SysOrgReviewDestinationPath -Leaf 'C:\Windows') | Should -BeFalse       # the leaf is relative to the plan root
        (Test-SysOrgReviewDestinationPath -Leaf 'a\b') | Should -BeTrue
    }
}
