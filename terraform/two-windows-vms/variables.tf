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
  description = "Daily shutdown time (24h HHMM) to cap cost if you forget to destroy."
  type        = string
  default     = "1900"
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID for the shutdown schedule."
  type        = string
  default     = "Central Standard Time"
}

# One entry per VM, keyed by VM name. Each entry is passed to modules/windows-vm,
# which owns the defaults (caching "None", 4 KB allocation units) and all disk
# validation. Optional attributes left unset here arrive as null, and the module
# replaces them with its defaults.
variable "vms" {
  description = "VMs to create, keyed by VM name. See modules/windows-vm/variables.tf for rules."
  type = map(object({
    size = string
    zone = optional(string)

    os_disk = object({
      size_gb              = number
      storage_account_type = string
    })

    data_disks = optional(list(object({
      lun                  = number
      label                = string
      drive_letter         = string
      size_gb              = number
      storage_account_type = string
      caching              = optional(string)
      allocation_unit_kb   = optional(number)
      iops                 = optional(number)
      mbps                 = optional(number)
    })), [])
  }))
}
