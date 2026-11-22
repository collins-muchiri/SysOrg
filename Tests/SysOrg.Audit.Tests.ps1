# Tests/SysOrg.Audit.Tests.ps1
# v3.0.1 A1: drive-relative path rejection and the folder-audit root bug.
#
# The defect: Get-SysOrgFolderAudit pushed 'X:' (slash stripped) as the enumeration
# root. 'X:' is a DRIVE-RELATIVE path - .NET resolves it against the drive's CURRENT
# directory, so an audit started from a subfolder enumerated the app folder and
# reported error 2 for every child ('C:.github', 'C:Cache', ...). The fix keeps
# 'X:\' for enumeration and probes and strips the slash only for display.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1') -Force
    $script:auditCfg = @{
        OrganizedRoots = @{ '*' = '__AUTO__' }
        ExcludedPaths  = @('$Recycle.Bin','System Volume Information')
        ExcludedFilePatterns = @('*.tmp')
        FolderAudit    = @{ Enabled=$true; SkipHiddenSystemDirs=$true; RespectDefenderCFA=$false; IncludeRestrictedInPlans=$false }
        TypeMap        = @{}
    }
}

Describe 'ConvertTo-SysOrgPath (A1)' {

    It 'keeps full drive paths and normalizes separators' {
        ConvertTo-SysOrgPath -Path 'C:\a\b' | Should -Be 'C:\a\b'
        ConvertTo-SysOrgPath -Path 'C:/a/b' | Should -Be 'C:\a\b'
        ConvertTo-SysOrgPath -Path 'C:\'    | Should -Be 'C:\'
        ConvertTo-SysOrgPath -Path '\\server\share\f.docx' | Should -Be '\\server\share\f.docx'
    }

    It 'REJECTS drive-relative forms - they resolve against the drive current directory' {
        { ConvertTo-SysOrgPath -Path 'C:' }       | Should -Throw '*drive-relative*'
        { ConvertTo-SysOrgPath -Path 'C:file' }   | Should -Throw '*drive-relative*'
        { ConvertTo-SysOrgPath -Path 'c:Cache' }  | Should -Throw '*drive-relative*'
        { ConvertTo-SysOrgPath -Path 'D:Tools\bin' } | Should -Throw '*drive-relative*'
    }

    It 'rejects empty paths and dot segments' {
        { ConvertTo-SysOrgPath -Path '' }            | Should -Throw
        { ConvertTo-SysOrgPath -Path '   ' }         | Should -Throw
        { ConvertTo-SysOrgPath -Path 'C:\a\..\b' }   | Should -Throw '*..*'
        { ConvertTo-SysOrgPath -Path 'C:\a\.\b' }    | Should -Throw '*..*'
    }
}

Describe 'Get-SysOrgDriveRootPath (A1)' {

    It 'always returns the full root form with the trailing slash kept' {
        Get-SysOrgDriveRootPath -Letter 'x'   | Should -Be 'X:\'
        Get-SysOrgDriveRootPath -Letter 'C:'  | Should -Be 'C:\'
        Get-SysOrgDriveRootPath -Letter 'd\'  | Should -Be 'D:\'
    }

    It 'rejects anything that is not a single drive letter' {
        { Get-SysOrgDriveRootPath -Letter 'AB' }  | Should -Throw
        { Get-SysOrgDriveRootPath -Letter '' }    | Should -Throw
    }
}

Describe 'Get-SysOrgFolderAudit root handling (A1)' {

    It 'audits the REAL drive-root children even when the current directory is a subfolder of the audited drive' -Skip:($env:OS -ne 'Windows_NT') {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'drive-root auditing needs a real drive letter (Windows)'; return }
        # Run the audit with the CURRENT DIRECTORY deep inside a subfolder of C: -
        # the defective code enumerated THIS folder's children as 'C:xxx'.
        $marker = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('sysorg-a1-' + [guid]::NewGuid().ToString('N').Substring(0,8))) -Force
        New-Item -ItemType Directory -Path (Join-Path $marker.FullName 'AppChild') -Force | Out-Null
        try{
            Push-Location $marker.FullName
            try{
                $audit = Get-SysOrgFolderAudit -Letter 'C' -Config $script:auditCfg -MaxDepth 1
                $paths = @($audit.Folders | ForEach-Object { "$($_.Path)" })
                # real drive-root children are listed ...
                ($paths -contains 'C:\Windows') | Should -BeTrue
                ($paths -contains 'C:\Users')   | Should -BeTrue
                # ... never the app-folder children (no drive-relative leak, no error-2 storm)
                ($paths -contains ('C:' + $marker.Name)) | Should -BeFalse
                @($paths | Where-Object { $_ -match '^C:[^\\]' }).Count | Should -Be 0
                @($audit.Folders | Where-Object { "$($_.Reason)" -match 'error 2' }).Count | Should -Be 0
                # the root itself is listed in display form (slash stripped ONLY for display)
                ($paths -contains 'C:') | Should -BeTrue
            } finally { Pop-Location }
        } finally { Remove-Item -LiteralPath $marker.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a drive that does not exist throws the not-found error' {
        # 'Z' is not assigned on the CI runners; the audit must fail loudly either way.
        $hasZ = $false
        if($env:OS -eq 'Windows_NT'){ try { $hasZ = [bool](Test-Path -LiteralPath 'Z:\') } catch { $hasZ = $false } }
        if($hasZ){ Set-ItResult -Inconclusive -Because 'drive Z: exists on this host'; return }
        { Get-SysOrgFolderAudit -Letter 'Z' -Config $script:auditCfg -MaxDepth 1 } | Should -Throw '*not found*'
    }
}
