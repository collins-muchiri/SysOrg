# Tests/SysOrg.Rev21.Tests.ps1
# Covers the revision 2.1 fixtures from ORGANIZATION-DESIGN.md section 14:
#   W5  holiday.jpg + holiday.mp4 -> two same-named families, never one mixed folder
#   W6  Report / byte-identical copy / Report final v2 -> (2) numbered, v2 keeps name,
#       all in Documents\Report; undo restores every original name and path
#   W6  three identical files with different write times -> keeper is the oldest,
#       (2)/(3) order deterministic
#   W2  localized category recognition preserves a 'Bilder' folder
#   W8  OneDrive-rooted source -> sync-out warning listed and counted
#   W5  code project folder moves whole as one MoveFolder unit
#   Downloads branch: provenance buckets and _NoSource
#   W12 migration preview maps Photo -> Pictures etc.; _Duplicates untouched

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Drives.psm1')      -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force

    $script:letter  = if($env:OS -eq 'Windows_NT'){ (Split-Path $TestDrive -Qualifier).TrimEnd(':').ToUpper() } else { 'S' }
    $script:orgRoot = Join-Path $TestDrive 'org'

    $script:prof = [pscustomobject]@{
        Letter=$script:letter; Root=("$script:letter" + ':\'); Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@()
        DestinationRoot=$script:orgRoot
    }
    $script:cfg = @{
        Version='2.1.0'; NamingPreset='Windows'; DestinationStyle='OrganizedRoot'
        OrganizedRoots=@{ $script:letter = $script:orgRoot }
        ExcludedPaths=@(); ExcludedFilePatterns=@()
        SkipHiddenSystemFiles=$true; ExcludeDestinations=$true
        DateFolders='Year'
        PreserveExistingFolders=$false
        Families=@{ Enabled=$true; MinFiles=2; WithinTypeOnly=$true; CrossTypeLink='SameName'
                    NoiseTokens=@('copy','copie','final','new','old','backup','bak','draft','rev','revised','edit','edited','version','untitled')
                    StripVersionSuffix=$true; KeepDates=$true; MaxNameLength=60 }
        Copies=@{ Policy='NumberCopies'; SuffixStyle='Parentheses'; StartIndex=2; MinFileSizeKB=1; HeaderHashKB=64; QuarantineFolderName='_Duplicates' }
        Downloads=@{ Roots=@('Downloads'); GroupBy='SourceFirst'; DateFolders='Year'; UseZoneIdentifier=$false; UnknownSourceFolder='_NoSource' }
        Projects=@{ Enabled=$true; Destination='Documents\Projects\Code'; Markers=@()
                    GenericNames=@('new folder','project','code','test','src','untitled','app') }
        Archives=@{ KeepMultipartTogether=$true }
        Preview=@{ NaturalSort=$true; ShowDenied=$true; WarnOneDriveSyncOut=$true }
        Move=@{ AllowCrossVolume=$true }
        MaxPlanActions=5000
        FolderAudit=@{ Enabled=$false }
        AppRoot=$TestDrive
    }

    function New-SysOrgTestRecord {
        param([Parameter(Mandatory)][string]$Path,[string]$Category='Other')
        $fi = Get-Item -LiteralPath $Path
        return [pscustomobject]@{
            FullName=$fi.FullName; Name=$fi.Name; Stem=$fi.BaseName
            Extension=$fi.Extension.ToLowerInvariant(); Length=[int64]$fi.Length
            LastWriteTime=$fi.LastWriteTime; Directory=$fi.DirectoryName; Category=$Category
        }
    }
    function New-SysOrgTestPlans {
        return (Join-Path $TestDrive ('plans-' + [guid]::NewGuid().ToString('N').Substring(0,6)))
    }
}

