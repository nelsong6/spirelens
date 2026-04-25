# Laptop Issue-Agent Runner

This is the active issue-agent host path.

The repo no longer treats Azure VMSS or a builder VM as the primary deployment
target for live `issue-agent` work. The expected host is now a local Windows
machine, typically the work laptop.

## Goal

Bring one Windows machine online as a self-hosted GitHub Actions runner with:

- runner label `issue-agent`
- Claude Code installed locally
- Slay the Spire 2 installed locally
- STS2 Modding MCP installed locally
- a local Anthropic API key file readable by the runner account

## Host Requirements

Install these once on the laptop:

- GitHub Actions runner files
- Git
- GitHub CLI
- Azure CLI
- .NET 9 SDK
- Python 3.12
- Steam
- Slay the Spire 2
- Claude Code
- STS2 Modding MCP checkout and its local dependencies

Common Claude CLI locations supported by the workflow:

- `D:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `C:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `%USERPROFILE%\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`

If you want a different location, set repository variable
`ISSUE_AGENT_CLAUDE_CLI_PATH`.

## Anthropic Key File

The issue-agent workflow reads `ANTHROPIC_API_KEY` from a local file on the
self-hosted runner. The default path is:

```text
C:\ProgramData\SpireLens\anthropic-api-key.txt
```

Create or refresh it from Key Vault once from an elevated PowerShell session on
each runner machine:

```powershell
$vaultName = 'romaine-kv'
$secretName = 'spirelens'
$secretDir = 'C:\ProgramData\SpireLens'
$keyPath = Join-Path $secretDir 'anthropic-api-key.txt'

az account show --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
  az login
}

$key = az keyvault secret show `
  --vault-name $vaultName `
  --name $secretName `
  --query value `
  --output tsv `
  --only-show-errors

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key)) {
  throw "Unable to read Key Vault secret '$secretName' from vault '$vaultName'."
}

New-Item -ItemType Directory -Force -Path $secretDir | Out-Null
Set-Content -LiteralPath $keyPath -Value $key.Trim() -NoNewline -Encoding ascii
icacls $secretDir /inheritance:r | Out-Null
icacls $secretDir /grant 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' "$($env:USERNAME):(OI)(CI)R" | Out-Null
Write-Host "Wrote Anthropic API key to $keyPath"
```

If a machine needs a different path, set repository variable
`ISSUE_AGENT_ANTHROPIC_KEY_PATH` to the full local path.

## Register The Runner

1. Install the GitHub Actions runner files somewhere stable such as
   `D:\actions-runner-spirelens`, `C:\actions-runner-spirelens`,
   `D:\actions-runner`, `C:\actions-runner`, or `%USERPROFILE%\actions-runner`.
2. If `GITHUB_PAT` is not already set, make it available locally before running
   the helper script.
3. Run the local registration helper from an elevated PowerShell session if you
   want the runner installed or repaired as a Windows service:

```powershell
pwsh -NoProfile -File .\ops\windows-worker\Register-LocalIssueAgentRunner.ps1 `
  -RepositorySlug nelsong6/spirelens `
  -RunnerLabels issue-agent
```

The script will:

- reuse `GITHUB_PAT` if already set, or
- read `github-pat` from Key Vault if `-KeyVaultName` is supplied, then
- register the machine as a repository-scoped runner, and
- run it as a Windows service by default

If the runner files are not under one of those default paths, pass
`-RunnerRoot`.

For live STS2 validation, prefer running the runner interactively from the
logged-in Steam user session instead of as a Windows service:

```powershell
cd C:\actions-runner-card-utility-stats
.\run.cmd
```

A Windows service launches STS2 in session 0, which does not provide the same
Steam client/session context as the logged-in user desktop.

## Workflow Expectations

The issue-agent workflow expects:

- the runner has labels `self-hosted`, `windows`, and `issue-agent`
- the repo checkout contains a working `.mcp.json`
- Claude can list and connect to `spire-lens-mcp`
- STS2 is available locally when the issue requires live validation
- `ANTHROPIC_API_KEY` is available from the local runner key file

The workflow itself still handles:

- mapping the local key file to `ANTHROPIC_API_KEY`
- uploading logs, screenshots, and validation artifacts

## Sanity Check

Once the runner is online in GitHub:

1. Confirm the machine appears under repository runners with label
   `issue-agent`.
2. Run the `Issue Agent` workflow manually for a low-risk issue number.
3. Confirm the run:
   - starts on the laptop
   - passes the STS2 bridge readiness check
   - launches Claude with MCP available
   - uploads the expected artifacts

## Secondary Machines

If you want a second machine later, use the same script and keep the same
`issue-agent` label unless you deliberately want to split hosts by capability.
