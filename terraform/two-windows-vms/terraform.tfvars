# VM inventory. No secrets belong in this file: the admin password is generated,
# and your IP comes from the TF_VAR_allowed_rdp_source_ip environment variable.
#
# Disk sizes are POC minimums (4 GiB standard/premium SSD, 1 GiB Premium SSD v2).
# LUNs start at 0 and are sequential in drive-letter order.
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
    # Cheapest x64 size with a SCSI temp disk (16 GiB, D:) and Premium storage.
    # Max 4 data disks, all used below. Burstable: fine for design tests, not load tests.
    size = "Standard_B2ms"
    zone = "1" # Premium SSD v2 requires a zonal VM in East US 2

    # SQL Server 2025 Standard Developer: no SQL license cost (dev/test only).
    source_image = {
      publisher = "MicrosoftSQLServer"
      offer     = "sql2025-ws2025"
      sku       = "stddev-gen2"
    }
    patch_mode = "AutomaticByOS" # SQL images don't support AutomaticByPlatform

    # tempdb on the temp disk (D:\tempDb). A startup task re-creates the folders and
    # permissions after the disk is wiped by deallocation or redeploy, then starts SQL.
    # tempdb gets 8 data files (the default), sized for production VMs with 8+ vCPUs.
    sql_server = {}

    os_disk = {
      size_gb              = 128
      storage_account_type = "Premium_LRS"
    }

    # D: is the temp disk (tempdb and pagefile), so data disks start at E:.
    data_disks = [
      {
        lun                  = 0
        label                = "Application"
        drive_letter         = "E"
        size_gb              = 4
        storage_account_type = "StandardSSD_LRS"
      },
      {
        # Data files (F:\Data is SQL Server's default). Premium SSD v2 can't use host
        # caching (on Premium SSD, use ReadOnly).
        # iops/mbps: 1 GiB disks are limited to the free baseline; raise size_gb to raise these.
        lun                  = 1
        label                = "SqlData"
        drive_letter         = "F"
        size_gb              = 1
        storage_account_type = "PremiumV2_LRS"
        allocation_unit_kb   = 64
        iops                 = 3000
        mbps                 = 125
        sql_role             = "data"
      },
      {
        # Transaction log (G:\Log). Caching must be None on any disk type (write durability).
        lun                  = 2
        label                = "SqlLogs"
        drive_letter         = "G"
        size_gb              = 1
        storage_account_type = "PremiumV2_LRS"
        allocation_unit_kb   = 64
        iops                 = 3000
        mbps                 = 125
        sql_role             = "log"
      },
      {
        # Backups (H:\Backup): sequential writes, cost over latency. Standard storage is fine.
        lun                  = 3
        label                = "SqlBackups"
        drive_letter         = "H"
        size_gb              = 4
        storage_account_type = "StandardSSD_LRS"
        allocation_unit_kb   = 64
        sql_role             = "backup"
      },
    ]
  }
}
