# VM inventory. No secrets belong in this file: the admin password is generated,
# and your IP comes from the TF_VAR_allowed_rdp_source_ip environment variable.
#
# Disk sizes are POC minimums (4 GiB standard/premium SSD, 1 GiB Premium SSD v2).
# Caching and allocation units follow Microsoft's SQL Server on Azure VM guidance.
# LUNs are sequential in drive-letter order (D: = 0, E: = 1, ...).

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
      { lun = 0, label = "Application", drive_letter = "D", size_gb = 4, storage_account_type = "StandardSSD_LRS" },
      { lun = 1, label = "SQLTemp", drive_letter = "E", size_gb = 4, storage_account_type = "StandardSSD_LRS", caching = "ReadOnly", allocation_unit_kb = 64 },
      { lun = 2, label = "SqlData", drive_letter = "F", size_gb = 1, storage_account_type = "PremiumV2_LRS", allocation_unit_kb = 64 },
      { lun = 3, label = "SqlLogs", drive_letter = "G", size_gb = 1, storage_account_type = "PremiumV2_LRS", allocation_unit_kb = 64 },
      { lun = 4, label = "SqlBackups", drive_letter = "H", size_gb = 4, storage_account_type = "StandardSSD_LRS", allocation_unit_kb = 64 },
    ]
  }
}
