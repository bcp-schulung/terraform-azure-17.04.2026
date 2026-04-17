output "scale_set_id" {
  description = "ID of the Azure Linux VM scale set"
  value       = azurerm_linux_virtual_machine_scale_set.vmss.id
}

output "autoscale_setting_name" {
  description = "Name of the autoscale setting for the scale set"
  value       = azurerm_monitor_autoscale_setting.vmss.name
}