Describe 'W6 fixture: Report + byte-identical copy + Report final v2' {
    It 'numbers the copy (2), keeps the v2 name, all in Documents\Report; undo restores everything' {
        $src = Join-Path $TestDrive ('w6-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $p1 = Join-Path $src 'Report.docx'
        $p2 = Join-Path $src 'Report - Copy.docx'
        $p3 = Join-Path $src 'Report final v2.docx'
        Set-Content -LiteralPath $p1 -Value ('R' * 1200)
        Set-Content -LiteralPath $p2 -Value ('R' * 1200)          # byte-identical copy
        Set-Content -LiteralPath $p3 -Value ('S' * 1200)          # different content
        (Get-Item -LiteralPath $p1).LastWriteTime = Get-Date '2026-01-01'
        (Get-Item -LiteralPath $p2).LastWriteTime = Get-Date '2026-01-02'
        (Get-Item -LiteralPath $p3).LastWriteTime = Get-Date '2026-01-03'
        $inv = @((New-SysOrgTestRecord $p1 'Documents'), (New-SysOrgTestRecord $p2 'Documents'), (New-SysOrgTestRecord $p3 'Documents'))
        $dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $cfg)
        $dups.Count | Should -Be 1
        $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $prof -DupGroups $dups -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 3
        $famRoot = Join-Path (Join-Path $orgRoot 'Documents') 'Report'
        foreach($a in @($plan.Actions)){ (Split-Path $_.Destination -Parent) | Should -Be $famRoot }
        $keeper = @($plan.Actions | Where-Object { $_.Source -eq $p1 })[0]
        (Split-Path $keeper.Destination -Leaf) | Should -Be 'Report.docx'
        $copy = @($plan.Actions | Where-Object { $_.Source -eq $p2 })[0]
        (Split-Path $copy.Destination -Leaf) | Should -Be 'Report (2).docx'
        $copy.CopyIndex | Should -Be 2
        $v2 = @($plan.Actions | Where-Object { $_.Source -eq $p3 })[0]
        (Split-Path $v2.Destination -Leaf) | Should -Be 'Report final v2.docx'   # original name never rewritten
        $plan.Families[0].Name | Should -Be 'Report'

        # execute + undo: numbering is fully reversible (9.6)
        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder (New-SysOrgTestPlans)
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfg -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 3
        Test-Path -LiteralPath (Join-Path $famRoot 'Report.docx') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $famRoot 'Report (2).docx') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $famRoot 'Report final v2.docx') | Should -BeTrue
        Test-Path -LiteralPath $p1 | Should -BeFalse
        $u = Undo-SysOrgPlan -PlanId $plan.PlanId -AppRoot $TestDrive -Config $cfg
        $u.Restored | Should -Be 3
        foreach($p in @($p1,$p2,$p3)){ Test-Path -LiteralPath $p | Should -BeTrue }
        (Get-Item -LiteralPath $p2).Name | Should -Be 'Report - Copy.docx'   # original copy name restored
    }
}

Describe 'W6/W7 fixture: three identical files, deterministic numbering' {
    It 'keeper is the oldest write time; (2) and (3) follow LastWriteTime then natural order' {
        $src = Join-Path $TestDrive ('w67-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $pA = Join-Path $src 'first.bin'
        $pB = Join-Path $src 'second.bin'
        $pC = Join-Path $src 'third.bin'
        Set-Content -LiteralPath $pA -Value ('K' * 1200)
        Set-Content -LiteralPath $pB -Value ('K' * 1200)
        Set-Content -LiteralPath $pC -Value ('K' * 1200)
        (Get-Item -LiteralPath $pA).LastWriteTime = Get-Date '2026-01-05'
        (Get-Item -LiteralPath $pB).LastWriteTime = Get-Date '2026-01-03'   # oldest -> keeper
        (Get-Item -LiteralPath $pC).LastWriteTime = Get-Date '2026-01-04'
        $inv = @((New-SysOrgTestRecord $pA 'Other'), (New-SysOrgTestRecord $pB 'Other'), (New-SysOrgTestRecord $pC 'Other'))
        $dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $cfg)
        $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $prof -DupGroups $dups -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 3
        $keeper = @($plan.Actions | Where-Object { $_.CopyIndex -eq $null -and "$($_.Action)" -eq 'Move' })[0]
        $keeper.Source | Should -Be $pB
        $n2 = @($plan.Actions | Where-Object { $_.CopyIndex -eq 2 })[0]
        $n3 = @($plan.Actions | Where-Object { $_.CopyIndex -eq 3 })[0]
        $n2.Source | Should -Be $pC      # next-oldest gets (2)
        $n3.Source | Should -Be $pA      # newest gets (3)
        (Split-Path $n2.Destination -Leaf) | Should -Be 'second (2).bin'
        (Split-Path $n3.Destination -Leaf) | Should -Be 'second (3).bin'
        (Split-Path $n2.Destination -Parent) | Should -Be (Split-Path $keeper.Destination -Parent)
    }
}

