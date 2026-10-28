variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = "Short name used in shared resource names (e.g. rg-<prefix>)."
  type        = string
  default     = "lab"
}

variable "admin_username" {
  description = "Local administrator username. Azure blocks common names like 'admin' and 'administrator'."
  type        = string
  default     = "azureadmin"
}

variable "allowed_rdp_source_ip" {
  description = "Your public IPv4 address. Only this address can reach RDP (port 3389)."
  type        = string

  validation {
    condition     = can(cidrhost("${var.allowed_rdp_source_ip}/32", 0))
    error_message = "Must be a single IPv4 address, e.g. 203.0.113.10."
  }
}

variable "optical_drive_letter" {
  description = "Drive letter that any CD/DVD drive is moved to, freeing D: and later letters for data disks."
  type        = string
  default     = "Z"
}

variable "auto_shutdown_time" {
  description = "Daily shutdown time (24h HHMM) to cap cost if you forget to destroy."
  type        = string
  default     = "1900"
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID for the shutdown schedule."
  type        = string
  default     = "Central Standard Time"
}

# One entry per VM, keyed by VM name. Data disks are attached in list order:
# the list index becomes the LUN, which the setup script uses to find each disk in Windows.
variable "vms" {
  description = "VMs to create, keyed by VM name."
  type = map(object({
    size = string
    zone = optional(string) # required when any data disk is PremiumV2_LRS

    os_disk = object({
      size_gb              = number
      storage_account_type = string
    })

    data_disks = optional(list(object({
      label                = string # NTFS volume label, also used in the Azure disk name
      drive_letter         = string
      size_gb              = number
      storage_account_type = string
      caching              = optional(string, "None")
      allocation_unit_kb   = optional(number, 4) # use 64 for SQL Server data, log, tempdb, and backup volumes
    })), [])
  }))

  validation {
    condition     = alltrue([for name in keys(var.vms) : length(name) <= 15])
    error_message = "VM names must be 15 characters or fewer (Windows computer name limit)."
  }

  validation {
    condition = alltrue(flatten([
      for vm in values(var.vms) : [for d in vm.data_disks : can(regex("^[D-Y]$", d.drive_letter))]
    ]))
    error_message = "Data disk drive letters must be a single uppercase letter from D to Y (C is the OS, Z is reserved for optical drives)."
  }

  validation {
    condition = alltrue([
      for vm in values(var.vms) :
      length(distinct([for d in vm.data_disks : d.drive_letter])) == length(vm.data_disks) &&
      length(distinct([for d in vm.data_disks : lower(d.label)])) == length(vm.data_disks)
    ])
    error_message = "Drive letters and labels must be unique within each VM."
  }

  validation {
    condition = alltrue(flatten([
      for vm in values(var.vms) : [
        for d in vm.data_disks : contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS", "PremiumV2_LRS"], d.storage_account_type)
      ]
    ]))
    error_message = "storage_account_type must be Standard_LRS, StandardSSD_LRS, Premium_LRS, or PremiumV2_LRS."
  }

  validation {
    condition = alltrue(flatten([
      for vm in values(var.vms) : [
        for d in vm.data_disks : d.storage_account_type != "PremiumV2_LRS" || (vm.zone != null && d.caching == "None")
      ]
    ]))
    error_message = "PremiumV2_LRS disks require the VM to have a zone and caching = \"None\" (no host caching support)."
  }

  validation {
    condition = alltrue(flatten([
      for vm in values(var.vms) : [for d in vm.data_disks : contains([4, 8, 16, 32, 64], d.allocation_unit_kb)]
    ]))
    error_message = "allocation_unit_kb must be 4, 8, 16, 32, or 64."
  }
}
