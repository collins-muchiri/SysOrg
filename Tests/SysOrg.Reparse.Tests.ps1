# ---------------------------------------------------------------------------
# v3.0.2 B1: reparse points are classified by TAG, not by the attribute alone.
# The real run skipped OneDrive Documents/Pictures/Desktop as 'cannot alter'
# purely on the ReparsePoint attribute (scanned files fell 9,579 -> 1,570).
# Tag values are the documented Windows constants; tests drive them through the
# v3.0.2 mock seam (Set-SysOrgReparseTagMock), which is the exact resolver the
# production code calls before FindFirstFileW. B3's legacy-junction quiet skip
# is asserted here too (same code path).
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

AfterAll { Clear-SysOrgReparseTagMocks }

Describe 'Get-SysOrgReparseClassification (v3.0.2 B1)' {

    It 'classifies the cloud-files family (OneDrive) as Cloud - any variant tag' {
        Set-SysOrgReparseTagMock -Path 'C:\Users\a\Documents' -Tag 0x90000001
        Set-SysOrgReparseTagMock -Path 'C:\Users\a\Pictures'  -Tag 0x9000A001
        Get-SysOrgReparseClassification -Path 'C:\Users\a\Documents' | Should -Be 'Cloud'
        Get-SysOrgReparseClassification -Path 'C:\Users\a\Pictures'  | Should -Be 'Cloud'
    }

    It 'classifies symlinks and junctions as never-follow links' {
        Set-SysOrgReparseTagMock -Path 'C:\link\one' -Tag 0xA000000C   # IO_REPARSE_TAG_SYMLINK
        Set-SysOrgReparseTagMock -Path 'C:\link\two' -Tag 0xA0000003   # IO_REPARSE_TAG_MOUNT_POINT
        Get-SysOrgReparseClassification -Path 'C:\link\one' | Should -Be 'Symlink'
        Get-SysOrgReparseClassification -Path 'C:\link\two' | Should -Be 'Junction'
    }

    It 'classifies other tags (APPEXECLINK) as Other and tag 0 as None' {
        Set-SysOrgReparseTagMock -Path 'C:\store\app.exe' -Tag 0x8000001B
        Set-SysOrgReparseTagMock -Path 'C:\plain\folder'  -Tag 0
        Get-SysOrgReparseClassification -Path 'C:\store\app.exe' | Should -Be 'Other'
        Get-SysOrgReparseClassification -Path 'C:\plain\folder'  | Should -Be 'None'
    }

    It 'reports Unknown when the tag is unknowable (portable host, no mock)' {
        $p = Join-Path $TestDrive ('unknowable-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        if($env:OS -eq 'Windows_NT'){
            # v3.0.2 CI: on Windows the REAL FindFirstFileW resolver CAN read the
            # tag, so a plain folder is not a reparse point -> 'None'. 'Unknown'
            # is the portable-host contract (non-Windows host without a mock).
            Get-SysOrgReparseClassification -Path $p | Should -Be 'None'
        } else {
            Get-SysOrgReparseClassification -Path $p | Should -Be 'Unknown'
        }
    }
}

Describe 'cloud folders are scanned, not "cannot alter" (v3.0.2 B1)' {

    It 'a cloud-reparse Documents root is traversed and its files listed' {
        $tree = Join-Path $TestDrive ('cloud-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tree 'Documents') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'Documents\cloud doc.txt') -Value 'cloud'
        Set-Content -LiteralPath (Join-Path $tree 'plain file.txt') -Value 'plain'
        Set-SysOrgReparseTagMock -Path $tree -Tag 0x90000001
        $trail = New-Object System.Collections.Generic.List[object]
        $inv = @(Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true } } -AuditTrail $trail)
        @($inv | Where-Object { "$($_.Name)" -eq 'cloud doc.txt' }).Count | Should -Be 1 -Because 'the cloud root is traversed like any folder'
        # and the cloud root is NOT in the cannot-alter list
        @($trail | Where-Object { $_.Status -eq 'Protected' -and $_.Path -eq $tree }).Count | Should -Be 0
    }

    It 'a junction-tagged folder is skipped and recorded as Protected (loud)' {
        $tree = Join-Path $TestDrive ('junc-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $tree 'Link Folder') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'Link Folder\inside.txt') -Value 'x'
        Set-SysOrgReparseTagMock -Path (Join-Path $tree 'Link Folder') -Tag 0xA0000003
        $trail = New-Object System.Collections.Generic.List[object]
        $inv = @(Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true } } -AuditTrail $trail)
        @($inv | Where-Object { "$($_.Name)" -eq 'inside.txt' }).Count | Should -Be 0 -Because 'junctions are never followed'
        $row = @($trail | Where-Object { $_.Status -eq 'Protected' -and "$($_.Path)".EndsWith('Link Folder') })
        @($row).Count | Should -Be 1
        "$($row[0].Reason)" | Should -Match 'junction'
    }
}

