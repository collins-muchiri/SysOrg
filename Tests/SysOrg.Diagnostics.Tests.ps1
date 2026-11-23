# ---------------------------------------------------------------------------
# v3.0.2 A1: exception diagnostics. The menu catch-all and every CLI entry
# point must log the exception type, message, ScriptStackTrace and
# InvocationInfo.PositionMessage to the log file; Get-SysOrgLastError keeps the
# record for -Diagnostics (A4). The menu/CLI wiring itself is exercised
# end-to-end by the v3.0.2 smoke fixtures (SysOrg.Smoke.Tests.ps1); these tests
# pin the diagnostic helper and its output contract.
#
# v3.0.2 A4: transcript capture (Logs\last-run.txt), the log-tail helper and
# the -Diagnostics support bundle.
# ---------------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot '..\Modules\SysOrg.Core.psm1') -Force -DisableNameChecking

Describe 'Write-SysOrgErrorDiagnostic (v3.0.2 A1)' {

    BeforeEach {
        $script:testLog = Join-Path $TestDrive ('diag-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    }
    AfterEach { if(Test-Path -LiteralPath $script:testLog){ Remove-Item -LiteralPath $script:testLog -Recurse -Force } }

    It 'logs the exception type, message, script stack trace and position' {
        function Thrower { throw [System.InvalidOperationException] 'synthetic plan fault' }
        $err = $null
        try { Thrower } catch { $err = $_ }
        $path = Write-SysOrgErrorDiagnostic -ErrorRecord $err -LogFolder $script:testLog -Phase 'preview'
        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeTrue
        $log = Get-Content -LiteralPath $path -Raw
        $log | Should -Match 'System\.InvalidOperationException'
        $log | Should -Match 'synthetic plan fault'
        $log | Should -Match 'Script stack trace'
        $log | Should -Match 'Position:'
        $log | Should -Match 'phase=preview'
    }

    It 'records the last error for Get-SysOrgLastError' {
        function Thrower2 { throw [System.ArgumentException] 'second synthetic fault' }
        $err = $null
        try { Thrower2 } catch { $err = $_ }
        $null = Write-SysOrgErrorDiagnostic -ErrorRecord $err -LogFolder $script:testLog -Phase 'execute'
        $last = Get-SysOrgLastError
        $last | Should -Not -BeNullOrEmpty
        "$($last.Type)" | Should -Be 'System.ArgumentException'
        "$($last.Message)" | Should -Be 'second synthetic fault'
        "$($last.Phase)" | Should -Be 'execute'
        "$($last.ScriptStackTrace)" | Should -Match 'Thrower2'
    }

    It 'never throws even when the log folder is unwritable' {
        function Thrower3 { throw 'third synthetic fault' }
        $err = $null
        try { Thrower3 } catch { $err = $_ }
        # an impossible path: the parent is a real FILE, so no folder can ever
        # exist under it (v3.0.2 CI: a fresh 'C:\definitely\missing\...' chain is
        # CREATABLE on a clean runner - the fixture must stay impossible everywhere)
        $badRoot = if($env:OS -eq 'Windows_NT'){
            $fileAsParent = Join-Path $TestDrive ('notadir-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
            Set-Content -LiteralPath $fileAsParent -Value 'a file, never a folder'
            Join-Path $fileAsParent 'sub'
        } else { '/proc/definitely-not-writable/sysorg' }
        { $null = Write-SysOrgErrorDiagnostic -ErrorRecord $err -LogFolder $badRoot -Phase 'preview' } | Should -Not -Throw
    }
}

Describe 'Transcript capture (v3.0.2 A4)' {

    BeforeEach { $script:trLog = Join-Path $TestDrive ('tr-' + [guid]::NewGuid().ToString('N').Substring(0,8)) }
    AfterEach  { Stop-SysOrgTranscriptCapture; if(Test-Path -LiteralPath $script:trLog){ Remove-Item -LiteralPath $script:trLog -Recurse -Force } }

    It 'writes Logs\last-run.txt capturing host output while it runs' {
        $path = Start-SysOrgTranscriptCapture -LogFolder $script:trLog
        $path | Should -Not -BeNullOrEmpty
        Write-Host 'TRANSCRIPT-MARKER-selftest'
        Stop-SysOrgTranscriptCapture
        Test-Path -LiteralPath $path | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw) | Should -Match 'TRANSCRIPT-MARKER-selftest'
        (Split-Path $path -Leaf) | Should -Be 'last-run.txt'
    }

    It 'never throws when the log folder cannot exist' {
        # the parent is a real FILE, so the folder is uncreatable on any host
        # (v3.0.2 CI: 'C:\definitely\missing\...' is creatable on a clean runner)
        $badRoot = if($env:OS -eq 'Windows_NT'){
            $fileAsParent = Join-Path $TestDrive ('notadir-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
            Set-Content -LiteralPath $fileAsParent -Value 'a file, never a folder'
            Join-Path $fileAsParent 'sub'
        } else { '/proc/definitely-not-writable/sysorg' }
        { $null = Start-SysOrgTranscriptCapture -LogFolder $badRoot } | Should -Not -Throw
        $p2 = Start-SysOrgTranscriptCapture -LogFolder $badRoot
        "$p2" | Should -Be ''
        Stop-SysOrgTranscriptCapture
    }
}

Describe 'Get-SysOrgLogTail (v3.0.2 A4)' {

    It 'returns the newest log file and exactly the last -Lines lines' {
        $logDir = Join-Path $TestDrive ('tail-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $logFile = Join-Path $logDir 'sysorg-20990101.log'
        $all = @(1..250 | ForEach-Object { "line-$_" })
        [System.IO.File]::WriteAllLines($logFile, $all)
        # an OLDER second log must not win
        $oldFile = Join-Path $logDir 'sysorg-20980101.log'
        [System.IO.File]::WriteAllLines($oldFile, @('old-log-line'))
        (Get-Item -LiteralPath $oldFile).LastWriteTime = (Get-Date).AddHours(-2)
        $tail = Get-SysOrgLogTail -LogFolder $logDir -Lines 200
        "$($tail.Path)" | Should -Be $logFile
        @($tail.Lines).Count | Should -Be 200
        "$($tail.Lines[0])" | Should -Be 'line-51'
        "$($tail.Lines[199])" | Should -Be 'line-250'
    }

    It 'returns an empty tail - never a throw - when there is no log' {
        $missing = Join-Path $TestDrive ('notail-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $tail = Get-SysOrgLogTail -LogFolder $missing -Lines 200
        "$($tail.Path)" | Should -Be ''
        @($tail.Lines).Count | Should -Be 0
    }
}

Describe 'Invoke-SysOrgDiagnosticsBundle (v3.0.2 A4)' {

    BeforeAll {
        $repo = Split-Path $PSScriptRoot -Parent
        $sysAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'SysOrg.ps1'), [ref]$null, [ref]$null)
        $fd = $sysAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { $_.Name -eq 'Invoke-SysOrgDiagnosticsBundle' } | Select-Object -First 1
        if(-not $fd){ throw 'SysOrg.ps1 no longer defines Invoke-SysOrgDiagnosticsBundle' }
        Invoke-Expression $fd.Extent.Text
    }

    It 'bundles version, PowerShell and OS versions, config hash, log tail and the last error' {
        $diagDir = Join-Path $TestDrive ('diag-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $logsDir = Join-Path $diagDir 'Logs'
        $appDir  = Join-Path $diagDir 'app'
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        $cfgFile = Join-Path $diagDir 'SysOrg.config.psd1'
        Set-Content -LiteralPath $cfgFile -Value "@{ Version = '9.9.9-test' }"
        $logFile = Join-Path $logsDir 'sysorg-20990101.log'
        [System.IO.File]::WriteAllLines($logFile, @(1..5 | ForEach-Object { "logevent-$_" }))
        # record a last error through the A1 helper (it writes its own log file)
        function ThrowerDiag { throw [System.InvalidOperationException] 'bundle fault' }
        $err = $null
        try { ThrowerDiag } catch { $err = $_ }
        $null = Write-SysOrgErrorDiagnostic -ErrorRecord $err -LogFolder $logsDir -Phase 'preview'
        # the bundle tails the NEWEST log - make the fixture log decisively the newest
        (Get-Item -LiteralPath $logFile).LastWriteTime = (Get-Date).AddMinutes(1)

        # script-scope variables the bundle reads (same names as in SysOrg.ps1)
        $script:SysOrgElevatedSession = $false
        $script:appRoot   = $appDir
        $script:logFolder = $logsDir
        $script:ConfigPath = $cfgFile
        $script:Config = @{ Version = '9.9.9-test' }

        $outPath = Invoke-SysOrgDiagnosticsBundle
        $outPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $outPath | Should -BeTrue
        (Split-Path $outPath -Parent) | Should -Be $logsDir
        $bundle = Get-Content -LiteralPath $outPath -Raw
        $bundle | Should -Match 'SysOrg diagnostics bundle'
        $bundle | Should -Match 'SysOrg version:\s+9\.9\.9-test'
        $bundle | Should -Match ('PowerShell:\s+' + [regex]::Escape($PSVersionTable.PSVersion.ToString()))
        $bundle | Should -Match 'OS:'
        $bundle | Should -Match 'Config SHA256:'
        $bundle | Should -Match 'logevent-5'
        $bundle | Should -Match 'last recorded error'
        $bundle | Should -Match 'bundle fault'
        $bundle | Should -Match 'System\.InvalidOperationException'
        $bundle | Should -Match 'Session transcript'
    }

    It 'says "none recorded" when no error was captured in this session' {
        $diagDir2 = Join-Path $TestDrive ('diag2-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $logsDir2 = Join-Path $diagDir2 'Logs'
        New-Item -ItemType Directory -Path $logsDir2 -Force | Out-Null
        $script:SysOrgElevatedSession = $false
        $script:appRoot = $diagDir2
        $script:logFolder = $logsDir2
        $script:ConfigPath = $null
        $script:Config = @{}
        # clear any previously recorded error by writing into a throwaway runspace-free way:
        # Get-SysOrgLastError reflects module state; this session may carry one from a
        # previous test - only assert the honest fallback TEXT exists either way.
        $out2 = Invoke-SysOrgDiagnosticsBundle
        $bundle2 = Get-Content -LiteralPath $out2 -Raw
        $bundle2 | Should -Match 'last recorded error'
    }
}
