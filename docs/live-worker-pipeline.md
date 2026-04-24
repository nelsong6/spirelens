# Live Worker Pipeline

Issue [#51](https://github.com/nelsong6/spirelens/issues/51) is now aligned around a direct GitHub Actions + Claude + MCP model.

The old repo-managed scenario manifests, bridge-driver queue files, and in-game `active-request.json` automation path were removed because they kept pulling the agent into obsolete side infrastructure.

## Current Model

The intended flow is:

1. GitHub issue event triggers the issue-agent workflow.
2. GitHub Actions selects one self-hosted Windows runner labeled `issue-agent`.
3. Claude receives the exact issue number from the event.
4. Claude uses the project `.mcp.json` and the `sts2-modding` MCP server directly for STS2 inspection/control.
5. Claude comments on the issue, updates labels, opens a PR if code changes are required, and records validation artifacts for review.

## Direct MCP Rule

For live STS2 work, the repo now treats MCP as the primary control surface.

Claude should not use:

- repo-managed scenario manifests
- repo-owned live-driver scripts
- filesystem request queues
- `D:\automation\spirelens-live-bridge`
- in-game automation contracts based on `request.json` / `ready.json` / `accepted.json` / `result.json`

If the MCP surface is insufficient for a task, the correct result is a blocker report on the issue, not resurrection of old bridge machinery.

## Worker Layout

The active worker path is a local Windows machine, usually the laptop.

Common local layout:

- repo checkout wherever GitHub Actions places `GITHUB_WORKSPACE`
- STS2 Modding MCP checkout at any stable local path referenced by `.mcp.json`
- Claude Code at one of the documented default locations or repository variable
  `ISSUE_AGENT_CLAUDE_CLI_PATH`

The project `.mcp.json` should point Claude to `sts2-modding`.

Expected live MCP endpoints when STS2 is running with the MCP bridge mods installed:

- `localhost:21337`
- `localhost:27020`

## Auth And Visibility

The issue-agent workflow:

- loads Azure Key Vault secret `spirelens`
- maps it to `ANTHROPIC_API_KEY`
- streams Claude activity into the Actions log
- uploads validation artifacts after every run

Uploaded artifacts:

- `claude-issue-agent-events.jsonl`
- `claude-issue-agent-summary.log`
- `claude-issue-agent-debug.log`
- screenshots saved under `sts2-screenshots/`
- additional validation artifacts saved under `sts2-artifacts/`

For card- and tooltip-facing issues, runs should include at least one screenshot from a representative in-run test case, along with a test-case summary describing what was set up, what was exercised, and what the screenshot proves. Use judgment for additional coverage, but keep each issue or pull request to 10 screenshots or fewer and split broader work when needed.

## Current Deployment Direction

The current deployment direction is not VMSS. The active path is a local
Windows issue-agent runner with the `issue-agent` label.

That runner should still be built around:

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
- [docs/laptop-issue-agent-runner.md](./laptop-issue-agent-runner.md)
