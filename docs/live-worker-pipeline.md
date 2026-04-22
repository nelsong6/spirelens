# Live Worker Pipeline

Issue [#51](https://github.com/nelsong6/card-utility-stats/issues/51) proposes a control-plane / worker-pool split:

- the main work machine edits code, dispatches runs, and reviews artifacts
- dedicated Windows side machines run Slay the Spire 2 and execute live scenarios

This document is the first milestone implementation plan for that setup using GitHub Actions self-hosted runners.

## Current Rollout Phase

The target design is still a small worker pool, but the current rollout should start with one side machine first.

Current shape:

- one Windows self-hosted worker machine
- that machine is labeled both `sts2-live` and `sts2-side-a`
- the workflow still targets the shared `sts2-live` label so a second worker can be added later without changing the workflow contract

## Current First Milestone

The repo now includes:

- a manual GitHub Actions workflow at [.github/workflows/live-sts2-manual.yml](D:/repos/card-utility-stats/.github/workflows/live-sts2-manual.yml:1)
- a runner-side harness at [scripts/ci/run-live-scenario.ps1](D:/repos/card-utility-stats/scripts/ci/run-live-scenario.ps1:1)
- checked-in scenario manifests under [LiveScenarios](D:/repos/card-utility-stats/LiveScenarios/README.md:1)

The first pass is intentionally conservative:

- dispatch manually with `workflow_dispatch`
- target any available runner labeled `sts2-live`
- run repo tests
- build and deploy the mod to the worker's local STS2 `mods` directory
- hand off to a worker-local live-driver script
- upload artifacts back to GitHub Actions

The workflow does not try to solve worker reset, Steam login recovery, or MCP/game automation orchestration centrally yet. Those remain worker-local concerns until the live path is stable.

## Worker Model

Register the first side machine as a self-hosted GitHub Actions runner for this repo.

When a second machine exists later, reuse the same shared label strategy.

Recommended shared labels:

- `self-hosted`
- `windows`
- `sts2-live`

Recommended unique label for the first machine:

- `sts2-side-a`

Use the shared label for normal queueing. Keep the unique labels available for debugging or machine-specific dispatch later.

## Required Worker Software

Each side machine should have:

- Steam installed and able to launch Slay the Spire 2 without interactive repair prompts
- Slay the Spire 2 installed locally
- GitHub Actions runner service installed and running
- PowerShell 7 available for workflow steps
- .NET 9 SDK available, or allow `actions/setup-dotnet` to acquire it per run
- whatever local MCP bridge / window automation tooling will eventually drive STS2

Recommended but not enforced yet:

- disable sleep while the runner service is active
- use a dedicated Windows user profile for the runner
- keep Steam in a stable logged-in state
- keep game resolution and display arrangement fixed so screenshot comparisons remain meaningful

## Required Worker Environment Variables

Set these on each side machine before expecting live scenario execution to succeed:

- `CARD_UTILITY_STATS_STS2_PATH`
  - Absolute path to the local Slay the Spire 2 install.
  - Example: `D:\SteamLibrary\steamapps\common\Slay the Spire 2`
- `CARD_UTILITY_STATS_LIVE_DRIVER`
  - Absolute path to the worker-local PowerShell script that actually launches the game, drives the scenario, and captures screenshots/logs.
  - Example: `D:\automation\card-utility-stats\Invoke-Sts2Scenario.ps1`
- `CARD_UTILITY_STATS_RUN_DATA_DIR`
  - Optional override for the directory containing run JSON output.
  - Default if omitted: `%APPDATA%\SlayTheSpire2\CardUtilityStats\runs`

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

## Next Steps

After the bootstrap pipeline is proven on the first side machine, the next likely improvements are:

- add a real worker reset routine before each run
- promote the worker-local driver contract into a repo-managed script package
- standardize screenshot naming and metadata
- add machine health checks
- split quick validation runs from full live scenario runs
- add a second `sts2-live` worker once the single-machine path is stable
- optionally add a second workflow for queued branch validation against the shared `sts2-live` pool
