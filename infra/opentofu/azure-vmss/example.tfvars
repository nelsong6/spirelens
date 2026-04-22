name_prefix = "card-utility-stats-dev"
location    = "West US 3"

admin_username = "runneradmin"

# Phase 0: create only the temporary builder VM.
enable_builder_vm  = true
enable_vmss        = false
builder_vm_sku     = "Standard_D4s_v5"
create_nat_gateway = false

# The GitHub Actions workflow can inject TF_VAR_enable_rdp_rule and
# TF_VAR_rdp_allowed_cidrs from the Key Vault secret
# `card-utility-stats-rdp-allowed-cidrs`, so this file does not need to
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
