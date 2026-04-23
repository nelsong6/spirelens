# Codex Issue Queue

The autonomous issue queue is intended to run on a dedicated queue host, not on every live STS2 worker. In Azure terms, that usually means one standalone VM or one VMSS instance/pool kept at capacity `1`.

The key requirement is operational, not prompt-based:

- the queue host can stay on by itself
- Codex can run headlessly on the queue host
- issues are processed through an actual queue
- the queue is drained one issue at a time until empty
- progress does not depend on a human repeatedly telling Codex to continue

## Queue Contract

The queue is defined by GitHub issue labels.

Issues are eligible for autonomous work when they have:

- `codex-queue`

Queue state is tracked with:

- `codex-active`
- `codex-blocked`
- `codex-complete`

Recommended meaning:

- `codex-queue`
  - ready for the worker to pick up
- `codex-active`
  - currently claimed by the worker
- `codex-blocked`
  - removed from the queue pending human input or missing prerequisites
- `codex-complete`
  - processed by the queue worker and no longer queued

## Processing Model

The worker script does not process "a couple of issues if the model remembers."

Instead it performs this deterministic loop:

1. acquire a local lock so only one queue run is active on the machine
2. find the oldest open issue labeled `codex-queue`
3. claim it by adding `codex-active`
4. invoke Codex headlessly against the repository for that issue
5. read the structured result from Codex
6. update labels/comments based on that result
7. repeat until no queued issues remain

That outer loop is owned by the script, not by the model.

## Why This Matters

This directly addresses the failure mode where Codex says "I'll keep going through 50 items" but stops after 2 or 3. In this design:

- each Codex run is responsible for one issue only
- the queue worker is responsible for continuing to the next issue
- the queue drain only stops when the queue is empty, the worker is blocked, or the machine/process fails

## VMSS Deployment Note

The current queue worker only prevents overlap on one machine by using a local lock file.

That means:

- it is safe against duplicate queue runs on the same host
- it is not yet a distributed lease/claim system across multiple hosts

Because of that, do not scale the queue role horizontally yet.

Current recommendation:

- give the queue host its own runner label: `codex-queue`
- run the scheduled task only on that queue host
- if one VM or VMSS instance is doing both queue and live work, keep capacity at `1`
- split queue and live roles before scaling the `sts2-live` pool beyond one instance

The live workflow can scale out earlier because GitHub Actions already handles runner selection for a single workflow job.

## Headless Codex

The worker does not rely on the packaged WindowsApps alias for `codex.exe`, which is awkward to execute from unattended shells.

Instead, the bootstrap step copies the installed Codex CLI into a normal local path and executes that copy. The copied CLI still uses the existing `~/.codex` auth and configuration on the machine.

For GitHub Actions wakeups, the repo uses API-key auth for repeatability across laptops, desktop PCs, and VMSS instances. Store the key in Azure Key Vault as:

- Key Vault secret name: `card-utility-stats`

The workflow loads that process-specific secret and maps it to the standard environment variable Codex expects:

- `OPENAI_API_KEY`

This keeps the secret name scoped to this automation while avoiding custom Codex configuration on every runner. If the secret is absent or inaccessible, the queue wakeup fails before claiming an issue.

The workflow expects these repository variables to already point at the Key Vault subscription and vault:

- `ARM_CLIENT_ID`
- `ARM_TENANT_ID`
- `ARM_SUBSCRIPTION_ID`
- `KEY_VAULT_NAME`
- `KEY_VAULT_SUBSCRIPTION_ID`

## Reusable Queue Host Setup

Each Windows queue host should use the same shape so the laptop, the next PC, and VMSS workers are interchangeable:

- a stable worker name such as `sts2-side-a`
- GitHub runner label `codex-queue`
- a persistent queue state directory outside the disposable Actions workspace
- a machine-level `CODEX_ISSUE_QUEUE_STATE_ROOT`

Use the initializer to create the local directories, grant the runner service account access, and optionally attach runner labels:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ops\codex-queue\Initialize-CodexQueueHost.ps1 `
  -WorkerName 'sts2-side-a' `
  -RunnerName 'sts2-side-a' `
  -SetMachineEnvironment `
  -AddRunnerLabels
```

Restart the GitHub runner service after changing machine-level environment variables.

## Scheduling

The intended steady state is hybrid:

- GitHub issue events wake the queue worker immediately on a dedicated runner labeled `codex-queue`
- a Windows Scheduled Task still wakes the queue worker periodically on that same queue host as a recovery mechanism
- each invocation drains the queue until empty
- if another invocation starts while one is already running, the lock file causes it to exit cleanly

This gives the queue host fast reaction time without making event delivery the only correctness path.

## Dashboard Push Events

The worker can optionally push signed lifecycle events to a remote dashboard backend so the dashboard changes status immediately when the queue host starts or finishes work.

Supported event transitions include:

- `worker_run_started`
- `issue_claimed`
- `issue_finished`
- `queue_empty`
- `worker_run_finished`
- `worker_run_failed`

The worker signs each event with a short-lived HS256 JWT and posts it to the configured dashboard endpoint.

### Queue-host setup

1. Store the shared JWT secret on the queue host.
2. Recommended secret name: `codex-queue-jwt-secret`
3. The worker looks for the secret in either:
   - environment variable `CODEX_QUEUE_JWT_SECRET`
   - PowerShell SecretManagement via `Get-Secret -Name codex-queue-jwt-secret -AsPlainText`

If you use PowerShell SecretManagement, an example is:

```powershell
Set-Secret -Name codex-queue-jwt-secret -Secret 'replace-with-long-random-secret'
```

### Endpoint configuration

The worker only pushes events when `DashboardEventUrl` is configured.

There are two intended ways to provide that:

- GitHub Actions wake path
  - set repository variable `CODEX_QUEUE_PUSH_EVENT_URL`
- Local scheduled task path
  - reinstall the scheduled task with `-DashboardEventUrl`

Example:

```powershell
.\ops\codex-queue\Install-IssueQueueWorkerTask.ps1 `
  -RepoRoot 'D:\repos\card-utility-stats' `
  -DashboardEventUrl 'https://diagrams.romaine.life/ci/codex/push'
```

If you want a friendlier worker name in comments and dashboard events, set `CARD_UTILITY_STATS_WORKER_NAME` on the queue host. Otherwise the script will use the runner name or VM hostname.

### Backend-side setup

The receiving dashboard backend must know the same shared secret.

For the `diagrams` backend this can come from either:

- Key Vault secret `codex-queue-jwt-secret`
- environment variable `CODEX_QUEUE_JWT_SECRET`

## Current Scope

The worker is repo-specific right now:

- repo: `nelsong6/card-utility-stats`
- local checkout: `D:\repos\card-utility-stats`
- queue role label: `codex-queue`

That is intentional. The first milestone is to make the pattern real and reliable on one queue host. Once that is stable, the worker can later be generalized into a shared automation repo or upgraded to use a distributed claim/lease model.
