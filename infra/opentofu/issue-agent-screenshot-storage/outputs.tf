output "resource_group_name" {
  description = "Resource group containing screenshot evidence resources."
  value       = azurerm_resource_group.this.name
}

output "storage_account_name" {
  description = "Storage account that hosts public screenshot blobs."
  value       = azurerm_storage_account.screenshots.name
}

output "container_name" {
  description = "Public-read screenshot container name."
  value       = azurerm_storage_container.screenshots.name
}

output "container_url" {
  description = "Base public URL for screenshot blobs."
  value       = "https://${azurerm_storage_account.screenshots.name}.blob.core.windows.net/${azurerm_storage_container.screenshots.name}"
}

output "github_uploader_client_id" {
  description = "Client ID for azure/login from GitHub Actions."
  value       = azurerm_user_assigned_identity.github_uploader.client_id
}

output "github_uploader_principal_id" {
  description = "Principal ID granted Storage Blob Data Contributor on the screenshot storage account."
  value       = azurerm_user_assigned_identity.github_uploader.principal_id
}