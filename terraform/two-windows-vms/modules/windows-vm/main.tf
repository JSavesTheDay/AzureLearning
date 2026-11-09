# One Windows VM with a public IP, NIC, data disks, one-time disk setup, and
# auto-shutdown. Resource names follow the Cloud Adoption Framework abbreviations
# (pip-, nic-, disk-): https://aka.ms/caf/abbreviations

locals {
  # Key each disk by its lowercase label, so for_each addresses stay stable
  # when disks are added or reordered.
  data_disks = { for d in var.data_disks : lower(d.label) => d }
}

resource "azurerm_public_ip" "this" {
  name                = "pip-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard" # Basic SKU public IPs were retired in Sept 2025
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  name                = "nic-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  name                  = var.name
  location              = var.location
  resource_group_name   = var.resource_group_name
  zone                  = var.zone
  size                  = var.size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.this.id]
  tags                  = var.tags

  # Trusted Launch: Secure Boot + virtual TPM. Microsoft's recommended baseline for Gen2 VMs.
  secure_boot_enabled = true
  vtpm_enabled        = true

  # AutomaticByPlatform: Azure applies OS patches during off-peak hours, with health checks.
  patch_mode                = var.patch_mode
  automatic_updates_enabled = var.patch_mode != "Manual"

  os_disk {
    caching              = "ReadWrite" # Microsoft's default for OS disks; don't change it
    storage_account_type = var.os_disk.storage_account_type
    disk_size_gb         = var.os_disk.size_gb
  }

  # Use full-size images (127 GB OS disk), which can grow to the size requested.
  # The -smalldisk images start at 30 GB.
  source_image_reference {
    publisher = var.source_image.publisher
    offer     = var.source_image.offer
    sku       = var.source_image.sku
    version   = var.source_image.version
  }

  # Managed boot diagnostics (no storage account needed): lets you see the
  # screenshot and serial log in the portal if a VM won't boot.
  boot_diagnostics {}
}

# --- Data disks -------------------------------------------------------------

resource "azurerm_managed_disk" "data" {
  for_each = local.data_disks

  name                 = "disk-${var.name}-${each.key}"
  location             = var.location
  resource_group_name  = var.resource_group_name
  zone                 = var.zone # a zonal VM's disks must be in the same zone
  storage_account_type = each.value.storage_account_type
  create_option        = "Empty"
  disk_size_gb         = each.value.size_gb
  tags                 = var.tags

  # Premium SSD v2 sets performance separately from size. null (unset in
  # tfvars) gives the free baseline (3,000 IOPS / 125 MB/s).
  disk_iops_read_write = each.value.iops
  disk_mbps_read_write = each.value.mbps
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each = local.data_disks

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.this.id
  lun                = each.value.lun
  caching            = each.value.caching
}

# --- One-time in-guest disk setup ---------------------------------------------

# Managed Run Command: Azure runs the script inside the VM once, when this
# resource is created, and again only if the script or parameters change.
# It never runs at boot, so it can't compete with hardening scripts.
resource "azurerm_virtual_machine_run_command" "disk_setup" {
  # count = 0 or 1 toggles a single resource on or off.
  count = var.run_disk_setup ? 1 : 0

  name               = "initialize-data-disks"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.this.id
  tags               = var.tags

  source {
    # path.module is this module's folder, wherever it's called from.
    script = file("${path.module}/scripts/Initialize-DataDisks.ps1")
  }

  # The disk layout is passed as Base64-encoded JSON so its quotes don't break
  # the command line that Run Command builds.
  parameter {
    name = "DiskLayoutBase64"
    value = base64encode(jsonencode([
      for d in var.data_disks : {
        lun              = d.lun
        label            = d.label
        driveLetter      = d.drive_letter
        allocationUnitKb = d.allocation_unit_kb
      }
    ]))
  }

  parameter {
    name  = "OpticalDriveLetter"
    value = var.optical_drive_letter
  }

  # All disks must be attached before the script looks for them.
  depends_on = [azurerm_virtual_machine_data_disk_attachment.data]
}

# --- SQL Server default folders (SQL Server images only) ------------------------

locals {
  # Folder for each sql_role, on that disk's volume. null when no disk has the role.
  sql_paths = {
    for role, folder in { data = "Data", log = "Log", backup = "Backup" } :
    role => one([for d in var.data_disks : "${d.drive_letter}:\\${folder}" if d.sql_role == role])
  }
}

# A second one-time Run Command: after the disks are formatted, point SQL Server's
# default data, log and backup folders at them.
resource "azurerm_virtual_machine_run_command" "sql_default_paths" {
  count = var.run_disk_setup && var.sql_server != null && anytrue([for d in var.data_disks : d.sql_role != null]) ? 1 : 0

  name               = "set-sql-default-paths"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.this.id
  tags               = var.tags

  source {
    script = file("${path.module}/scripts/Set-SqlDefaultPaths.ps1")
  }

  # One parameter per role that has a disk (DataPath, LogPath, BackupPath).
  # dynamic emits a block per map entry; roles without a disk are filtered out.
  dynamic "parameter" {
    for_each = { for role, path in local.sql_paths : role => path if path != null }
    content {
      name  = "${title(parameter.key)}Path"
      value = parameter.value
    }
  }

  # The volumes must exist, and Run Commands on one VM run one at a time.
  depends_on = [azurerm_virtual_machine_run_command.disk_setup]
}

# --- tempdb on the temp disk (SQL Server images only) ----------------------------

# A third one-time Run Command: moves tempdb to the temp disk and installs a startup
# task, because the temp disk comes back empty after deallocation. The script's
# default of 8 data files follows Microsoft's guidance of one per vCPU, up to 8,
# for target sizes with 8 or more vCPUs.
resource "azurerm_virtual_machine_run_command" "sql_tempdb" {
  count = var.run_disk_setup && var.sql_server != null ? 1 : 0

  name               = "set-sql-tempdb"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.this.id
  tags               = var.tags

  source {
    script = file("${path.module}/scripts/Set-SqlTempDb.ps1")
  }

  parameter {
    name  = "StartupScriptBase64"
    value = filebase64("${path.module}/scripts/Start-SqlOnTempDisk.ps1")
  }

  parameter {
    name  = "TempDbPath"
    value = var.sql_server.tempdb_path
  }

  # Run Commands are VM extensions. Azure rejects concurrent extension operations
  # on one VM, and both of these restart SQL Server, so run them one after another.
  depends_on = [
    azurerm_virtual_machine_run_command.disk_setup,
    azurerm_virtual_machine_run_command.sql_default_paths,
  ]
}

# Daily auto-shutdown: a safety net for Pay-As-You-Go cost.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  virtual_machine_id    = azurerm_windows_virtual_machine.this.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = var.tags

  notification_settings {
    enabled = false
  }
}
