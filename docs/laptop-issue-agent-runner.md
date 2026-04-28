# Laptop Issue-Agent Runner

This is the active issue-agent host path.

The repo no longer treats Azure VMSS or a builder VM as the primary deployment
target for live `issue-agent` work. The expected host is now a local Windows
machine, typically the work laptop.

## Goal

Bring one Windows machine online as a self-hosted GitHub Actions runner with:

- a host route label such as `issue-agent-runner-nelsonlaptop`
- one live-game runner label such as `issue-agent-sts2-nelsonlaptop`
- phase labels for the runner role: `issue-agent-test-plan`,
  `issue-agent-implementation`, and/or `issue-agent-verification`
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
D:\Programs\SteamLibrary\steamapps\common\Slay the Spire 2
```

This must be the Steam-registered install from
`D:\Programs\SteamLibrary\steamapps\appmanifest_2868840.acf`, not the older
unregistered `D:\SteamLibrary` copy. On NELSONPC the aligned Steam build is
`22823976`, and `sts2.dll` reports product version
`0.1.0+89765e1e54a888b031c826143eb77005b353f75d`.

Because the runner launches STS2 directly during validation, the game folder
must contain `steam_appid.txt` with:

```text
2868840
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
    <Sts2Path>D:/Programs/SteamLibrary/steamapps/common/Slay the Spire 2</Sts2Path>
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
  -RunnerLabels issue-agent-runner-nelsonlaptop,issue-agent-sts2-nelsonlaptop,issue-agent-test-plan,issue-agent-verification
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
and give it a unique route label such as `issue-agent-runner-nelsonpc-user`.
For a single-runner host, put every phase and live-game label on that runner:

```powershell
$token = gh api -X POST repos/nelsong6/spirelens/actions/runners/registration-token --jq .token
New-Item -ItemType Directory -Force D:\actions-runner-user | Out-Null
Set-Location D:\actions-runner-user
# install or copy the GitHub Actions runner files here before configuring
.\config.cmd --url https://github.com/nelsong6/spirelens --token $token --name issue-agent-NELSONPC-user --labels issue-agent-runner-nelsonpc-user,issue-agent-sts2-nelsonpc-user,issue-agent-test-plan,issue-agent-implementation,issue-agent-verification --work _work
.\run.cmd
```

Then queue issue-agent work by applying `issue-agent`. To force this host, apply
`issue-agent-runner-nelsonpc-user` before applying `issue-agent`. If no route
label is present, the workflow auto-selects one route from
`ISSUE_AGENT_ROUTE_LABEL_POOL` and adds the chosen route label to the issue.

The workflow derives the live STS2 label from the route label:
`issue-agent-runner-nelsonpc-user` requires
`issue-agent-sts2-nelsonpc-user` for test-plan and verification jobs. Put the
`issue-agent-sts2-*` label on exactly one runner for each physical STS2 game
session so GitHub's runner queue serializes live-game work without
canceling pending issue-agent runs.

If these self-hosted runners are restricted to a GitHub Actions runner group,
set repository variable `ISSUE_AGENT_RUNNER_GROUP` to that group name. The
workflow will target the group plus the same route, phase, and live-game labels.
Use these optional overrides only when phases live in different groups:

- `ISSUE_AGENT_TEST_PLAN_RUNNER_GROUP`
- `ISSUE_AGENT_IMPLEMENTATION_RUNNER_GROUP`
- `ISSUE_AGENT_VERIFICATION_RUNNER_GROUP`

For a two-runner host, split labels by role:

| Runner role | Labels |
| --- | --- |
| Live STS2 runner | `issue-agent-runner-<host>`, `issue-agent-sts2-<host>`, `issue-agent-test-plan`, `issue-agent-verification` |
| Code implementation runner | `issue-agent-runner-<host>`, `issue-agent-implementation` |

The laptop is currently configured this way:

| Runner | Role | Labels |
| --- | --- | --- |
| `sts2-side-a` | Live STS2 runner | `issue-agent-runner-nelsonlaptop`, `issue-agent-sts2-nelsonlaptop`, `issue-agent-test-plan`, `issue-agent-verification` |
| `sts2-side-b` | Code implementation runner | `issue-agent-runner-nelsonlaptop`, `issue-agent-implementation` |

NELSONPC currently has this non-admin runner registered and online:

