# Windows Issue-Agent Runner Setup

This is the setup guide for local Windows machines that can run SpireLens
issue-agent work against a real Slay the Spire 2 install.

The current model is:

1. Add the `issue-agent` label to an issue.
2. Glimmung owns queueing and picks one available host.
3. Glimmung dispatches `.github/workflows/issue-agent.yaml` with a lease id,
   issue metadata, and a `host` value such as `issue-agent-runner-nelsonlaptop`.
4. GitHub Actions runs every Windows phase on runners with:
   - `issue-agent-worker`
   - the selected route label, for example `issue-agent-runner-nelsonlaptop`

Do not use GitHub Actions concurrency as the queue. It evicts pending runs. Do
not use issue labels to force host routing unless Glimmung is explicitly changed
to support that. Old labels like `issue-agent-runner-nelsonpc-user` on issues
are historical clutter, not scheduler input.

## Labels

Issue labels:

- `issue-agent`: queues the issue. The workflow removes it on claim.
- `issue-agent-running`: applied by the workflow after it claims the issue, removed by the release job.

Runner labels:

- `issue-agent-worker`: every runner that may execute issue-agent jobs.
- `issue-agent-runner-<host>`: route label for every runner on one Glimmung
  host, for example `issue-agent-runner-nelsonlaptop`.

Do not add the old phase labels to runners:

- `issue-agent-test-plan`
- `issue-agent-implementation`
- `issue-agent-verification`
- `issue-agent-sts2-<host>`

The workflow intentionally lets any runner on the selected host take any Windows
phase. Glimmung serializes whole issues per host; GitHub can schedule phase jobs
across that host's worker runners.

## Current Runner Inventory

As of 2026-04-28, the intended runner shape is:

| Machine | Runner name | Custom labels |
| --- | --- | --- |
| NELSONLAPTOP | `issue-agent-nelsonlaptop-a` | `issue-agent-runner-nelsonlaptop`, `issue-agent-worker` |
| NELSONLAPTOP | `issue-agent-nelsonlaptop-b` | `issue-agent-runner-nelsonlaptop`, `issue-agent-worker` |
| NELSONPC | `issue-agent-NELSONPC-user` | `issue-agent-runner-nelsonpc-user`, `issue-agent-worker` |
| NELSONPC | `issue-agent-NELSONPC-user-implementation` | `issue-agent-runner-nelsonpc-user`, `issue-agent-worker` |

Any old runner that has only the default labels `self-hosted`, `Windows`, and
`X64` cannot receive issue-agent work. That is acceptable for stale disabled
services, but do not rely on those runners.

## Host Prerequisites

Install and verify these for the same Windows account that will run
`run.cmd`:

- Git
- GitHub CLI, authenticated with `gh auth status`
- .NET 9 SDK
- Godot .NET 4.5.1, if publish/export validation is needed
- Python 3.12
- `uv`
- Node.js and npm
- Claude Code CLI
- ripgrep
- Steam
- Slay the Spire 2
- BaseLib in the STS2 `mods` folder
- SpireLens mod checkout
- `spire-lens-mcp` checkout and local dependencies

The runner must be able to run:

```powershell
git --version
gh auth status
dotnet --info
python --version
uv --version
node --version
npm --version
claude auth status
rg --version
```

Use PowerShell for Windows runner scripts. Do not assume `bash` is safe on
Windows self-hosted runners; it can resolve to a broken WSL install.

## STS2 Version Alignment

A host is not ready just because the repo builds. It must use the same Steam
branch/build as the known-good STS2 host.

The current known-good STS2 values are:

| Field | Value |
| --- | --- |
| Steam branch | `public-beta` |
| Build id | `22931561` |
| Depot manifest | `9066164797111423434` |
| `sts2.dll` product version | `0.1.0+dc286199d0203e9dc5bcbef57d373870c5c0e996` |
| Required type check | `MegaCrit.Sts2.Core.Combat.ICombatState` resolves |

The game folder must contain `steam_appid.txt` with:

```text
2868840
```

Example smoke check:

