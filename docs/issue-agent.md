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

1. GitHub issue event fires.
2. GitHub Actions starts one workflow job on a self-hosted runner labeled `issue-agent`.
3. Claude is launched for that exact issue number only.
4. Claude owns the issue work: code changes, comments, labels, tests, and PR creation.

There is no second script that chooses issues, reads structured result files, or drains a local queue.

## Runner Contract

Each Windows issue-agent host should provide:

- self-hosted GitHub Actions runner labeled `issue-agent`
- Claude Code installed locally and discoverable either through repository
  variable `ISSUE_AGENT_CLAUDE_CLI_PATH` or one of the documented default
  locations
- a normal Actions checkout for this repo under `GITHUB_WORKSPACE`
- an STS2 Modding MCP checkout wherever the local `.mcp.json` points to it
- project `.mcp.json` configured to point at `sts2-modding`

The workflow loads Azure Key Vault secret `spirelens` and exposes it to Claude Code as:

- `ANTHROPIC_API_KEY`

Required repository variables:

- `ARM_CLIENT_ID`
- `ARM_TENANT_ID`
- `ARM_SUBSCRIPTION_ID`
- `KEY_VAULT_NAME`
- `KEY_VAULT_SUBSCRIPTION_ID`

## Local Host Bring-Up

The active host path is now laptop-first.

Use [docs/laptop-issue-agent-runner.md](./laptop-issue-agent-runner.md) for the
local Windows runner setup and
[ops/windows-worker/Register-LocalIssueAgentRunner.ps1](../ops/windows-worker/Register-LocalIssueAgentRunner.ps1)
to register the machine as the repository runner.

## MCP Requirement

For STS2 issue-agent work, `sts2-modding` is a hard prerequisite.

- `.mcp.json` must declare `sts2-modding`
- Claude must be able to list and connect to `sts2-modding` before the issue agent starts
- `sts2-modding` must pass a minimal no-side-effect readiness probe before the main task begins
- if any of those checks fail, stop immediately and report a blocker
- do not fall back to raw TCP bridge calls, ad hoc PowerShell bridge scripts, Azure Python imports, Windows API clicking, or other non-MCP workarounds
- missing MCP capability is a tooling gap to report, not a reason to invent side automation

In this environment, stateful STS2 work should go through approved MCP tools rather than improvised side paths.


## Phased Script Workflow

The issue-agent job is script-controlled and runs Claude in three separate phases:

1. Investigation: identifies the issue target, card/character facts, MCP/game-state needs, and validation plan. It cannot edit code.
2. Implementation: applies code changes only if the investigation plan is viable and appropriately scoped.
3. Verification: runs tests, live MCP validation, screenshots, and final evidence checks.

Each phase writes both machine-readable JSON and human-readable Markdown:

- `issue-agent-investigation.json` / `issue-agent-investigation.md`
- `issue-agent-implementation.json` / `issue-agent-implementation.md`
- `issue-agent-verification.json` / `issue-agent-verification.md`
- `issue-agent-result.json` / `issue-agent-result.md`

The script reads each phase JSON before continuing. If a phase reports `status: abort`, the script stops and the final summary reports the abort layer and reason.

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
- `mcp_state_mismatch`
- `claimed_result_not_observed`
- `artifact_contract_missing`

Each phase Markdown is appended to the GitHub job summary as soon as the phase finishes. The final summarizer also posts a compact rollup with phase statuses, artifact links, screenshot counts, and any PR link reported by the implementation or result JSON.

## Visibility

The issue-agent workflow writes and uploads validation artifacts:

- `claude-issue-agent-events.jsonl`
- `claude-issue-agent-summary.log`
- `claude-issue-agent-debug.log`
- screenshots saved under `sts2-screenshots/`
- additional validation artifacts saved under `sts2-artifacts/`

These are uploaded as Actions artifacts after every run, even on failure, so the post-run Claude trace and live validation evidence are visible from another machine.

## Screenshot Validation

For STS2 issue-agent work:

- capture screenshot artifacts of the affected card or tooltip states before marking the issue complete
- always include at least one screenshot
- if the issue is about a specific card, include at least one screenshot showing that card's stats working in a representative in-run test case
- document the test case used for the screenshot artifacts: what was set up, what was exercised, and what each screenshot is intended to prove
- capture screenshots after the behavior is working, not just during setup
- for tooltip-related changes, capture the affected tooltip states and use judgment about which views materially need coverage
- if multiple materially distinct views changed, such as compact hand-hover and fuller deck-view tooltip states, capture each affected view when that is the clearest way to prove the change
- use judgment on how many screenshots to include, but do not exceed 10 screenshots for a single issue or pull request
- if adequate proof would require more than 10 screenshots, split the work into smaller branches or pull requests instead of overloading one
- if screenshot capture is impossible, stop and report the blocker instead of completing the issue without screenshot artifacts
- in the issue comment and pull request summary, include the test-case summary and the screenshot or artifact links or paths

## Direct Control Rule

For STS2 work, Claude should use direct MCP/game control through `sts2-modding`.

The issue-agent path should not use:

- `LiveScenarios/`
- `ops/live-worker/`
- filesystem request queues such as `request.json`, `ready.json`, `accepted.json`, or `result.json`
- `D:\automation\spirelens-live-bridge`

If the current MCP surface is insufficient for an issue, Claude should report the blocker on the issue instead of reviving side infrastructure.
