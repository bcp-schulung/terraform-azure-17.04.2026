data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

module "network" {
  source = "./modules/network"

  prefix      = var.prefix
  rg_location = data.azurerm_resource_group.rg.location
  rg_name     = data.azurerm_resource_group.rg.name
}

module "vm" {
  source = "./modules/vm"

  prefix      = var.prefix
  rg_location = data.azurerm_resource_group.rg.location
  rg_name     = data.azurerm_resource_group.rg.name
  subnet_id   = module.network.subnet_id
}

module "vm-test" {
  source = "./modules/vm"

  prefix      = "${var.prefix}-test"
  rg_location = data.azurerm_resource_group.rg.location
  rg_name     = data.azurerm_resource_group.rg.name
  subnet_id   = module.network.subnet_id
}