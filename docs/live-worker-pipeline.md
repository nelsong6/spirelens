# Live Worker Pipeline

The live worker path is now the Glimmung-dispatched issue-agent workflow.

This document is a short orientation page. The operational setup details live in
[docs/issue-agent.md](./issue-agent.md) and
[docs/laptop-issue-agent-runner.md](./laptop-issue-agent-runner.md).

## Current Model

1. A human adds `issue-agent` to a GitHub issue.
2. Glimmung receives the issue event, claims one compatible host lease, and
   dispatches `.github/workflows/issue-agent.yaml`.
3. The workflow verifies the lease, then routes all Windows phase jobs to
   self-hosted runners with `issue-agent-worker` plus the selected
   `issue-agent-runner-<host>` label.
4. Claude uses the repo `.mcp.json` and `spire-lens-mcp` for STS2
   inspection/control.
5. The workflow wrapper uploads logs and artifacts, publishes an implementation
   branch, and opens a PR only after verification passes.

GitHub Actions is not the queue. Do not add a workflow-level concurrency group
for issue-agent runs; GitHub keeps only one pending run per group and evicts
older pending runs.

## Direct MCP Rule

For live STS2 work, MCP is the primary control surface.

Claude should not use:

- repo-managed scenario manifests
- repo-owned live-driver scripts
- filesystem request queues
- `D:\automation\spirelens-live-bridge`
- in-game automation contracts based on `request.json`, `ready.json`,
  `accepted.json`, or `result.json`

If the MCP surface is insufficient for a task, the correct result is a blocker
report on the issue, not resurrection of old bridge machinery.

## Worker Layout

Each Glimmung host should have at least one, preferably two, interactive
Windows GitHub Actions runners. Every worker runner on a host should have:

- `issue-agent-worker`
- one route label such as `issue-agent-runner-nelsonlaptop`

Runner route labels are not issue labels. Applying `issue-agent-runner-...` to
an issue does not force routing.

The runner account must be the logged-in Steam user with Claude auth, Steam,
STS2, `uv`, and the expected user PATH available.

## Visibility

The issue-agent workflow uploads artifacts after every run, including failures:

- `claude-issue-agent-events.jsonl`
- `claude-issue-agent-summary.log`
- `claude-issue-agent-debug.log`
- screenshots under `sts2-screenshots/`
- additional validation artifacts under `sts2-artifacts/`

Workflow run names should include the issue number, issue title, and selected
host, for example:

```text
#149 Add relic stats for Orichalcum (issue-agent-runner-nelsonlaptop)
```

## Related Docs

- [docs/issue-agent.md](./issue-agent.md)
- [docs/laptop-issue-agent-runner.md](./laptop-issue-agent-runner.md)
- [docs/reboot-safe-issue-agent-runner.md](./reboot-safe-issue-agent-runner.md)
