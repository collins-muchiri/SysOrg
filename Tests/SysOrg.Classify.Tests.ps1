# Tests/SysOrg.Classify.Tests.ps1
# Covers v3.0 Phase 2: the Decision record, the pipeline skeleton (safety gates
# always win), context signals, and the user/learned rules contract
# (precedence, fail-closed validation, learned rules never apply silently).

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')   -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1') -Force
    $script:prof = [pscustomobject]@{ Letter='T'; Root='T:\'; Role='Data'; ProposedScope='FullDrive'
        KnownFolders=@(); DownloadRoots=@('C:\dl'); Artifacts=@(); TopLevelDirs=@() }
    $script:cfg = @{
        Classify = @{ MinConfidence=0.40; ReviewConfidence=0.70 }
        Rules    = @{ ApplyLearned=$false; UserRulesPath='' }
    }
}

Describe 'Decision record and safety gates (Phase 2.1)' {

    It 'creates a decision skeleton with all documented fields' {
        $d = New-SysOrgDecision -Path 'C:\x\a.pdf'
        $d.Path | Should -Be 'C:\x\a.pdf'
        $d.Confidence | Should -Be 0.0
        $d.RuleId | Should -Be ''
        $d.NeedsDecision | Should -BeFalse
        @($d.Signals).Count | Should -Be 0
    }

    It 'a gate reason wins over everything and never plans a destination' {
        $d = Invoke-SysOrgClassifyPipeline -Path 'C:\Windows\a.pdf' -Extension '.pdf' -Category 'Documents' -Config $script:cfg -GateReason 'Protected path'
        $d.Gate | Should -Be 'Protected path'
        $d.RuleId | Should -Be 'gate'
        $d.Destination | Should -BeNullOrEmpty
        $d.Confidence | Should -Be 0.0
        (@($d.Signals) | Where-Object { $_ -like 'Gate: Protected path' }).Count | Should -Be 1
    }

    It 'an ungated file records the gate-passed signal and a destination' {
        $d = Invoke-SysOrgClassifyPipeline -Path 'C:\Users\t\Documents\Invoice KRA 2024.pdf' -Extension '.pdf' -Category 'Documents' -Config $script:cfg -DriveProfile $script:prof
        (@($d.Signals) | Where-Object { $_ -like 'Gate: passed*' }).Count | Should -Be 1
        $d.Destination | Should -Be 'Documents\Finance\Invoices'
        $d.Confidence | Should -BeGreaterThan 0
    }
}

Describe 'Context signals (Phase 2.2)' {

    It 'detects screenshot, screen-recording, messaging and voice patterns' {
        $c1 = Get-SysOrgContextSignals -Path 'C:\x\Screenshot_2024-01-01.png'
        $c1.IsScreenshot | Should -BeTrue
        (@($c1.Signals) | Where-Object { $_ -eq 'Context: screenshot filename pattern' }).Count | Should -Be 1
        $c2 = Get-SysOrgContextSignals -Path 'C:\x\screen recording demo.mp4'
        $c2.IsScreenRecording | Should -BeTrue
        $c3 = Get-SysOrgContextSignals -Path 'C:\x\WhatsApp Image 2024-01-01.jpg'
        $c3.IsMessaging | Should -BeTrue
        $c4 = Get-SysOrgContextSignals -Path 'C:\x\VOICE_2024-01-01-WA0001.m4a'
        $c4.IsVoiceNote | Should -BeTrue
        (@($c4.Signals) | Where-Object { $_ -eq 'Context: voice-recording filename pattern' }).Count | Should -Be 1
    }

    It 'download-root membership comes from the drive profile' {
        $in = Get-SysOrgContextSignals -Path 'C:\dl\setup.exe' -DownloadRoots @('C:\dl')
        $in.InDownloads | Should -BeTrue
        (@($in.Signals) | Where-Object { $_ -eq 'Context: inside a download root' }).Count | Should -Be 1
        $out = Get-SysOrgContextSignals -Path 'C:\work\setup.exe' -DownloadRoots @('C:\dl')
        $out.InDownloads | Should -BeFalse
    }

    It 'an URL bucket is honored as a messaging source' {
        $c = Get-SysOrgContextSignals -Path 'C:\dl\photo.jpg' -UrlBucket 'WhatsApp'
        $c.IsMessaging | Should -BeTrue
        (@($c.Signals) | Where-Object { $_ -eq 'Context: messaging source WhatsApp' }).Count | Should -Be 1
    }
}

