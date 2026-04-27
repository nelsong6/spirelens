# Issue Agent

The current issue-agent model is GitHub Actions driven.

There is no repo-owned queue worker, scheduled task, filesystem lock, or outer loop script anymore. GitHub supplies the event and queue layer.

## Trigger Contract

An issue is eligible for autonomous work when it has:

- `issue-agent`

The issue-agent workflow is triggered by the GitHub issue event, and GitHub passes the exact issue number into the run.

Issue-agent labels are:

- `issue-agent`
- `issue-agent-running`
- `issue-agent-blocked`
- `issue-agent-complete`
- `issue-agent-pr-open`

## Processing Model

The processing model is intentionally simple:

1. GitHub issue event fires, or a human manually dispatches the workflow for one issue number.
2. GitHub Actions starts one workflow job on a self-hosted runner labeled `issue-agent`.
3. That one job exposes investigation, implementation, and verification as separate visible Actions steps.
4. Each phase step launches a fresh Claude Code invocation with its own prompt, tool permissions, timeout, budget, logs, and handoff artifacts.
5. Claude owns the issue work through the phase contract: investigation, implementation, verification, tests, screenshots, and evidence. GitHub mutations are wrapper-owned after phase artifacts are written.

There is no second script that chooses issues, reads structured result files, or drains a local queue.

## Runner Contract

Each Windows issue-agent host should provide:

- self-hosted GitHub Actions runner labeled `issue-agent`
- Claude Code installed locally and discoverable either through repository
  variable `ISSUE_AGENT_CLAUDE_CLI_PATH` or one of the documented default
  locations
- a normal Actions checkout for this repo under `GITHUB_WORKSPACE`
- a SpireLens MCP checkout wherever the local `.mcp.json` points to it
- project `.mcp.json` configured to point at `spire-lens-mcp`
- Claude Code authenticated once as the interactive runner account

The workflow verifies `claude auth status` before launching the phased agent. It does not load an Anthropic API key from a runner file.

## Local Host Bring-Up

The active host path is now laptop-first.

Use [docs/laptop-issue-agent-runner.md](./laptop-issue-agent-runner.md) for the
local Windows runner setup and
[ops/windows-worker/Register-LocalIssueAgentRunner.ps1](../ops/windows-worker/Register-LocalIssueAgentRunner.ps1)
to register the machine as the repository runner.

## MCP Requirement

For STS2 issue-agent work, `spire-lens-mcp` is a hard prerequisite.

- `.mcp.json` must declare `spire-lens-mcp`
- Claude must be able to list and connect to `spire-lens-mcp` before the issue agent starts
- `spire-lens-mcp` must pass a minimal no-side-effect readiness probe before the main task begins
- if any of those checks fail, stop immediately and report a blocker
- do not fall back to raw TCP bridge calls, ad hoc PowerShell bridge scripts, Azure Python imports, Windows API clicking, or other non-MCP workarounds
- missing MCP capability is a tooling gap to report, not a reason to invent side automation

In this environment, stateful STS2 work should go through approved MCP tools rather than improvised side paths.

## Phased Step Workflow

The issue-agent workflow is one GitHub Actions job with separate visible phase steps:

1. `Investigate test primitives`
2. `Implement code change`
3. `Verify in STS2`
4. `Create pull request`
5. `Summarize issue-agent run`

This keeps the Actions page easy to follow without turning the flow into several independent CI jobs. It also preserves the important split: each phase has a fresh context, narrower tool permissions, its own timeout, its own budget, and explicit JSON/Markdown handoff artifacts.

Claude runs in three separate invocations:

1. Investigation: reads the issue/comments, identifies the issue target, card/character facts, MCP/game-state needs, and validation plan. It cannot edit code.
2. Implementation: consumes the investigation handoff artifacts and applies code changes only if the investigation plan is viable and appropriately scoped. It cannot read or mutate GitHub.
3. Verification: consumes the investigation and implementation handoff artifacts, runs tests, save-backed live MCP validation, screenshots, and final evidence checks. It has no GitHub token and cannot read or mutate GitHub.
4. The workflow wrapper creates the branch, commit, push, and PR only after verification reports `status: pass`.

Verification should default to the save-backed route: materialize a scenario from the correct character base save, install it as current, validate/load it, inspect the live state, and only then configure the already-loaded combat. Quick helpers that start ad hoc runs or choose Neow options are intentionally out of the default path.

Investigation also writes a machine-checkable `required_evidence` contract. Each item has an `id`, `kind`, `required`, and `must_show`; screenshot evidence can also require `target_visible_required` and `text_visible_required`. Verification must answer every required item in `evidence_results` before it can pass. The wrapper blocks contradictory passes, including tooltip/text evidence that says the tooltip was unavailable, visible evidence that has no screenshot path, or screenshot evidence that relies on unit tests instead of visible UI proof.

Each phase writes both machine-readable JSON and human-readable Markdown:

- `issue-agent-investigation.json` / `issue-agent-investigation.md`
- `issue-agent-implementation.json` / `issue-agent-implementation.md`
- `issue-agent-verification.json` / `issue-agent-verification.md`
- `issue-agent-result.json` / `issue-agent-result.md`

The workflow reads each phase JSON before continuing. If investigation or implementation reports `status: abort`, later phase steps are skipped and the final summary reports the abort layer and reason. If verification aborts, no PR is created; the summary still publishes screenshots gathered so far and the specific verifier failure. A verifier `status: pass` is rechecked by the wrapper against the investigation `required_evidence` contract before the workflow can proceed to PR creation.

Allowed investigation abort reasons:

