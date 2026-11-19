#Requires -Version 5.1
# SysOrg.Drives.psm1 - internal/external + SSD/HDD detection with confidence and evidence.

function ConvertFrom-SysOrgEnum {
    param($Value,$Map)
    if($null -eq $Value){ return 'Unknown' }
    $s = "$Value"
    if($Map.ContainsKey($s)){ return $Map[$s] }
    return $s
}

function Get-SysOrgDrive {
    <#
      Confidence model (each result includes the evidence used):
        Removable volume            -> External, High
        BusType USB / SD / MMC      -> External, High
        BusType NVMe                -> Internal, High (NVMe is always internal solid-state)
        MediaType SSD (SATA/SCSI)   -> Internal, Medium-High (firmware-reported)
        MediaType HDD               -> Internal, Medium
        Win32 InterfaceType USB     -> External, Medium (legacy fallback)
        Only 'Fixed' volume known   -> Internal, Low (metadata missing)
    #>
    param([string[]]$Letters)

    $results = @()
    try { $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') }) } catch { $volumes = @() }
    try { $parts   = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }) } catch { $parts = @() }
    try { $wmiDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue) } catch { $wmiDisks = @() }
    try { $physDisks = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_PhysicalDisk' -ErrorAction SilentlyContinue) } catch { $physDisks = @() }

    $mediaMap = @{ '0'='Unspecified'; '3'='HDD'; '4'='SSD' }
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

        $results += [pscustomobject]@{
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
        }
    }
    return ($results | Sort-Object Drive)
}

Export-ModuleMember -Function *-SysOrg*
