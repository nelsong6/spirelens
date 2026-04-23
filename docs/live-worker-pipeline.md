# Live Worker Pipeline

Issue [#51](https://github.com/nelsong6/card-utility-stats/issues/51) is now aligned around a direct GitHub Actions + Claude + MCP model.

The old repo-managed scenario manifests, bridge-driver queue files, and in-game `active-request.json` automation path were removed because they kept pulling the agent into obsolete side infrastructure.

## Current Model

The intended flow is:

1. GitHub issue event triggers the issue-agent workflow.
2. GitHub Actions selects one self-hosted Windows runner labeled `issue-agent`.
3. Claude receives the exact issue number from the event.
4. Claude uses the project `.mcp.json` and the `sts2-modding` MCP server directly for STS2 inspection/control.
5. Claude comments on the issue, updates labels, and opens a PR if code changes are required.

## Direct MCP Rule

For live STS2 work, the repo now treats MCP as the primary control surface.

Claude should not use:

- repo-managed scenario manifests
- repo-owned live-driver scripts
- filesystem request queues
- `D:\automation\card-utility-stats-live-bridge`
- in-game automation contracts based on `request.json` / `ready.json` / `accepted.json` / `result.json`

If the MCP surface is insufficient for a task, the correct result is a blocker report on the issue, not resurrection of old bridge machinery.

## Worker Layout

Standard Windows worker layout:

- `D:\repos\card-utility-stats`
- `D:\repos\sts2-modding-mcp`
- `D:\automation\claude-code`

The project `.mcp.json` should point Claude to `sts2-modding`.

Expected live MCP endpoints when STS2 is running with the MCP bridge mods installed:

- `localhost:21337`
- `localhost:27020`

## Auth And Visibility

The issue-agent workflow:

- loads Azure Key Vault secret `card-utility-stats`
- maps it to `ANTHROPIC_API_KEY`
- streams Claude activity into the Actions log
- uploads agent logs as artifacts after every run

Uploaded logs:

- `claude-issue-agent-events.jsonl`
- `claude-issue-agent-summary.log`
- `claude-issue-agent-debug.log`

## VMSS Direction

VMSS is still a valid target, but the worker image should be built around:

- GitHub Actions runner
- Claude Code
- STS2 install
- STS2 Modding MCP
- project checkout + `.mcp.json`

Not around:

- queue-worker scheduled tasks
- scenario JSON manifests
- filesystem bridge request directories

## Related Docs

- [docs/issue-agent.md](./issue-agent.md)
- [docs/vmss-worker-bootstrap.md](./vmss-worker-bootstrap.md)
