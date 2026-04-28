# Reboot-Safe Issue-Agent Runner

Live STS2 issue-agent work must run from the logged-in Steam user's desktop session. A Windows service runner can build and test, but it launches STS2 as a service account/session 0 and Steam initialization fails.

The reboot-safe setup is:

1. Keep each GitHub Actions worker runner registered to the repository.
2. Disable service-backed runner processes for this repository.
3. Start each worker's `run.cmd` from the logged-in Steam user's session.
4. Use either a logon scheduled task or the user's Startup folder so the
   interactive runners come back after reboot/logon.

This preserves the interactive Steam session after a reboot without leaving a manually opened PowerShell window as the only thing keeping automation alive.

For issue-agent hosts with parallel test-plan and implementation jobs, configure
two worker runner directories and start both interactively. Both runners on the
same host should use the same labels:

- `issue-agent-runner-<host>`
- `issue-agent-worker`

Do not use the old phase labels.

## One-Time Scheduled Task Setup

Run from an elevated PowerShell session while logged in as the Steam user. Repeat
with a unique `-TaskName` for each runner directory that should be restarted at
logon:

```powershell
pwsh -NoProfile -File .\ops\windows-worker\Register-InteractiveIssueAgentRunner.ps1 `
  -RunnerRoot C:\actions-runner-card-utility-stats `
  -TaskName 'SpireLens Issue Agent Interactive Runner A' `
  -LogDir C:\ProgramData\SpireLens\issue-agent-runner-a

pwsh -NoProfile -File .\ops\windows-worker\Register-InteractiveIssueAgentRunner.ps1 `
  -RunnerRoot C:\actions-runner-card-utility-stats-implementation `
  -TaskName 'SpireLens Issue Agent Interactive Runner B' `
  -LogDir C:\ProgramData\SpireLens\issue-agent-runner-b
```

If the runner is somewhere else, pass that path with `-RunnerRoot`. If omitted, the script checks the common runner locations used by this repo.

The script:

- finds the local runner root containing `run.cmd`
- disables matching service-backed `actions.runner.nelsong6-spirelens.*` services by default
- writes `Start-InteractiveIssueAgentRunner.ps1` under the selected `-LogDir`
- registers the requested scheduled task
- starts that task immediately unless `-NoStart` is supplied

The scheduled task runs only at logon, because STS2/Steam need the real user desktop session. For fully unattended reboot recovery, Windows must be configured to sign in the Steam user automatically or the machine must otherwise return to that user's session after reboot.

## Non-Admin Startup Folder Fallback

If elevated scheduled-task registration is not available, use per-user Startup
folder launchers. This is less formal, but still preserves the important
property: `run.cmd` starts in the logged-in user session.

Example files:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Start GitHub Runner issue-agent-nelsonlaptop-a.cmd
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Start GitHub Runner issue-agent-nelsonlaptop-b.cmd
```

Each file should contain only:

```cmd
@echo off
cd /d "C:\path\to\runner"
run.cmd
```

Use one file per runner directory.

## Verify Scheduled Tasks

After setup or after a reboot, verify:

```powershell
Get-ScheduledTask -TaskName 'SpireLens Issue Agent Interactive Runner*'
Get-ScheduledTaskInfo -TaskName 'SpireLens Issue Agent Interactive Runner A'
Get-Content C:\ProgramData\SpireLens\issue-agent-runner-a\interactive-runner.log -Tail 80
Get-Content C:\ProgramData\SpireLens\issue-agent-runner-b\interactive-runner.log -Tail 80
```

The log should show the user identity and a non-service session before `run.cmd` starts. If it shows `NETWORK SERVICE`, the machine is still using the service path and live STS2 validation will not be reliable.

## Why This Matters

Run 24934495614 failed before Claude launched because STS2 was started by the service-backed runner under `NETWORK SERVICE`. The STS2 logs reported:

```text
Steam failed to initialize. Make sure you run the game from Steam.
```

That is the expected failure mode when STS2 is launched outside the logged-in Steam user's session. The interactive scheduled task is the supported recovery path.

## Optional STS2 Launch Task

`restart-sts2.ps1` can launch STS2 through a scheduled task when `ISSUE_AGENT_STS2_LAUNCH_TASK` is set. The interactive runner launcher can set that environment variable for its child jobs:

```powershell
pwsh -NoProfile -File .\ops\windows-worker\Register-InteractiveIssueAgentRunner.ps1 `
  -RunnerRoot C:\actions-runner-card-utility-stats `
  -Sts2LaunchTaskName 'Your Existing STS2 Launch Task'
```

For the normal interactive-runner setup, this is optional because the workflow launches STS2 from the same logged-in user session as the runner.
