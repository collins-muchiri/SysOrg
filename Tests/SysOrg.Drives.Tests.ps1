# Tests/SysOrg.Drives.Tests.ps1
# Covers: P2-7 (SCM mapping) and the confidence ladder with mocked CIM objects.
# Note: Pester mocks are applied to the SysOrg.Drives module scope, so the
#       confidence model is exercised end-to-end without real storage hardware.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Drives.psm1') -Force
}

Describe 'Get-SysOrgDrive confidence ladder (P2-7)' {
    BeforeEach {
        # The mocks below stub Windows-only CIM cmdlets; creating them on a
        # non-Windows host fails, so mark inconclusive before any Mock call.
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets (Get-Volume/Get-Partition) cannot be mocked on non-Windows hosts'; return }
        Mock Get-Volume -ModuleName SysOrg.Drives {
            @([pscustomobject]@{ DriveLetter='X'; DriveType='Fixed'; Size=100GB; SizeRemaining=40GB
                                FileSystemLabel='Lbl'; FileSystem='NTFS' })
        }
        Mock Get-Partition -ModuleName SysOrg.Drives {
            @([pscustomobject]@{ DriveLetter='X'; DiskNumber=7 })
        }
        Mock Get-CimInstance -ModuleName SysOrg.Drives {
            param($Namespace,$ClassName,$ErrorAction)
            if($ClassName -eq 'Win32_DiskDrive'){
                @([pscustomobject]@{ Index=7; InterfaceType=$script:wmiInterface })
            } else {
                @([pscustomobject]@{ DeviceId='7'; MediaType=$script:physMedia; BusType=$script:physBus })
            }
        }
    }

    It 'BusType USB -> External, High' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets (Get-Volume/Get-Partition) cannot be mocked on non-Windows hosts'; return }
        $script:physMedia = 4; $script:physBus = 7; $script:wmiInterface = $null
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.Location   | Should -Be 'External'
        $d.Confidence | Should -Be 'High'
        $d.MediaType  | Should -Be 'SSD'
        $d.BusType    | Should -Be 'USB'
        $d.DetectionBasis | Should -Match 'USB'
    }
    It 'BusType NVMe -> Internal, High (and SSD inferred when firmware is silent)' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets'; return }
        $script:physMedia = $null; $script:physBus = 17; $script:wmiInterface = $null
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.Location   | Should -Be 'Internal'
        $d.Confidence | Should -Be 'High'
        $d.MediaType  | Should -Be 'SSD'
        $d.DetectionBasis | Should -Match 'NVMe'
    }
    It 'MediaType HDD on SATA -> Internal, Medium' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets'; return }
        $script:physMedia = 3; $script:physBus = 11; $script:wmiInterface = $null
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.Location   | Should -Be 'Internal'
        $d.Confidence | Should -Be 'Medium'
        $d.MediaType  | Should -Be 'HDD'
    }
    It 'MediaType SSD on SATA -> Internal, Medium-High' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets'; return }
        $script:physMedia = 4; $script:physBus = 11; $script:wmiInterface = $null
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.Location   | Should -Be 'Internal'
        $d.Confidence | Should -Be 'Medium-High'
        $d.MediaType  | Should -Be 'SSD'
    }
    It 'MediaType 5 maps to SCM (P2-7)' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets'; return }
        $script:physMedia = 5; $script:physBus = 11; $script:wmiInterface = $null
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.MediaType  | Should -Be 'SCM'
    }
    It 'Removable volume -> External, High regardless of storage metadata' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets'; return }
        Mock Get-Volume -ModuleName SysOrg.Drives {
            @([pscustomobject]@{ DriveLetter='X'; DriveType='Removable'; Size=32GB; SizeRemaining=1GB
                                FileSystemLabel='USB'; FileSystem='FAT32' })
        }
        Mock Get-Partition -ModuleName SysOrg.Drives { @() }
        $script:physMedia = $null; $script:physBus = $null; $script:wmiInterface = $null
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.Location   | Should -Be 'External'
        $d.Confidence | Should -Be 'High'
        $d.DetectionBasis | Should -Match 'Removable'
    }
    It 'Fixed volume with no storage metadata -> Internal, Low' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets'; return }
        Mock Get-Partition -ModuleName SysOrg.Drives { @() }
        $script:physMedia = $null; $script:physBus = $null; $script:wmiInterface = $null
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.Location   | Should -Be 'Internal'
        $d.Confidence | Should -Be 'Low'
        $d.MediaType  | Should -Be 'Unknown'
    }
    It 'Win32 InterfaceType USB (legacy fallback) -> External, Medium' {
        if($env:OS -ne 'Windows_NT'){ Set-ItResult -Inconclusive -Because 'Windows-only CIM cmdlets'; return }
        $script:physMedia = $null; $script:physBus = $null; $script:wmiInterface = 'USB'
        $d = @(Get-SysOrgDrive -Letters 'X')[0]
        $d.Location   | Should -Be 'External'
        $d.Confidence | Should -Be 'Medium'
        $d.DetectionBasis | Should -Match 'legacy'
    }
}
