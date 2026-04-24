locals {
  resource_group_name            = coalesce(var.resource_group_name, "rg-${var.name_prefix}")
  vnet_name                      = coalesce(var.vnet_name, "vnet-${var.name_prefix}")
  subnet_name                    = coalesce(var.subnet_name, "snet-${var.name_prefix}")
  nsg_name                       = coalesce(var.nsg_name, "nsg-${var.name_prefix}")
  nat_gateway_name               = coalesce(var.nat_gateway_name, "nat-${var.name_prefix}")
  nat_public_ip_name             = coalesce(var.nat_public_ip_name, "pip-${var.name_prefix}-nat")
  vmss_name                      = coalesce(var.vmss_name, "vmss-${var.name_prefix}")
  computer_name_prefix           = coalesce(var.computer_name_prefix, substr(replace(var.name_prefix, "-", ""), 0, 15))
  builder_vm_name                = coalesce(var.builder_vm_name, "vm-${var.name_prefix}-builder")
  builder_nic_name               = coalesce(var.builder_nic_name, "nic-${var.name_prefix}-builder")
  builder_public_ip_name         = coalesce(var.builder_public_ip_name, "pip-${var.name_prefix}-builder")
  builder_computer_name          = coalesce(var.builder_computer_name, substr(replace(local.builder_vm_name, "-", ""), 0, 15))
  effective_admin_password       = var.admin_password != null ? var.admin_password : data.azurerm_key_vault_secret.admin_password[0].value
  rdp_allowed_cidrs_secret_value = length(var.rdp_allowed_cidrs) > 0 || var.rdp_allowed_cidrs_secret_name == null ? null : nonsensitive(data.azurerm_key_vault_secret.rdp_allowed_cidrs[0].value)
  effective_rdp_allowed_cidrs = length(var.rdp_allowed_cidrs) > 0 ? var.rdp_allowed_cidrs : (
    var.rdp_allowed_cidrs_secret_name == null ? [] : (
      can(jsondecode(local.rdp_allowed_cidrs_secret_value))
      ? tolist(jsondecode(local.rdp_allowed_cidrs_secret_value))
      : [for cidr in split(",", trimsuffix(trimprefix(trimspace(local.rdp_allowed_cidrs_secret_value), "["), "]")) : trimspace(cidr) if trimspace(cidr) != ""]
    )
  )
  effective_enable_rdp_rule        = var.enable_rdp_rule || length(local.effective_rdp_allowed_cidrs) > 0
  winrm_allowed_cidrs_secret_value = length(var.winrm_allowed_cidrs) > 0 || var.winrm_allowed_cidrs_secret_name == null ? null : nonsensitive(data.azurerm_key_vault_secret.winrm_allowed_cidrs[0].value)
  effective_winrm_allowed_cidrs = length(var.winrm_allowed_cidrs) > 0 ? var.winrm_allowed_cidrs : (
    var.winrm_allowed_cidrs_secret_name == null ? [] : (
      can(jsondecode(local.winrm_allowed_cidrs_secret_value))
      ? tolist(jsondecode(local.winrm_allowed_cidrs_secret_value))
      : [for cidr in split(",", trimsuffix(trimprefix(trimspace(local.winrm_allowed_cidrs_secret_value), "["), "]")) : trimspace(cidr) if trimspace(cidr) != ""]
    )
  )
  effective_enable_winrm_rule = var.enable_winrm_rule || length(local.effective_winrm_allowed_cidrs) > 0

  issue_agent_runner_labels = [
    for label in var.issue_agent_runner_labels : trimspace(label)
    if trimspace(label) != ""
  ]
  issue_agent_runner_labels_csv           = join(",", local.issue_agent_runner_labels)
  issue_agent_runner_script_relative_path = "ops/windows-worker/Initialize-IssueAgentRunner.ps1"
  issue_agent_runner_script_source_path   = "${path.root}/../../../${local.issue_agent_runner_script_relative_path}"
  issue_agent_runner_group                = try(trimspace(var.issue_agent_runner_group), "")
  vmss_image_is_specialized               = var.vmss_image_os_state == "specialized"
  vmss_image_reference = var.source_image_id == null ? {
    publisher = var.marketplace_image.publisher
    offer     = var.marketplace_image.offer
    sku       = var.marketplace_image.sku
    version   = var.marketplace_image.version
    } : {
    id = var.source_image_id
  }
  vmss_security_profile = var.encryption_at_host_enabled || var.secure_boot_enabled || var.vtpm_enabled ? merge(
    var.encryption_at_host_enabled ? {
      encryptionAtHost = true
    } : {},
    var.secure_boot_enabled || var.vtpm_enabled ? {
      uefiSettings = {
        secureBootEnabled = var.secure_boot_enabled
        vTpmEnabled       = var.vtpm_enabled
      }
    } : {},
  ) : null
  vmss_virtual_machine_profile = merge(
    {
      extensionProfile = {
        extensionsTimeBudget = "PT1H30M"
      }
      networkProfile = {
        networkInterfaceConfigurations = [
          {
            name = "${var.name_prefix}-nic"
            properties = {
              enableAcceleratedNetworking = false
              enableIPForwarding          = false
              ipConfigurations = [
                {
                  name = "internal"
                  properties = {
                    primary                 = true
                    privateIPAddressVersion = "IPv4"
                    subnet = {
                      id = azurerm_subnet.vmss.id
                    }
                  }
                },
              ]
              primary = true
            }
          },
        ]
      }
      priority = "Regular"
      storageProfile = {
        dataDisks      = []
        imageReference = local.vmss_image_reference
        osDisk = {
          caching      = var.os_disk_caching
          createOption = "FromImage"
          diskSizeGB   = var.os_disk_size_gb
          managedDisk = {
            storageAccountType = var.os_disk_storage_account_type
          }
          osType = "Windows"
        }
      }
    },
    local.vmss_image_is_specialized ? {} : {
      osProfile = {
        adminPassword            = local.effective_admin_password
        adminUsername            = var.admin_username
        allowExtensionOperations = true
        computerNamePrefix       = local.computer_name_prefix
        windowsConfiguration = {
          enableAutomaticUpdates = true
          provisionVMAgent       = true
        }
      }
    },
    local.vmss_image_is_specialized ? {
      osProfile = {
        allowExtensionOperations = true
      }
    } : {},
    local.vmss_security_profile == null ? {} : {
      securityProfile = local.vmss_security_profile
    },
  )
  issue_agent_runner_script_url = format(
    "https://raw.githubusercontent.com/%s/%s/%s?v=%s",
    var.issue_agent_repository_slug,
    var.issue_agent_runner_script_ref,
    local.issue_agent_runner_script_relative_path,
    substr(filesha256(local.issue_agent_runner_script_source_path), 0, 12),
  )
  issue_agent_runner_extension_command = format(
    "powershell.exe -ExecutionPolicy Bypass -File Initialize-IssueAgentRunner.ps1 -RepositorySlug \"%s\" -RepositoryUrl \"%s\" -KeyVaultName \"%s\" -KeyVaultUri \"%s\" -GitHubPatSecretName \"%s\" -RunnerRoot \"%s\" -RunnerLabels \"%s\" -RunnerNamePrefix \"%s\"",
    var.issue_agent_repository_slug,
    "https://github.com/${var.issue_agent_repository_slug}",
    data.azurerm_key_vault.shared.name,
    data.azurerm_key_vault.shared.vault_uri,
    var.issue_agent_runner_pat_secret_name,
    var.issue_agent_runner_root,
    local.issue_agent_runner_labels_csv,
    var.issue_agent_runner_name_prefix,
  )
  issue_agent_runner_extension_command_with_group = local.issue_agent_runner_group == "" ? local.issue_agent_runner_extension_command : format(
    "%s -RunnerGroup \"%s\"",
    local.issue_agent_runner_extension_command,
    local.issue_agent_runner_group,
  )

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

data "azurerm_key_vault" "shared" {
  provider = azurerm.shared

  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

data "azurerm_key_vault_secret" "admin_password" {
  count = var.admin_password == null ? 1 : 0

  provider = azurerm.shared

  name         = var.admin_password_secret_name
  key_vault_id = data.azurerm_key_vault.shared.id
}

data "azurerm_key_vault_secret" "rdp_allowed_cidrs" {
  count = length(var.rdp_allowed_cidrs) == 0 && var.rdp_allowed_cidrs_secret_name != null ? 1 : 0

  provider = azurerm.shared

  name         = var.rdp_allowed_cidrs_secret_name
  key_vault_id = data.azurerm_key_vault.shared.id
}

data "azurerm_key_vault_secret" "winrm_allowed_cidrs" {
  count = length(var.winrm_allowed_cidrs) == 0 && var.winrm_allowed_cidrs_secret_name != null ? 1 : 0

  provider = azurerm.shared

  name         = var.winrm_allowed_cidrs_secret_name
  key_vault_id = data.azurerm_key_vault.shared.id
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
  count = local.effective_enable_rdp_rule && length(local.effective_rdp_allowed_cidrs) > 0 ? 1 : 0

  name                        = "allow-rdp"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefixes     = local.effective_rdp_allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.vmss.name
  network_security_group_name = azurerm_network_security_group.vmss.name
}

resource "azurerm_network_security_rule" "winrm" {
  count = local.effective_enable_winrm_rule && length(local.effective_winrm_allowed_cidrs) > 0 ? 1 : 0

  name                        = "allow-winrm"
  priority                    = 1010
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5986"
  source_address_prefixes     = local.effective_winrm_allowed_cidrs
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

resource "azapi_resource" "vmss" {
  count = var.enable_vmss ? 1 : 0

  type      = "Microsoft.Compute/virtualMachineScaleSets@2024-11-01"
  name      = local.vmss_name
  parent_id = azurerm_resource_group.vmss.id
  location  = azurerm_resource_group.vmss.location

  identity {
    type = "SystemAssigned"
  }

  tags = local.vmss_tags

  body = merge(
    {
      properties = {
        doNotRunExtensionsOnOverprovisionedVMs = false
        orchestrationMode                      = "Uniform"
        overprovision                          = false
        singlePlacementGroup                   = true
        upgradePolicy = {
          mode = var.upgrade_mode
        }
        virtualMachineProfile = local.vmss_virtual_machine_profile
      }
      sku = {
        capacity = var.instance_count
        name     = var.vm_sku
        tier     = "Standard"
      }
    },
    length(var.zones) == 0 ? {} : {
      zones = var.zones
    }
  )

  schema_validation_enabled = false
  response_export_values = {
    principal_id = "identity.principalId"
    tenant_id    = "identity.tenantId"
  }

  lifecycle {
    precondition {
      condition     = var.instance_count >= 1
      error_message = "instance_count must be at least 1 when enable_vmss is true."
    }

    precondition {
      condition     = !var.enable_issue_agent_runner_bootstrap || var.create_nat_gateway || var.subnet_default_outbound_access_enabled
      error_message = "enable_issue_agent_runner_bootstrap requires outbound internet access via create_nat_gateway or subnet_default_outbound_access_enabled."
    }

    precondition {
      condition     = !local.vmss_image_is_specialized || var.source_image_id != null
      error_message = "vmss_image_os_state=specialized requires source_image_id to point at a specialized gallery image."
    }
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.vmss,
    azurerm_nat_gateway_public_ip_association.vmss,
    azurerm_subnet_nat_gateway_association.vmss,
  ]
}

resource "azurerm_role_assignment" "vmss_key_vault_secrets_user" {
  count = var.enable_vmss && var.enable_issue_agent_runner_bootstrap ? 1 : 0

  provider = azurerm.shared

  scope                            = data.azurerm_key_vault.shared.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azapi_resource.vmss[0].output.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azapi_resource" "issue_agent_runner_bootstrap" {
  count = var.enable_vmss && var.enable_issue_agent_runner_bootstrap ? 1 : 0

  type      = "Microsoft.Compute/virtualMachineScaleSets/extensions@2024-11-01"
  name      = "issue-agent-runner-bootstrap"
  parent_id = azapi_resource.vmss[0].id

  body = {
    properties = {
      autoUpgradeMinorVersion = true
      enableAutomaticUpgrade  = false
      publisher               = "Microsoft.Compute"
      settings = {
        commandToExecute = local.issue_agent_runner_extension_command_with_group
        fileUris         = [local.issue_agent_runner_script_url]
      }
      suppressFailures   = false
      type               = "CustomScriptExtension"
      typeHandlerVersion = "1.10"
    }
  }

  schema_validation_enabled = false

  depends_on = [
    azurerm_role_assignment.vmss_key_vault_secrets_user,
  ]
}

resource "azurerm_public_ip" "builder" {
  count = var.enable_builder_vm ? 1 : 0

  name                = local.builder_public_ip_name
  location            = azurerm_resource_group.vmss.location
  resource_group_name = azurerm_resource_group.vmss.name
  allocation_method   = "Static"
  domain_name_label   = var.builder_public_ip_dns_label
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
  admin_password = local.effective_admin_password

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
