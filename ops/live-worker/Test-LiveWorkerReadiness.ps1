[CmdletBinding()]
param(
    [string]$RepoSlug = "nelsong6/card-utility-stats",
    [string]$WorkerName = "",
    [string[]]$RequiredLabels = @("self-hosted", "windows", "sts2-live"),
    [switch]$RequireGameDriver,
    [string]$WorkerEnvPath = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-WorkerEnvPath {
    param(
        [string]$ExplicitPath
    )

    $candidates = @(
        $ExplicitPath,
        $env:CARD_UTILITY_STATS_RUNNER_ENV_PATH,
        "C:\actions-runner-card-utility-stats\.env"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return ""
}

function Read-WorkerEnvFile {
    param(
        [string]$Path
    )

    $settings = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $settings
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $separator = $line.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $settings[$key] = $value
    }

    return $settings
}

$resolvedWorkerEnvPath = Resolve-WorkerEnvPath -ExplicitPath $WorkerEnvPath
$script:WorkerEnvironment = Read-WorkerEnvFile -Path $resolvedWorkerEnvPath

function Get-WorkerSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$DefaultValue = ""
    )

    foreach ($scope in @("Process", "User", "Machine")) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    if ($script:WorkerEnvironment.ContainsKey($Name)) {
        return $script:WorkerEnvironment[$Name]
    }

    return $DefaultValue
}

if ([string]::IsNullOrWhiteSpace($WorkerName)) {
    $WorkerName = Get-WorkerSetting -Name "CARD_UTILITY_STATS_WORKER_NAME"
}
if ([string]::IsNullOrWhiteSpace($WorkerName)) {
    $WorkerName = $env:RUNNER_NAME
}
if ([string]::IsNullOrWhiteSpace($WorkerName)) {
    $WorkerName = "sts2-side-a"
}

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet("pass", "warn", "fail")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [hashtable]$Data = @{}
    )

    $script:checks.Add([ordered]@{
        name = $Name
        status = $Status
        message = $Message
        data = $Data
    }) | Out-Null
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string[]]$VersionArgs = @("--version"),

        [ValidateSet("pass", "warn", "fail")]
        [string]$MissingStatus = "fail"
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        Add-Check -Name "tool:$Name" -Status $MissingStatus -Message "$Name is not available on PATH."
        return
    }

    $version = ""
    try {
        $version = (& $Name @VersionArgs 2>$null | Select-Object -First 1)
    }
    catch {
        $version = "available"
    }

    Add-Check -Name "tool:$Name" -Status "pass" -Message "$Name is available." -Data @{
        path = $command.Source
        version = $version
    }
}

function Get-GitHubRunner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $payloadJson = & gh api "repos/$Repo/actions/runners" 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($payloadJson)) {
            $global:LASTEXITCODE = 0
            return $null
        }

        $payload = $payloadJson | ConvertFrom-Json
        return $payload.runners | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    }
    catch {
        $global:LASTEXITCODE = 0
        return $null
    }
}

function Compare-Labels {
    param(
        [string[]]$Actual,
        [string[]]$Expected
    )

    $actualLower = @($Actual | ForEach-Object { $_.ToLowerInvariant() })
    return @($Expected | Where-Object { $actualLower -notcontains $_.ToLowerInvariant() })
}

Test-CommandAvailable -Name "git"
Test-CommandAvailable -Name "gh"
Test-CommandAvailable -Name "dotnet"
Test-CommandAvailable -Name "pwsh" -VersionArgs @("-NoLogo", "-NoProfile", "-Command", '$PSVersionTable.PSVersion.ToString()') -MissingStatus "warn"

if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $runnerServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "actions.runner.*" -and ($_.Name -like "*.$WorkerName" -or $_.DisplayName -like "*$WorkerName*")
    })

    if ($runnerServices.Count -eq 0) {
        Add-Check -Name "runner-service" -Status "fail" -Message "No GitHub Actions runner service was found for worker '$WorkerName'."
    }
    else {
        $runningServices = @($runnerServices | Where-Object { $_.Status -eq "Running" })
        Add-Check `
            -Name "runner-service" `
            -Status ($(if ($runningServices.Count -gt 0) { "pass" } else { "fail" })) `
            -Message ($(if ($runningServices.Count -gt 0) { "Runner service for '$WorkerName' is running." } else { "Runner service for '$WorkerName' exists but is not running." })) `
            -Data @{
                services = @($runnerServices | ForEach-Object {
                    [ordered]@{
                        name = $_.Name
                        status = $_.Status.ToString()
                        display_name = $_.DisplayName
                    }
                })
            }
    }
}
else {
    Add-Check -Name "runner-service" -Status "warn" -Message "Windows service check skipped on non-Windows host."
}

$githubRunner = Get-GitHubRunner -Repo $RepoSlug -Name $WorkerName
if (-not $githubRunner) {
    if ($env:GITHUB_ACTIONS -eq "true" -and $env:RUNNER_NAME -eq $WorkerName) {
        Add-Check -Name "github-runner" -Status "pass" -Message "This workflow is running on '$WorkerName'; runner-list API access was not required to prove pool reachability." -Data @{
            runner_name = $env:RUNNER_NAME
            runner_os = $env:RUNNER_OS
            note = "Repository tokens may not have permission to list self-hosted runners."
        }
    }
    else {
        Add-Check -Name "github-runner" -Status "fail" -Message "GitHub did not return runner '$WorkerName' for '$RepoSlug'."
    }
}
else {
    $labelNames = @($githubRunner.labels | ForEach-Object { $_.name })
    $missingLabels = Compare-Labels -Actual $labelNames -Expected $RequiredLabels
    $runnerStatus = if ($githubRunner.status -eq "online" -and $missingLabels.Count -eq 0) { "pass" } else { "fail" }
    $message = if ($runnerStatus -eq "pass") {
        "GitHub runner '$WorkerName' is online with the required pool labels."
    }
    elseif ($githubRunner.status -ne "online") {
        "GitHub runner '$WorkerName' is '$($githubRunner.status)'."
    }
    else {
        "GitHub runner '$WorkerName' is missing label(s): $($missingLabels -join ', ')."
    }

    Add-Check -Name "github-runner" -Status $runnerStatus -Message $message -Data @{
        status = $githubRunner.status
        busy = [bool]$githubRunner.busy
        labels = $labelNames
        missing_labels = $missingLabels
    }
}

