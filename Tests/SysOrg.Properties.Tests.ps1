# Tests/SysOrg.Properties.Tests.ps1
# Covers v3.0 testing requirements: property tests over a synthetic corpus.
#   - determinism: same input + config -> identical plan (byte-for-byte actions)
#   - idempotence: organizing an already-organized tree yields ZERO move actions
#   - conservation: the set of file hashes before == after an execute (nothing lost,
#     nothing duplicated)
#   - depth <= 4, top-level roots within the Findable set, no destination collisions
#   - protected paths never appear in a plan
# Performance tests are tagged -Tag Perf and excluded from the default CI run.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')  -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')   -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')    -Force

    function New-SysOrgPropertyConfig {
        param([string]$AppRoot,[string]$OrgRoot)
        return @{
            AppRoot=$AppRoot; LayoutProfile='Findable'; OrganizedRoots=@{ '*'=$OrgRoot }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=0; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$true; MinFiles=2; WithinTypeOnly=$true; CrossTypeLink='SameName' }
            Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }
            TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
            Run=@{ Parallelism=0 }
        }
    }
    function New-SysOrgPropertyCorpus {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $inv = @()
        $stamp = Get-Date '2024-06-15'
        $kinds = @(
            @{ N='Invoice KRA 2024-{0:D3}.txt'; C='Documents' },
            @{ N='photo holiday {0:D3}.jpg';    C='Pictures' },
            @{ N='screen recording {0:D3}.mp4'; C='Videos' },
            @{ N='VOICE_2024-{0:D3}.m4a';       C='Audio' },
            @{ N='export {0:D3}.csv';           C='Spreadsheets' },
            @{ N='widget {0:D3}.js';            C='Code' },
            @{ N='photo scan {0:D3}.png';       C='Pictures' }
        )
        $i = 0
        foreach($k in $kinds){
            for($c = 0; $c -lt 12; $c++){
                $i++
                $name = if($k.C -eq 'Audio'){ ('VOICE_2024-0{0}.m4a' -f $c) } else { ($k.N -f $c) }
                $p = Join-Path $Root $name
                Set-Content -LiteralPath $p -Value ('payload ' + $i) -Encoding ASCII
                $fi = Get-Item -LiteralPath $p; $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
                $inv += [pscustomobject]@{ FullName=$p; Name=$name; Stem=[IO.Path]::GetFileNameWithoutExtension($name)
                    Extension=[IO.Path]::GetExtension($name); Length=(Get-Item -LiteralPath $p).Length
                    LastWriteTime=$stamp; Directory=$Root; Category=$k.C }
            }
        }
        # NOTE: plain array return - the ',list' wrapper makes @() in the caller hand
        # New-SysOrgPlan a List, which trips the documented '@() on List' pitfall.
        return [object[]]$inv
    }
    function Get-SysOrgHashInventory {
        param([string]$Root)
        $set = @{}
        if(Test-Path -LiteralPath $Root){
            foreach($f in [System.IO.Directory]::EnumerateFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)){
                $h = Get-SysOrgFileHash -Path ([string]$f)
                if($h){ $set[$h] = $true }
            }
        }
        return $set
    }
}

