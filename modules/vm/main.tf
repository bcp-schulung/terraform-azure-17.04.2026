resource "azurerm_network_security_group" "nsg" {
  name                = "${var.prefix}-${var.vm_name}-nsg"
  location            = var.rg_location
  resource_group_name = var.rg_name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                 = "${var.prefix}-${var.vm_name}-vmss"
  resource_group_name  = var.rg_name
  location             = var.rg_location
  sku                  = var.vm_size
  instances            = var.instance_count
  admin_username       = var.admin_username
  computer_name_prefix = "node"
  upgrade_mode         = "Manual"
  overprovision        = false

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  network_interface {
    name                      = "${var.prefix}-${var.vm_name}-nic"
    primary                   = true
    network_security_group_id = azurerm_network_security_group.nsg.id

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = var.subnet_id

      public_ip_address {
        name = "${var.prefix}-${var.vm_name}-pip"
      }
    }
  }
}

resource "azurerm_monitor_autoscale_setting" "vmss" {
  name                = "${var.prefix}-${var.vm_name}-autoscale"
  resource_group_name = var.rg_name
  location            = var.rg_location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id

  profile {
    name = "cpu-based-scaling"

    capacity {
      default = tostring(var.instance_count)
      minimum = tostring(var.min_instances)
      maximum = tostring(var.max_instances)
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 75
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }
}