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
- Claude Code authenticated once as the interactive runner account
- an interactive runner process started from the logged-in Steam user session

## Host Requirements

Install these once on the laptop:

- GitHub Actions runner files
- Git
- GitHub CLI
- .NET 9 SDK
- Godot .NET 4.5.1 for publish/export
- Python 3.12
- Steam
- Slay the Spire 2
- Claude Code
- STS2 Modding MCP checkout and its local dependencies

## NELSONPC Setup Snapshot

`NELSONPC` has been prepared as a Windows issue-agent candidate with:

- Git `2.54.0.windows.1`
- GitHub CLI `2.91.0`
- Node.js `24.15.0` and npm `11.12.1`
- Corepack with pnpm `10.33.2` and Yarn `4.14.1`
- Python `3.12.10`, `pipx`, and `uv`
- PowerShell `7.6.1`
- .NET SDK `9.0.313`
- Godot .NET `4.5.1.stable.mono`
- ripgrep `15.1.0`

Local workspace folders:

```text
C:\Users\Nelson\Documents\Codex\repos
C:\Users\Nelson\Documents\Codex\scratch
C:\Users\Nelson\Documents\Codex\logs
```

Slay the Spire 2 is installed at:

```text
D:\SteamLibrary\steamapps\common\Slay the Spire 2
```

BaseLib is present in the game's `mods` folder.

Godot .NET 4.5.1 is installed at:

```text
D:\automation\godot\Godot_v4.5.1-stable_mono_win64
```

The local CardUtilityStats checkout uses an ignored `Directory.Build.props`
with machine-specific paths:

```xml
<Project>
  <PropertyGroup>
    <Sts2Path>D:/SteamLibrary/steamapps/common/Slay the Spire 2</Sts2Path>
    <GodotPath>D:/automation/godot/Godot_v4.5.1-stable_mono_win64/Godot_v4.5.1-stable_mono_win64_console.exe</GodotPath>
  </PropertyGroup>
</Project>
```

Do not commit this file; it is ignored because the paths are host-specific.

## Build Versus Publish

For CardUtilityStats, Godot is required for the full mod workflow.

`dotnet build -c Release` compiles and deploys the DLL, manifest, and runtime
dependencies to the Slay the Spire 2 `mods` folder. This is sufficient for
code-only DLL changes.

`dotnet publish -c Release` invokes Godot headlessly and exports
`CardUtilityStats.pck`. Use publish when an issue touches assets, export
behavior, Nexus packaging, or any validation path that should match a runner
where Godot visibly launches.

On `NELSONPC`, publish currently writes the `.pck` but emits Godot export
warnings because the export scanner sees C# files under `Core` and `Tests` and
expects `CardUtilityStats.sln`. That is a repository export-configuration issue,
not a missing machine prerequisite.

Common Claude CLI locations supported by the workflow:

- `D:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `C:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `%USERPROFILE%\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe`

If you want a different location, set repository variable
`ISSUE_AGENT_CLAUDE_CLI_PATH`.

## Claude Subscription Auth

The issue-agent workflow uses the local Claude Code login for the Windows account
running the interactive runner. Log in once from that same account before
dispatching jobs:

```powershell
claude auth status
claude
```

If `claude auth status` does not report a logged-in Claude.ai account, launch
`claude` interactively and complete the browser login. The workflow runs
`claude auth status` as a preflight and fails early if the runner account is not
authenticated.

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

## Running Live STS2 Jobs

For live STS2 validation, run the runner interactively from the logged-in Steam
user session instead of as a Windows service:

```powershell
$svc = 'actions.runner.nelsong6-card-utility-stats.sts2-side-a'
Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
cd C:\actions-runner-card-utility-stats
.\run.cmd
```

Leave that window open while issue-agent jobs run. The interactive runner must
show as session 1, not session 0. A Windows service launches STS2 in session 0,
which does not provide the same Steam client/session context as the logged-in
user desktop.

If dispatching workflow runs manually from the laptop, make sure GitHub CLI is
authenticated:

```powershell
gh auth status
gh auth login
```

`gh auth login` is only needed when `gh auth status` reports that the local token
has expired or is missing.

## Workflow Expectations

The issue-agent workflow expects:

- the runner has labels `self-hosted`, `windows`, and `issue-agent`
- the repo checkout contains a working `.mcp.json`
- Claude can list and connect to `spire-lens-mcp`
- STS2 is available locally when the issue requires live validation
- Claude Code is authenticated for the interactive runner account

The workflow itself still handles:

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