Describe 'legacy junctions are skipped quietly (v3.0.2 B3)' {

    It 'Documents\My Pictures gets reason "legacy junction (expected)", not a Protected entry' {
        $tree = Join-Path $TestDrive ('legacy-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $docs = Join-Path $tree 'Documents'
        New-Item -ItemType Directory -Path (Join-Path $docs 'My Pictures') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $docs 'My Pictures\would-not-list.txt') -Value 'x'
        Set-SysOrgReparseTagMock -Path (Join-Path $docs 'My Pictures') -Tag 0xA0000003
        $trail = New-Object System.Collections.Generic.List[object]
        $inv = @(Get-SysOrgInventory -Letter 'X' -Roots @($docs) -Config @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true } } -AuditTrail $trail)
        @($inv | Where-Object { "$($_.Name)" -eq 'would-not-list.txt' }).Count | Should -Be 0 -Because 'the legacy junction is never followed either'
        @($trail | Where-Object { $_.Status -eq 'Protected' }).Count | Should -Be 0 -Because 'a legacy junction is EXPECTED, not alarming'
        $row = @($trail | Where-Object { $_.Status -eq 'Preserved' -and $_.Reason -eq 'legacy junction (expected)' })
        @($row).Count | Should -Be 1
        Test-SysOrgLegacyJunctionName -Name 'My Videos' | Should -BeTrue
        Test-SysOrgLegacyJunctionName -Name 'My Music'  | Should -BeTrue
        Test-SysOrgLegacyJunctionName -Name 'Backup'    | Should -BeFalse
    }
}