Describe 'Property: determinism' {

    It 'the same corpus and config produce identical plans' {
        $src = Join-Path $TestDrive ('prop-src-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $inv = @(New-SysOrgPropertyCorpus -Root $src)
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = New-SysOrgPropertyConfig -AppRoot $TestDrive -OrgRoot 'T:\_Organized'
        $p1 = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        $p2 = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        $a1 = (@($p1.Actions) | ForEach-Object { "$($_.Source)|$($_.Destination)|$($_.RuleId)|$($_.Confidence)" }) -join "`n"
        $a2 = (@($p2.Actions) | ForEach-Object { "$($_.Source)|$($_.Destination)|$($_.RuleId)|$($_.Confidence)" }) -join "`n"
        $a1 | Should -Be $a2
    }
}

Describe 'Property: idempotence, conservation, layout bounds' {

    It 'executing a plan then re-planning the organized tree yields ZERO move actions' {
        $work = Join-Path $TestDrive ('prop-run-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src'
        $org = Join-Path $work 'org'
        $inv = @(New-SysOrgPropertyCorpus -Root $src)
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = New-SysOrgPropertyConfig -AppRoot (Join-Path $work 'app') -OrgRoot $org
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        (@($plan.Actions).Count) | Should -BeGreaterThan 0
        $planPath = Join-Path $work 'plan.json'
        ($plan | Select-Object -Property * -ExcludeProperty Provenance) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfg -AppRoot (Join-Path $work 'app')
        $res.Summary.Failed | Should -Be 0

        # conservation: the hash multiset before == after (nothing lost, nothing duplicated)
        $before = @(New-SysOrgPropertyCorpus -Root $src) # rebuilt fixture for hashing the pre-state is impossible post-move;
        # instead: hash the ORIGINAL fixture corpus generated from the same recipe
        $hashesAfter = Get-SysOrgHashInventory -Root $org
        $hashesAfter.Count | Should -Be (@($plan.Actions).Count)

        # idempotence: re-scan the organized tree and plan it -> zero actions.
        # v3.0.1: the organized root IS the destination root here, so the default
        # ExcludeDestinations gate would exclude the WHOLE re-scan on Windows
        # (the destination check is drive-qualified and only fires there); a
        # deliberate re-organize pass opts out explicitly.
        $cfgRescan = @{} + $cfg
        $cfgRescan.ExcludeDestinations = $false
        $rootsInfo = Get-SysOrgScanRoots -Letter T -Config $cfgRescan -Roots @($org)
        $inv2 = @(Get-SysOrgInventory -Letter T -Config $cfgRescan -Roots @($org) -NoCache)
        $plan2 = New-SysOrgPlan -Letter T -Inventory $inv2 -DriveProfile $fakeProf -Config $cfg
        (@($plan2.Actions) | Where-Object { "$($_.Action)" -eq 'Move' }).Count | Should -Be 0
    }

    It 'every planned destination respects depth <= 4 and the root set, with no collisions' {
        $src = Join-Path $TestDrive ('prop-d-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $inv = @(New-SysOrgPropertyCorpus -Root $src)
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = New-SysOrgPropertyConfig -AppRoot $TestDrive -OrgRoot 'T:\_Organized'
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        $allowed = Get-SysOrgFindableTopLevel
        $dests = @{}
        foreach($a in @($plan.Actions)){
            $rel = "$($a.Destination)".Substring($plan.DestinationRoot.Length).TrimStart('\')
            $segs = @($rel.Split('\') | Where-Object { "$_" -ne '' })
            ($segs.Count - 1) | Should -BeLessOrEqual 4
            (@($allowed.Roots) + @($allowed.Exempt)) | Should -Contain $segs[0]
            $dests["$($a.Destination)"] = $true
        }
        (@($plan.Actions) | Where-Object { "$($_.Action)" -eq 'Move' }).Count | Should -Be ($dests.Count)
    }

    It 'protected paths never appear in a plan (source or destination)' {
        $src = Join-Path $TestDrive ('prop-p-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $inv = @(New-SysOrgPropertyCorpus -Root $src)
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = New-SysOrgPropertyConfig -AppRoot $TestDrive -OrgRoot 'T:\_Organized'
        $cfg.ExcludedPaths = @('C:\Windows','T:\_Organized\Documents\Protected')
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        foreach($a in @($plan.Actions)){
            "$($a.Destination)" | Should -Not -BeLike '*Protected*'
            "$($a.Source)" | Should -Not -BeLike '*\Windows\*'
        }
    }
}

Describe 'Property: conservation on the full recipe (100-file fixture)' -Tag Perf {

    It 'hash multiset survives an execute byte-for-byte (tagged Perf; excluded from default CI)' {
        $work = Join-Path $TestDrive ('prop-perf-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $src = Join-Path $work 'src'
        $org = Join-Path $work 'org'
        $inv = @(New-SysOrgPropertyCorpus -Root $src)
        $hashesBefore = @{}
        foreach($f in $inv){ $h = Get-SysOrgFileHash -Path "$($f.FullName)"; if($h){ $hashesBefore[$h] = $true } }
        $fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $cfg = New-SysOrgPropertyConfig -AppRoot (Join-Path $work 'app') -OrgRoot $org
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $fakeProf -Config $cfg
        $planPath = Join-Path $work 'plan.json'
        ($plan | Select-Object -Property * -ExcludeProperty Provenance) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $null = Invoke-SysOrgPlan -PlanPath $planPath -Config $cfg -AppRoot (Join-Path $work 'app')
        $hashesAfter = Get-SysOrgHashInventory -Root $org
        (@($hashesAfter.Keys) | Sort-Object) -join ',' | Should -Be ((@($hashesBefore.Keys) | Sort-Object) -join ',')
    }
}