Describe 'User and learned rules (precedence, fail closed, never silent)' {

    It 'user rules run before the built-in pipeline and carry the rule id' {
        $rulesPath = Join-Path $TestDrive 'UserRules.psd1'
        Set-Content -LiteralPath $rulesPath -Value @'
@{
    Rules = @(
        @{ Name = 'kra-to-tax'; Priority = 5
           When = @{ NameRegex = '(?i)kra'; Extension = @('.pdf') }
           Destination = 'Documents\Finance\Tax\{Year}' }
        @{ Name = 'pdf-to-docs'; Priority = 10
           When = @{ Extension = @('.pdf') }
           Destination = 'Documents\Work\{Year}' }
    )
}
'@ -Encoding UTF8
        $d = Invoke-SysOrgClassifyPipeline -Path 'C:\x\KRA return.pdf' -Extension '.pdf' -Category 'Documents' -Config $script:cfg -UserRules (Get-SysOrgRulesFile -Path $rulesPath -Kind 'User')
        $d.RuleId | Should -Be 'user:kra-to-tax'
        $d.Confidence | Should -Be 1.0
        $d.Destination | Should -Be 'Documents\Finance\Tax\{Year}'
        # second rule never evaluated when the first matches
        $d2 = Invoke-SysOrgClassifyPipeline -Path 'C:\x\other.pdf' -Extension '.pdf' -Category 'Documents' -Config $script:cfg -UserRules (Get-SysOrgRulesFile -Path $rulesPath -Kind 'User')
        $d2.RuleId | Should -Be 'user:pdf-to-docs'
    }

    It 'invalid user rules fail closed with a clear message' {
        $bad = Join-Path $TestDrive 'BadRules1.psd1'
        Set-Content -LiteralPath $bad -Value "@{ Rules = @( @{ Name='r'; Priority=1; When=@{ NameRegex='(' }; Destination='X\{Year}' } ) }" -Encoding UTF8
        { Get-SysOrgRulesFile -Path $bad -Kind 'User' } | Should -Throw '*NameRegex*'
        $bad2 = Join-Path $TestDrive 'BadRules2.psd1'
        Set-Content -LiteralPath $bad2 -Value "@{ Rules = @( @{ Name='r'; Priority=1; When=@{}; Destination='X\{Bogus}' } ) }" -Encoding UTF8
        { Get-SysOrgRulesFile -Path $bad2 -Kind 'User' } | Should -Throw "*Bogus*"
        $bad3 = Join-Path $TestDrive 'BadRules3.psd1'
        Set-Content -LiteralPath $bad3 -Value "@{ Rules = @( @{ Name='r'; Priority=1; When=@{}; Destination='X\..\Windows' } ) }" -Encoding UTF8
        { Get-SysOrgRulesFile -Path $bad3 -Kind 'User' } | Should -Throw "*'..'*"
        $bad4 = Join-Path $TestDrive 'BadRules4.psd1'
        Set-Content -LiteralPath $bad4 -Value '@{ Bogus = 1 }' -Encoding UTF8
        { Get-SysOrgRulesFile -Path $bad4 -Kind 'User' } | Should -Throw '*Rules list*'
    }

    It 'learned rules are never applied silently (opt-in required)' {
        $learnedPath = Join-Path $TestDrive 'LearnedRules.psd1'
        Set-Content -LiteralPath $learnedPath -Value "@{ Rules = @( @{ Name='correction-1'; Priority=1; When=@{ NameRegex='(?i)receipt' }; Destination='Documents\Finance\Receipts\{Year}' } ) }" -Encoding UTF8
        $cfgOff = @{ Rules = @{ ApplyLearned=$false } }
        $rulesOff = Get-SysOrgLearnedRules -Config $cfgOff -Path $learnedPath
        @($rulesOff).Count | Should -Be 0
        $d1 = Invoke-SysOrgClassifyPipeline -Path 'C:\x\receipt scan.pdf' -Extension '.pdf' -Category 'Documents' -Config $cfgOff -LearnedRules $rulesOff
        $d1.RuleId | Should -Not -Be 'learned:correction-1'
        $cfgOn = @{ Rules = @{ ApplyLearned=$true } }
        $rulesOn = @(Get-SysOrgLearnedRules -Config $cfgOn -Path $learnedPath)
        @($rulesOn).Count | Should -Be 1
        $d2 = Invoke-SysOrgClassifyPipeline -Path 'C:\x\receipt scan.pdf' -Extension '.pdf' -Category 'Documents' -Config $cfgOn -LearnedRules $rulesOn
        $d2.RuleId | Should -Be 'learned:correction-1'
        @($d2.Flags) | Should -Contain 'learned'
    }

    It 'user rules take precedence over learned rules' {
        $u = Get-SysOrgRulesFile -Path (Join-Path $TestDrive 'u.psd1') -Kind 'User' 2>$null
        Set-Content -LiteralPath (Join-Path $TestDrive 'u.psd1') -Value "@{ Rules = @( @{ Name='user-first'; Priority=1; When=@{ NameRegex='(?i)tax' }; Destination='Documents\Work\{Year}' } ) }" -Encoding UTF8
        $l = Join-Path $TestDrive 'l.psd1'
        Set-Content -LiteralPath $l -Value "@{ Rules = @( @{ Name='learned-second'; Priority=1; When=@{ NameRegex='(?i)tax' }; Destination='Documents\Finance\Tax\{Year}' } ) }" -Encoding UTF8
        $u = Get-SysOrgRulesFile -Path (Join-Path $TestDrive 'u.psd1') -Kind 'User'
        $l2 = Get-SysOrgRulesFile -Path $l -Kind 'Learned'
        $m = Get-SysOrgRuleMatch -Path 'C:\x\tax.pdf' -Name 'tax.pdf' -UserRules $u -LearnedRules $l2
        $m.RuleId | Should -Be 'user:user-first'
        $m.IsLearned | Should -BeFalse
    }

    It 'Save-SysOrgLearnedRule writes a loadable, valid rules file' {
        $p = Join-Path $TestDrive '_Index\LearnedRules.psd1'
        Save-SysOrgLearnedRule -Path $p -Name 'corr-1' -NameRegex '(?i)^kra' -Destination 'Documents\Finance\Tax\{Year}' | Out-Null
        Save-SysOrgLearnedRule -Path $p -Name 'corr-2' -NameRegex '(?i)^saf' -Destination 'Documents\Finance\Invoices\{Year}' | Out-Null
        $rules = @(Get-SysOrgRulesFile -Path $p -Kind 'Learned')
        $rules.Count | Should -Be 2
        $rules[0].Name | Should -Be 'corr-1'
        ($rules[0].Destination) | Should -Be 'Documents\Finance\Tax\{Year}'
    }

    It 'template expansion fills known tokens and rejects nothing else' {
        (Expand-SysOrgRuleTemplate -Template 'Documents\Work\{Year}' -Context @{ Year='2024' }) | Should -Be 'Documents\Work\2024'
        (Expand-SysOrgRuleTemplate -Template 'Downloads\{Source}\{Stem}' -Context @{ Source='GitHub'; Stem='tool' }) | Should -Be 'Downloads\GitHub\tool'
        (Expand-SysOrgRuleTemplate -Template 'Documents\Work\{Year}' -Context @{}) | Should -Be 'Documents\Work\'
    }
}

