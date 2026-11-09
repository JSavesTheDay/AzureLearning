# Resource names follow the Cloud Adoption Framework abbreviations
# (rg-, vnet-, snet-, nsg-): https://aka.ms/caf/abbreviations
#
# The root module holds what all VMs share. Everything per VM lives in
# modules/windows-vm, called once per entry in var.vms.

locals {
  tags = {
    environment = "lab"
    managed_by  = "terraform"
    project     = "AzureLearning"
  }
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

# One generated password shared by all VMs. It is stored in the state file,
# which is why *.tfstate is gitignored. In production, use Key Vault or Entra ID login.
resource "random_password" "admin" {
  length      = 24
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

# --- VMs ----------------------------------------------------------------------

# for_each on a module block creates one module instance per VM:
# module.vm["web1"], module.vm["db01"].
module "vm" {
  source   = "./modules/windows-vm"
  for_each = var.vms

  name                = each.key
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.vms.id
  tags                = local.tags

  size         = each.value.size
  zone         = each.value.zone
  patch_mode   = each.value.patch_mode
  source_image = each.value.source_image
  os_disk      = each.value.os_disk
  data_disks   = each.value.data_disks
  sql_server   = each.value.sql_server

  admin_username = var.admin_username
  admin_password = random_password.admin.result

  run_disk_setup         = var.run_disk_setup
  optical_drive_letter   = var.optical_drive_letter
  auto_shutdown_time     = var.auto_shutdown_time
  auto_shutdown_timezone = var.auto_shutdown_timezone
}
