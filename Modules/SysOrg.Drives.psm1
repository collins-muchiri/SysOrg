#Requires -Version 5.1
# SysOrg.Drives.psm1 - internal/external + SSD/HDD detection with confidence and evidence,
#                      plus the drive hierarchy profiler (design section 4, W1).

function ConvertFrom-SysOrgEnum {
<#
.SYNOPSIS
    Maps a numeric CIM enum value to a friendly name using the supplied table.
.EXAMPLE
    ConvertFrom-SysOrgEnum -Value 7 -Map $busMap   # -> 'USB'
#>
    param($Value,$Map)
    if($null -eq $Value){ return 'Unknown' }
    $s = "$Value"
    if($Map.ContainsKey($s)){ return $Map[$s] }
    return $s
}

function Get-SysOrgDrive {
<#
.SYNOPSIS
    Detects drives with location (internal/external), media type and confidence.
.DESCRIPTION
    Confidence model (each result includes the evidence used):
      Removable volume            -> External, High
      BusType USB / SD / MMC      -> External, High
      BusType NVMe                -> Internal, High (NVMe is always internal solid-state)
      MediaType SSD (SATA/SCSI)   -> Internal, Medium-High (firmware-reported)
      MediaType HDD               -> Internal, Medium
      Win32 InterfaceType USB     -> External, Medium (legacy fallback)
      Only 'Fixed' volume known   -> Internal, Low (metadata missing)
    Caveat: eSATA and Thunderbolt externals report as Internal (the PC sees them as
    SATA/PCIe); the confidence model downgrades certainty and the DetectionBasis
    string is the source of truth. SCM (MediaType 5) is mapped and reported as-is.
.PARAMETER Letters
    Optional filter, e.g. @('C','D').
.EXAMPLE
    Get-SysOrgDrive | Format-Table Drive,MediaType,BusType,Location,Confidence,DetectionBasis -AutoSize
#>
    param([string[]]$Letters)

    $results = New-Object System.Collections.Generic.List[object]
    try { $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') }) } catch { Write-Verbose "Get-Volume unavailable: $($_.Exception.Message)"; $volumes = @() }
    try { $parts   = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }) } catch { Write-Verbose "Get-Partition unavailable: $($_.Exception.Message)"; $parts = @() }
    try { $wmiDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue) } catch { Write-Verbose "Win32_DiskDrive unavailable: $($_.Exception.Message)"; $wmiDisks = @() }
    try { $physDisks = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_PhysicalDisk' -ErrorAction SilentlyContinue) } catch { Write-Verbose "MSFT_PhysicalDisk unavailable: $($_.Exception.Message)"; $physDisks = @() }

    # P2-7: '5' = SCM (Storage Class Memory) added
    $mediaMap = @{ '0'='Unspecified'; '3'='HDD'; '4'='SSD'; '5'='SCM' }
    $busMap   = @{ '1'='SCSI'; '2'='ATAPI'; '3'='ATA'; '4'='IEEE1394'; '5'='SSA'; '6'='Fabric'
                   '7'='USB'; '8'='RAID'; '9'='iSCSI'; '10'='SAS'; '11'='SATA'; '12'='SD'
                   '13'='MMC'; '14'='Virtual'; '15'='FileBacked'; '16'='Spaces'; '17'='NVMe' }

    foreach($vol in $volumes){
        $letter = "$($vol.DriveLetter)"
        if($Letters -and ($Letters -notcontains $letter)){ continue }

        $diskNumber = $null
        $part = $parts | Where-Object { "$($_.DriveLetter)" -eq $letter } | Select-Object -First 1
        if($part){ $diskNumber = $part.DiskNumber }

        $phys = $null
        if($null -ne $diskNumber){
            $phys = $physDisks | Where-Object { "$($_.DeviceId)" -eq "$diskNumber" } | Select-Object -First 1
        }
        $wmi = $wmiDisks | Where-Object { $_.Index -eq $diskNumber } | Select-Object -First 1

        $mediaType = 'Unknown'; $busType = 'Unknown'
        if($phys){
            $mediaType = ConvertFrom-SysOrgEnum $phys.MediaType $mediaMap
            $busType   = ConvertFrom-SysOrgEnum $phys.BusType $busMap
        }

        $sizeGB = 0; if($vol.Size){ $sizeGB = [math]::Round($vol.Size/1GB,1) }
        $freeGB = 0; if($vol.SizeRemaining){ $freeGB = [math]::Round($vol.SizeRemaining/1GB,1) }

        $externalBus = (@('USB','SD','MMC','IEEE1394') -contains $busType)

        $location='Unknown'; $confidence='Low'; $basis='Limited storage metadata'

        if($vol.DriveType -eq 'Removable'){
            $location='External'; $confidence='High'; $basis='Volume reports Removable media'
        }
        elseif($externalBus){
            $location='External'; $confidence='High'; $basis="BusType=$busType (external bus)"
        }
        elseif($busType -eq 'NVMe'){
            $location='Internal'; $confidence='High'; $basis='NVMe bus (internal, always solid-state)'
            if($mediaType -eq 'Unknown'){ $mediaType='SSD' }
        }
        elseif($mediaType -eq 'SSD'){
            $location='Internal'; $confidence='Medium-High'; $basis="MediaType=SSD reported by firmware (bus=$busType)"
        }
        elseif($mediaType -eq 'HDD'){
            $location='Internal'; $confidence='Medium'; $basis="MediaType=HDD reported by firmware (bus=$busType)"
        }
        elseif($wmi -and $wmi.InterfaceType -eq 'USB'){
            $location='External'; $confidence='Medium'; $basis='Win32_DiskDrive InterfaceType=USB (legacy source)'
        }
        elseif($wmi -and $wmi.InterfaceType){
            $location='Internal'; $confidence='Low'; $basis="Win32 InterfaceType=$($wmi.InterfaceType), fixed volume"
        }
        elseif($vol.DriveType -eq 'Fixed'){
            $location='Internal'; $confidence='Low'; $basis='Fixed volume, no storage metadata'
        }

        $results.Add([pscustomobject]@{
            Drive          = "$letter`:"
            Label          = $vol.FileSystemLabel
            FileSystem     = $vol.FileSystem
            SizeGB         = $sizeGB
            FreeGB         = $freeGB
            MediaType      = $mediaType
            BusType        = $busType
            Location       = $location
            Confidence     = $confidence
            DetectionBasis = $basis
        })
    }

    # v3.0.2 CI: drive letters that exist on the FILESYSTEM but have no volume
    # object - a 'subst' mapping creates a DOS device alias, not a volume, so
    # Get-Volume never reports it and -ScanDrive on such a letter failed with
    # 'could not be profiled' although the tree is perfectly scannable. DriveInfo
    # sees them; their evidence is limited and the confidence says so, exactly
    # like the module's other low-confidence fallbacks. Never invents letters:
    # only letters the filesystem actually serves, and only ones Get-Volume missed.
    # Windows only: a subst alias is a Windows concept, and portable hosts must
    # keep the old behaviour exactly.
    if($env:OS -eq 'Windows_NT'){
        try{
            $known = @($results | ForEach-Object { "$($_.Drive)".TrimEnd(':') })
            foreach($di in [System.IO.DriveInfo]::GetDrives()){
                $dLetter = "$($di.Name)".TrimEnd('\', ':').ToUpperInvariant()
                if(-not $dLetter -or ($known -contains $dLetter)){ continue }
                if($Letters -and ($Letters -notcontains $dLetter)){ continue }
                $dt = $di.DriveType
                if($dt -ne [System.IO.DriveType]::Fixed -and $dt -ne [System.IO.DriveType]::Removable){ continue }
                if(-not $di.IsReady){ continue }
                $sizeGB = 0; $freeGB = 0
                try { $sizeGB = [math]::Round($di.TotalSize/1GB,1) } catch { }
                try { $freeGB = [math]::Round($di.AvailableFreeSpace/1GB,1) } catch { }
                $rLocation = 'Internal'; $rConfidence = 'Low'
                $rBasis = 'Drive letter served by the filesystem without volume metadata (subst or virtual mapping)'
                if($dt -eq [System.IO.DriveType]::Removable){ $rLocation = 'External'; $rConfidence = 'High'; $rBasis = 'DriveInfo reports Removable media (no volume object)' }
                $results.Add([pscustomobject]@{
                    Drive          = "$dLetter`:"
                    Label          = "$($di.VolumeLabel)"
                    FileSystem     = $di.DriveFormat
                    SizeGB         = $sizeGB
                    FreeGB         = $freeGB
                    MediaType      = 'Unknown'
                    BusType        = 'Unknown'
                    Location       = $rLocation
                    Confidence     = $rConfidence
                    DetectionBasis = $rBasis
                })
            }
        } catch { Write-Verbose "DriveInfo fallback unavailable: $($_.Exception.Message)" }
    }

    return ($results.ToArray() | Sort-Object Drive)
}

function Get-SysOrgDriveProfile {
<#
.SYNOPSIS
    Profiles the hierarchy of every volume BEFORE any plan is built (W1).
.DESCRIPTION
    Produces one profile per volume: role (System / Removable / Data), detection evidence,
    protected artifacts found at the drive root (Windows, Program Files, WindowsApps,
    XboxGames, ...), known folders resolved on THIS drive (with redirection and OneDrive
    flags), download roots, the top-level directory tree, the proposed writable scope and
    the destination root. NO PLAN IS BUILT WITHOUT A PROFILE.
.PARAMETER Letters
    Optional drive-letter filter, e.g. @('C').
.EXAMPLE
    Get-SysOrgDriveProfile -Config $cfg | Show-SysOrgDriveProfileReport
#>
    [CmdletBinding()]
    param($Config,[string[]]$Letters,[object[]]$KnownFolders)
    if(-not $KnownFolders -or @($KnownFolders).Count -eq 0){ $KnownFolders = @(Get-SysOrgKnownFolders) }
    $systemDrive = 'C'
    try { if($env:SystemDrive){ $systemDrive = $env:SystemDrive.TrimEnd(':').ToUpperInvariant() } } catch { }
    $artifacts = @(Get-SysOrgSetting $Config 'Policy.ProtectedArtifacts' @())

    $profiles = @()
    foreach($d in @(Get-SysOrgDrive -Letters $Letters)){
        $letter = "$($d.Drive)".TrimEnd(':').ToUpperInvariant()
        $root = ("{0}:\" -f $letter)
        $role = 'Data'
        if($letter -eq $systemDrive){ $role = 'System' }
        elseif("$($d.Location)" -eq 'External'){ $role = 'Removable' }

        $found = @()
        foreach($a in $artifacts){
            if([string]::IsNullOrWhiteSpace("$a")){ continue }
            $ap = ($root + "$a")
            if(Test-Path -LiteralPath $ap){ $found += "$a" }
        }

        $kf = @($KnownFolders | Where-Object { $_.Path -and ("$($_.Path)".StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) })

        # Download roots: resolved Downloads known folders on this drive + <root>\Downloads
        $dl = @()
        $seen = @{}
        foreach($k in $kf){
            if("$($k.Name)" -ieq 'Downloads'){
                $kk = "$($k.Path)".ToLowerInvariant()
                if(-not $seen.ContainsKey($kk)){ $seen[$kk]=$true; $dl += [string]$k.Path }
            }
        }
        $dlRoot = ($root + 'Downloads')
        if(Test-Path -LiteralPath $dlRoot){
            $kk = $dlRoot.ToLowerInvariant()
            if(-not $seen.ContainsKey($kk)){ $seen[$kk]=$true; $dl += $dlRoot }
        }

        $top = @()
        try {
            $top = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                     Select-Object -First 60 | ForEach-Object { $_.Name })
        } catch { $top = @() }

        $scope = if($role -eq 'System'){ 'KnownFolders' } else { 'FullDrive' }

        $profiles += [pscustomobject]@{
            Letter          = $letter
            Root            = $root
            Role            = $role
            Drive           = $d
            Artifacts       = $found
            KnownFolders    = $kf
            DownloadRoots   = $dl
            TopLevelDirs    = $top
            ProposedScope   = $scope
            DestinationRoot = (Get-SysOrgDestinationRoot -Letter $letter -Config $Config)
        }
    }
    return $profiles
}

function Show-SysOrgDriveProfileReport {
<#
.SYNOPSIS
    Renders the drive hierarchy profile report (design sections 4 and 12.5).
.DESCRIPTION
    Per volume: role and detection evidence, protected artifacts found, known folders
    (with redirection / OneDrive flags), top-level folders, download roots and the
    proposed writable scope. The user sees the architecture before confirming anything.
.EXAMPLE
    Show-SysOrgDriveProfileReport -Profiles (Get-SysOrgDriveProfile -Config $cfg)
#>
    param([Parameter(Mandatory)]$Profiles,[switch]$AsText)
    if(-not $Profiles -or @($Profiles).Count -eq 0){
        Write-Host 'No drive profiles available.' -ForegroundColor Yellow
        return
    }
    foreach($p in @($Profiles)){
        Write-Host ''
        Write-Host ("Drive {0}\   role={1}   proposed scope={2}" -f $p.Letter, $p.Role, $p.ProposedScope) -ForegroundColor White
        Write-Host ("  Destination root: {0}" -f $p.DestinationRoot)
        $d = $p.Drive
        if($d){
            Write-Host ("  Detection: {0} / {1} / {2} / {3}  (confidence {4})" -f $d.MediaType, $d.BusType, $d.Location, $d.FileSystem, $d.Confidence)
            Write-Host ("  Evidence : {0}" -f $d.DetectionBasis)
        }
        if(@($p.Artifacts).Count -gt 0){
            Write-Host ("  Protected artifacts at root: {0}" -f (@($p.Artifacts) -join ', ')) -ForegroundColor Yellow
        }
        if(@($p.KnownFolders).Count -gt 0){
            foreach($k in @($p.KnownFolders)){
                $flags = @()
                if($k.IsRedirected){ $flags += 'redirected' }
                if($k.UnderOneDrive){ $flags += 'OneDrive' }
                $fs = ''
                if($flags.Count -gt 0){ $fs = ('  [' + ($flags -join ', ') + ']') }
                Write-Host ("  Known folder: {0,-10} -> {1}{2}" -f $k.Name, $k.Path, $fs)
            }
        } else {
            Write-Host '  Known folders on this drive: (none)' -ForegroundColor DarkGray
        }
        if(@($p.DownloadRoots).Count -gt 0){
            Write-Host ("  Download roots: {0}" -f (@($p.DownloadRoots) -join ', '))
        }
        if(@($p.TopLevelDirs).Count -gt 0){
            Write-Host ("  Top-level folders: {0}" -f (@($p.TopLevelDirs) -join ', '))
        }
    }
    Write-Host ''
}

Export-ModuleMember -Function *-SysOrg*
