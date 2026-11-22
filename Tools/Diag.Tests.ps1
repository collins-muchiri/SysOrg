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
    Import-Module (Join-Path $repo 'Modules\SysOrg.Score.psm1')       -Force
    $script:fakeProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
    $script:baseCfg = @{
        AppRoot        = (Join-Path $TestDrive 'app')
        LayoutProfile  = 'Findable'
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
        Layout = @{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
        Review = @{ Mode='Report'; FolderName='_Review' }
    }
}

Describe 'DIAG: unplaceable file Skipped recording' {
    It 'dumps the full plan object' {
        $dir = Join-Path $TestDrive 'src-mystery'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'blob.bin'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(1,2,3,4,5,6,7,8,9,10,11,12))
        $stampB1 = Get-Date '2024-06-15'
        $fiB1 = Get-Item -LiteralPath $p
        $fiB1.CreationTime = $stampB1; $fiB1.LastWriteTime = $stampB1
        $inv = @([pscustomobject]@{ FullName=$p; Name='blob.bin'; Stem='blob'
            Extension='.bin'; Length=12; LastWriteTime=(Get-Date '2024-06-15'); Directory=$dir; Category='Other' })
        $plan = New-SysOrgPlan -Letter T -Inventory $inv -DriveProfile $script:fakeProf -Config $script:baseCfg
        Write-Host ("DIAG reviewMode   : " + (Get-SysOrgSetting $script:baseCfg 'Review.Mode' 'Report'))
        Write-Host ("DIAG actions      : " + @($plan.Actions).Count)
        Write-Host ("DIAG skipped n    : " + @($plan.Skipped).Count)
        foreach($s in @($plan.Skipped)){ Write-Host ("DIAG skipped entry: [" + $_.Reason + "]  <- " + $_.Source) }
        Write-Host ("DIAG needs n      : " + @($plan.NeedsDecision).Count)
        foreach($d in @($plan.NeedsDecision)){ Write-Host ("DIAG needs entry  : " + $d.Disposition + " conf=" + $d.Confidence) }
        Write-Host ("DIAG skipped prop : " + ($plan.PSObject.Properties['Skipped'] -ne $null))
        $dec = Invoke-SysOrgClassifyPipeline -Path $p -Extension '.bin' -Category 'Other' -Config $script:baseCfg -DriveProfile $script:fakeProf -IncludeMetadata -UserRules @() -LearnedRules @() -AppRoot (Join-Path $TestDrive 'app')
        Write-Host ("DIAG dec needs    : " + $dec.NeedsDecision + "  conf=" + $dec.Confidence + "  rule=" + $dec.RuleId)
        (@($plan.Skipped) | Where-Object { $_.Reason -like 'Needs a decision*' }).Count | Should -Be 1
    }
}

Describe 'DIAG: layout migration destinations + skipped' {
    It 'dumps migration plan folders and skipped' {
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
            DateFolders='Year'; FolderAudit=@{ Enabled=$false }
            TypeMap=@{}
            Layout=@{ MaxFilesPerFolder=150; MinFilesPerFolder=8; MaxTopLevelFolders=10; MaxDepth=4; MaxPathChars=200 }
            Review=@{ Mode='Report'; FolderName='_Review' }
            Classify=@{ MinConfidence=0.40; ReviewConfidence=0.70 }
            Rules=@{ ApplyLearned=$false; UserRulesPath=''; LexiconPath=''; LearnedRulesPath='' }
            Run=@{ Parallelism=0 }
        }
        $plan = New-SysOrgLayoutMigrationPlan -Letter T -Config $cfg -TargetProfile 'Findable'
        Write-Host ("DIAG mig actions  : " + @($plan.Actions).Count)
        foreach($a in @($plan.Actions)){ Write-Host ("DIAG mig action   : " + $_.Kind + "  " + $_.Source + "  ->  " + $_.Destination) }
        Write-Host ("DIAG mig skipped n: " + @($plan.Skipped).Count)
        foreach($s in @($plan.Skipped)){ Write-Host ("DIAG mig skipped  : [" + $_.Reason + "]") }
        $dec = Invoke-SysOrgClassifyPipeline -Path (Join-Path $d1 'Invoice KRA 2024-000.txt') -Extension '.txt' -Category 'Documents' -Config $cfg -DriveProfile $script:fakeProf -IncludeMetadata -UserRules @() -LearnedRules @() -AppRoot (Join-Path $TestDrive 'app')
        Write-Host ("DIAG mig dec      : dest=[" + $dec.Destination + "] conf=" + $dec.Confidence + " rule=" + $dec.RuleId)
        (@($plan.Actions).Count) | Should -BeGreaterThan 0
    }
}

