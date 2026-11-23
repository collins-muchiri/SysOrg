# ---------------------------------------------------------------------------
# v3.0.2 A1: exception diagnostics. The menu catch-all and every CLI entry
# point must log the exception type, message, ScriptStackTrace and
# InvocationInfo.PositionMessage to the log file; Get-SysOrgLastError keeps the
# record for -Diagnostics (A4). The menu/CLI wiring itself is exercised
# end-to-end by the v3.0.2 smoke fixtures (SysOrg.Smoke.Tests.ps1); these tests
# pin the diagnostic helper and its output contract.
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
        # an impossible path under a FILE root forces the log write to fail
        $badRoot = if($env:OS -eq 'Windows_NT'){ 'C:\definitely\missing\zzz\file.txt\sub' } else { '/proc/definitely-not-writable/sysorg' }
        { $null = Write-SysOrgErrorDiagnostic -ErrorRecord $err -LogFolder $badRoot -Phase 'preview' } | Should -Not -Throw
    }
}
