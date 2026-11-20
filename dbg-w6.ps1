
Import-Module ./Modules/SysOrg.Core.psm1 -Force
Import-Module ./Modules/SysOrg.KnownFolders.psm1 -Force
Import-Module ./Modules/SysOrg.Scan.psm1 -Force
Import-Module ./Modules/SysOrg.Plan.psm1 -Force
$TestDrive = '/tmp/w6dbg2'
if(Test-Path $TestDrive){ Remove-Item -Recurse -Force $TestDrive -ErrorAction SilentlyContinue }
$src = Join-Path $TestDrive 'w6a'
New-Item -ItemType Directory -Path $src -Force | Out-Null
$p1 = Join-Path $src 'Report.docx'; $p2 = Join-Path $src 'Report - Copy.docx'; $p3 = Join-Path $src 'Report final v2.docx'
Set-Content -LiteralPath $p1 -Value ('R' * 1200); Set-Content -LiteralPath $p2 -Value ('R' * 1200); Set-Content -LiteralPath $p3 -Value ('S' * 1200)
(Get-Item -LiteralPath $p1).LastWriteTime = Get-Date '2026-01-01'
(Get-Item -LiteralPath $p2).LastWriteTime = Get-Date '2026-01-02'
(Get-Item -LiteralPath $p3).LastWriteTime = Get-Date '2026-01-03'
function New-Rec([string]$Path,[string]$Category){
  $fi = Get-Item -LiteralPath $Path
  [pscustomobject]@{ FullName=$fi.FullName; Name=$fi.Name; Stem=$fi.BaseName; Extension=$fi.Extension.ToLowerInvariant(); Length=[int64]$fi.Length; LastWriteTime=$fi.LastWriteTime; Directory=$fi.DirectoryName; Category=$Category }
}
$inv = @((New-Rec $p1 'Documents'),(New-Rec $p2 'Documents'),(New-Rec $p3 'Documents'))
$cfg = @{ OrganizedRoots=@{ 'S'=(Join-Path $TestDrive 'org') }; ExcludedPaths=@(); ExcludedFilePatterns=@(); SkipHiddenSystemFiles=$true; ExcludeDestinations=$true; DateFolders='Year'; PreserveExistingFolders=$false
  Families=@{Enabled=$true;MinFiles=2;WithinTypeOnly=$true;CrossTypeLink='SameName';KeepDates=$true;StripVersionSuffix=$true;MaxNameLength=60}
  Copies=@{Policy='NumberCopies';SuffixStyle='Parentheses';StartIndex=2;MinFileSizeKB=1;HeaderHashKB=64;QuarantineFolderName='_Duplicates'}
  Downloads=@{Roots=@('Downloads');GroupBy='SourceFirst';DateFolders='Year';UseZoneIdentifier=$false;UnknownSourceFolder='_NoSource'}
  Projects=@{Enabled=$true}; Archives=@{KeepMultipartTogether=$true}; Preview=@{}; Move=@{AllowCrossVolume=$true}; MaxPlanActions=5000; FolderAudit=@{Enabled=$false} }
$prof = [pscustomobject]@{ Letter='S'; Root='S:\'; Role='Data'; ProposedScope='FullDrive'; KnownFolders=@(); DownloadRoots=@(); Artifacts=@() }
$dups = @(Find-SysOrgDuplicates -Inventory $inv -Config $cfg)
$plan = New-SysOrgPlan -Letter 'S' -Inventory $inv -DriveProfile $prof -DupGroups $dups -Config $cfg -KnownFolders @()
Write-Host ('p1=' + $p1)
foreach($a in @($plan.Actions)){ Write-Host ('src=[' + $a.Source + '] dst=[' + $a.Destination + '] copyIdx=' + $a.CopyIndex) }
