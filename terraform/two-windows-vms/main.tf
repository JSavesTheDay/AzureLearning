# Resource names follow the Cloud Adoption Framework abbreviations
# (rg-, vnet-, snet-, nsg-, pip-, nic-, disk-): https://aka.ms/caf/abbreviations

locals {
  tags = {
    environment = "lab"
    managed_by  = "terraform"
    project     = "AzureLearning"
  }

  # Flatten vms -> data_disks into one map keyed "<vm>-<label>", so for_each can
  # create one managed disk and one attachment per entry.
  data_disks = merge([
    for vm_name, vm in var.vms : {
      for disk in vm.data_disks : "${vm_name}-${lower(disk.label)}" => merge(disk, {
        vm_name = vm_name
        zone    = vm.zone
      })
    }
  ]...)
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.prefix}-${var.location}"
  location = var.location
  tags     = local.tags
}

# --- Networking -------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.10.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "vms" {
  name                 = "snet-vms"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.10.1.0/24"]

  # Private subnet: no implicit internet egress. The VMs still reach the
  # internet through their own public IPs. This matches Azure's current default.
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "vms" {
  name                = "nsg-${var.prefix}-vms"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  security_rule {
    name                       = "Allow-RDP-From-My-IP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "${var.allowed_rdp_source_ip}/32"
    destination_address_prefix = "*"
  }
}

# Attach the NSG at the subnet so every VM in it gets the same rules.
resource "azurerm_subnet_network_security_group_association" "vms" {
  subnet_id                 = azurerm_subnet.vms.id
  network_security_group_id = azurerm_network_security_group.vms.id
}

# --- Per-VM resources (for_each creates one of each per VM) -----------------

resource "azurerm_public_ip" "vm" {
  for_each = var.vms

  name                = "pip-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard" # Basic SKU public IPs were retired in Sept 2025
  tags                = local.tags
}

resource "azurerm_network_interface" "vm" {
  for_each = var.vms

  name                = "nic-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vms.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }
}

# One generated password shared by all VMs. It is stored in the state file,
# which is why *.tfstate is gitignored. In production, use Key Vault or Entra ID login.
resource "random_password" "admin" {
  length      = 24
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "azurerm_windows_virtual_machine" "this" {
  for_each = var.vms

  name                  = each.key
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  zone                  = each.value.zone
  size                  = each.value.size
  admin_username        = var.admin_username
  admin_password        = random_password.admin.result
  network_interface_ids = [azurerm_network_interface.vm[each.key].id]
  tags                  = local.tags

  # Trusted Launch: Secure Boot + virtual TPM. Microsoft's recommended baseline for Gen2 VMs.
  secure_boot_enabled = true
  vtpm_enabled        = true

  # Azure applies OS patches during off-peak hours, with health checks.
  patch_mode                = "AutomaticByPlatform"
  automatic_updates_enabled = true

  os_disk {
    caching              = "ReadWrite" # Microsoft's default for OS disks; don't change it
    storage_account_type = each.value.os_disk.storage_account_type
    disk_size_gb         = each.value.os_disk.size_gb
  }

  # Full-size image (127 GB OS disk), which can grow to the 128 GB requested.
  # The -smalldisk images start at 30 GB.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-azure-edition"
    version   = "latest"
  }

  # Managed boot diagnostics (no storage account needed): lets you see the
  # screenshot and serial log in the portal if a VM won't boot.
  boot_diagnostics {}
}

# --- Data disks -------------------------------------------------------------

resource "azurerm_managed_disk" "data" {
  for_each = local.data_disks

  name                 = "disk-${each.value.vm_name}-${lower(each.value.label)}"
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  zone                 = each.value.zone # a zonal VM's disks must be in the same zone
  storage_account_type = each.value.storage_account_type
  create_option        = "Empty"
  disk_size_gb         = each.value.size_gb
  tags                 = local.tags

  # Premium SSD v2 sets performance separately from size. null (unset in
  # tfvars) gives the free baseline (3,000 IOPS / 125 MB/s).
  disk_iops_read_write = each.value.iops
  disk_mbps_read_write = each.value.mbps
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each = local.data_disks

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.this[each.value.vm_name].id
  lun                = each.value.lun
  caching            = each.value.caching
}

# --- One-time in-guest disk setup ---------------------------------------------

# Managed Run Command: Azure runs the script inside the VM once, when this
# resource is created, and again only if the script or parameters change.
# It never runs at boot, so it can't compete with hardening scripts.
resource "azurerm_virtual_machine_run_command" "disk_setup" {
  for_each = var.vms

  name               = "initialize-data-disks"
  location           = azurerm_resource_group.this.location
  virtual_machine_id = azurerm_windows_virtual_machine.this[each.key].id
  tags               = local.tags

  source {
    script = file("${path.module}/scripts/Initialize-DataDisks.ps1")
  }

  # The disk layout is passed as Base64-encoded JSON so its quotes don't break
  # the command line that Run Command builds.
  parameter {
    name = "DiskLayoutBase64"
    value = base64encode(jsonencode([
      for d in each.value.data_disks : {
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

# Daily auto-shutdown: a safety net for Pay-As-You-Go cost.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  for_each = var.vms

  virtual_machine_id    = azurerm_windows_virtual_machine.this[each.key].id
  location              = azurerm_resource_group.this.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