Describe 'Confidence gating (Phase 2 stage 9)' {

    It 'confident media plans normally; Other-category files are flagged for review' {
        $d1 = Invoke-SysOrgClassifyPipeline -Path 'C:\x\IMG_2024.jpg' -Extension '.jpg' -Category 'Pictures' -Config $script:cfg -DriveProfile $script:prof
        $d1.Confidence | Should -BeGreaterOrEqual 0.70
        @($d1.Flags) | Should -Not -Contain 'review'
        $d2 = Invoke-SysOrgClassifyPipeline -Path 'C:\x\mystery.bin' -Extension '.bin' -Category 'Other' -Config $script:cfg -DriveProfile $script:prof
        $d2.Confidence | Should -BeGreaterOrEqual 0.40
        $d2.Confidence | Should -BeLessThan 0.70
        @($d2.Flags) | Should -Contain 'review'
        $d2.NeedsDecision | Should -BeFalse
    }

    It 'the pipeline never throws on odd inputs' {
        { Invoke-SysOrgClassifyPipeline -Path 'C:\x\weird file**.txt' -Extension '.txt' -Category 'Documents' -Config $script:cfg } | Should -Not -Throw
    }
}

Describe 'True type: magic-byte sniffing (Phase 2.3)' {

    It 'corrects a mismatched extension from the content (PNG bytes named .txt)' {
        $p = Join-Path $TestDrive 'photo.txt'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x01,0x02,0x03))
        $tt = Get-SysOrgTrueType -Path $p -Extension '.txt' -Category 'Documents'
        $tt.Matched | Should -BeTrue
        $tt.Corrected | Should -BeTrue
        $tt.Category | Should -Be 'Pictures'
        $d = Invoke-SysOrgClassifyPipeline -Path $p -Extension '.txt' -Category 'Documents' -Config $script:cfg -DriveProfile $script:prof
        $d.Category | Should -Be 'Pictures'
        (@($d.Signals) | Where-Object { $_ -like 'TrueType: content is image/png*' }).Count | Should -Be 1
    }

    It 'detects a type when the extension is missing (%PDF with no extension)' {
        $p = Join-Path $TestDrive 'noext'
        [System.IO.File]::WriteAllText($p, '%PDF-1.4 fake body')
        $tt = Get-SysOrgTrueType -Path $p -Extension '' -Category 'Other'
        $tt.Category | Should -Be 'Documents'
        $d = Invoke-SysOrgClassifyPipeline -Path $p -Extension '' -Category 'Other' -Config $script:cfg -DriveProfile $script:prof
        $d.Category | Should -Be 'Documents'
    }

    It 'zip bytes named .dat route to Archives; OLE bytes named .dat stay Documents' {
        $zip = Join-Path $TestDrive 'thing.dat'
        [System.IO.File]::WriteAllBytes($zip, [byte[]]@(0x50,0x4B,0x03,0x04,0x00,0x00))
        (Get-SysOrgTrueType -Path $zip -Extension '.dat' -Category 'Other').Category | Should -Be 'Archives'
        $ole = Join-Path $TestDrive 'ole.dat'
        [System.IO.File]::WriteAllBytes($ole, [byte[]]@(0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1,0x00,0x00))
        (Get-SysOrgTrueType -Path $ole -Extension '.dat' -Category 'Other').Category | Should -Be 'Documents'
        $msi = Join-Path $TestDrive 'thing.msi'
        [System.IO.File]::WriteAllBytes($msi, [byte[]]@(0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1,0x00,0x00))
        (Get-SysOrgTrueType -Path $msi -Extension '.msi' -Category 'Installers').Category | Should -Be 'Installers'
    }

    It 'MZ bytes with no extension route to Installers' {
        $exe = Join-Path $TestDrive 'prog'
        [System.IO.File]::WriteAllBytes($exe, [byte[]]@(0x4D,0x5A,0x90,0x00,0x03,0x00))
        (Get-SysOrgTrueType -Path $exe -Extension '' -Category 'Other').Category | Should -Be 'Installers'
    }

    It 'matching media extensions are not sniffed (no wasted IO)' {
        $jpg = Join-Path $TestDrive 'real.jpg'
        [System.IO.File]::WriteAllBytes($jpg, [byte[]]@(0xFF,0xD8,0xFF,0xE0,0x00,0x10))
        Get-SysOrgTrueType -Path $jpg -Extension '.jpg' -Category 'Pictures' | Should -BeNullOrEmpty
        $mp4 = Join-Path $TestDrive 'clip.mp4'
        [System.IO.File]::WriteAllBytes($mp4, [byte[]]@(0x00,0x00,0x00,0x08) + [System.Text.Encoding]::ASCII.GetBytes('ftyp') + [byte[]]@(0x00,0x00,0x00,0x00,0xFF,0xFF))
        Get-SysOrgTrueType -Path $mp4 -Extension '.mp4' -Category 'Videos' | Should -BeNullOrEmpty
    }

    It 'a docx container (zip) does not count as an archive mismatch' {
        $docx = Join-Path $TestDrive 'doc.docx'
        [System.IO.File]::WriteAllBytes($docx, [byte[]]@(0x50,0x4B,0x03,0x04,0x00,0x00))
        $tt = Get-SysOrgTrueType -Path $docx -Extension '.docx' -Category 'Documents'
        $tt.Corrected | Should -BeFalse
        $tt.Category | Should -Be 'Documents'
    }

    It 'empty and unreadable files never match and never throw' {
        $empty = Join-Path $TestDrive 'empty.dat'
        [System.IO.File]::WriteAllBytes($empty, [byte[]]@())
        $r = Get-SysOrgTrueType -Path $empty -Extension '.dat' -Category 'Other'
        ($null -eq $r -or -not $r.Matched) | Should -BeTrue
        $short = Join-Path $TestDrive 'short.dat'
        [System.IO.File]::WriteAllBytes($short, [byte[]]@(0x50,0x4B))
        ($null -eq (Get-SysOrgTrueType -Path $short -Extension '.dat' -Category 'Other')) | Should -BeTrue
        { Get-SysOrgTrueType -Path (Join-Path $TestDrive 'does-not-exist.bin') -Extension '.bin' -Category 'Other' } | Should -Not -Throw
    }
}
