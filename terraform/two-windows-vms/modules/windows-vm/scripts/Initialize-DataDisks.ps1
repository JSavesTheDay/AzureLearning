<#
.SYNOPSIS
    One-time setup of Azure data disks inside a Windows VM.

.DESCRIPTION
    Runs once through an Azure managed Run Command (Windows PowerShell 5.1, as SYSTEM).
      1. Moves CD/DVD drives to the optical drive letter (Z: by default), freeing D: and later letters.
      2. Finds each data disk by its Azure LUN, then initializes (GPT), partitions,
         formats (NTFS) and labels it, and assigns its drive letter.
      3. Extends C: to fill the OS disk if any space is unallocated.
    Safe to re-run: disks that already have a data partition are skipped.

.PARAMETER DiskLayoutBase64
    Base64-encoded JSON array: [{ lun, label, driveLetter, allocationUnitKb }, ...]

.PARAMETER OpticalDriveLetter
    Letter for the first optical drive. Any additional optical drives count down from it (Y:, X:, ...).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $DiskLayoutBase64,
    [ValidatePattern('^[A-Z]$')]
    [string] $OpticalDriveLetter = 'Z'
)

$ErrorActionPreference = 'Stop'

$layout = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($DiskLayoutBase64)) | ConvertFrom-Json

# --- 1. Move optical drives out of the way ------------------------------------
# Win32_Volume DriveType 5 = CD-ROM. Moving these first frees letters such as D: and E:.
$letterCode = [int][char]$OpticalDriveLetter.ToUpper()
foreach ($volume in @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 5')) {
    $target = "$([char]$letterCode):"
    if ($volume.DriveLetter -ne $target) {
        $oldLetter = $volume.DriveLetter # Set-CimInstance updates $volume in place, so save it first
        Set-CimInstance -InputObject $volume -Property @{ DriveLetter = $target }
        Write-Output "Optical drive $oldLetter moved to $target"
    }
    $letterCode--
}

# --- 2. Initialize, format, and letter each data disk by LUN --------------------
# Data disks have their own SCSI controller. The OS disk (LUN 0) and any temp disk
# share a different one, so keep only disks that aren't on the boot disk's controller.
$systemDiskNumbers = @(Get-Disk | Where-Object { $_.IsBoot -or $_.IsSystem } | ForEach-Object Number)
$allDisks = @(Get-CimInstance -ClassName Win32_DiskDrive)
$bootPort = ($allDisks | Where-Object { $systemDiskNumbers -contains $_.Index } | Select-Object -First 1).SCSIPort
$dataDisks = @($allDisks | Where-Object SCSIPort -ne $bootPort)

foreach ($entry in $layout) {
    $match = @($dataDisks | Where-Object SCSILogicalUnit -eq $entry.lun)
    if ($match.Count -ne 1) {
        throw "Expected exactly one data disk at LUN $($entry.lun), found $($match.Count)."
    }
    $disk = Get-Disk -Number $match[0].Index

    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }

    if ($disk.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    }

    # GPT disks also get a hidden 'Reserved' (MSR) partition; the data partition is 'Basic'.
    $existing = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic'
    if ($existing) {
        Write-Output "LUN $($entry.lun): disk $($disk.Number) already has a data partition; skipped."
        continue
    }

    $letterOwner = Get-Partition -DriveLetter $entry.driveLetter -ErrorAction SilentlyContinue
    if ($letterOwner) {
        throw "Drive letter $($entry.driveLetter): is already used by disk $($letterOwner.DiskNumber)."
    }

    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $entry.driveLetter
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $entry.label `
        -AllocationUnitSize ($entry.allocationUnitKb * 1KB) -Confirm:$false | Out-Null

    Write-Output ("LUN {0}: {1}: '{2}' formatted NTFS, {3} KB allocation units" -f `
            $entry.lun, $entry.driveLetter, $entry.label, $entry.allocationUnitKb)
}

# --- 3. Extend C: if the OS disk was resized larger than the image --------------
$maxSize = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
$current = (Get-Partition -DriveLetter C).Size
if (($maxSize - $current) -gt 1MB) {
    Resize-Partition -DriveLetter C -Size $maxSize
    Write-Output ("C: extended by {0:N0} MB" -f (($maxSize - $current) / 1MB))
}

# --- Summary --------------------------------------------------------------------
Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter |
Format-Table DriveLetter, FileSystemLabel, FileSystem, DriveType, AllocationUnitSize,
@{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } } -AutoSize |
Out-String -Width 200
