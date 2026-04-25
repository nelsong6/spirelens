# Reboot-Safe Issue-Agent Runner

Live STS2 issue-agent work must run from the logged-in Steam user's desktop session. A Windows service runner can build and test, but it launches STS2 as a service account/session 0 and Steam initialization fails.

The reboot-safe setup is:

1. Keep the GitHub Actions runner registered to the repository.
2. Disable the service-backed runner process for this repository.
3. Start `run.cmd` from a scheduled task triggered at user logon.
4. Let the scheduled task relaunch `run.cmd` if the runner exits.

This preserves the interactive Steam session after a reboot without leaving a manually opened PowerShell window as the only thing keeping automation alive.

## One-Time Setup

Run from an elevated PowerShell session while logged in as the Steam user:

```powershell
pwsh -NoProfile -File .\ops\windows-worker\Register-InteractiveIssueAgentRunner.ps1 `
  -RunnerRoot C:\actions-runner-card-utility-stats
```

If the runner is somewhere else, pass that path with `-RunnerRoot`. If omitted, the script checks the common runner locations used by this repo.

The script:

- finds the local runner root containing `run.cmd`
- disables matching service-backed `actions.runner.nelsong6-spirelens.*` services by default
- writes `C:\ProgramData\SpireLens\issue-agent-runner\Start-InteractiveIssueAgentRunner.ps1`
- registers the `SpireLens Issue Agent Interactive Runner` scheduled task
- starts that task immediately unless `-NoStart` is supplied

The scheduled task runs only at logon, because STS2/Steam need the real user desktop session. For fully unattended reboot recovery, Windows must be configured to sign in the Steam user automatically or the machine must otherwise return to that user's session after reboot.

## Verify

After setup or after a reboot, verify:

```powershell
Get-ScheduledTask -TaskName 'SpireLens Issue Agent Interactive Runner'
Get-ScheduledTaskInfo -TaskName 'SpireLens Issue Agent Interactive Runner'
Get-Content C:\ProgramData\SpireLens\issue-agent-runner\interactive-runner.log -Tail 80
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