```powershell
$gameDir = 'D:\Programs\SteamLibrary\steamapps\common\Slay the Spire 2'
$manifest = 'D:\Programs\SteamLibrary\steamapps\appmanifest_2868840.acf'
$sts2Dll = Join-Path $gameDir 'data_sts2_windows_x86_64\sts2.dll'

Select-String -Path $manifest -Pattern 'buildid|TargetBuildID|manifest|BetaKey'
Get-Item $sts2Dll | Select-Object FullName, LastWriteTime, @{Name='ProductVersion'; Expression={$_.VersionInfo.ProductVersion}}
$asm = [Reflection.Assembly]::LoadFrom($sts2Dll)
$asm.GetType('MegaCrit.Sts2.Core.Combat.ICombatState', $false) -ne $null
```

The type check must print `True`.

Then prove MCP builds against that install:

```powershell
git -C D:\repos\spire-lens-mcp status --short --branch
D:\repos\spire-lens-mcp\build.ps1 -GameDir $gameDir -Configuration Release
```

Keep a host out of Glimmung's route pool until STS2 version alignment and MCP
build both pass.

## Claude Setup

Issue-agent jobs use the local Claude Code subscription login for the Windows
account running the Actions runner. The workflow does not load an Anthropic API
key from a runner file.

From the same account that will run `run.cmd`:

```powershell
claude auth status
claude
claude auth status
```

The workflow runs `claude auth status` before each LLM phase and invokes Claude
with:

```text
--permission-mode bypassPermissions
```

If a run reports `permission_denied`, treat it as a workflow policy or tool
allow/deny problem, not as an expected interactive approval prompt.

If Claude is installed somewhere unusual, set repository variable
`ISSUE_AGENT_CLAUDE_CLI_PATH`. Common supported locations include:

- `D:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `C:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `%USERPROFILE%\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe`

## Register Worker Runners

Use two runner directories per host when you want test planning and
implementation to run in parallel.

Download or copy the GitHub Actions runner files into each directory. Then
register each directory against `nelsong6/spirelens`.

The helper `ops/windows-worker/Register-LocalIssueAgentRunner.ps1` can register
one runner directory, but it must be called with both required labels. It now
rejects the old `issue-agent` runner label and the old phase labels.

Laptop example:

```powershell
$repo = 'nelsong6/spirelens'
$url = 'https://github.com/nelsong6/spirelens'
$labels = 'issue-agent-runner-nelsonlaptop,issue-agent-worker'

$token = gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token
Set-Location C:\actions-runner-card-utility-stats
.\config.cmd --unattended --url $url --token $token --name issue-agent-nelsonlaptop-a --work _work --labels $labels --replace

$token = gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token
Set-Location C:\actions-runner-card-utility-stats-implementation
.\config.cmd --unattended --url $url --token $token --name issue-agent-nelsonlaptop-b --work _work --labels $labels --replace
```

NELSONPC example:

```powershell
$repo = 'nelsong6/spirelens'
$url = 'https://github.com/nelsong6/spirelens'
$labels = 'issue-agent-runner-nelsonpc-user,issue-agent-worker'

$token = gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token
Set-Location D:\actions-runner-user
.\config.cmd --unattended --url $url --token $token --name issue-agent-NELSONPC-user --work _work --labels $labels --replace

$token = gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token
Set-Location D:\actions-runner-user-implementation
.\config.cmd --unattended --url $url --token $token --name issue-agent-NELSONPC-user-implementation --work _work --labels $labels --replace
```

If a directory is already registered and needs to be renamed, GitHub runner
names cannot be changed in place. Stop `run.cmd`, remove or delete the old
registration, then register the directory again with the new name.

Normal removal path:

```powershell
$removeToken = gh api -X POST repos/nelsong6/spirelens/actions/runners/remove-token --jq .token
.\config.cmd remove --token $removeToken
```

If removal is blocked by an old disabled Windows service and you cannot elevate,
delete the stale runner in GitHub, back up local `.runner` and `.credentials*`
files, and re-register. Do not delete runner work directories unless you are
intentionally clearing local Actions workspaces.

## Run Interactively

Live STS2 validation must run from the logged-in Steam user's desktop session.
A Windows service runner launches jobs from a service account/session 0, which
does not have the same Steam, Claude, PATH, or desktop context.

Run each worker from the interactive account:

```powershell
Set-Location C:\actions-runner-card-utility-stats
.\run.cmd
```

In another terminal:

```powershell
Set-Location C:\actions-runner-card-utility-stats-implementation
.\run.cmd
```

