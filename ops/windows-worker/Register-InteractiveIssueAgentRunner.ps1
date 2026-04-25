param(
    [string]$RunnerRoot = "",
    [string]$TaskName = "SpireLens Issue Agent Interactive Runner",
    [string]$LogDir = "C:\\ProgramData\\SpireLens\\issue-agent-runner",
    [string]$RunnerServiceNamePrefix = "actions.runner.nelsong6-spirelens.",
    [string]$Sts2LaunchTaskName = "",
    [switch]$KeepRunnerServices,
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "==> $Message"
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-RunnerRoot {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($RequestedPath)
        if (-not (Test-Path -LiteralPath (Join-Path $expanded 'run.cmd'))) {
            throw "GitHub Actions runner run.cmd was not found under '$expanded'."
        }
        return [System.IO.Path]::GetFullPath($expanded).TrimEnd('\\')
    }

    $candidates = @(
        "C:\\actions-runner-card-utility-stats",
        "D:\\actions-runner-card-utility-stats",
        "D:\\actions-runner-spirelens",
        "C:\\actions-runner-spirelens",
        "D:\\actions-runner",
        "C:\\actions-runner",
        (Join-Path $env:USERPROFILE "actions-runner-card-utility-stats"),
        (Join-Path $env:USERPROFILE "actions-runner-spirelens"),
        (Join-Path $env:USERPROFILE "actions-runner")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'run.cmd')) {
            return [System.IO.Path]::GetFullPath($candidate).TrimEnd('\\')
        }
    }

    throw "Unable to find a GitHub Actions runner root containing run.cmd. Pass -RunnerRoot."
}

function Stop-ServiceBackedRunners {
    param([string]$ServiceNamePrefix)

    if ([string]::IsNullOrWhiteSpace($ServiceNamePrefix)) {
        return
    }

    $services = @(Get-Service | Where-Object { $_.Name -like "$ServiceNamePrefix*" })
    foreach ($service in $services) {
        Write-Step "Disabling service-backed runner '$($service.Name)'"
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $service.Name -Force -ErrorAction Stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(2))
        }
        Set-Service -Name $service.Name -StartupType Disabled
    }
}

function Write-LauncherScript {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerRootPath,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$LauncherLogDir,
        [string]$LaunchTaskName
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LauncherPath) | Out-Null
    New-Item -ItemType Directory -Force -Path $LauncherLogDir | Out-Null

    $escapedRunnerRoot = $RunnerRootPath.Replace("'", "''")
    $escapedLogDir = $LauncherLogDir.Replace("'", "''")
    $escapedLaunchTask = $LaunchTaskName.Replace("'", "''")

    $launcher = @"
`$ErrorActionPreference = 'Continue'
`$runnerRoot = '$escapedRunnerRoot'
`$logDir = '$escapedLogDir'
`$launchTask = '$escapedLaunchTask'
New-Item -ItemType Directory -Force -Path `$logDir | Out-Null
`$logPath = Join-Path `$logDir 'interactive-runner.log'

function Write-RunnerLog {
    param([string]`$Message)
    `$line = '{0} {1}' -f (Get-Date).ToString('o'), `$Message
    Add-Content -LiteralPath `$logPath -Value `$line -Encoding UTF8
    Write-Host `$line
}

Write-RunnerLog "Starting interactive issue-agent runner launcher. Identity=`$([Security.Principal.WindowsIdentity]::GetCurrent().Name) Session=`$((Get-Process -Id `$PID).SessionId) RunnerRoot=`$runnerRoot"
if (-not [string]::IsNullOrWhiteSpace(`$launchTask)) {
    `$env:ISSUE_AGENT_STS2_LAUNCH_TASK = `$launchTask
    Write-RunnerLog "ISSUE_AGENT_STS2_LAUNCH_TASK=`$launchTask"
}

while (`$true) {
    try {
        Set-Location -LiteralPath `$runnerRoot
        `$env:ISSUE_AGENT_INTERACTIVE_RUNNER = '1'
        Write-RunnerLog 'Launching run.cmd.'
        & (Join-Path `$runnerRoot 'run.cmd') 2>&1 | ForEach-Object { Write-RunnerLog ([string]`$_) }
        Write-RunnerLog "run.cmd exited with code `$LASTEXITCODE. Restarting after delay."
    } catch {
        Write-RunnerLog "Launcher error: `$(`$_.Exception.Message)"
    }
    Start-Sleep -Seconds 15
}
"@

    Set-Content -LiteralPath $LauncherPath -Value $launcher -Encoding UTF8
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script from an elevated PowerShell session so it can disable service-backed runners and register the scheduled task."
}

$resolvedRunnerRoot = Resolve-RunnerRoot -RequestedPath $RunnerRoot
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principalProcess = Get-Process -Id $PID

Write-Step "Configuring interactive runner for '$identity' in session $($principalProcess.SessionId)"
Write-Step "Runner root: $resolvedRunnerRoot"

if (-not $KeepRunnerServices) {
    Stop-ServiceBackedRunners -ServiceNamePrefix $RunnerServiceNamePrefix
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$launcherPath = Join-Path $LogDir 'Start-InteractiveIssueAgentRunner.ps1'
Write-LauncherScript -RunnerRootPath $resolvedRunnerRoot -LauncherPath $launcherPath -LauncherLogDir $LogDir -LaunchTaskName $Sts2LaunchTaskName

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $launcherPath) `
    -WorkingDirectory $resolvedRunnerRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Write-Step "Registering scheduled task '$TaskName'"
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

if (-not $NoStart) {
    Write-Step "Starting scheduled task '$TaskName' now"
    Start-ScheduledTask -TaskName $TaskName
}

Write-Step "Interactive issue-agent runner autostart is configured."
Write-Host "Task: $TaskName"
Write-Host "Launcher: $launcherPath"
Write-Host "Log: $(Join-Path $LogDir 'interactive-runner.log')"
Write-Host "Runner root: $resolvedRunnerRoot"
