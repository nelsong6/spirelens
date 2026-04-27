terraform {
  required_version = ">= 1.6.0"

  backend "azurerm" {}
}

provider "azurerm" {
  features {}

  storage_use_azuread = true
}