$sts2Path = Get-WorkerSetting -Name "CARD_UTILITY_STATS_STS2_PATH" -DefaultValue "C:\Program Files (x86)\Steam\steamapps\common\Slay the Spire 2"

$sts2Exists = Test-Path -LiteralPath $sts2Path
Add-Check `
    -Name "sts2-path" `
    -Status ($(if ($sts2Exists) { "pass" } elseif ($RequireGameDriver) { "fail" } else { "warn" })) `
    -Message ($(if ($sts2Exists) { "STS2 path exists." } elseif ($RequireGameDriver) { "STS2 path is required but was not found." } else { "STS2 path was not found yet; pool membership can still be validated before game automation." })) `
    -Data @{ path = $sts2Path }

$modsPath = Join-Path $sts2Path "mods"
$modsExists = Test-Path -LiteralPath $modsPath
Add-Check `
    -Name "sts2-mods-path" `
    -Status ($(if ($modsExists) { "pass" } elseif ($RequireGameDriver) { "fail" } else { "warn" })) `
    -Message ($(if ($modsExists) { "STS2 mods path exists." } elseif ($RequireGameDriver) { "STS2 mods path is required but was not found." } else { "STS2 mods path was not found yet." })) `
    -Data @{ path = $modsPath }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$defaultLiveDriver = Join-Path $repoRoot "ops\live-worker\Invoke-Sts2BridgeDriver.ps1"
$driverScript = Get-WorkerSetting -Name "CARD_UTILITY_STATS_LIVE_DRIVER" -DefaultValue $defaultLiveDriver
$driverExists = -not [string]::IsNullOrWhiteSpace($driverScript) -and (Test-Path -LiteralPath $driverScript)
Add-Check `
    -Name "live-driver" `
    -Status ($(if ($driverExists) { "pass" } elseif ($RequireGameDriver) { "fail" } else { "warn" })) `
    -Message ($(if ($driverExists) { "Worker-local live driver exists." } elseif ($RequireGameDriver) { "CARD_UTILITY_STATS_LIVE_DRIVER is required but missing or invalid." } else { "Worker-local live driver is not configured yet." })) `
    -Data @{ path = $driverScript }

$bridgeRoot = Get-WorkerSetting -Name "CARD_UTILITY_STATS_LIVE_BRIDGE_DIR" -DefaultValue "D:\automation\card-utility-stats-live-bridge"
$bridgeRootExists = Test-Path -LiteralPath $bridgeRoot
Add-Check `
    -Name "live-bridge-dir" `
    -Status ($(if ($bridgeRootExists) { "pass" } elseif ($RequireGameDriver) { "fail" } else { "warn" })) `
    -Message ($(if ($bridgeRootExists) { "Live bridge queue directory exists." } elseif ($RequireGameDriver) { "Live bridge queue directory is required but missing." } else { "Live bridge queue directory is not initialized yet." })) `
    -Data @{ path = $bridgeRoot }

$bridgeProcesses = @()
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $bridgeProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -like "*Start-Sts2InteractiveBridge.ps1*"
    })
}

Add-Check `
    -Name "live-bridge-process" `
    -Status ($(if ($bridgeProcesses.Count -gt 0) { "pass" } elseif ($RequireGameDriver) { "fail" } else { "warn" })) `
    -Message ($(if ($bridgeProcesses.Count -gt 0) { "User-session STS2 bridge process is running." } elseif ($RequireGameDriver) { "User-session STS2 bridge process is required but not running." } else { "User-session STS2 bridge process is not running yet." })) `
    -Data @{
        processes = @($bridgeProcesses | ForEach-Object {
            [ordered]@{
                process_id = $_.ProcessId
                name = $_.Name
            }
        })
    }

$runDataDir = Get-WorkerSetting -Name "CARD_UTILITY_STATS_RUN_DATA_DIR" -DefaultValue (Join-Path $env:APPDATA "SlayTheSpire2\CardUtilityStats\runs")

Add-Check -Name "run-data-dir" -Status "pass" -Message "Run data directory resolved." -Data @{
    path = $runDataDir
    exists = Test-Path -LiteralPath $runDataDir
}

$hasFail = @($checks | Where-Object { $_.status -eq "fail" }).Count -gt 0
$hasWarn = @($checks | Where-Object { $_.status -eq "warn" }).Count -gt 0
$overall = if ($hasFail) { "fail" } elseif ($hasWarn) { "warn" } else { "pass" }

$report = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    repo = $RepoSlug
    worker_name = $WorkerName
    worker_env_path = $resolvedWorkerEnvPath
    require_game_driver = [bool]$RequireGameDriver
    required_labels = $RequiredLabels
    status = $overall
    checks = $checks
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputParent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
        New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath
}

$report | ConvertTo-Json -Depth 10

if ($overall -eq "fail") {
    exit 1
}

exit 0
