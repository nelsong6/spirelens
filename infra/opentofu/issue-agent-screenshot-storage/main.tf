locals {
  storage_account_name = substr("${var.name_prefix}${random_string.storage_suffix.result}", 0, 24)

  federated_subjects = {
    for idx, subject in var.github_federated_subjects : tostring(idx) => subject
  }
}

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "screenshots" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = true
  shared_access_key_enabled       = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "screenshots" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.screenshots.id
  container_access_type = "blob"
}

resource "azurerm_user_assigned_identity" "github_uploader" {
  name                = "${var.name_prefix}-github-uploader"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "github" {
  for_each            = local.federated_subjects
  name                = "github-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.github_uploader.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = each.value
}

resource "azurerm_role_assignment" "blob_data_contributor" {
  scope                = azurerm_storage_account.screenshots.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_uploader.principal_id
}

resource "azurerm_storage_management_policy" "screenshots" {
  count              = var.retention_days > 0 ? 1 : 0
  storage_account_id = azurerm_storage_account.screenshots.id

  rule {
    name    = "delete-old-issue-agent-screenshots"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.retention_days
      }
    }
  }
}