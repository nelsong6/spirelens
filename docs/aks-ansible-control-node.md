# AKS Ansible Control Node

This document is the repo-side control path for running the first real
`bootstrap-builder.yml` pass against the Azure builder over private WinRM.

## Purpose

Keep GitHub-hosted runners out of the private WinRM path.

The control split is now:

- GitHub-hosted runner:
  - deploy or update ARC in AKS
  - fetch GitHub App credentials from Azure Key Vault
  - stand up the ansible-only runner scale set
- AKS ARC runner scale set `ansible-control`:
  - run manual Ansible workflows inside `infra-vnet`
  - reach the builder private IP such as `10.42.1.4`
  - execute `infra/ansible/playbooks/bootstrap-builder.yml`

This is intentionally separate from the Windows STS2 `issue-agent` workers. The
AKS runner is a small Linux control node only.

## Repo Assets

- [deploy-aks-ansible-control-runner.yml](../.github/workflows/deploy-aks-ansible-control-runner.yml)
- [bootstrap-azure-builder-ansible.yml](../.github/workflows/bootstrap-azure-builder-ansible.yml)
- [infra/aks/arc/ansible-control.values.yaml](../infra/aks/arc/ansible-control.values.yaml)

## Required Inputs And Secrets

Existing repo variables still used:

- `ARM_CLIENT_ID`
- `ARM_TENANT_ID`
- `ARM_SUBSCRIPTION_ID`
- `KEY_VAULT_NAME`
- `KEY_VAULT_SUBSCRIPTION_ID`

Default Key Vault secret names expected by the runner-deploy workflow:

- `github-pat`

Optional GitHub App secret names if you choose App auth instead of PAT:

- `github-app-id`
- `github-app-installation-id`
- `github-app-private-key`

Default Key Vault secret used by the Ansible bootstrap workflow:

- `card-utility-stats-vm-admin-password`

## Bring Up The Control Runner

1. Run `Deploy AKS Ansible Control Runner`.
2. Point it at the existing AKS cluster that has network reachability into `vnet-card-utility-stats-dev`.
3. Leave the defaults unless you already need different namespaces or scale-set naming:
   - controller namespace: `arc-systems`
   - runner namespace: `arc-runners-ansible-control`
   - runner scale set name: `ansible-control`
   - max runners: `1`
4. Verify the workflow summary shows the controller pod and runner namespace pods as running.

The workflow installs or updates:

- the ARC controller Helm chart
- the ARC runner scale set Helm chart
- the Kubernetes secret `arc-github-app` in the runner namespace

Today this repo defaults to PAT-backed ARC auth because the currently installed GitHub App does not have enough permission to mint repository runner registration tokens for `nelsong6/card-utility-stats`.

## Run The Builder Bootstrap

After the ARC runner is online, run `Bootstrap Azure Builder via Ansible`.

Recommended first invocation:

- `runner_scale_set_name = ansible-control`
- `builder_host = 10.42.1.4`
- `builder_user = runneradmin`
- `builder_password_secret_name = card-utility-stats-vm-admin-password`
- `check_mode = false`

What this workflow does:

- schedules on the private ARC runner scale set
- installs the minimal Linux control-node dependencies it needs at runtime
- loads the builder VM password from Azure Key Vault
- renders a disposable WinRM inventory file
- runs `infra/ansible/playbooks/bootstrap-builder.yml`
- uploads the Ansible log as an artifact

## Boundaries

- The AKS runner is for Ansible and private WinRM control work, not for live STS2 gameplay or the Windows `issue-agent` path.
- Keep GitHub App credentials in Key Vault and pass only Kubernetes secret references into ARC values.
- Treat the ARC runner as ephemeral. Durable guest configuration still belongs in `infra/ansible/`.
- The deploy workflow assumes the AKS control plane is reachable from the GitHub-hosted workflow. If that assumption is false for the target cluster, switch the deploy step to an Azure-side execution path instead of opening WinRM publicly.