- Runner root: `D:\actions-runner-user`
- Runner name: `issue-agent-NELSONPC-user`
- Routing label: `issue-agent-runner-nelsonpc-user`
- STS2 live-game label: `issue-agent-sts2-nelsonpc-user`
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
- A later STS2/MCP prep run failed because `spire-lens-mcp` could not compile
  against the machine's current STS2/publicized assembly context:
  `ICombatState` was missing. The MCP compatibility fix was pushed in
  `nelsong6/spire-lens-mcp` commit `e3cf4b0`, and the local MCP build now
  passes against the Steam-registered install above.

Before adding any host to `ISSUE_AGENT_ROUTE_LABEL_POOL`, use that runner as a
host smoke test and confirm:

- Steam resolves Slay the Spire 2 to the intended current install, not an older
  checkout, copied install, or stale publicized assembly directory.
- The resolved game assembly is the current raw STS2 assembly at
  `D:\SteamLibrary\steamapps\common\Slay the Spire 2\data_sts2_windows_x86_64\sts2.dll`.
- That `sts2.dll` contains
  `MegaCrit.Sts2.Core.Combat.ICombatState`.
- `spire-lens-mcp` builds cleanly from a clean checkout against the resolved
  STS2 data directory.
- The runner process is the same logged-in interactive Windows account that has
  Claude auth, Steam access, `uv`, and the expected user `PATH`.

A quick local assembly/version check:

```powershell
$sts2Dll = 'D:\SteamLibrary\steamapps\common\Slay the Spire 2\data_sts2_windows_x86_64\sts2.dll'
Get-Item $sts2Dll | Select-Object FullName, LastWriteTime, @{Name='ProductVersion'; Expression={$_.VersionInfo.ProductVersion}}
[Reflection.Assembly]::LoadFrom($sts2Dll).GetType('MegaCrit.Sts2.Core.Combat.ICombatState', $false) -ne $null
```

The type check must print `True`. If it prints `False`, the runner is building
against the wrong or stale STS2 assembly context and should stay out of the
auto-route pool until that is fixed.

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

- every runner used for an issue has the chosen `issue-agent-runner-<host>` route label
- exactly one live-game runner per host has `issue-agent-sts2-<host>`
- live-game runners have `issue-agent-test-plan` and `issue-agent-verification`
- code runners have `issue-agent-implementation`
- the repo checkout contains a working `.mcp.json`
- Claude can list and connect to `spire-lens-mcp`
- STS2 is available locally when the issue requires live validation
- Claude Code is authenticated for the interactive runner account

The workflow itself still handles:

- uploading logs, screenshots, and validation artifacts

## Sanity Check

Once the runner is online in GitHub:

1. Confirm the machine appears under repository runners with label
   `issue-agent-runner-<host>`.
2. Add `issue-agent` to a low-risk issue and confirm the workflow auto-applies
   one route label from `ISSUE_AGENT_ROUTE_LABEL_POOL`.
3. To force a specific machine, add that machine's route label before adding
   `issue-agent`.
4. Confirm the run:
   - starts on the laptop
   - passes the STS2 bridge readiness check
   - launches Claude with MCP available
   - uploads the expected artifacts

## Secondary Machines

For a second machine, use the same route/phase/live label pattern with a unique
host suffix:

- `issue-agent-runner-<host>` goes on every runner for that machine.
- `issue-agent-sts2-<host>` goes on exactly one live-game runner.
- `issue-agent-test-plan` and `issue-agent-verification` go on the live-game
  runner.
- `issue-agent-implementation` goes on the implementation runner.

For example, a two-runner `nelsonpc-user` setup would be:

| Runner role | Labels |
| --- | --- |
| Live STS2 runner | `issue-agent-runner-nelsonpc-user`, `issue-agent-sts2-nelsonpc-user`, `issue-agent-test-plan`, `issue-agent-verification` |
| Code implementation runner | `issue-agent-runner-nelsonpc-user`, `issue-agent-implementation` |

The default auto-route pool is:

```text
issue-agent-runner-nelsonlaptop,issue-agent-runner-nelsonpc-user
```

Set repository variable `ISSUE_AGENT_ROUTE_LABEL_POOL` if a machine should be
temporarily removed from or added to automatic issue assignment. Explicit route
labels on an issue always override the pool.

Set repository variable `ISSUE_AGENT_RUNNER_GROUP` if the runner labels live
inside a non-default GitHub Actions runner group. The workflow still requires
the matching route/phase/live labels inside that group.

While bringing up a new machine, set `ISSUE_AGENT_ROUTE_LABEL_POOL` to only the
known-good host, for example:

```text
issue-agent-runner-nelsonlaptop
```

Add the new host back only after its live STS2 runner and implementation runner
both pass host prep, Claude auth, `spire-lens-mcp` build, and a low-risk
issue-agent smoke run.
