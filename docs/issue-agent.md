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
- Claude Code installed at `D:\automation\claude-code`
- project checkout under `D:\repos\card-utility-stats`
- STS2 Modding MCP checkout under `D:\repos\sts2-modding-mcp`
- project `.mcp.json` configured to point at `sts2-modding`

The workflow loads Azure Key Vault secret `card-utility-stats` and exposes it to Claude Code as:

- `ANTHROPIC_API_KEY`

Required repository variables:

- `ARM_CLIENT_ID`
- `ARM_TENANT_ID`
- `ARM_SUBSCRIPTION_ID`
- `KEY_VAULT_NAME`
- `KEY_VAULT_SUBSCRIPTION_ID`

## Visibility

The issue-agent workflow writes and uploads:

- `claude-issue-agent-events.jsonl`
- `claude-issue-agent-summary.log`
- `claude-issue-agent-debug.log`

These are uploaded as Actions artifacts after every run, even on failure, so the post-run Claude trace is visible from another machine.

## Direct Control Rule

For STS2 work, Claude should use direct MCP/game control through `sts2-modding`.

The issue-agent path should not use:

- `LiveScenarios/`
- `ops/live-worker/`
- filesystem request queues such as `request.json`, `ready.json`, `accepted.json`, or `result.json`
- `D:\automation\card-utility-stats-live-bridge`

If the current MCP surface is insufficient for an issue, Claude should report the blocker on the issue instead of reviving side infrastructure.
