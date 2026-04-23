[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoSlug = "nelsong6/card-utility-stats",
    [string]$WorkerName = $env:COMPUTERNAME,
    [string]$RunnerName = "",
    [string[]]$RunnerLabels = @("codex-queue"),
    [string]$CodexHome = "D:\automation\codex\home",
    [string]$QueueStateRoot = "D:\automation\card-utility-stats\codex-queue-state",
    [switch]$SetMachineEnvironment,
    [switch]$AddRunnerLabels
)

$ErrorActionPreference = "Stop"

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Grant-RunnerAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $aclTarget = (Resolve-Path -LiteralPath $Path).Path
    & icacls $aclTarget /grant "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)M" "SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update ACL for $aclTarget."
    }
}

function Set-MachineEnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($PSCmdlet.ShouldProcess("Machine environment", "Set $Name")) {
        [Environment]::SetEnvironmentVariable($Name, $Value, "Machine")
    }
}

function Get-Runner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $runners = gh api "repos/$RepoSlug/actions/runners" | ConvertFrom-Json
    return $runners.runners | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Add-GitHubRunnerLabels {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string[]]$Labels
    )

    $runner = Get-Runner -Name $Name
    if (-not $runner) {
        throw "Runner '$Name' was not found in $RepoSlug."
    }

    foreach ($label in $Labels) {
        & gh api --method POST "repos/$RepoSlug/actions/runners/$($runner.id)/labels" -f "labels[]=$label" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add runner label '$label' to '$Name'."
        }
    }
}

$resolvedCodexHome = Ensure-Directory -Path $CodexHome
$resolvedQueueStateRoot = Ensure-Directory -Path $QueueStateRoot
Grant-RunnerAccess -Path $resolvedCodexHome
Grant-RunnerAccess -Path $resolvedQueueStateRoot

if ($SetMachineEnvironment) {
    Set-MachineEnvironmentVariable -Name "CARD_UTILITY_STATS_WORKER_NAME" -Value $WorkerName
    Set-MachineEnvironmentVariable -Name "CODEX_HOME" -Value $resolvedCodexHome
    Set-MachineEnvironmentVariable -Name "CODEX_ISSUE_QUEUE_STATE_ROOT" -Value $resolvedQueueStateRoot
}

if ($AddRunnerLabels) {
    $effectiveRunnerName = if ([string]::IsNullOrWhiteSpace($RunnerName)) { $WorkerName } else { $RunnerName }
    Add-GitHubRunnerLabels -Name $effectiveRunnerName -Labels $RunnerLabels
}

Write-Host ""
Write-Host "Codex queue host profile:"
Write-Host "- Worker name: $WorkerName"
Write-Host "- CODEX_HOME: $resolvedCodexHome"
Write-Host "- Queue state root: $resolvedQueueStateRoot"
Write-Host "- Runner labels requested: $($RunnerLabels -join ', ')"
Write-Host ""
Write-Host "If this host runs GitHub Actions as a Windows service, restart that service after machine environment changes."
