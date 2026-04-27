terraform {
  required_version = ">= 1.6.0"

  backend "azurerm" {}

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}