Verify the processes are not service-session runners:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -eq 'Runner.Listener.exe' } |
  Select-Object ProcessId,ParentProcessId,Name,CommandLine
```

The runner should belong to the logged-in user session. If it runs as
`NETWORK SERVICE`, live STS2 validation is not reliable.

## Reboot Persistence

Use [docs/reboot-safe-issue-agent-runner.md](./reboot-safe-issue-agent-runner.md)
for the admin scheduled-task path. That path is best when you can register
logon tasks with elevated rights.

Without elevation, user Startup folder launchers are acceptable for interactive
user machines. On NELSONLAPTOP the current startup launchers are:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Start GitHub Runner issue-agent-nelsonlaptop-a.cmd
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Start GitHub Runner issue-agent-nelsonlaptop-b.cmd
```

Each file should simply `cd` to the runner directory and run `run.cmd`.

## Glimmung Host Registration

The Glimmung host name must match the route label that appears on the runners.
Examples:

- `issue-agent-runner-nelsonlaptop`
- `issue-agent-runner-nelsonpc-user`

Each host should advertise capabilities compatible with the SpireLens workflow,
currently:

```json
{
  "os": "windows",
  "apps": ["sts2"],
  "machine": "nelsonlaptop"
}
```

The SpireLens workflow registration currently uses:

```json
{
  "project": "spirelens",
  "name": "issue-agent",
  "workflow_filename": "issue-agent.yaml",
  "workflow_ref": "main",
  "trigger_label": "issue-agent",
  "default_requirements": {
    "apps": ["sts2"]
  }
}
```

Check live state before queueing:

```powershell
Invoke-RestMethod https://glimmung.romaine.life/v1/state | ConvertTo-Json -Depth 10
```

A host is available when it is not drained and `current_lease_id` is `null`.

## Local Repo And MCP Config

The repository checkout must contain a working `.mcp.json` that points Claude at
`spire-lens-mcp`. For STS2 work, the issue-agent path must use MCP tools rather
than side channels.

Do not edit tracked `.mcp.json` for machine-specific STS2 paths during a run.
The workflow reads `.mcp.json` as a template, writes a per-job config under
`RUNNER_TEMP\issue-agent-mcp\`, updates that temporary file with the selected
host's `STS2_GAME_DIR`, and passes the temporary config to Claude and STS2 prep.
`.mcp.json` remains blocked from issue-agent publication.

Do not revive:

- `LiveScenarios/`
- `ops/live-worker/`
- request queues such as `request.json`, `ready.json`, `accepted.json`, or
  `result.json`
- `D:\automation\spirelens-live-bridge`

If the MCP surface is missing a needed capability, report that as a blocker.

If a checkout was created by a different Windows account, add a Git safe
directory exception for the interactive runner account:

```powershell
git config --global --add safe.directory D:/repos/spire-lens-mcp
```

## Baseline Checks

Before queueing real work on a new host, run:

```powershell
dotnet build SpireLens.csproj -c Debug -p:SkipModsDeploy=true
dotnet build Core/SpireLens.Core.csproj -c Debug -p:SkipModsDeploy=true
dotnet build Tests/SpireLens.Core.Tests/SpireLens.Core.Tests.csproj -c Debug
dotnet test Tests/SpireLens.Core.Tests/SpireLens.Core.Tests.csproj -c Debug --no-build
```

Then check GitHub sees the runners:

```powershell
gh api repos/nelsong6/spirelens/actions/runners --paginate `
  --jq '.runners[] | {name,status,busy,labels:[.labels[].name]}'
```

Expected:

- both runners for the host are `online`
- both have `issue-agent-worker`
- both have the same `issue-agent-runner-<host>` route label
- neither is busy before a smoke test

## Smoke Test

1. Confirm Glimmung state lists the host as free.
2. Add `issue-agent` to a low-risk issue.
3. Confirm the workflow run name includes the issue number/title and selected
   host.
4. Confirm both Windows jobs pass:
   - `Heartbeat glimmung lease`
   - `Prepare issue-agent host`
   - `Build and test baseline main`
   - `Verify Claude subscription auth`
5. Confirm Claude can use `spire-lens-mcp`.
6. Confirm artifacts upload even if the task later fails.

Do not requeue many issues until this smoke path passes on the host.
