terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.65.0"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    resource_group_name = "rg-tf-lab"
    storage_account_name = "tfstateseminar"
    container_name = "tfstate"
    key = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}