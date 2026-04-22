locals {
  resource_group_name    = coalesce(var.resource_group_name, "rg-${var.name_prefix}")
  vnet_name              = coalesce(var.vnet_name, "vnet-${var.name_prefix}")
  subnet_name            = coalesce(var.subnet_name, "snet-${var.name_prefix}")
  nsg_name               = coalesce(var.nsg_name, "nsg-${var.name_prefix}")
  nat_gateway_name       = coalesce(var.nat_gateway_name, "nat-${var.name_prefix}")
  nat_public_ip_name     = coalesce(var.nat_public_ip_name, "pip-${var.name_prefix}-nat")
  vmss_name              = coalesce(var.vmss_name, "vmss-${var.name_prefix}")
  computer_name_prefix   = coalesce(var.computer_name_prefix, substr(replace(var.name_prefix, "-", ""), 0, 15))
  builder_vm_name        = coalesce(var.builder_vm_name, "vm-${var.name_prefix}-builder")
  builder_nic_name       = coalesce(var.builder_nic_name, "nic-${var.name_prefix}-builder")
  builder_public_ip_name = coalesce(var.builder_public_ip_name, "pip-${var.name_prefix}-builder")
  builder_computer_name  = coalesce(var.builder_computer_name, substr(replace(local.builder_vm_name, "-", ""), 0, 15))

  tags = merge(
    {
      "managed-by" = "opentofu"
      "repo"       = "CardUtilityStats"
      "workload"   = "sts2-live-worker"
    },
    var.tags
  )

  vmss_tags = merge(
    local.tags,
    {
      "role" = "worker-vmss"
    }
  )

  builder_tags = merge(
    local.tags,
    {
      "role" = "builder-vm"
    }
  )
}

resource "azurerm_resource_group" "vmss" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "vmss" {
  name                = local.vnet_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "vmss" {
  name                            = local.subnet_name
  resource_group_name             = azurerm_resource_group.vmss.name
  virtual_network_name            = azurerm_virtual_network.vmss.name
  address_prefixes                = var.subnet_address_prefixes
  default_outbound_access_enabled = var.subnet_default_outbound_access_enabled
}

resource "azurerm_network_security_group" "vmss" {
  name                = local.nsg_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "rdp" {
  count = var.enable_rdp_rule && length(var.rdp_allowed_cidrs) > 0 ? 1 : 0

  name                        = "allow-rdp"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefixes     = var.rdp_allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.vmss.name
  network_security_group_name = azurerm_network_security_group.vmss.name
}

resource "azurerm_subnet_network_security_group_association" "vmss" {
  subnet_id                 = azurerm_subnet.vmss.id
  network_security_group_id = azurerm_network_security_group.vmss.id
}

resource "azurerm_public_ip" "nat" {
  count = var.create_nat_gateway ? 1 : 0

  name                = local.nat_public_ip_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = length(var.zones) == 0 ? null : var.zones
  tags                = local.tags
}

resource "azurerm_nat_gateway" "vmss" {
  count = var.create_nat_gateway ? 1 : 0

  name                    = local.nat_gateway_name
  location                = azurerm_resource_group.vmss.location
  resource_group_name     = azurerm_resource_group.vmss.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = var.nat_idle_timeout_in_minutes
  zones                   = length(var.zones) == 0 ? null : var.zones
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "vmss" {
  count = var.create_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.vmss[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "vmss" {
  count = var.create_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.vmss.id
  nat_gateway_id = azurerm_nat_gateway.vmss[0].id
}

resource "azurerm_windows_virtual_machine_scale_set" "vmss" {
  count = var.enable_vmss ? 1 : 0

  name                = local.vmss_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  sku                 = var.vm_sku
  instances           = var.instance_count

  admin_username       = var.admin_username
  admin_password       = var.admin_password
  computer_name_prefix = local.computer_name_prefix

  encryption_at_host_enabled = var.encryption_at_host_enabled
  secure_boot_enabled        = var.secure_boot_enabled
  vtpm_enabled               = var.vtpm_enabled
  overprovision              = false
  upgrade_mode               = var.upgrade_mode
  zones                      = length(var.zones) == 0 ? null : var.zones
  source_image_id            = var.source_image_id

  dynamic "source_image_reference" {
    for_each = var.source_image_id == null ? [var.marketplace_image] : []

    content {
      publisher = source_image_reference.value.publisher
      offer     = source_image_reference.value.offer
      sku       = source_image_reference.value.sku
      version   = source_image_reference.value.version
    }
  }

  os_disk {
    caching              = var.os_disk_caching
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.os_disk_size_gb
  }

  network_interface {
    name    = "${var.name_prefix}-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.vmss.id
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.vmss_tags

  lifecycle {
    precondition {
      condition     = var.instance_count >= 1
      error_message = "instance_count must be at least 1 when enable_vmss is true."
    }
  }
}

resource "azurerm_public_ip" "builder" {
  count = var.enable_builder_vm ? 1 : 0

  name                = local.builder_public_ip_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = length(var.zones) == 0 ? null : var.zones
  tags                = local.builder_tags
}

resource "azurerm_network_interface" "builder" {
  count = var.enable_builder_vm ? 1 : 0

  name                = local.builder_nic_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  tags                = local.builder_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vmss.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.builder[0].id
  }
}

resource "azurerm_windows_virtual_machine" "builder" {
  count = var.enable_builder_vm ? 1 : 0

  name                = local.builder_vm_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  size                = var.builder_vm_sku

  admin_username = var.admin_username
  admin_password = var.admin_password

  computer_name         = local.builder_computer_name
  network_interface_ids = [azurerm_network_interface.builder[0].id]
  source_image_id       = var.builder_source_image_id

  encryption_at_host_enabled = var.encryption_at_host_enabled
  secure_boot_enabled        = var.secure_boot_enabled
  vtpm_enabled               = var.vtpm_enabled

  dynamic "source_image_reference" {
    for_each = var.builder_source_image_id == null ? [var.builder_marketplace_image] : []

    content {
      publisher = source_image_reference.value.publisher
      offer     = source_image_reference.value.offer
      sku       = source_image_reference.value.sku
      version   = source_image_reference.value.version
    }
  }

  os_disk {
    caching              = var.os_disk_caching
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.os_disk_size_gb
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.builder_tags
}
