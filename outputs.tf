output "public_ip" {
  value = azurerm_public_ip.pip[*].ip_address
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.vm[*].name
}

output "ssh_command" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.pip[0].ip_address}"
}