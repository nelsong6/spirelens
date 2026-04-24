name_prefix = "card-utility-stats-dev"
location    = "West US 3"

admin_username       = "runneradmin"
computer_name_prefix = "cusvmss"

# Keep the builder resource so the original seed box can be started again if
# we need to inspect or recapture it later.
enable_builder_vm = true
enable_vmss       = true
builder_vm_sku    = "Standard_NV6ads_A10_v5"

# VMSS instances need outbound internet so first-boot runner registration can
# reach GitHub and the shared Key Vault.
create_nat_gateway                  = true
enable_issue_agent_runner_bootstrap = true
encryption_at_host_enabled          = false

# Private WinRM from the infra-aks node subnet so the Ansible control runner
# can reach the builder VM without opening 5986 publicly.
winrm_allowed_cidrs = ["10.0.0.0/22"]

instance_count = 1
vm_sku         = "Standard_NV6ads_A10_v5"

# Specialized Azure Compute Gallery image captured from the prepared builder VM
# on 2026-04-23. This preserves the Steam and STS2 state we validated by hand.
source_image_id = "/subscriptions/606a1ca1-5833-4d21-8937-d0fcd97cd0a0/resourceGroups/rg-card-utility-stats-dev/providers/Microsoft.Compute/galleries/cardutilitystatsdevgallery/images/issue-agent-specialized"

tags = {
  environment = "dev"
  project     = "CardUtilityStats"
}
