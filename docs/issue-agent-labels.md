# Issue Agent Labels

The issue-agent workflow has two different label concepts:

- `flow improvement`: human backlog and design work. This label must never start automation.
- `issue-agent-run`: explicit runnable automation label. Applying this label to an issue is a request to run the issue-agent.

Do not use the runnable label while bulk-creating or organizing backlog issues. Prefer `workflow_dispatch` with an explicit issue number when testing a single issue-agent run.