Describe 'Get-SysOrgFolderProtectionReason by tag (v3.0.2 B1)' {

    It 'does not protect a cloud folder' {
        $p = Join-Path $TestDrive ('clouddir-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-SysOrgReparseTagMock -Path $p -Tag 0x90000001
        Get-SysOrgFolderProtectionReason -Path $p -Config @{ FolderAudit=@{ SkipHiddenSystemDirs=$true } } -CfaFolders @() | Should -BeNullOrEmpty
    }

    It 'protects junctions and symlinks with the never-followed reason' {
        $pj = Join-Path $TestDrive ('jdir-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $pj -Force | Out-Null
        Set-SysOrgReparseTagMock -Path $pj -Tag 0xA0000003
        Get-SysOrgFolderProtectionReason -Path $pj -Config @{ FolderAudit=@{ SkipHiddenSystemDirs=$true } } -CfaFolders @() | Should -Match 'junction'
        $ps = Join-Path $TestDrive ('sdir-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $ps -Force | Out-Null
        Set-SysOrgReparseTagMock -Path $ps -Tag 0xA000000C
        Get-SysOrgFolderProtectionReason -Path $ps -Config @{ FolderAudit=@{ SkipHiddenSystemDirs=$true } } -CfaFolders @() | Should -Match 'symlink'
    }
}

# Windows CI legs only: the REAL tags through FindFirstFileW
Describe 'real reparse tags through FindFirstFileW (v3.0.2 B1, Windows)' -Skip:($env:OS -ne 'Windows_NT') {

    It 'reads IO_REPARSE_TAG_MOUNT_POINT from a real junction' {
        $root = Join-Path $TestDrive ('realjunc-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'target') -Force | Out-Null
        $jp = Join-Path $root 'real junction'
        $null = New-Item -ItemType Junction -Path $jp -Target (Join-Path $root 'target') -ErrorAction Stop
        Get-SysOrgReparseClassification -Path $jp | Should -Be 'Junction'
        # and the attribute fallback still answers for a plain folder
        Get-SysOrgReparseClassification -Path (Join-Path $root 'target') | Should -Be 'None'
    }
}

# ---------------------------------------------------------------------------
# v3.0.2 B4: name-based system rules apply ONLY at drive-root level or under
# known absolute system parents - never deep inside user or project trees.
# The real run flagged '...\deploy\windows' inside a project as 'System
# location (never alter)' purely by its leaf name.
# ---------------------------------------------------------------------------
Describe 'name-based system rules are scoped (v3.0.2 B4)' {

    It 'C:\Windows stays System location (never alter)' {
        Get-SysOrgFolderProtectionReason -Path 'C:\Windows' -Config @{} -CfaFolders $null | Should -Be 'System location (never alter)'
    }

    It 'C:\Program Files\Intel stays protected through its known absolute parent' {
        Get-SysOrgFolderProtectionReason -Path 'C:\Program Files\Intel' -Config @{} -CfaFolders $null | Should -Be 'System location (never alter)'
    }

    It 'X:\dell at a data-drive root stays protected' {
        Get-SysOrgFolderProtectionReason -Path 'X:\dell' -Config @{} -CfaFolders $null | Should -Be 'Protected folder name (never alter)'
    }

    It 'proj\deploy\windows deep inside a project tree is NOT protected by its name' {
        $proj = Join-Path $TestDrive ('b4proj-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $deploy = Join-Path $proj 'deploy\windows'
        New-Item -ItemType Directory -Path $deploy -Force | Out-Null
        Get-SysOrgFolderProtectionReason -Path $deploy -Config @{ FolderAudit=@{ SkipHiddenSystemDirs=$true } } -CfaFolders @() | Should -BeNullOrEmpty
    }

    It 'the deep-in-project windows folder is scannable by the walk' {
        $proj = Join-Path $TestDrive ('b4walk-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $deploy = Join-Path $proj 'deploy\windows'
        New-Item -ItemType Directory -Path $deploy -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $deploy 'deploy tool (x86).exe') -Value 'binary'
        $inv = @(Get-SysOrgInventory -Letter 'X' -Roots @($proj) -Config @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true }; Move=@{ AllowInstallersInDownloads=$true } })
        @($inv | Where-Object { "$($_.Name)" -eq 'deploy tool (x86).exe' }).Count | Should -BeGreaterThan 0
    }

    It 'a system name two levels deep under a user tree is not protected either' {
        $user = Join-Path $TestDrive ('b4user-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $deep = Join-Path $user 'backup\intel'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Get-SysOrgFolderProtectionReason -Path $deep -Config @{ FolderAudit=@{ SkipHiddenSystemDirs=$true } } -CfaFolders @() | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# v3.0.2 B2: a scan root that is dropped is NEVER silent - the walk reports it
# via CacheStats.SkippedRoots, the scan summary and the plan header say so
# loudly, and the count is part of the skip taxonomy.
# ---------------------------------------------------------------------------
Describe 'skipped scan roots are loud (v3.0.2 B2)' {

    It 'the walk records a dropped root with its reason in the cache stats' {
        $tree = Join-Path $TestDrive ('b2root-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $tree 'Junction Root') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'Junction Root\hidden file.txt') -Value 'x'
        Set-SysOrgReparseTagMock -Path (Join-Path $tree 'Junction Root') -Tag 0xA0000003
        $stats = @{}
        $null = Get-SysOrgInventory -Letter 'X' -Roots @((Join-Path $tree 'Junction Root')) -Config @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true } } -CacheStatsOut $stats
        $stats.ContainsKey('SkippedRoots') | Should -BeTrue
        $roots = @($stats.SkippedRoots)
        @($roots).Count | Should -Be 1
        "$($roots[0].Reason)" | Should -Match 'junction'
    }

    It 'a healthy root is not reported' {
        $tree = Join-Path $TestDrive ('b2ok-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'fine.txt') -Value 'fine'
        $stats = @{}
        $null = Get-SysOrgInventory -Letter 'X' -Roots @($tree) -Config @{ ExcludedPaths=@(); ExcludedFilePatterns=@(); ExcludeDestinations=$true; FolderAudit=@{ Enabled=$true } } -CacheStatsOut $stats
        if($stats.ContainsKey('SkippedRoots')){ @($stats.SkippedRoots).Count | Should -Be 0 }
    }

    It 'New-SysOrgPlan carries the dropped roots into the plan and warns' {
        $inv = @([pscustomobject]@{ FullName='C:\src\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\src'; Category='Documents' })
        $prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = @{ AppRoot=(Join-Path $TestDrive 'b2app'); OrganizedRoots=@{ '*'='__AUTO__' }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=0 }; Families=@{ Enabled=$false }
            Downloads=@{ UseZoneIdentifier=$false }; Move=@{ AllowCrossVolume=$true }
            ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true; ExcludeDestinations=$true
            PreserveExistingFolders=$false; DateFolders='Year'; FolderAudit=@{ Enabled=$false }; TypeMap=@{} }
        $plan = New-SysOrgPlan -Letter 'T' -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders @() `
            -SkippedScanRoots @([pscustomobject]@{ Path='C:\Users\a\Documents'; Reason='Reparse point (junction - never followed)' })
        $plan.PSObject.Properties['SkippedRoots'] | Should -Not -BeNullOrEmpty
        @($plan.SkippedRoots).Count | Should -Be 1
        $warnLine = @($plan.Warnings | Where-Object { $_ -match 'NOT scanned' })
        @($warnLine).Count | Should -Be 1
        "$warnLine" | Should -Match '1 scan root\(s\) were NOT scanned'
        "$warnLine" | Should -Match 'Documents \(Reparse point \(junction - never followed\)\)' -Because ($warnLine -join ' ')
    }

    It 'the plan preview states the count in the skip taxonomy' {
        $inv = @([pscustomobject]@{ FullName='C:\src\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
            Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\src'; Category='Documents' })
        $prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = @{ AppRoot=(Join-Path $TestDrive 'b2app2'); OrganizedRoots=@{ '*'='__AUTO__' }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=0 }; Families=@{ Enabled=$false }
            Downloads=@{ UseZoneIdentifier=$false }; Move=@{ AllowCrossVolume=$true }
            ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true; ExcludeDestinations=$true
            PreserveExistingFolders=$false; DateFolders='Year'; FolderAudit=@{ Enabled=$false }; TypeMap=@{} }
        $plan = New-SysOrgPlan -Letter 'T' -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders @() `
            -SkippedScanRoots @([pscustomobject]@{ Path='C:\Users\a\Documents'; Reason='legacy junction (expected)' })
        $out = Show-SysOrgPlan -Plan $plan -Config $cfg 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        $text | Should -Match 'Scan roots NOT scanned: 1'
        $text | Should -Match 'Documents was NOT scanned: legacy junction \(expected\)'
    }
}
