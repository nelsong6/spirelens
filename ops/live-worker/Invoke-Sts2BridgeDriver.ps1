[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioPath,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [Parameter(Mandatory = $true)]
    [string]$ScreenshotsDir,

    [Parameter(Mandatory = $true)]
    [string]$LogsDir,

    [Parameter(Mandatory = $true)]
    [string]$RunDataDir,

    [Parameter(Mandatory = $true)]
    [string]$Sts2Path
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

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return
    }

    New-Directory -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Write-DriverLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[{0}] {1}" -f (Get-Date).ToString("s"), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:BridgeLogPath -Value $line
}

$driverRoot = New-Directory -Path $ArtifactRoot
$script:BridgeLogPath = Join-Path $driverRoot "bridge-driver.log"
New-Directory -Path $ScreenshotsDir | Out-Null
New-Directory -Path $LogsDir | Out-Null
New-Directory -Path $RunDataDir | Out-Null

$queueRoot = $env:CARD_UTILITY_STATS_LIVE_BRIDGE_DIR
if ([string]::IsNullOrWhiteSpace($queueRoot)) {
    $queueRoot = "D:\automation\card-utility-stats-live-bridge"
}

$requestsRoot = New-Directory -Path (Join-Path $queueRoot "requests")
$scenario = Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json
$timeoutMinutes = 30
if ($scenario.driver -and $scenario.driver.timeout_minutes) {
    $timeoutMinutes = [Math]::Max(5, [int]$scenario.driver.timeout_minutes + 5)
}

$requestId = "{0}-{1}" -f (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$requestDir = New-Directory -Path (Join-Path $requestsRoot $requestId)
$exchangeRoot = New-Directory -Path (Join-Path $requestDir "artifacts")
$exchangeLogs = New-Directory -Path (Join-Path $exchangeRoot "logs")
$exchangeScreenshots = New-Directory -Path (Join-Path $exchangeRoot "screenshots")
$exchangeRunData = New-Directory -Path (Join-Path $exchangeRoot "run-data")
$exchangeOutput = New-Directory -Path (Join-Path $exchangeRoot "driver-output")

$request = [ordered]@{
    id = $requestId
    created_at = (Get-Date).ToString("o")
    scenario_path = (Resolve-Path -LiteralPath $ScenarioPath).Path
    scenario = $scenario
    sts2_path = $Sts2Path
    timeout_minutes = $timeoutMinutes
    artifacts = [ordered]@{
        logs = $exchangeLogs
        screenshots = $exchangeScreenshots
        run_data = $exchangeRunData
        driver_output = $exchangeOutput
    }
    options = [ordered]@{
        require_scenario_automation = ($env:CARD_UTILITY_STATS_REQUIRE_SCENARIO_AUTOMATION -eq "true")
        mcp_endpoint = $env:CARD_UTILITY_STATS_MCP_ENDPOINT
    }
}

$requestPath = Join-Path $requestDir "request.json"
$readyPath = Join-Path $requestDir "ready.json"
$resultPath = Join-Path $requestDir "result.json"

$request | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $requestPath
@{
    ready_at = (Get-Date).ToString("o")
    request_id = $requestId
} | ConvertTo-Json | Set-Content -LiteralPath $readyPath

Write-DriverLog "Queued STS2 live request $requestId at $requestDir"
Write-DriverLog "Waiting up to $timeoutMinutes minute(s) for the interactive bridge."

$deadline = (Get-Date).AddMinutes($timeoutMinutes)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $resultPath) {
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json

        Copy-DirectoryContents -Source $exchangeLogs -Destination $LogsDir
        Copy-DirectoryContents -Source $exchangeScreenshots -Destination $ScreenshotsDir
        Copy-DirectoryContents -Source $exchangeRunData -Destination $RunDataDir
        Copy-DirectoryContents -Source $exchangeOutput -Destination $driverRoot

        Copy-Item -LiteralPath $requestPath -Destination (Join-Path $driverRoot "bridge-request.json") -Force
        Copy-Item -LiteralPath $resultPath -Destination (Join-Path $driverRoot "bridge-result.json") -Force

        Write-DriverLog "Interactive bridge completed request $requestId with status '$($result.status)'."

        if ($result.status -eq "failure") {
            exit 1
        }

        exit 0
    }

    Start-Sleep -Seconds 2
}

$timeoutResult = [ordered]@{
    request_id = $requestId
    status = "failure"
    completed_at = (Get-Date).ToString("o")
    message = "Timed out waiting for the user-session STS2 bridge."
}
$timeoutResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $driverRoot "bridge-result.json")
Write-DriverLog "Timed out waiting for request $requestId."
exit 1
