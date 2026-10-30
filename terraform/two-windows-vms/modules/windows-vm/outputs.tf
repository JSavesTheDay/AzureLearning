output "id" {
  description = "VM resource ID."
  value       = azurerm_windows_virtual_machine.this.id
}

output "public_ip_address" {
  description = "VM public IP address."
  value       = azurerm_public_ip.this.ip_address
}

output "private_ip_address" {
  description = "VM private IP address."
  value       = azurerm_network_interface.this.private_ip_address
}
