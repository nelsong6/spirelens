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
- Claude Code CLI `2.1.121`, installed, on user `PATH`, and authenticated
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

Claude Code CLI is available as:

```text
C:\Users\Nelson\AppData\Roaming\npm\claude.ps1
```

The earlier install path also exists at:

```text
D:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe
```

New interactive terminals should resolve `claude`.

Claude setup has three separate gates:

1. Get Claude Code installed and resolvable as `claude`.
2. Authenticate Claude for the same Windows account that runs the GitHub Actions runner.
3. Run Claude with permission bypass enabled for issue-agent jobs.

Current Claude status on this machine:

```text
Version: 2.1.121
Auth: logged in via claude.ai
Subscription: max
```

The issue-agent workflow runs `claude auth status` before each LLM phase. This
passes for the interactive `Nelson` user, but the current Windows service
`actions.runner.nelsong6-card-utility-stats.issue-agent-NELSONPC` runs as
`NT AUTHORITY\NETWORK SERVICE`. Do not rely on that service mode for this
machine: it does not have the interactive user's Claude auth or tool PATH.

For NELSONPC, prefer the same pattern used on the other working PC: stop the
Windows service and run the runner interactively from the logged-in `Nelson`
desktop session. The service account does not inherit the interactive user's
Claude auth, Steam session, user `PATH`, or `uv` setup.

If the Windows account does not have an administrator password, stopping or
reconfiguring the existing service is blocked. In that case, do not spend time
trying to make `NETWORK SERVICE` behave like the desktop user. Register a
separate interactive runner under the logged-in `Nelson` account with its own
runner name and route label, then queue issues with that label. This avoids
needing admin rights to stop the existing service and keeps the interactive
runner attached to the user account that already has Claude, Steam, and `uv`
ready.

Observed NELSONPC test runs:

- Routing issue #105 with `issue-agent-runner-nelsonpc` successfully routed
  jobs to `issue-agent-NELSONPC`.
- The first run failed because the service could not find Claude. Repository
  variable `ISSUE_AGENT_CLAUDE_CLI_PATH` is now set to
  `D:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`.
- The second run found Claude, but implementation failed because Claude was not
  authenticated for the runner user (`NETWORK SERVICE`).
- The test-plan setup also failed because the service account could not resolve
  `uv`.
- Under the interactive `Nelson` user, both `claude auth status` and
  `uv --version` pass.

After auth, bypass Claude's interactive permission prompts for issue-agent jobs.
The workflow script currently invokes Claude with:

```text
--permission-mode bypassPermissions
```

That is the intended runner mode. Do not queue issue-agent work with default
interactive permissions, because the job can stall or fail waiting for approval.
If a run still reports `permission_denied`, treat it as a workflow phase policy
or tool allow/deny configuration issue, not as a missing interactive approval.

Runner readiness order:

```text
get claude -> auth claude -> bypass permissions -> queue issue
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

The issue-agent workflow uses the local Claude Code login for the Windows
account running the interactive runner. Log in once from that same account
before queueing jobs:

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
$svc = 'actions.runner.nelsong6-card-utility-stats.issue-agent-NELSONPC'
Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
Set-Location D:\actions-runner
.\run.cmd
```

Stopping the service may require an elevated PowerShell session. Leave the
`run.cmd` window open while issue-agent jobs run. The interactive runner must
show as session 1, not session 0. A Windows service launches STS2 in session 0,
which does not provide the same Steam client/session context as the logged-in
user desktop.

If there is no administrator password available, use a second interactive runner
instead of stopping the existing service. Configure it in a separate directory
and give it a unique label such as `issue-agent-runner-nelsonpc-user`:

```powershell
$token = gh api -X POST repos/nelsong6/spirelens/actions/runners/registration-token --jq .token
New-Item -ItemType Directory -Force D:\actions-runner-user | Out-Null
Set-Location D:\actions-runner-user
# install or copy the GitHub Actions runner files here before configuring
.\config.cmd --url https://github.com/nelsong6/spirelens --token $token --name issue-agent-NELSONPC-user --labels issue-agent,issue-agent-test-plan,issue-agent-implementation,issue-agent-verification,issue-agent-runner-nelsonpc-user,issue-agent-sts2-nelsonpc-user --work _work
.\run.cmd
```

Then queue issue-agent work by applying `issue-agent-runner-nelsonpc-user` to
the issue before applying `issue-agent`.

The workflow derives the live STS2 verification label from the route label:
`issue-agent-runner-nelsonpc-user` requires
`issue-agent-sts2-nelsonpc-user` for the verification job. Put the
`issue-agent-sts2-*` label on exactly one runner for each physical STS2 game
session so GitHub's runner queue serializes live-game verification without
canceling pending issue-agent runs.

NELSONPC currently has this non-admin runner registered and online:

- Runner root: `D:\actions-runner-user`
- Runner name: `issue-agent-NELSONPC-user`
- Routing label: `issue-agent-runner-nelsonpc-user`
- STS2 verification label: `issue-agent-sts2-nelsonpc-user`
- Runner log: `D:\actions-runner-user\_codex-logs\runner.out.log`

Because `D:\repos\spire-lens-mcp` was originally created by the old
`NETWORK SERVICE` runner, the interactive user also needs the Git safe-directory
exception:

```powershell
git config --global --add safe.directory D:/repos/spire-lens-mcp
```

Observed validation for the user runner:

- Issue #105 routed to `issue-agent-NELSONPC-user`.
- The implementation job passed host preparation and Claude subscription auth.
- Claude ran successfully under the interactive `Nelson` account with
  `--permission-mode bypassPermissions`.
- The run later failed in project build/test logic, not in runner registration,
  Claude lookup, Claude auth, or Windows permissions.

If queueing issue-agent runs from the laptop with GitHub CLI labels, make sure
GitHub CLI is authenticated:

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
2. Add the machine route label to a low-risk issue, then add `issue-agent`.
3. Confirm the run:
   - starts on the laptop
   - passes the STS2 bridge readiness check
   - launches Claude with MCP available
   - uploads the expected artifacts

## Secondary Machines

If you want a second machine later, use the same script and keep the same
`issue-agent` label unless you deliberately want to split hosts by capability.
