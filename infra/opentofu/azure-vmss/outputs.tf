output "resource_group_name" {
  description = "Resource group containing the VMSS deployment."
  value       = azurerm_resource_group.vmss.name
}

output "virtual_network_name" {
  description = "Virtual network name for the worker environment."
  value       = azurerm_virtual_network.vmss.name
}

output "subnet_id" {
  description = "Worker subnet ID."
  value       = azurerm_subnet.vmss.id
}

output "vmss_id" {
  description = "Azure resource ID of the Windows VM scale set."
  value       = var.enable_vmss ? azurerm_windows_virtual_machine_scale_set.vmss[0].id : null
}

output "vmss_name" {
  description = "Name of the Windows VM scale set."
  value       = var.enable_vmss ? azurerm_windows_virtual_machine_scale_set.vmss[0].name : null
}

output "vmss_identity_principal_id" {
  description = "System-assigned managed identity principal ID for the VMSS."
  value       = var.enable_vmss ? azurerm_windows_virtual_machine_scale_set.vmss[0].identity[0].principal_id : null
}

output "nat_gateway_public_ip_address" {
  description = "Outbound public IP used by the NAT gateway, if enabled."
  value       = var.create_nat_gateway ? azurerm_public_ip.nat[0].ip_address : null
}

output "builder_vm_id" {
  description = "Azure resource ID of the standalone builder VM, if enabled."
  value       = var.enable_builder_vm ? azurerm_windows_virtual_machine.builder[0].id : null
}

output "builder_vm_name" {
  description = "Name of the standalone builder VM, if enabled."
  value       = var.enable_builder_vm ? azurerm_windows_virtual_machine.builder[0].name : null
}

output "builder_vm_public_ip_address" {
  description = "Public IP address for the standalone builder VM, if enabled."
  value       = var.enable_builder_vm ? azurerm_public_ip.builder[0].ip_address : null
}

output "builder_vm_public_fqdn" {
  description = "Azure-managed FQDN for the standalone builder VM public IP, if a DNS label is configured."
  value       = var.enable_builder_vm ? azurerm_public_ip.builder[0].fqdn : null
}

output "builder_vm_private_ip_address" {
  description = "Private IP address for the standalone builder VM, if enabled."
  value       = var.enable_builder_vm ? azurerm_network_interface.builder[0].private_ip_address : null
}

output "builder_vm_identity_principal_id" {
  description = "System-assigned managed identity principal ID for the standalone builder VM, if enabled."
  value       = var.enable_builder_vm ? azurerm_windows_virtual_machine.builder[0].identity[0].principal_id : null
}
