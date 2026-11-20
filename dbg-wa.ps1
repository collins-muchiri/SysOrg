
Import-Module ./Modules/SysOrg.Core.psm1 -Force
Import-Module ./Modules/SysOrg.KnownFolders.psm1 -Force
Import-Module ./Modules/SysOrg.Scan.psm1 -Force
Import-Module ./Modules/SysOrg.Plan.psm1 -Force
Write-Host ('bucket1: [' + (Get-SysOrgSourceBucket -HostUrl '' -ReferrerUrl '' -FileName 'WhatsApp Image 2024-01-01 at 10.00.00.jpeg') + ']')
$dl = Join-Path /tmp 'wadbg'
New-Item -ItemType Directory -Path $dl -Force | Out-Null
$p1 = Join-Path $dl 'WhatsApp Image 2024-01-01 at 10.00.00.jpeg'
Set-Content -LiteralPath $p1 -Value ('W' * 100)
$fi = Get-Item -LiteralPath $p1
$inv = @([pscustomobject]@{ FullName=$fi.FullName; Name=$fi.Name; Stem=$fi.BaseName; Extension=$fi.Extension.ToLowerInvariant(); Length=[int64]$fi.Length; LastWriteTime=$fi.LastWriteTime; Directory=$fi.DirectoryName; Category='Pictures' })
$prof = [pscustomobject]@{ Letter='S'; Root='S:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@($dl); Artifacts=@() }
$cfg = @{ OrganizedRoots=@{ 'S'='/tmp/wadbg-org' }; ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; DateFolders='Year'; PreserveExistingFolders=$false
  Families=@{Enabled=$false}; Copies=@{Policy='NumberCopies';StartIndex=2;MinFileSizeKB=1}; Downloads=@{Roots=@('Downloads');GroupBy='SourceFirst';DateFolders='Year';UseZoneIdentifier=$false;UnknownSourceFolder='_NoSource'}; FolderAudit=@{Enabled=$false}; Move=@{AllowCrossVolume=$true}; MaxPlanActions=5000 }
$plan = New-SysOrgPlan -Letter S -Inventory $inv -DriveProfile $prof -DupGroups @() -Config $cfg -KnownFolders @()
Write-Host ('actions: ' + @($plan.Actions).Count)
foreach($a in @($plan.Actions)){ Write-Host ('  bucket=[' + $a.SourceBucket + '] dest=' + $a.Destination) }
foreach($s in @($plan.Skipped)){ Write-Host ('  skip: ' + $s.Source + ' [' + $s.Reason + ']') }
