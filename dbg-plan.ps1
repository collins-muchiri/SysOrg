
Import-Module /home/z/sysorg-build/SysOrg/Modules/SysOrg.Core.psm1 -Force
Import-Module /home/z/sysorg-build/SysOrg/Modules/SysOrg.KnownFolders.psm1 -Force
Import-Module /home/z/sysorg-build/SysOrg/Modules/SysOrg.Scan.psm1 -Force
Import-Module /home/z/sysorg-build/SysOrg/Modules/SysOrg.Plan.psm1 -Force
$sysProf = [pscustomobject]@{ Letter='C'; Root='C:\'; Role='System'; ProposedScope='KnownFolders'
    KnownFolders=@([pscustomobject]@{ Name='Documents'; Path='C:\Users\t\Documents' })
    DownloadRoots=@('C:\Users\t\Downloads') }
$ok   = [pscustomobject]@{ FullName='C:\Users\t\Documents\note.txt'; Name='note.txt'; Stem='note'; Extension='.txt'
    Length=5; LastWriteTime=(Get-Date '2026-02-03'); Directory='C:\Users\t\Documents'; Category='Documents' }
$mCfg = @{ OrganizedRoots=@{ 'C'='C:\Organized' }; ExcludedPaths=@(); ExcludedFilePatterns=@()
           SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; PreserveExistingFolders=$false
           Copies=@{Policy='NumberCopies';StartIndex=2;MinFileSizeKB=1}; Families=@{Enabled=$false}
           Downloads=@{UseZoneIdentifier=$false}; FolderAudit=@{Enabled=$false}; DateFolders='Year'
           Policy=@{ SystemDrive=@{ Scope='KnownFolders'; WritablePaths=@()
                BlockedExtensions=@('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url'); AllowInstallersInDownloads=$true }
                DataDrives=@{ Scope='FullDrive' } } }
$plan = New-SysOrgPlan -Letter C -Inventory @($ok) -DriveProfile $sysProf -DupGroups @() -Config $mCfg -KnownFolders @($sysProf.KnownFolders)
Write-Host ('ACTIONS: ' + @($plan.Actions).Count)
foreach($a in @($plan.Actions)){ Write-Host ('  ' + $a.Source + ' -> ' + $a.Destination) }
Write-Host ('SKIPPED: ' + @($plan.Skipped).Count)
foreach($s in @($plan.Skipped)){ Write-Host ('  skip: ' + $s.Source + ' [' + $s.Reason + ']') }
Write-Host ('Allowed: ' + $plan.Mutability.Allowed)
