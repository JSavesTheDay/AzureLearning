<#
.SYNOPSIS
    Read-only snapshot of a Windows VM's disks, volumes, drive letters, and pagefile.

.DESCRIPTION
    Changes nothing. Run before and after Initialize-DataDisks.ps1 to compare.
    Output is kept compact because Run Command returns only the last 4 KB.

    az vm run-command invoke --resource-group <rg> --name <vm> --command-id RunPowerShellScript --scripts '@scripts\Get-DriveInventory.ps1'
#>

$driveType = @{ 0 = 'Unknown'; 1 = 'NoRoot'; 2 = 'Removable'; 3 = 'Fixed'; 4 = 'Network'; 5 = 'CD-ROM'; 6 = 'RAM' }
$scsi = @{}
Get-CimInstance -ClassName Win32_DiskDrive | ForEach-Object { $scsi[[int]$_.Index] = $_ }

'## DISKS (Port/LUN = Azure attachment)'
Get-Disk | Sort-Object Number | Format-Table -AutoSize `
    @{ n = '#'; e = { $_.Number } },
    @{ n = 'Port'; e = { $scsi[[int]$_.Number].SCSIPort } },
    @{ n = 'LUN'; e = { $scsi[[int]$_.Number].SCSILogicalUnit } },
    @{ n = 'GB'; e = { [math]::Round($_.Size / 1GB) } },
    @{ n = 'Style'; e = { $_.PartitionStyle } },
    @{ n = 'Boot'; e = { $_.IsBoot } },
    @{ n = 'Offline'; e = { $_.IsOffline } } | Out-String -Width 120

'## VOLUMES (including unlettered)'
Get-CimInstance -ClassName Win32_Volume | Sort-Object DriveLetter | Format-Table -AutoSize `
    @{ n = 'Ltr'; e = { $_.DriveLetter } },
    @{ n = 'Label'; e = { $_.Label } },
    @{ n = 'FS'; e = { $_.FileSystem } },
    @{ n = 'Type'; e = { $driveType[[int]$_.DriveType] } },
    @{ n = 'GB'; e = { if ($_.Capacity) { [math]::Round($_.Capacity / 1GB, 1) } } },
    @{ n = 'AU'; e = { $_.BlockSize } } | Out-String -Width 120

'## OPTICAL DRIVES'
$cd = @(Get-CimInstance -ClassName Win32_CDROMDrive)
if ($cd.Count) { $cd | Format-Table -AutoSize Drive, Caption, MediaLoaded | Out-String -Width 120 } else { '(none)' }

# MountedDevices maps \DosDevices\X: to a volume signature. An entry whose volume
# is gone still reserves that letter, so Windows won't hand it out automatically.
'## LETTER RESERVATIONS (HKLM\SYSTEM\MountedDevices)'
$mounted = (Get-Item -Path 'HKLM:\SYSTEM\MountedDevices').GetValueNames() |
    ForEach-Object { if ($_ -match '^\\DosDevices\\([A-Z]):$') { $Matches[1] } }
$live = @(Get-CimInstance -ClassName Win32_Volume | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter.TrimEnd(':') })
foreach ($l in ($mounted | Sort-Object)) {
    '{0}: {1}' -f $l, $(if ($live -contains $l) { 'in use' } else { 'RESERVED (no volume present)' })
}

'## PAGEFILE'
$pf = @(Get-CimInstance -ClassName Win32_PageFileUsage)
if ($pf.Count) { $pf | ForEach-Object { '{0} ({1} MB allocated)' -f $_.Name, $_.AllocatedBaseSize } } else { '(none)' }
'AutomaticManagedPagefile: ' + (Get-CimInstance -ClassName Win32_ComputerSystem).AutomaticManagedPagefile
