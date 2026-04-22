name_prefix = "card-utility-stats-dev"
location    = "West US 3"

admin_username = "runneradmin"

# Phase 0: create only the temporary builder VM.
enable_builder_vm  = true
enable_vmss        = false
builder_vm_sku     = "Standard_D4s_v5"
create_nat_gateway = false
encryption_at_host_enabled = false

# If `rdp_allowed_cidrs` is left empty, the root will read
# `card-utility-stats-rdp-allowed-cidrs` from the configured Key Vault via
# the `azurerm_key_vault_secret` data source, so this file does not need to
# hardcode a personal public IP.

# Phase 1+: flip enable_vmss to true and point this at the captured worker image.
instance_count = 1
vm_sku         = "Standard_D4s_v5"

# Point this at your prepared Windows runner image once the golden image exists.
# Leave it unset while building the seed VM from the marketplace image.
source_image_id = null

tags = {
  environment = "dev"
  project     = "CardUtilityStats"
}
