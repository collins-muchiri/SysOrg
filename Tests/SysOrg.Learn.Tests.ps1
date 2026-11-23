# Tests/SysOrg.Learn.Tests.ps1
# v3.0.1 B3: self-supervised learning from the user's own structure.
#   - naive Bayes model built from existing subfolders of the known folders
#   - labels need >= Learn.MinFilesPerLabel (5) files; generic labels ignored
#   - model.json under <root>\_Index, fingerprint-guarded (rebuilt only on change)
#   - predictions are a confidence SIGNAL: they appear in -Explain, never move
#   - a single-label model can never produce a meaningful margin -> not trusted

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')     -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')   -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1') -Force

    # deterministic training tree: Work / Personal are trusted, Finance has too few files
    $script:learnRoot = Join-Path $TestDrive ('learn-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $script:destRoot  = Join-Path $script:learnRoot 'org'
    $script:docs      = Join-Path $script:learnRoot 'Documents'
    $work = Join-Path $script:docs 'Work'
    $personal = Join-Path $script:docs 'Personal'
    $finance = Join-Path $script:docs 'Finance'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    New-Item -ItemType Directory -Path $personal -Force | Out-Null
    New-Item -ItemType Directory -Path $finance -Force | Out-Null
    foreach($i in 1..8){
        Set-Content -LiteralPath (Join-Path $work ("monthly narrative report {0}.txt" -f $i)) `
            -Value 'narrative report for the programme supervision workplan indicators baseline workshop training budget' -Encoding UTF8
    }
    foreach($i in 1..8){
        Set-Content -LiteralPath (Join-Path $personal ("curriculum vitae profile {0}.txt" -f $i)) `
            -Value 'curriculum vitae personal bio profile work experience skills references hobbies education history' -Encoding UTF8
    }
    foreach($i in 1..3){
        Set-Content -LiteralPath (Join-Path $finance ("invoice {0}.txt" -f $i)) `
            -Value 'invoice amount due payment mpesa receipt' -Encoding UTF8
    }
    $script:learnCfg = @{
        Learn = @{ Enabled=$true; FromPaths=@(); MinFilesPerLabel=5; MinMargin=0.5; MaxFilesPerLabel=500; MaxTokensPerLabel=2000 }
        Classify = @{ MinConfidence=0.40; ReviewConfidence=0.70 }
    }
    $script:learnKf = @([pscustomobject]@{ Name='Documents'; Path=$script:docs; IsRedirected=$false; UnderOneDrive=$false })
}

Describe 'Learn model build (v3.0.1 B3)' {

    It 'trains trusted labels from the user folders and excludes weak/generic ones' {
        $lm = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot $script:destRoot -KnownFolders $script:learnKf
        $lm | Should -Not -BeNullOrEmpty
        $lm.Rebuilt | Should -BeTrue
        $names = @(Get-SysOrgLearnLabelNames -Model $lm.Model)
        $names | Should -Be @('Personal','Work')       # Finance (3 files) is NOT trusted; 'Documents' itself is not a label
        $work = Get-SysOrgLearnLabel -Model $lm.Model -Name 'Work'
        [int]$work.Files | Should -Be 8
    }

    It 'stores model.json under <root>\_Index and round-trips through JSON' {
        $modelPath = Get-SysOrgLearnModelPath -Root $script:destRoot
        Test-Path -LiteralPath $modelPath | Should -BeTrue
        $m = Get-Content -LiteralPath $modelPath -Raw | ConvertFrom-Json
        "$($m.Version)" | Should -Be '1'
        $m.Fingerprint | Should -Not -BeNullOrEmpty
        $m.VocabSize | Should -BeGreaterThan 0
        @(Get-SysOrgLearnLabelNames -Model $m) | Should -Be @('Personal','Work')
    }

    It 'reuses the model when the fingerprint is unchanged and rebuilds on change' {
        $lm1 = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot $script:destRoot -KnownFolders $script:learnKf
        $lm1.Rebuilt | Should -BeFalse
        # touch one training file -> newest mtime changes -> fingerprint changes
        Start-Sleep -Milliseconds 50
        Set-Content -LiteralPath (Join-Path $script:docs 'Work\monthly narrative report 1.txt') -Value 'narrative report updated content' -Encoding UTF8
        $lm2 = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot $script:destRoot -KnownFolders $script:learnKf
        $lm2.Rebuilt | Should -BeTrue
        "$($lm2.Fingerprint)" | Should -Not -Be "$($lm1.Fingerprint)"
    }

    It 'ignores generic labels and date-like folder names' {
        $extra = Join-Path $script:docs 'Downloads'
        New-Item -ItemType Directory -Path $extra -Force | Out-Null
        foreach($i in 1..6){ Set-Content -LiteralPath (Join-Path $extra "g$i.txt") -Value 'generic downloads content' -Encoding UTF8 }
        $dates = Join-Path $script:docs '2024'
        New-Item -ItemType Directory -Path $dates -Force | Out-Null
        foreach($i in 1..6){ Set-Content -LiteralPath (Join-Path $dates "d$i.txt") -Value 'date folder content' -Encoding UTF8 }
        $lm = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot $script:destRoot -KnownFolders $script:learnKf
        $names = @(Get-SysOrgLearnLabelNames -Model $lm.Model)
        $names | Should -Not -Contain 'Downloads'
        $names | Should -Not -Contain '2024'
        $names | Should -Contain 'Work'
    }
}

Describe 'Learn prediction (v3.0.1 B3)' {

    It 'predicts the user-structure label for a matching document with a strong margin' {
        $lm = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot $script:destRoot -KnownFolders $script:learnKf
        $probe = Join-Path $TestDrive ('probe-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '\monthly narrative report.txt')
        New-Item -ItemType Directory -Path (Split-Path $probe) -Force | Out-Null
        Set-Content -LiteralPath $probe -Value 'monthly narrative report supervision workplan indicators baseline workshop budget' -Encoding UTF8
        $p = Get-SysOrgLearnPrediction -Model $lm.Model -Path $probe -Config $script:learnCfg
        $p | Should -Not -BeNullOrEmpty
        $p.Label | Should -Be 'Work'
        $p.Trusted | Should -BeTrue
        $p.Margin | Should -BeGreaterOrEqual 0.5
        $p.LabelFiles | Should -BeGreaterOrEqual 5
    }

    It 'a single-label model can never be trusted (no meaningful margin exists)' {
        $only = Join-Path $TestDrive ('learn-single-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $onlyDocs = Join-Path $only 'Documents'
        $onlyWork = Join-Path $onlyDocs 'Work'
        New-Item -ItemType Directory -Path $onlyWork -Force | Out-Null
        foreach($i in 1..6){ Set-Content -LiteralPath (Join-Path $onlyWork "report $i.txt") -Value 'report work content' -Encoding UTF8 }
        $lm = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot (Join-Path $only 'org') -KnownFolders @([pscustomobject]@{ Name='Documents'; Path=$onlyDocs })
        $lm | Should -Not -BeNullOrEmpty
        @(Get-SysOrgLearnLabelNames -Model $lm.Model).Count | Should -Be 1
        $probe = Join-Path $only 'probe.txt'
        Set-Content -LiteralPath $probe -Value 'completely unrelated probe content' -Encoding UTF8
        $p = Get-SysOrgLearnPrediction -Model $lm.Model -Path $probe -Config $script:learnCfg
        $p.Label | Should -Be 'Work'      # it is the only label the model knows
        $p.Trusted | Should -BeFalse      # ...but a one-class margin is meaningless
    }
}

Describe 'Learn signal in the classification pipeline (v3.0.1 B3)' {

    It 'raises document confidence to the model posterior and appears in -Explain, never moving alone' {
        $lm = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot $script:destRoot -KnownFolders $script:learnKf
        $probe = Join-Path $TestDrive ('probe2-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '\quarterly supervision report.txt')
        New-Item -ItemType Directory -Path (Split-Path $probe) -Force | Out-Null
        Set-Content -LiteralPath $probe -Value 'quarterly supervision report workplan indicators workshop training' -Encoding UTF8
        $prof = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $d = Invoke-SysOrgClassifyPipeline -Path $probe -Extension '.txt' -Category 'Documents' -Config $script:learnCfg -DriveProfile $prof -IncludeMetadata -LearnModel $lm.Model
        $d.Confidence | Should -BeGreaterOrEqual 0.70
        $d.Subtype | Should -Be 'Work'                 # a known document subtype may be adopted
        $d.RuleId | Should -Match 'model'
        (@($d.Signals) | Where-Object { $_ -match '^Learn: model suggests Work' }).Count | Should -BeGreaterOrEqual 1
        $d.NeedsDecision | Should -BeFalse
    }

    It 'a user label that is NOT a document subtype never becomes a destination' {
        # label 'Taxes' (not in the known document subtypes) may only sharpen confidence
        $taxRoot = Join-Path $TestDrive ('learn-tax-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $taxDocs = Join-Path $taxRoot 'Documents'
        $taxes = Join-Path $taxDocs 'Taxes'
        $edu = Join-Path $taxDocs 'Education'
        New-Item -ItemType Directory -Path $taxes -Force | Out-Null
        New-Item -ItemType Directory -Path $edu -Force | Out-Null
        foreach($i in 1..8){ Set-Content -LiteralPath (Join-Path $taxes ("kra paye tax return {0}.txt" -f $i)) -Value 'kra paye tax return pin vat withholding itax' -Encoding UTF8 }
        foreach($i in 1..8){ Set-Content -LiteralPath (Join-Path $edu ("lecture notes {0}.txt" -f $i)) -Value 'university lecture course examination semester campus' -Encoding UTF8 }
        $lm = New-SysOrgLearnModel -Config $script:learnCfg -DestinationRoot (Join-Path $taxRoot 'org') -KnownFolders @([pscustomobject]@{ Name='Documents'; Path=$taxDocs })
        $probe = Join-Path $taxRoot 'probe.txt'
        Set-Content -LiteralPath $probe -Value 'kra paye tax return pin vat withholding itax' -Encoding UTF8
        $prof = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $d = Invoke-SysOrgClassifyPipeline -Path $probe -Extension '.txt' -Category 'Documents' -Config $script:learnCfg -DriveProfile $prof -IncludeMetadata -LearnModel $lm.Model
        $d.Subtype | Should -Not -Be 'Taxes'           # arbitrary user labels never become destinations
        $d.Destination | Should -Not -Match 'Taxes'
        $d.Confidence | Should -BeGreaterOrEqual 0.5   # the model still contributes honestly
    }

    It 'runs without a model (no Learn signal, baseline confidences untouched)' {
        $probe = Join-Path $TestDrive 'probe3\plain note.txt'
        New-Item -ItemType Directory -Path (Split-Path $probe) -Force | Out-Null
        Set-Content -LiteralPath $probe -Value 'unrelated plain text' -Encoding UTF8
        $prof = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }
        $d = Invoke-SysOrgClassifyPipeline -Path $probe -Extension '.txt' -Category 'Documents' -Config $script:learnCfg -DriveProfile $prof -IncludeMetadata
        (@($d.Signals) | Where-Object { $_ -match '^Learn:' }).Count | Should -Be 0
        $d.Confidence | Should -Be 0.5
    }
}
