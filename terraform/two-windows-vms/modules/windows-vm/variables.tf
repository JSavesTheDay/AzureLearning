# Inputs for ONE Windows VM. The root module calls this with for_each, once per VM.
# Defaults and validation live here, so every caller gets the same rules.

variable "name" {
  description = "VM name, also used as the Windows computer name."
  type        = string

  validation {
    condition     = length(var.name) <= 15
    error_message = "VM names must be 15 characters or fewer (Windows computer name limit)."
  }
}

variable "resource_group_name" {
  description = "Resource group to create the VM and its resources in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the VM's network interface."
  type        = string
}

variable "size" {
  description = "VM size, e.g. Standard_B2als_v2."
  type        = string
}

variable "zone" {
  description = "Availability zone. Required when any data disk is PremiumV2_LRS."
  type        = string
  default     = null
}

# nullable = false: a caller passing null gets the default instead of null.
variable "source_image" {
  description = "Marketplace image. Defaults to Windows Server 2025 Datacenter: Azure Edition."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = optional(string, "latest")
  })
  nullable = false
  default = {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-azure-edition"
  }
}

# AutomaticByPlatform (Azure orchestrates patching with health checks) supports
# only some images: https://aka.ms/VMGuestPatchingCompatibility
# SQL Server images aren't on the list and need AutomaticByOS (Windows Update).
variable "patch_mode" {
  description = "Guest OS patching: AutomaticByPlatform, AutomaticByOS, or Manual."
  type        = string
  nullable    = false
  default     = "AutomaticByPlatform"

  validation {
    condition     = contains(["AutomaticByPlatform", "AutomaticByOS", "Manual"], var.patch_mode)
    error_message = "patch_mode must be AutomaticByPlatform, AutomaticByOS, or Manual."
  }
}

# Set only for a SQL Server image. Puts tempdb on the temp disk (D:), where a startup
# task re-creates the folders and permissions after the disk is wiped.
variable "sql_server" {
  description = "SQL Server settings. null = not a SQL Server VM."
  type = object({
    tempdb_path = optional(string, "D:\\tempDb")
  })
  default = null
}

variable "admin_username" {
  description = "Local administrator username."
  type        = string
}

variable "admin_password" {
  description = "Local administrator password."
  type        = string
  sensitive   = true
}

variable "os_disk" {
  description = "OS disk size and storage type."
  type = object({
    size_gb              = number
    storage_account_type = string
  })
}

