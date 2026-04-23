# Live Scenarios

These manifests are the repo-owned description of a live STS2 test run.

They are deliberately lightweight:

- GitHub Actions owns dispatch and artifact upload
- the repo-owned harness owns build/test/deploy and handoff
- the worker-local live-driver script decides how to drive the game for each manifest

## Current Shape

Each scenario file is JSON with:

- `name`
- `description`
- `tags`
- `intent`
- `artifact_expectations`
- `driver`

The `driver` payload is intentionally flexible for the bootstrap phase. It gives us a checked-in, reviewable scenario contract without forcing a single automation engine before the VMSS-backed workers are live.

`driver.automation` opts a scenario into the in-game mod automation path. The worker bridge publishes the active request, the `CardUtilityStats` mod executes each step inside STS2, and the result is uploaded as `driver-output/scenario-automation-result.json`.

## Initial Scenarios

- [noxious_fumes_basic.json](D:/repos/card-utility-stats/LiveScenarios/noxious_fumes_basic.json:1)
- [forge_grant_basic.json](D:/repos/card-utility-stats/LiveScenarios/forge_grant_basic.json:1)
- [make_it_so_summon_basic.json](D:/repos/card-utility-stats/LiveScenarios/make_it_so_summon_basic.json:1)
- [tooltip_visual_check.json](D:/repos/card-utility-stats/LiveScenarios/tooltip_visual_check.json:1)

## Driver Guidance

The worker-local automation layer should use the `driver` payload to decide:

- what save/profile/bootstrap state to load
- what scripted actions to perform
- when to capture screenshots
- what success conditions to enforce

The initial in-game automation actions are:

- `start_run`
- `wait_for_run`
- `enter_combat`
- `wait_for_combat`
- `grant_card`
- `play_card`
- `console`
- `wait`
- `win_combat`

If the scenario contract grows beyond this lightweight phase, we can promote it into a dedicated schema with validation.
