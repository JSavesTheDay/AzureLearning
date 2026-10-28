output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vm_public_ips" {
  description = "Map of VM name to public IP."
  value       = { for name, pip in azurerm_public_ip.vm : name => pip.ip_address }
}

output "rdp_commands" {
  description = "Run one of these to open Remote Desktop."
  value       = { for name, pip in azurerm_public_ip.vm : name => "mstsc /v:${pip.ip_address}" }
}

output "admin_username" {
  value = var.admin_username
}

output "admin_password" {
  description = "Read with: terraform output -raw admin_password"
  value       = random_password.admin.result
  sensitive   = true
}