Describe 'W5 fixture: holiday.jpg + holiday.mp4' {
    It 'produces same-named families in Pictures and Videos - never one mixed folder' {
        $src = Join-Path $TestDrive ('w5-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $p1 = Join-Path $src 'holiday.jpg'
        $p2 = Join-Path $src 'holiday.mp4'
        Set-Content -LiteralPath $p1 -Value 'jpg-data'
        Set-Content -LiteralPath $p2 -Value 'mp4-data-more-bytes'
        $inv = @((New-SysOrgTestRecord $p1 'Pictures'), (New-SysOrgTestRecord $p2 'Videos'))
        $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 2
        @($plan.Families).Count | Should -Be 2
        foreach($fam in @($plan.Families)){
            $fam.Name | Should -Be 'holiday'
            $fam.Basis | Should -Match 'across types'
        }
        $a1 = @($plan.Actions | Where-Object { $_.Source -eq $p1 })[0]
        $a2 = @($plan.Actions | Where-Object { $_.Source -eq $p2 })[0]
        $a1.Family | Should -Be $a2.Family                       # plan audit field links them
        (Split-Path (Split-Path $a1.Destination -Parent) -Leaf) | Should -Be 'Pictures'
        (Split-Path (Split-Path $a2.Destination -Parent) -Leaf) | Should -Be 'Videos'
        (Split-Path $a1.Destination -Parent) | Should -Not -Be (Split-Path $a2.Destination -Parent)
        $a1.Destination | Should -Be (Join-Path (Join-Path $orgRoot 'Pictures\holiday') 'holiday.jpg')
        $a2.Destination | Should -Be (Join-Path (Join-Path $orgRoot 'Videos\holiday') 'holiday.mp4')
    }
}

Describe 'W2 fixture: localized category recognition preserves a Bilder folder' {
    It 'a folder whose localized leaf name matches a known-folder name is preserved' {
        $mockKf = @([pscustomobject]@{ Name='Pictures'; Path=(Join-Path $TestDrive 'bilder'); IsRedirected=$true; UnderOneDrive=$false })
        $src = Join-Path $TestDrive ('w2-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $bilder = Join-Path $src 'Bilder'
        New-Item -ItemType Directory -Path (Join-Path $bilder 'trip') -Force | Out-Null
        $p1 = Join-Path $bilder 'trip\photo1.jpg'
        $p2 = Join-Path $bilder 'trip\photo2.jpg'
        Set-Content -LiteralPath $p1 -Value 'x1'
        Set-Content -LiteralPath $p2 -Value 'x2'
        $inv = @((New-SysOrgTestRecord $p1 'Pictures'), (New-SysOrgTestRecord $p2 'Pictures'))
        $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders $mockKf
        @($plan.Actions).Count | Should -Be 0
        $skips = @($plan.Skipped | Where-Object { $_.Source -eq $p1 -or $_.Source -eq $p2 })
        $skips.Count | Should -Be 2
        $skips[0].Reason | Should -Match 'Existing Pictures folder \(preserved'
    }
}

Describe 'W8 fixture: OneDrive sync-out warning' {
    It 'a move out of a OneDrive root is listed and counted' {
        $oldOD = $env:OneDrive
        try{
            $env:OneDrive = (Join-Path $TestDrive 'od')
            $odDocs = Join-Path $env:OneDrive 'docs'
            New-Item -ItemType Directory -Path $odDocs -Force | Out-Null
            $p1 = Join-Path $odDocs 'synced.txt'
            Set-Content -LiteralPath $p1 -Value 'cloud file'
            $inv = @(New-SysOrgTestRecord $p1 'Documents')
            $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders @()
            @($plan.Actions).Count | Should -Be 1
            @($plan.OneDrive.SyncOut).Count | Should -Be 1
            $plan.Actions[0].OneDriveSyncOut | Should -BeTrue
            $sum = Show-SysOrgPlan -Plan $plan -Config $cfg
            $sum.OneDriveSyncOut | Should -Be 1
        } finally {
            $env:OneDrive = $oldOD
        }
    }
}

Describe 'Code project folders move whole (rev 2.0 D4 via W5)' {
    It 'a marker-bearing folder becomes one MoveFolder action with .git intact' {
        $src = Join-Path $TestDrive ('proj-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $repoDir = Join-Path $src 'myapp'
        New-Item -ItemType Directory -Path (Join-Path $repoDir '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repoDir 'readme.md') -Value 'repo'
        Set-Content -LiteralPath (Join-Path $repoDir '.git\HEAD') -Value 'ref'
        $loose = Join-Path $src 'loose.txt'
        Set-Content -LiteralPath $loose -Value 'loose'
        $projects = @(Get-SysOrgProjectFolders -Roots @($src) -Config $cfg -DriveProfile $prof -KnownFolders @())
        $projects.Count | Should -Be 1
        $projects[0].SafeName | Should -Be 'myapp'
        $inv = @((New-SysOrgTestRecord (Join-Path $repoDir 'readme.md') 'Documents'), (New-SysOrgTestRecord $loose 'Documents'))
        $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders @() -ProjectFolders $projects
        $folderActions = @($plan.Actions | Where-Object { "$($_.Kind)" -eq 'Folder' })
        $folderActions.Count | Should -Be 1
        $folderActions[0].Destination | Should -Be (Join-Path (Join-Path $orgRoot 'Documents\Projects\Code') 'myapp')
        # the repo files are NOT planned individually
        @($plan.Actions | Where-Object { $_.Source -like '*readme.md' -and "$($_.Kind)" -eq 'File' }).Count | Should -Be 0

        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder (New-SysOrgTestPlans)
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfg -AppRoot $TestDrive
        $res.Summary.FolderMoves | Should -Be 1
        Test-Path -LiteralPath (Join-Path $folderActions[0].Destination '.git\HEAD') | Should -BeTrue
        Test-Path -LiteralPath $repoDir | Should -BeFalse
    }
}

Describe 'Downloads branch provenance' {
    It 'WhatsApp-named files in a download root route to Downloads\WhatsApp\<type>\<year>' {
        $dl = Join-Path $TestDrive ('dl-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $dl -Force | Out-Null
        $p1 = Join-Path $dl 'WhatsApp Image 2024-01-01 at 10.00.00.jpeg'
        Set-Content -LiteralPath $p1 -Value ('W' * 100)
        $inv = @(New-SysOrgTestRecord $p1 'Pictures')
        $dlProf = [pscustomobject]@{ Letter=$letter; Root=("$letter" + ':\'); Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@($dl); Artifacts=@(); TopLevelDirs=@(); DestinationRoot=$orgRoot }
        $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $dlProf -DupGroups @() -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 1
        $plan.Actions[0].SourceBucket | Should -Be 'WhatsApp'
        $plan.Actions[0].Destination | Should -BeLike ((Join-Path $orgRoot 'Downloads\WhatsApp\Pictures') + '*')
        $year = (Get-Item -LiteralPath $p1).LastWriteTime.ToString('yyyy')
        $plan.Actions[0].Destination | Should -BeLike (("*\" + $year) + "\*")
    }
    It 'files without provenance land in _NoSource; installers route to _NoSource\Installers' {
        $dl = Join-Path $TestDrive ('dl2-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $dl -Force | Out-Null
        $p1 = Join-Path $dl 'data.bin'
        $p2 = Join-Path $dl 'setup.exe'
        Set-Content -LiteralPath $p1 -Value ('D' * 100)
        Set-Content -LiteralPath $p2 -Value ('E' * 100)
        $inv = @((New-SysOrgTestRecord $p1 'Other'), (New-SysOrgTestRecord $p2 'Installers'))
        $dlProf = [pscustomobject]@{ Letter=$letter; Root=("$letter" + ':\'); Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@($dl); Artifacts=@(); TopLevelDirs=@(); DestinationRoot=$orgRoot }
        $plan = New-SysOrgPlan -Letter $letter -Inventory $inv -DriveProfile $dlProf -DupGroups @() -Config $cfg -KnownFolders @()
        @($plan.Actions).Count | Should -Be 2
        $bin = @($plan.Actions | Where-Object { $_.Source -eq $p1 })[0]
        $exe = @($plan.Actions | Where-Object { $_.Source -eq $p2 })[0]
        $bin.Destination  | Should -BeLike ((Join-Path $orgRoot 'Downloads\_NoSource\Other') + '*')
        $exe.Destination  | Should -BeLike ((Join-Path $orgRoot 'Downloads\_NoSource\Installers') + '*')
    }
}

Describe 'W12 fixture: migration preview from old trees' {
    It 'maps Photo -> Pictures, Video\Audio -> Music, leaves _Duplicates untouched; undoable' {
        $old = Join-Path $TestDrive ('migrate-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $old 'Photo\2024')        -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $old 'Video\Audio\2023')  -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $old '_Duplicates\p-1')   -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $old 'Downloads')         -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $old 'Photo\2024\a.jpg')    -Value 'a'
        Set-Content -LiteralPath (Join-Path $old 'Photo\loose.jpg')     -Value 'l'
        Set-Content -LiteralPath (Join-Path $old 'Video\Audio\2023\b.mp3') -Value 'b'
        Set-Content -LiteralPath (Join-Path $old 'Video\clip.mp4')      -Value 'c'
        Set-Content -LiteralPath (Join-Path $old '_Duplicates\p-1\c.bin') -Value 'd'
        Set-Content -LiteralPath (Join-Path $old 'Downloads\keep.txt')  -Value 'k'
        $migCfg = @{ OrganizedRoots=@{ $letter = $old }; ReportsFolderName='_Reports'; MaxPlanActions=5000 }
        $plan = New-SysOrgMigrationPlan -Letter $letter -Config $migCfg
        $act = @($plan.Actions)
        $folders = @($act | Where-Object { "$($_.Kind)" -eq 'Folder' })
        @($folders | Where-Object { $_.Source -eq (Join-Path $old 'Photo\2024') -and $_.Destination -eq (Join-Path $old 'Pictures\2024') }).Count | Should -Be 1
        @($folders | Where-Object { $_.Source -eq (Join-Path $old 'Video\Audio\2023') -and $_.Destination -eq (Join-Path $old 'Music\2023') }).Count | Should -Be 1
        @($act | Where-Object { $_.Source -eq (Join-Path $old 'Photo\loose.jpg') -and $_.Destination -eq (Join-Path $old 'Pictures\loose.jpg') }).Count | Should -Be 1
        @($act | Where-Object { $_.Source -eq (Join-Path $old 'Video\clip.mp4') -and $_.Destination -eq (Join-Path $old 'Videos\clip.mp4') }).Count | Should -Be 1
        @($act | Where-Object { $_.Source -like '*_Duplicates*' }).Count | Should -Be 0     # quarantine folder untouched
        @($act | Where-Object { $_.Source -like '*Downloads\keep.txt*' }).Count | Should -Be 0
        @($plan.Skipped | Where-Object { $_.Source -eq (Join-Path $old '_Duplicates') }).Count | Should -Be 1

        $planPath = Save-SysOrgPlan -Plan $plan -PlansFolder (New-SysOrgTestPlans)
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $migCfg -AppRoot $TestDrive
        $res.Summary.Moved | Should -Be 2
        $res.Summary.FolderMoves | Should -Be 2
        Test-Path -LiteralPath (Join-Path $old 'Pictures\2024\a.jpg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $old 'Music\2023\b.mp3') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $old 'Videos\clip.mp4') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $old 'Pictures\loose.jpg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $old '_Duplicates\p-1\c.bin') | Should -BeTrue   # untouched
        $u = Undo-SysOrgPlan -PlanId $plan.PlanId -AppRoot $TestDrive -Config $migCfg
        $u.Restored | Should -Be 4
        Test-Path -LiteralPath (Join-Path $old 'Photo\2024\a.jpg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $old 'Video\Audio\2023\b.mp3') | Should -BeTrue
    }
}

Describe 'W1 fixture: no plan builds without a profile; profiles describe every volume' {
    It 'Get-SysOrgDriveProfile returns role, scope and destination per volume' {
        Mock Get-SysOrgDrive -ModuleName SysOrg.Drives {
            @([pscustomobject]@{ Drive='X:'; Label='Lbl'; FileSystem='NTFS'; SizeGB=100; FreeGB=40
                MediaType='SSD'; BusType='SATA'; Location='Internal'; Confidence='Medium-High'; DetectionBasis='fixture' })
        }
        $pCfg = @{ OrganizedRoots=@{ '*'='__AUTO__' }; Policy=@{ ProtectedArtifacts=@('Windows','WindowsApps','XboxGames') } }
        $profiles = @(Get-SysOrgDriveProfile -Config $pCfg -Letters 'X')
        $profiles.Count | Should -Be 1
        $profiles[0].Letter | Should -Be 'X'
        $profiles[0].Role | Should -Be 'Data'
        $profiles[0].ProposedScope | Should -Be 'FullDrive'
        $profiles[0].DestinationRoot | Should -Be 'X:\_Organized'
        Mock Get-SysOrgDrive -ModuleName SysOrg.Drives {
            @([pscustomobject]@{ Drive='C:'; Label='OS'; FileSystem='NTFS'; SizeGB=200; FreeGB=50
                MediaType='SSD'; BusType='NVMe'; Location='Internal'; Confidence='High'; DetectionBasis='fixture' })
        }
        $p2 = @(Get-SysOrgDriveProfile -Config $pCfg -Letters 'C')[0]
        $p2.Role | Should -Be 'System'
        $p2.ProposedScope | Should -Be 'KnownFolders'
    }
}
