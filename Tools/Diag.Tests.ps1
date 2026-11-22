# Tools/Diag.Tests.ps1 - TEMPORARY ground-truth probe for Windows-only test
# failures. NEVER runs in CI (CI runs .\Tests only). Executed by
# .github/workflows/diag.yml via Invoke-Pester on windows-latest (PS 5.1).

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')      -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1')    -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Catalog.psm1')     -Force
    $script:fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
}

Describe 'DIAG: where-object mechanics in Pester 5.1' {
    It 'probes filter semantics' {
        $found = @([pscustomobject]@{ Path='C:\x\real'; Name='real'; SafeName='real' })
        $m1 = @($found | Where-Object { $_.Name -eq 'real' })
        Write-Host ("DIAG m1 n          : " + @($m1).Count)
        $m2 = @($found | Where-Object -Property 'Name' -EQ -Value 'real')
        Write-Host ("DIAG m2 n          : " + @($m2).Count)
        $m3 = (@($found) | Where-Object { $_.Name -eq 'real' }).Count
        Write-Host ("DIAG m3 raw        : [$m3]  isNull=" + ($null -eq $m3))
        $itm = $found[0]
        Write-Host ("DIAG type          : " + $itm.GetType().FullName)
        Write-Host ("DIAG nametype      : " + $itm.Name.GetType().FullName + " eq=" + ($itm.Name -eq 'real'))
        Write-Host ("DIAG props         : " + (($itm.PSObject.Properties | ForEach-Object { $_.Name + '=' + $_.Value }) -join '; '))
        (@($found) | Where-Object { $_.Name -eq 'real' }).Count | Should -Be 1
    }
}

Describe 'DIAG: unplaceable skipped entry, correct print' {
    It 'dumps skipped via indexed access' {
        $baseCfg = @{
            AppRoot        = (Join-Path $TestDrive 'app')
            LayoutProfile  = 'Findable'
            OrganizedRoots = @{ '*' = '__AUTO__' }
            Copies         = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=0; HeaderHashKB=64 }
            Families       = @{ Enabled=$false }
            Downloads      = @{ UseZoneIdentifier=$false }
            Move           = @{ AllowCrossVolume = $true }
            ExcludedPaths  = @(); ExcludedFilePatterns = @()
            SkipHiddenSystemFiles = $true; ExcludeDestinations = $true
            PreserveExistingFolders = $false; DateFolders = 'Year'
            FolderAudit = @{ Enabled = $false }; TypeMap = @{}
            Layout = @{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review = @{ Mode='Report'; FolderName='_Review' }
        }
        $dir = Join-Path $TestDrive 'src-mystery'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'blob.bin'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(1,2,3,4,5,6,7,8,9,10,11,12))
        $inv = @([pscustomobject]@{ FullName=$p; Name='blob.bin'; Stem='blob'
            Extension='.bin'; Length=12; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Other' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $baseCfg
        $sk = @($plan.Skipped)
        Write-Host ("DIAG skipped n     : " + $sk.Count)
        for($i=0; $i -lt $sk.Count; $i++){
            Write-Host ("DIAG skipped[$i]   : reason=[" + $sk[$i].Reason + "] src=[" + $sk[$i].Source + "]")
        }
        $matched = @($sk | Where-Object { $_.Reason -like 'Needs a decision*' })
        Write-Host ("DIAG matched n     : " + @($matched).Count)
        $sk.Count | Should -Be 1
    }
}

Describe 'DIAG: migration action destinations, correct print' {
    It 'dumps migration actions via indexed access' {
        $work = Join-Path $TestDrive 'migdiag'
        $root = Join-Path $work 'org'
        $d1 = Join-Path $root 'Documents\2024'
        New-Item -ItemType Directory -Path $d1 -Force | Out-Null
        $stamp = Get-Date '2024-06-15'
        for($i=0; $i -lt 3; $i++){
            $p = Join-Path $d1 ('Invoice KRA 2024-{0:D3}.txt' -f $i)
            Set-Content -LiteralPath $p -Value ('invoice ' + $i) -Encoding ASCII
            $fi = Get-Item -LiteralPath $p; $fi.CreationTime = $stamp; $fi.LastWriteTime = $stamp
        }
        $cfg = @{
            AppRoot=(Join-Path $TestDrive 'app'); LayoutProfile='Findable'; OrganizedRoots=@{ '*'=$root }
            Copies=@{ Policy='NumberCopies'; MinFileSizeKB=256; HeaderHashKB=64; QuarantineFolderName='_Duplicates'; RenameToKeeper=$false; StartIndex=2; SuffixStyle='Parentheses' }
            Families=@{ Enabled=$false }; Downloads=@{ UseZoneIdentifier=$false }
            Move=@{ AllowCrossVolume=$true }; ExcludedPaths=@(); ExcludedFilePatterns=@()
            SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }; TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
            Run=@{ Parallelism=0 }
        }
        $plan = New-SysOrgLayoutMigrationPlan -Letter T -Config $cfg -TargetProfile 'Findable'
        $acts = @($plan.Actions)
        Write-Host ("DIAG mig actions n : " + $acts.Count)
        for($i=0; $i -lt $acts.Count; $i++){
            Write-Host ("DIAG mig act[$i]    : kind=[" + $acts[$i].Kind + "] dest=[" + $acts[$i].Destination + "]")
        }
        $acts.Count | Should -BeGreaterThan 0
    }
}

