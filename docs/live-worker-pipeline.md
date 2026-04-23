# Live Worker Pipeline

Issue [#51](https://github.com/nelsong6/card-utility-stats/issues/51) started as a control-plane / worker-pool split:

- the main work machine edits code, dispatches runs, and reviews artifacts
- dedicated Windows workers run Slay the Spire 2 and execute live scenarios

The long-term deployment target is Azure VM Scale Sets (VMSS), but the laptop can also be a first-class worker-pool member while Azure quota and image bootstrap are still moving. This document describes the shared GitHub Actions worker contract that both the laptop and VMSS nodes should satisfy.

## Current Rollout Phase

The target design is:

- a scalable Windows VMSS for live STS2 execution
- a singleton queue host for autonomous Codex issue draining
- repo-owned scenario manifests, artifact contracts, and runner-side harness scripts

The current first step should stay conservative:

- recruit the laptop as Worker 1 in the shared `sts2-live` pool
- prove the workflow on one manually configured Windows VM first
- capture that VM as the golden image
- create a VMSS at capacity `1`
- register the first instance as both `sts2-live` and `codex-queue`
- keep that combined role only while capacity is `1`
- split queue and live roles before scaling live execution beyond one instance

## Current First Milestone

The repo now includes:

- a manual GitHub Actions workflow at [.github/workflows/live-sts2-manual.yml](../.github/workflows/live-sts2-manual.yml)
- a runner-side harness at [scripts/ci/run-live-scenario.ps1](../scripts/ci/run-live-scenario.ps1)
- checked-in scenario manifests under [LiveScenarios](../LiveScenarios/README.md)

The first pass is intentionally conservative:

- dispatch manually with `workflow_dispatch`
- target any available runner labeled `sts2-live`
- run repo tests
- build and deploy the mod to the worker's local STS2 `mods` directory
- hand off to a worker-local live-driver script
- upload artifacts back to GitHub Actions

The workflow does not try to solve VM reimage policy, laptop reset policy, Steam recovery, or MCP/game automation orchestration centrally yet. Those remain worker-local concerns until the live path is stable.

## Laptop Worker 1

The laptop is allowed to be a real pool member, not just a temporary manual test box.

Treat it as:

- worker name: `sts2-side-a`
- shared pool label: `sts2-live`
- unique debug label: `sts2-side-a`
- queue host role: optional, only if it also carries the queue scheduled task
- live scenario role: yes, once STS2 and the worker-local driver are configured

The repo includes a readiness check at [ops/live-worker/Test-LiveWorkerReadiness.ps1](../ops/live-worker/Test-LiveWorkerReadiness.ps1). It separates two questions:

- Is this machine in the agent pool and reachable by GitHub Actions?
- Is this machine fully ready to drive STS2 through the live driver?

That distinction lets the laptop join the pool before the Modding Assistant/MCP automation is fully stable.

The self-hosted workflows launch their repo-owned scripts with built-in Windows PowerShell so a runner service account does not depend on a user-scoped PowerShell 7 alias. The readiness report still records whether `pwsh` is visible because VMSS images should install PowerShell 7 machine-wide.

Because the GitHub runner service runs as `NETWORK SERVICE`, it should not directly manipulate the visible desktop. The repo default driver uses a file bridge instead:

- Actions calls [ops/live-worker/Invoke-Sts2BridgeDriver.ps1](../ops/live-worker/Invoke-Sts2BridgeDriver.ps1).
- The bridge driver writes a request under `D:\automation\card-utility-stats-live-bridge`.
- A user-session process runs [ops/live-worker/Start-Sts2InteractiveBridge.ps1](../ops/live-worker/Start-Sts2InteractiveBridge.ps1).
- The user-session process launches or attaches to STS2, captures screenshots/logs, and writes the result back for Actions to upload.

The first checked-in interactive driver is a launch/capture smoke driver. It proves the full Actions -> laptop bridge -> STS2 -> artifact loop. Scenario-specific intelligent navigation still belongs behind `CARD_UTILITY_STATS_MCP_ENDPOINT` or a richer future driver.

STS2 direct launches need `steam_appid.txt` in the game install folder with the Steam app id `2868840`. The checked-in interactive driver creates that file if it is missing.

Run this locally on the laptop:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ops\live-worker\Test-LiveWorkerReadiness.ps1 `
  -RepoSlug 'nelsong6/card-utility-stats' `
  -WorkerName 'sts2-side-a' `
  -OutputPath "$env:TEMP\card-utility-stats-worker-readiness.json"
```

When STS2 and the live-driver script are configured, run the stricter check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ops\live-worker\Test-LiveWorkerReadiness.ps1 `
  -RepoSlug 'nelsong6/card-utility-stats' `
  -WorkerName 'sts2-side-a' `
  -RequireGameDriver `
  -OutputPath "$env:TEMP\card-utility-stats-worker-readiness.json"
```

There is also a manual GitHub Actions workflow, `Live Worker Readiness`, that targets the `sts2-live` pool and uploads the same readiness report as an artifact.

For this laptop specifically, dispatch it with:

- `runs_on_json`: `["self-hosted","windows","sts2-side-a"]`
- `worker_name`: `sts2-side-a`
- `require_game_driver`: `false` until STS2 and the live driver are ready

Start the laptop user-session bridge with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ops\live-worker\Start-Sts2InteractiveBridge.ps1
```

The bridge can also be registered as a per-user logon task so it comes back after reboot.

## Recommended Pool Shape

Phase 1 combined host:

- one Windows VM or VMSS instance
- labels: `self-hosted`, `windows`, `sts2-live`, `codex-queue`
- runs both the manual live workflow and the autonomous issue queue

Phase 2 split roles:

- live execution pool: VMSS instances labeled `self-hosted`, `windows`, `sts2-live`
- queue host: one dedicated VM or capacity-1 VMSS instance labeled `self-hosted`, `windows`, `codex-queue`
- optional canary label for experiments such as `sts2-live-canary`

Why split the roles before scaling?

- the live workflow is safe to scale horizontally because GitHub Actions selects one runner per job
- the queue worker is not yet safe to scale horizontally because its lock is local to one machine; see [docs/codex-issue-queue.md](./codex-issue-queue.md)

## VMSS Worker Model

Each VMSS instance should boot from an image that already contains:

- Steam installed and ready to launch Slay the Spire 2 in offline mode
- Slay the Spire 2 installed locally and launched at least once
- GitHub Actions runner bits or a first-boot runner registration bootstrap
- PowerShell 7
- GitHub CLI
- Git
- .NET 9 SDK available locally, or allow `actions/setup-dotnet` to acquire it per run
- the worker-local STS2 scenario driver plus any MCP/window automation dependencies it needs

If an instance also carries the `codex-queue` role, it additionally needs working Codex CLI access and GitHub CLI auth for unattended issue/PR operations.

Runner identity should come from the VMSS instance itself:

- default worker identity: runner name or hostname
- optional override: `CARD_UTILITY_STATS_WORKER_NAME`
- avoid hard-coded laptop-style names in workflow configuration

## Required Worker Environment Variables

Set these on the worker image or during first-boot bootstrap before expecting live scenario execution to succeed:

- `CARD_UTILITY_STATS_STS2_PATH`
  - Absolute path to the local Slay the Spire 2 install.
  - Example: `D:\SteamLibrary\steamapps\common\Slay the Spire 2`
- `CARD_UTILITY_STATS_LIVE_DRIVER`
  - Absolute path to the worker-local PowerShell script that launches the game, drives the scenario, and captures screenshots/logs.
  - Example: `D:\automation\card-utility-stats\Invoke-Sts2Scenario.ps1`
- `CARD_UTILITY_STATS_RUN_DATA_DIR`
  - Optional override for the directory containing run JSON output.
  - Default if omitted: `%APPDATA%\SlayTheSpire2\CardUtilityStats\runs`
- `CARD_UTILITY_STATS_WORKER_NAME`
  - Optional friendly worker name override for dashboards and queue comments.
  - Default if omitted: the runner name or VM hostname

The repo-owned workflow handles build/test/artifact staging. The worker-local driver handles game-specific automation.

## Dispatch Flow

Run the workflow from GitHub Actions with these inputs:

- `scenario_path`
  - Repo-relative path to a scenario manifest in `LiveScenarios/`
- `git_ref`
  - Branch, tag, or commit to test
- `configuration`
  - Usually `Release`
- `run_tests`
  - Run the core test suite before live execution
- `execute_live_driver`
  - Set to `false` when validating the runner/build/artifact pipeline before the real STS2 automation is ready

The selected runner will:

1. check out the requested ref
2. install .NET 9
3. run core tests
4. build `CardUtilityStats`
5. deploy the mod into the worker's local STS2 `mods` directory
6. invoke the worker-local live driver
7. collect artifacts back into the workflow run

## Artifact Contract

The harness stages these artifact directories:

- `scenario/`
  - the scenario manifest used for the run
- `logs/`
  - test logs and worker-driver logs
- `screenshots/`
  - visual captures created by the worker-local driver
- `run-data/`
  - `CardUtilityStats` JSON outputs and `prefs.json` when available
- `build/`
  - loader build output and the deployed `mods/CardUtilityStats` payload
- `driver-output/`
  - any extra files the worker-local driver writes

The worker-local live-driver script should treat those directories as its stable output contract.

## Worker-Local Driver Contract

`scripts/ci/run-live-scenario.ps1` expects `CARD_UTILITY_STATS_LIVE_DRIVER` to point at a PowerShell script that accepts these parameters:

- `-ScenarioPath`
- `-ArtifactRoot`
- `-ScreenshotsDir`
- `-LogsDir`
- `-RunDataDir`
- `-Sts2Path`

That driver should be responsible for:

- resetting the worker into a known pre-run state
- launching STS2
- applying or loading the requested scenario
- waiting for the scenario to complete or time out
- writing logs and screenshots into the provided artifact folders
- exiting non-zero on failure

Keeping the driver local lets the repo own the pipeline contract now without locking us into one automation implementation too early.

## Scenario Format

Scenario manifests live under `LiveScenarios/` and are intentionally simple JSON files.

Current fields:

- `name`
- `description`
- `tags`
- `intent`
- `artifact_expectations`
- `driver`

The `driver` object is the worker-local handoff payload. The repo documents the shape and expected semantics, but the first version does not require a single global scenario engine yet.

## Rollout Order

1. Prove one end-to-end live run on a hand-built Windows VM.
2. Capture that VM as the golden image.
3. Create a VMSS at capacity `1` and label the instance for both `sts2-live` and `codex-queue`.
4. Validate the manual workflow with `execute_live_driver=false`, then with `execute_live_driver=true`.
5. Enable the queue worker only after GitHub CLI auth and Codex auth are configured on the queue host.
6. Split `codex-queue` away from `sts2-live` before scaling live execution above one instance.
7. Add health checks, image refresh cadence, and autoscale rules after the single-instance path is stable.

## Related Docs

- [docs/codex-issue-queue.md](./codex-issue-queue.md)
- [docs/vmss-worker-bootstrap.md](./vmss-worker-bootstrap.md)