# Each data disk sets its LUN explicitly, so reordering or inserting disks never
# renumbers others. The setup script uses the LUN to find each disk in Windows.
variable "data_disks" {
  description = "Data disks to create, attach, and format."
  type = list(object({
    lun                  = number # 0-63; convention here: sequential in drive-letter order
    label                = string # NTFS volume label, also used in the Azure disk name
    drive_letter         = string
    size_gb              = number
    storage_account_type = string
    caching              = optional(string, "None")
    allocation_unit_kb   = optional(number, 4) # use 64 for SQL Server data, log, tempdb, and backup volumes

    # Premium SSD v2 only: performance is set independently of size.
    # Unset = free baseline (3,000 IOPS / 125 MB/s). Higher values add cost.
    iops = optional(number)
    mbps = optional(number)

    # "data", "log" or "backup": makes <drive_letter>:\Data, \Log or \Backup SQL
    # Server's default folder for that role (Set-SqlDefaultPaths.ps1).
    sql_role = optional(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for d in var.data_disks : d.sql_role == null || (contains(["data", "log", "backup"], coalesce(d.sql_role, "none")) && var.sql_server != null)
    ])
    error_message = "sql_role must be \"data\", \"log\" or \"backup\", and only on a SQL Server VM (sql_server set)."
  }

  # SQL Server has one default folder per role.
  validation {
    condition = alltrue([
      for role in ["data", "log", "backup"] : length([for d in var.data_disks : d if d.sql_role == role]) <= 1
    ])
    error_message = "At most one data disk per sql_role."
  }

  validation {
    condition     = alltrue([for d in var.data_disks : can(regex("^[D-Y]$", d.drive_letter))])
    error_message = "Data disk drive letters must be a single uppercase letter from D to Y (C is the OS, Z is reserved for optical drives)."
  }

  validation {
    condition = (
      length(distinct([for d in var.data_disks : d.drive_letter])) == length(var.data_disks) &&
      length(distinct([for d in var.data_disks : lower(d.label)])) == length(var.data_disks)
    )
    error_message = "Drive letters and labels must be unique within each VM."
  }

  validation {
    condition = (
      length(distinct([for d in var.data_disks : d.lun])) == length(var.data_disks) &&
      alltrue([for d in var.data_disks : d.lun >= 0 && d.lun <= 63 && floor(d.lun) == d.lun])
    )
    error_message = "Each data disk needs a unique whole-number lun from 0 to 63 within its VM."
  }

  validation {
    condition = alltrue([
      for d in var.data_disks : contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS", "PremiumV2_LRS"], d.storage_account_type)
    ])
    error_message = "storage_account_type must be Standard_LRS, StandardSSD_LRS, Premium_LRS, or PremiumV2_LRS."
  }

  # Validations can reference other variables (Terraform 1.9+), here var.zone.
  validation {
    condition = alltrue([
      for d in var.data_disks : d.storage_account_type != "PremiumV2_LRS" || (var.zone != null && d.caching == "None")
    ])
    error_message = "PremiumV2_LRS disks require the VM to have a zone and caching = \"None\" (no host caching support)."
  }

  validation {
    condition     = alltrue([for d in var.data_disks : contains([4, 8, 16, 32, 64], d.allocation_unit_kb)])
    error_message = "allocation_unit_kb must be 4, 8, 16, 32, or 64."
  }

  validation {
    condition = alltrue([
      for d in var.data_disks : (d.iops == null && d.mbps == null) || d.storage_account_type == "PremiumV2_LRS"
    ])
    error_message = "iops and mbps can only be set on PremiumV2_LRS disks."
  }

  # Premium SSD v2 IOPS: 3,000 baseline; max = 500 per GiB (never below 3,000), capped at 80,000.
  # coalesce() substitutes the baseline for unset values, so no comparison ever sees null.
  validation {
    condition = alltrue([
      for d in var.data_disks :
      floor(coalesce(d.iops, 3000)) == coalesce(d.iops, 3000) &&
      coalesce(d.iops, 3000) >= 3000 &&
      coalesce(d.iops, 3000) <= min(80000, max(3000, 500 * d.size_gb))
    ])
    error_message = "Premium SSD v2 iops must be a whole number from 3000 to min(80000, max(3000, 500 x size_gb))."
  }

  # Premium SSD v2 throughput: 125 MB/s baseline. Disks of 6 GiB or less stay at 125.
  # Larger disks allow up to 0.25 MB/s per provisioned IOPS, capped at 2,000.
  validation {
    condition = alltrue([
      for d in var.data_disks :
      floor(coalesce(d.mbps, 125)) == coalesce(d.mbps, 125) &&
      coalesce(d.mbps, 125) >= 125 &&
      coalesce(d.mbps, 125) <= (d.size_gb <= 6 ? 125 : min(2000, max(125, 0.25 * coalesce(d.iops, 3000))))
    ])
    error_message = "Premium SSD v2 mbps must be a whole number from 125 up to 0.25 x iops (max 2000); disks of 6 GiB or less are fixed at 125."
  }
}

variable "run_disk_setup" {
  description = "Run the one-time in-guest disk setup. Set false to deploy first and inspect the raw drive state."
  type        = bool
  default     = true
}

variable "optical_drive_letter" {
  description = "Drive letter that any CD/DVD drive is moved to, freeing D: and later letters for data disks."
  type        = string
  default     = "Z"
}

variable "auto_shutdown_time" {
  description = "Daily shutdown time (24h HHMM)."
  type        = string
  default     = "1900"
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID for the shutdown schedule."
  type        = string
  default     = "Central Standard Time"
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}
