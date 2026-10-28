# VM inventory. No secrets belong in this file: the admin password is generated,
# and your IP comes from the TF_VAR_allowed_rdp_source_ip environment variable.
#
# Disk sizes are POC minimums (4 GiB standard/premium SSD, 1 GiB Premium SSD v2).
# LUNs are sequential in drive-letter order (D: = 0, E: = 1, ...).
#
# SQL disk settings follow Microsoft's storage best practices for SQL Server on Azure VMs:
# https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/performance-guidelines-best-practices-storage

vms = {
  web1 = {
    size = "Standard_B2als_v2" # no temp disk, max 4 data disks
    zone = "1"

    os_disk = {
      size_gb              = 128
      storage_account_type = "StandardSSD_LRS"
    }

    data_disks = [
      { lun = 0, label = "Data", drive_letter = "D", size_gb = 4, storage_account_type = "StandardSSD_LRS" },
    ]
  }

  db01 = {
    size = "Standard_B4als_v2" # no temp disk, max 8 data disks (2-vCPU sizes cap at 4)
    zone = "1"                 # Premium SSD v2 requires a zonal VM in East US 2

    os_disk = {
      size_gb              = 128
      storage_account_type = "Premium_LRS"
    }

    data_disks = [
      {
        lun                  = 0
        label                = "Application"
        drive_letter         = "D"
        size_gb              = 4
        storage_account_type = "StandardSSD_LRS"
        caching              = "None"
        allocation_unit_kb   = 4 # general-purpose files: NTFS default
      },
      {
        # tempdb on a dedicated managed disk (no temp-disk VM size):
        # - ReadOnly caching: Microsoft's guidance when tempdb can't use the local temp disk
        # - 64 KB allocation units: SQL Server allocates in 64 KB extents
        # - Production: Premium SSD (ReadOnly caching) or Premium SSD v2 (no caching)
        lun                  = 1
        label                = "SQLTemp"
        drive_letter         = "E"
        size_gb              = 4
        storage_account_type = "StandardSSD_LRS"
        caching              = "ReadOnly"
        allocation_unit_kb   = 64
      },
      {
        # Data files. Premium SSD v2 can't use host caching (on Premium SSD, use ReadOnly).
        # iops/mbps: 1 GiB disks are limited to the free baseline; raise size_gb to raise these.
        lun                  = 2
        label                = "SqlData"
        drive_letter         = "F"
        size_gb              = 1
        storage_account_type = "PremiumV2_LRS"
        caching              = "None"
        allocation_unit_kb   = 64
        iops                 = 3000
        mbps                 = 125
      },
      {
        # Transaction log. Caching must be None on any disk type (write durability).
        lun                  = 3
        label                = "SqlLogs"
        drive_letter         = "G"
        size_gb              = 1
        storage_account_type = "PremiumV2_LRS"
        caching              = "None"
        allocation_unit_kb   = 64
        iops                 = 3000
        mbps                 = 125
      },
      {
        # Backups: sequential writes, cost over latency. Standard storage is fine.
        lun                  = 4
        label                = "SqlBackups"
        drive_letter         = "H"
        size_gb              = 4
        storage_account_type = "StandardSSD_LRS"
        caching              = "None"
        allocation_unit_kb   = 64
      },
    ]
  }
}
