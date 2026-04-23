name_prefix = "card-utility-stats-dev"
location    = "West US 3"

admin_username = "runneradmin"

# Phase 0: create only the temporary builder VM.
enable_builder_vm = true
enable_vmss       = false
builder_vm_sku    = "Standard_NV6ads_A10_v5"
# Optional: set this to get a stable Azure FQDN like
# <label>.<region>.cloudapp.azure.com for the builder VM public IP.
# builder_public_ip_dns_label = "card-utility-stats-builder"
create_nat_gateway         = false
encryption_at_host_enabled = false

# If `rdp_allowed_cidrs` is left empty, the root will read
# `card-utility-stats-rdp-allowed-cidrs` from the configured Key Vault via
# the `azurerm_key_vault_secret` data source, so this file does not need to
# hardcode a personal public IP.

# Private WinRM from the infra-aks node subnet so an ansible-only runner can
# reach the builder VM without exposing port 5986 publicly.
winrm_allowed_cidrs = ["10.0.0.0/22"]

# Phase 1+: flip enable_vmss to true and point this at the captured worker image.
instance_count = 1
vm_sku         = "Standard_NV6ads_A10_v5"

# Point this at your prepared Windows runner image once the golden image exists.
# Leave it unset while building the seed VM from the marketplace image.
source_image_id = null

tags = {
  environment = "dev"
  project     = "CardUtilityStats"
}