Describe 'DIAG: msCfg execute + run log' {
    It 'dumps execute summary and the run-log refusal lines' {
        $src = Join-Path $TestDrive 'ms\doc.txt'
        New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
        Set-Content -LiteralPath $src -Value 'v'
        $msCfg = @{ AppRoot=(Join-Path $TestDrive 'app'); OrganizedRoots=@{ 'T' = (Join-Path $TestDrive 'ms-org') }
                    ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true
                    ExcludeDestinations=$true; PreserveExistingFolders=$false; DateFolders='None'
                    Copies=@{Policy='NumberCopies';StartIndex=2}; Families=@{Enabled=$false}
                    Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; TypeMap=@{}
                    Move=@{ AllowCrossVolume=$true }; MaxPlanActions=5000 }
        $plan = New-SysOrgPlan -Letter T -Inventory @([pscustomobject]@{ FullName=$src; Name='doc.txt'; Stem='doc'; Extension='.txt'
            Length=2; LastWriteTime=(Get-Date); Directory=(Split-Path $src); Category='Documents' }) -DriveProfile $script:fakeProf -DupGroups @() -Config $msCfg
        Write-Host ("DIAG ms actions   : " + @($plan.Actions).Count)
        foreach($a in @($plan.Actions)){ Write-Host ("DIAG ms action    : " + $_.Source + " -> " + $_.Destination + " rule=" + $_.RuleId) }
        $planPath = Join-Path $TestDrive 'ms-diag-plan.json'
        ($plan | Select-Object -Property * -ExcludeProperty Provenance) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding UTF8
        $res = Invoke-SysOrgPlan -PlanPath $planPath -Config $msCfg -AppRoot (Join-Path $TestDrive 'app')
        Write-Host ("DIAG ms summary   : Moved=" + $res.Summary.Moved + " Failed=" + $res.Summary.Failed + " Skipped=" + $res.Summary.Skipped)
        $logFile = Join-Path (Join-Path $TestDrive 'app\Logs') ('sysorg-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        if(Test-Path -LiteralPath $logFile){
            Get-Content -LiteralPath $logFile | Select-Object -Last 25 | ForEach-Object { Write-Host ("DIAG log          : " + $_) }
        } else {
            Write-Host "DIAG log          : (no log file at $logFile)"
        }
        $res.Summary.Moved | Should -Be 1
    }
}

Describe 'DIAG: catalog read exception visibility' {
    It 'reads the catalog with visible errors' {
        $catDir = Join-Path $TestDrive 'find-diag'
        New-Item -ItemType Directory -Path (Join-Path $catDir '_Index') -Force | Out-Null
        $catPath = Join-Path $catDir '_Index\catalog.ndjson'
        $line = ('{{"CurrentPath":"{0}\\Documents\\Finance\\Invoices\\2024\\inv1.pdf","OriginalPath":"C:\\dl\\inv1.pdf","Type":"File","Category":"Documents\\Finance\\Invoices","Date":"2024-03-01T10:00:00","DateSource":"plan","SourceBucket":"GitHub","Family":"inv","Hash":"AAA","SizeBytes":12000,"Confidence":0.9,"RuleId":"lexicon","PlanId":"plan-1"}}' -f $catDir)
        [System.IO.File]::WriteAllLines($catPath, @($line))
        Write-Host ("DIAG line         : " + $line.Substring(0, 90))
        $raw = Get-Content -LiteralPath $catPath
        Write-Host ("DIAG raw lines    : " + @($raw).Count)
        $o = $null
        try { $o = ConvertFrom-Json $raw[0]; Write-Host ("DIAG convert ok   : CurrentPath=" + $o.CurrentPath) }
        catch { Write-Host ("DIAG convert FAIL : " + $_.Exception.GetType().FullName + " - " + $_.Exception.Message) }
        $entries = New-Object System.Collections.Generic.List[object]
        $reader = $null
        try { $reader = New-Object System.IO.StreamReader($catPath, $true) }
        catch { Write-Host ("DIAG reader FAIL  : " + $_.Exception.Message) }
        if($reader){
            try{
                while($null -ne ($ln = $reader.ReadLine())){
                    Write-Host ("DIAG read line len: " + $ln.Length)
                    try { [void]$entries.Add((ConvertFrom-Json $ln)) }
                    catch { Write-Host ("DIAG convert2 FAIL: " + $_.Exception.Message) }
                }
            } finally { $reader.Dispose() }
        }
        Write-Host ("DIAG manual count : " + $entries.Count)
        $viaFn = @(Read-SysOrgCatalog -Path $catPath)
        Write-Host ("DIAG ReadFn count : " + @($viaFn).Count)
        $r1 = @(Find-SysOrgFile -Root $catDir -Name '*inv*')
        Write-Host ("DIAG find count   : " + @($r1).Count)
        @($viaFn).Count | Should -Be 1
    }
}

Describe 'DIAG: project detection in Pester context' {
    It 'dumps detection internals' {
        $projCfg = @{ Projects=@{ Enabled=$true; Markers=@() }; ExcludedPaths=@(); ExcludedFilePatterns=@()
                     ExcludeDestinations=$false; TypeMap=@{}; FolderAudit=@{ Enabled=$false } }
        $projProf = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; KnownFolders=@(); DownloadRoots=@() }
        $root = Join-Path $TestDrive ('two-m-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $root 'lone')    -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'lone\.gitignore') -Value ''
        New-Item -ItemType Directory -Path (Join-Path $root 'real')    -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'real\Makefile')     -Value 'all:'
        Set-Content -LiteralPath (Join-Path $root 'real\CMakeLists.txt') -Value 'proj()'
        Write-Host ("DIAG testdrive    : " + $TestDrive)
        $found = @(Get-SysOrgProjectFolders -Roots @($root) -Config $projCfg -DriveProfile $projProf)
        Write-Host ("DIAG projects n   : " + @($found).Count)
        foreach($f in @($found)){ Write-Host ("DIAG project      : " + $f.Name + " @ " + $f.Path) }
        (@($found) | Where-Object { $_.Name -eq 'real' }).Count | Should -Be 1
    }
}