Describe 'DIAG: jr2 orphan resume with run log' {
    It 'executes and dumps the run log' {
        $planId = 'plan-20260101-094002'
        $srcA = Join-Path $TestDrive 'jr2\a.txt'
        $srcB = Join-Path $TestDrive 'jr2\b.txt'
        New-Item -ItemType Directory -Path (Split-Path $srcA) -Force | Out-Null
        Set-Content -LiteralPath $srcA -Value 'aa'; Set-Content -LiteralPath $srcB -Value 'bb'
        $dstA = Join-Path $TestDrive 'jr2-org\Documents\2026\a.txt'
        $dstB = Join-Path $TestDrive 'jr2-org\Documents\2026\b.txt'
        $planCfg = @{
            AppRoot        = (Join-Path $TestDrive 'app')
            OrganizedRoots = @{ '*' = '__AUTO__' }
            Copies         = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=0; HeaderHashKB=64 }
            Families       = @{ Enabled=$false }
            Downloads      = @{ UseZoneIdentifier=$false }
            Move           = @{ AllowCrossVolume = $true }
            ExcludedPaths  = @(); ExcludedFilePatterns = @()
            SkipHiddenSystemFiles = $true; ExcludeDestinations = $true
            PreserveExistingFolders = $false; DateFolders = 'Year'
            FolderAudit = @{ Enabled = $false }; TypeMap = @{}
        }
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
            Actions=@(
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcA; Destination=$dstA; Reason='test'; SizeBytes=2 },
                [pscustomobject]@{ Action='Move'; Kind='File'; Source=$srcB; Destination=$dstB; Reason='test'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'jr2-diag.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        New-Item -ItemType Directory -Path (Split-Path $dstA) -Force | Out-Null
        Move-Item -LiteralPath $srcA -Destination $dstA
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Undo') -Force | Out-Null
        $undoPath = Join-Path $TestDrive ('Undo\undo-' + $planId + '.csv')
        Set-Content -LiteralPath $undoPath -Value @(
            'Timestamp,PlanId,Kind,Action,OriginalSource,CurrentLocation,ContentHash,Status',
            ('"2026-01-01T00:00:00","{0}","File","Move","{1}","{2}","","Pending"' -f $planId, $srcA, $dstA)
        ) -Encoding UTF8
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot (Join-Path $TestDrive 'app') -Force
        Write-Host ("DIAG jr2 summary   : Resumed=" + $res.Summary.Resumed + " Moved=" + $res.Summary.Moved + " Failed=" + $res.Summary.Failed + " Skipped=" + $res.Summary.Skipped)
        $logFile = Join-Path (Join-Path $TestDrive 'app\Logs') ('sysorg-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        if(Test-Path -LiteralPath $logFile){
            Get-Content -LiteralPath $logFile | Select-Object -Last 20 | ForEach-Object { Write-Host ("DIAG jr2 log       : " + $_) }
        } else { Write-Host "DIAG jr2 log       : (none)" }
        $res.Summary.Moved | Should -Be 1
    }
}

Describe 'DIAG: jr5 undo restore with run log' {
    It 'executes then undoes and dumps the log' {
        $planId = 'plan-20260101-094005'
        $src = Join-Path $TestDrive 'jr5\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v'
        $planCfg = @{
            AppRoot        = (Join-Path $TestDrive 'app')
            OrganizedRoots = @{ '*' = '__AUTO__' }
            Copies         = @{ Policy='Quarantine'; QuarantineFolderName='_Duplicates'; MinFileSizeKB=0; HeaderHashKB=64 }
            Families       = @{ Enabled=$false }
            Downloads      = @{ UseZoneIdentifier=$false }
            Move           = @{ AllowCrossVolume = $true }
            ExcludedPaths  = @(); ExcludedFilePatterns = @()
            SkipHiddenSystemFiles = $true; ExcludeDestinations = $true
            PreserveExistingFolders = $false; DateFolders = 'Year'
            FolderAudit = @{ Enabled = $false }; TypeMap = @{}
        }
        $plan = [pscustomobject]@{ PlanId=$planId; Drive='T:'
            Actions=@([pscustomobject]@{ Action='Move'; Kind='File'; Source=$src; Destination=(Join-Path $TestDrive 'jr5-org\Documents\2026\doc.txt'); Reason='test'; SizeBytes=2 }) }
        $planPath = Join-Path $TestDrive 'jr5-diag.json'
        $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $planCfg -AppRoot (Join-Path $TestDrive 'app')
        Write-Host ("DIAG jr5 exec      : Moved=" + $res.Summary.Moved + " Failed=" + $res.Summary.Failed + " Skipped=" + $res.Summary.Skipped)
        $u = Undo-SysOrgPlan -PlanId $planId -AppRoot (Join-Path $TestDrive 'app') -Config $planCfg
        Write-Host ("DIAG jr5 undo      : Restored=" + $u.Restored + " Failed=" + $u.Failed + " SkippedMissing=" + $u.SkippedMissing + " SkippedChanged=" + $u.SkippedChanged)
        $logFile = Join-Path (Join-Path $TestDrive 'app\Logs') ('sysorg-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        if(Test-Path -LiteralPath $logFile){
            Get-Content -LiteralPath $logFile | Select-Object -Last 20 | ForEach-Object { Write-Host ("DIAG jr5 log       : " + $_) }
        } else { Write-Host "DIAG jr5 log       : (none)" }
        $u.Restored | Should -Be 1
    }
}
