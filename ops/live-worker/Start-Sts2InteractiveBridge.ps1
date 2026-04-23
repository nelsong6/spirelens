[CmdletBinding()]
param(
    [string]$QueueRoot = "",
    [string]$Sts2Path = "",
    [int]$PollSeconds = 2,
    [switch]$StopAfterOne
)

$ErrorActionPreference = "Stop"

function New-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Write-BridgeLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[{0}] {1}" -f (Get-Date).ToString("s"), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:BridgeLogPath -Value $line
}

function Write-BridgeHeartbeat {
    [ordered]@{
        heartbeat_at = (Get-Date).ToString("o")
        process_id = $PID
        bridge_user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        bridge_machine = $env:COMPUTERNAME
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $queueRootPath "bridge-heartbeat.json")
}

function Complete-FailedRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestDir,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $requestId = Split-Path -Leaf $RequestDir
    [ordered]@{
        request_id = $requestId
        status = "failure"
        mode = "bridge"
        message = $Message
        completed_at = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RequestDir "result.json")
}

if ([string]::IsNullOrWhiteSpace($QueueRoot)) {
    $QueueRoot = $env:CARD_UTILITY_STATS_LIVE_BRIDGE_DIR
}
if ([string]::IsNullOrWhiteSpace($QueueRoot)) {
    $QueueRoot = "D:\automation\card-utility-stats-live-bridge"
}

if ([string]::IsNullOrWhiteSpace($Sts2Path)) {
    $Sts2Path = $env:CARD_UTILITY_STATS_STS2_PATH
}
if ([string]::IsNullOrWhiteSpace($Sts2Path)) {
    $Sts2Path = "D:\SteamLibrary\steamapps\common\Slay the Spire 2"
}

$queueRootPath = New-Directory -Path $QueueRoot
$requestsRoot = New-Directory -Path (Join-Path $queueRootPath "requests")
$script:BridgeLogPath = Join-Path $queueRootPath "interactive-bridge.log"
$scenarioScript = Join-Path $PSScriptRoot "Invoke-Sts2InteractiveScenario.ps1"

Write-BridgeLog "STS2 interactive bridge started. queue_root=$queueRootPath sts2_path=$Sts2Path stop_after_one=$([bool]$StopAfterOne)"

while ($true) {
    Write-BridgeHeartbeat
    $readyFiles = @(Get-ChildItem -LiteralPath $requestsRoot -Recurse -Filter "ready.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)

    foreach ($readyFile in $readyFiles) {
        $requestDir = Split-Path -Parent $readyFile.FullName
        $acceptedPath = Join-Path $requestDir "accepted.json"
        $resultPath = Join-Path $requestDir "result.json"

        if ((Test-Path -LiteralPath $acceptedPath) -or (Test-Path -LiteralPath $resultPath)) {
            continue
        }

        $requestId = Split-Path -Leaf $requestDir
        try {
            [ordered]@{
                request_id = $requestId
                accepted_at = (Get-Date).ToString("o")
                bridge_user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                bridge_machine = $env:COMPUTERNAME
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $acceptedPath

            Write-BridgeLog "Accepted request $requestId."
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scenarioScript -RequestDir $requestDir -Sts2Path $Sts2Path
            Write-BridgeLog "Completed request $requestId with exit code $LASTEXITCODE."
        }
        catch {
            Write-BridgeLog "Request $requestId failed before completion: $($_.Exception.Message)"
            Complete-FailedRequest -RequestDir $requestDir -Message $_.Exception.Message
        }

        if ($StopAfterOne) {
            Write-BridgeLog "StopAfterOne requested; exiting."
            return
        }
    }

    Start-Sleep -Seconds $PollSeconds
}
