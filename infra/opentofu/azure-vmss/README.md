# Azure VMSS OpenTofu Root

This directory contains the first-pass OpenTofu root for the Azure-hosted STS2 worker pool.

It is intentionally CI-first:

- the preferred execution path is GitHub Actions
- the backend is Azure Blob Storage via the `azurerm` backend
- Azure authentication is expected to use GitHub OIDC
- this repo does **not** assume local `tofu` usage as the normal workflow
- the workflow aligns with the existing `infra-bootstrap` ARM variable pattern

## What This Deploys

- one resource group
- one virtual network
- one subnet
- one network security group
- one NAT gateway plus one Standard public IP for explicit outbound access
- optionally, one standalone Windows builder VM with a public IP and system-assigned managed identity
- optionally, one Windows VM Scale Set with a system-assigned managed identity

The NAT gateway is included because the workers need reliable outbound internet access for GitHub, Steam, mod dependencies, and artifact upload. That is also the safer long-term Azure posture for new subnets. For the temporary builder-only phase, you can set `create_nat_gateway = false` and let the builder VM use its own public IP.

This root can also optionally allow private WinRM over HTTPS on port `5986`
from a trusted CIDR list, which is useful when an ansible-only GitHub runner in
AKS or another peered network needs to configure the builder VM without opening
WinRM to the public internet.

## Image Strategy

This root supports a staged path:

1. builder mode:
   - set `enable_builder_vm = true`
   - set `enable_vmss = false`
   - use the default Windows marketplace image or provide `builder_source_image_id`
   - RDP into the builder VM, install Steam and STS2, switch Steam into offline mode, and verify the worker setup
2. worker-image mode:
   - capture the builder VM into an Azure Compute Gallery image
   - set `enable_vmss = true`
   - set `source_image_id` to the Shared Image Gallery image definition or version ID
   - optionally disable or destroy the builder VM once the image is proven

The long-term VMSS path should use `source_image_id`. The builder VM exists only to create that image without requiring the work laptop to host STS2.

## Custom Domain And TLS

Azure does not provide a one-click custom-domain-and-certificate feature for direct RDP into a VM or VMSS instance.

The supported building blocks are:

- a stable public endpoint such as a VM public IP, load balancer, or Application Gateway
- DNS that you control
- a server-authentication certificate installed inside Windows and bound to the RDP listener

For this root, the practical first step is the builder VM:

- set `builder_public_ip_dns_label` if you want Azure to publish a stable FQDN such as `<label>.<region>.cloudapp.azure.com`
- point a custom DNS record such as `builder.romaine.life` at that public IP or Azure-managed FQDN
- install a CA-signed certificate for that hostname on the builder VM
- bind the certificate to the RDP listener

The worker VMSS in this root is private-only by default. It does not currently expose a public ingress endpoint that a custom domain can target. If direct inbound access to VMSS instances is needed later, add a deliberate ingress pattern first, such as Azure Bastion, a jumpbox, or a load balancer plus explicit NAT rules.

## Files

- [versions.tf](./versions.tf)
- [variables.tf](./variables.tf)
- [main.tf](./main.tf)
- [outputs.tf](./outputs.tf)
- [example.tfvars](./example.tfvars)

## CI Workflow

Use the manual GitHub Actions workflow at [opentofu-azure-vmss.yml](../../../.github/workflows/opentofu-azure-vmss.yml).

That workflow:

- logs into Azure with OIDC
- uses repository variables `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`
- uses repository variable `KEY_VAULT_NAME`
- passes `KEY_VAULT_NAME` into Terraform as `TF_VAR_key_vault_name`
- lets the root read the VM admin password plus optional RDP and WinRM CIDR allowlists from Azure Key Vault through `azurerm` data sources
- initializes the `azurerm` backend
- runs `tofu fmt -check`
- runs `tofu validate`
- runs `tofu plan`
- supports manual plan-only or plan+apply via `workflow_dispatch`

## infra-bootstrap Handoff

This repo likely needs its Azure app registration and GitHub OIDC trust created outside this repo, via `infra-bootstrap`.

Assumed handoff:

