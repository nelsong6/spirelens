# Windows Worker Ansible

This directory is the source of truth for guest-level Windows worker setup.

The Azure OpenTofu root creates the compute and network shell. This Ansible
layer is where we express what should be installed and configured inside the
guest OS so the same setup can be iterated on for:

- the standalone builder VM
- the captured golden image
- VMSS instances created from that image later

## Execution Model

Use Ansible as the configuration language, but do not treat the Windows guest as
the Ansible control node. The intended model is:

1. provision a Windows builder VM in Azure
2. run a small first-touch bootstrap on the VM to enable WinRM for Ansible
3. run these playbooks from a Linux or WSL control node that can reach the VM
4. iterate until the builder VM setup is stable
5. capture the image
6. reuse the same role against VMSS instances later

For now, the first-touch bootstrap script lives at:

- [Enable-AnsibleWinRm.ps1](../../ops/windows-worker/Enable-AnsibleWinRm.ps1)

That script is intentionally small. The durable setup belongs here in Ansible.

## Current Boundaries

This Ansible layer is designed to automate deterministic setup:

- Windows tuning
- directory layout
- toolchain install
- Claude Code install path
- GitHub runner files
- STS2 MCP checkout and venv
- Steam client install
- smoke checks

It does not try to fully automate everything on day one.

Still expected to be manual on the builder VM:

- Steam login
- Slay the Spire 2 install
- first launch confirmation
- Steam offline mode confirmation

## Structure

- [ansible.cfg](./ansible.cfg)
- [collections/requirements.yml](./collections/requirements.yml)
- [inventory/builder.example.yml](./inventory/builder.example.yml)
- [group_vars/windows_issue_agent_worker.yml](./group_vars/windows_issue_agent_worker.yml)
- [playbooks/bootstrap-builder.yml](./playbooks/bootstrap-builder.yml)
- [playbooks/bootstrap-worker.yml](./playbooks/bootstrap-worker.yml)
- [roles/windows_issue_agent_worker/tasks/main.yml](./roles/windows_issue_agent_worker/tasks/main.yml)

## Control Node Quick Start

```bash
cd infra/ansible
ansible-galaxy collection install -r collections/requirements.yml
ansible-playbook -i inventory/builder.example.yml playbooks/bootstrap-builder.yml
```

The example inventory is intentionally not runnable as-is. Replace the host,
credentials, and certificate assumptions with the real builder VM values.

## Iteration Rule

The right loop is:

1. prove tasks on the builder VM
2. tighten idempotence
3. capture the image
4. only then wire the same playbook into broader VMSS automation

Do not fork a separate builder-only bootstrap language if Ansible can express
the durable intent here.