- `card_not_found`
- `card_ambiguous`
- `character_not_found`
- `metadata_unavailable`
- `mcp_capability_missing`
- `game_state_unreachable`
- `validation_plan_impossible`

Allowed implementation abort reasons:

- `change_too_large`
- `requires_new_library`
- `requires_architecture_change`
- `unsafe_refactor`
- `missing_code_context`
- `conflicting_requirements`
- `cannot_implement_without_guessing`

Allowed verification abort reasons:

- `unit_tests_failed`
- `live_validation_failed`
- `screenshot_missing`
- `screenshot_not_relevant`
- `target_evidence_missing`
- `mcp_state_mismatch`
- `game_state_unreachable`
- `claimed_result_not_observed`
- `artifact_contract_missing`

Each phase Markdown is appended to the job summary as soon as the phase finishes. The final summary step posts a compact rollup with phase statuses, per-phase costs, grand total cost, artifact links, screenshot counts, and any PR link created by the wrapper and written back into the result JSON.

## Relic Stat Prompting

Relic-stat implementation issues should keep the same issue-agent workflow as card-stat issues, but their prompts should include an explicit reference-code boundary.

When assigning an agent relic-stat work:

- Point the agent at existing relic stats mods only for hook discovery, StS2 class/method names, relic IDs, behavior mapping, and likely validation scenarios.
- For unlicensed reference repos, including `rmac-silva/RelicTracker`, do not copy code, file structure, tooltip strings, formatting, or implementation organization.
- For MIT reference repos, including `ForgottenArbiter/StsRelicStats`, preserve attribution if any concrete design is reused, but still prefer a SpireLens-native implementation over transliterating Java/BaseMod patterns.
- Implement through SpireLens's existing `RunTracker`, `RunData`, schema fixtures, tests, runtime options, and tooltip conventions.
- Prefer observed outcomes over intended relic text or generic trigger animation counts. A generic `RelicModel.Flash()` count can be useful as a fallback or debugging clue, but user-facing stats should use richer observed outcomes when available.
- Classify each relic issue as `relic-only`, `card-modifier`, `shared-outcome`, or `economy/map` so overlap with card stats is handled deliberately instead of by accident.

Useful per-relic issue prompt language:

```md
Reference-code boundary:
You may inspect existing relic stats mods to identify StS2 relic class names, method names, hook candidates, and behavioral clues. Do not copy code, structure, tooltip strings, or formatting from unlicensed repositories. Implement original SpireLens-native code using the existing tracker, schema, tests, and tooltip style. Prefer observed outcomes over listed intent or generic trigger counts.
```

## Visibility

The issue-agent workflow writes and uploads validation artifacts:

- `claude-issue-agent-events.jsonl`
- `claude-issue-agent-summary.log`
- `claude-issue-agent-debug.log`
- screenshots saved under `sts2-screenshots/`
- additional validation artifacts saved under `sts2-artifacts/`

These are uploaded as Actions artifacts after every run, even on failure, so the post-run Claude trace and live validation evidence are visible from another machine. The workflow intentionally leaves STS2 running at the final validation state so a human can inspect the game after the Actions job finishes.

## Screenshot Validation

For STS2 issue-agent work:

- capture screenshot artifacts through the `capture_screenshot` MCP tool before marking the issue complete
- always include at least one full STS2 game-window screenshot
- if the issue is about a specific card, include at least one screenshot showing that card's stats working in a representative in-run test case
- if the issue is about a specific relic, include `get_game_state` evidence for the resolved relic id/name plus at least one screenshot showing that relic's stats working in a representative in-run test case
- document the test case used for the screenshot artifacts: what was set up, what was exercised, and what each screenshot is intended to prove
- capture screenshots after the behavior is working, not just during setup
- for tooltip-related changes, capture the affected tooltip states in the relevant hand, deck, draw pile, discard pile, exhaust pile, rewards, selection, or other card surface; the screenshot evidence item should set `text_visible_required:true`, and verification must copy the visible text into `observed_text`
- for SpireLens card-stat tooltip proof, use the MCP route `bridge_health` -> `set_spirelens_view_stats_enabled(true)` -> `list_visible_cards(surface)` -> `show_card_tooltip(surface, card_index, card_id)` -> `capture_screenshot` so the screenshot shows the target card tooltip text directly
- for SpireLens relic-stat tooltip proof, use the MCP route `bridge_health` -> `set_spirelens_view_stats_enabled(true)` -> `list_visible_relics(surface)` -> `show_relic_tooltip(surface, relic_id)` -> `capture_screenshot` so the screenshot shows the target relic tooltip text directly
- prefer `player_relic_bar` for owned relic stats unless the issue specifically needs `relic_select` or `treasure`
- if multiple materially distinct views changed, such as compact hand-hover and fuller deck-view tooltip states, capture each affected view when that is the clearest way to prove the change
- use judgment on how many screenshots to include, but do not exceed 10 screenshots for a single issue or pull request
- if adequate proof would require more than 10 screenshots, split the work into smaller branches or pull requests instead of overloading one
- if screenshot capture is impossible, stop and report the blocker instead of completing the issue without screenshot artifacts
- in the issue comment and pull request summary, include the test-case summary and the screenshot or artifact links or paths

## Direct Control Rule

For STS2 work, Claude should use direct MCP/game control through `spire-lens-mcp`.

The issue-agent path should not use:

- `LiveScenarios/`
- `ops/live-worker/`
- filesystem request queues such as `request.json`, `ready.json`, `accepted.json`, or `result.json`
- `D:\automation\spirelens-live-bridge`

If the current MCP surface is insufficient for an issue, Claude should report the blocker on the issue instead of reviving side infrastructure.