1. `infra-bootstrap` creates or updates the Microsoft Entra app registration / service principal for this repo.
2. `infra-bootstrap` adds GitHub OIDC federated credentials for this repo's default branch and pull requests.
3. `infra-bootstrap` stores the GitHub repository variables:
   - `ARM_CLIENT_ID`
   - `ARM_TENANT_ID`
   - `ARM_SUBSCRIPTION_ID`
   - `KEY_VAULT_NAME`
   - `TFSTATE_STORAGE_ACCOUNT`
4. `infra-bootstrap` stores the VM admin password in Key Vault as:
   - `card-utility-stats-vm-admin-password`
5. Optional but recommended for builder VM RDP access:
   - store a JSON array of trusted CIDRs in Key Vault as `card-utility-stats-rdp-allowed-cidrs`
   - example value: `["203.0.113.10/32"]`
6. Optional for private Ansible control-node access:
   - set `winrm_allowed_cidrs` in the `.tfvars` file, or
   - store a JSON array of trusted private CIDRs in Key Vault and point `winrm_allowed_cidrs_secret_name` at that secret

Recommended Azure permissions for that principal:

- on the target subscription:
  - `Contributor`
- on the target subscription:
  - `Role Based Access Control Administrator`
- on the state storage account or state container:
  - `Storage Blob Data Contributor`
- on the shared Key Vault:
  - `Key Vault Secrets Officer`

## Backend Notes

The root module uses an empty `backend "azurerm" {}` block on purpose.

The workflow injects the backend values at runtime so that:

- state location stays out of source control
- OIDC stays aligned with the repo-level branch and PR credentials already managed by `infra-bootstrap`
- local contributor machines do not need baked-in backend config
- the backend storage account comes from `TFSTATE_STORAGE_ACCOUNT`
- the backend resource group and container stay on the shared infra defaults

## Typical First Run

1. Open [example.tfvars](./example.tfvars) and copy it to a repo-specific non-secret `.tfvars` file.
2. Adjust names and region.
3. Ask `infra-bootstrap` to provision the Azure app registration / federated credential and repo variables for this repo.
4. Confirm the Key Vault secret `card-utility-stats-vm-admin-password` exists.
5. Run the manual workflow in GitHub with `apply=false`.
6. Review the plan for the builder VM.
7. Re-run with `apply=true` when ready.
8. RDP into the builder VM and install Steam, STS2, the modding tools, and any worker-local dependencies.
9. Switch Steam to Offline Mode and verify STS2 still launches after a reboot.
10. Capture the builder VM into an Azure Compute Gallery image.
11. Update the `.tfvars` file:
   - set `enable_vmss = true`
   - set `source_image_id` to the gallery image definition or version ID
   - optionally set `enable_builder_vm = false` if you no longer need the seed box
   - optionally set `create_nat_gateway = true` for the VMSS phase
   - optionally set `winrm_allowed_cidrs` for a private Ansible runner subnet such as the AKS node subnet
12. Re-run the workflow to stand up the VMSS from the captured image.

## Important Limits

- This root creates the compute/network shell, not the full worker bootstrap inside the guest.
- Runner registration, Codex auth, Steam offline state, and STS2 driver setup still belong in the golden image and/or first-boot bootstrap layer described in [docs/vmss-worker-bootstrap.md](../../../docs/vmss-worker-bootstrap.md).
- The builder VM shares the same subnet and NSG as the VMSS. If you need RDP through GitHub Actions, store trusted CIDRs in the Key Vault secret `card-utility-stats-rdp-allowed-cidrs` and let Terraform read them through the `azurerm_key_vault_secret` data source. Local runs can still set `enable_rdp_rule` and `rdp_allowed_cidrs` directly.
- Private WinRM is supported through the same pattern by setting `winrm_allowed_cidrs` or `winrm_allowed_cidrs_secret_name`. Keep WinRM scoped to trusted private ranges such as the AKS node subnet instead of opening `5986` broadly.
- For a trusted RDP certificate, connect by hostname, not by raw IP address. A public CA certificate for `builder.romaine.life` will not validate if the client connects to `20.x.x.x`.
