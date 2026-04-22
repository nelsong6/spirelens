[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioPath,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [bool]$RunTests = $true,

    [bool]$ExecuteLiveDriver = $true
)

$ErrorActionPreference = "Stop"

function New-ArtifactDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return $Path
}

function Copy-IfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Source) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
        return $true
    }

    return $false
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$resolvedScenarioPath = (Resolve-Path (Join-Path $repoRoot $ScenarioPath)).Path
$startTime = Get-Date

$artifactRoot = New-ArtifactDirectory -Path $ArtifactRoot
$logsDir = New-ArtifactDirectory -Path (Join-Path $artifactRoot "logs")
$screenshotsDir = New-ArtifactDirectory -Path (Join-Path $artifactRoot "screenshots")
$runDataDir = New-ArtifactDirectory -Path (Join-Path $artifactRoot "run-data")
$buildDir = New-ArtifactDirectory -Path (Join-Path $artifactRoot "build")
$scenarioDir = New-ArtifactDirectory -Path (Join-Path $artifactRoot "scenario")
$driverOutputDir = New-ArtifactDirectory -Path (Join-Path $artifactRoot "driver-output")

Copy-Item -LiteralPath $resolvedScenarioPath -Destination (Join-Path $scenarioDir (Split-Path $resolvedScenarioPath -Leaf)) -Force

$sts2Path = $env:CARD_UTILITY_STATS_STS2_PATH
if ([string]::IsNullOrWhiteSpace($sts2Path)) {
    $sts2Path = "C:\Program Files (x86)\Steam\steamapps\common\Slay the Spire 2"
}

$modsPath = Join-Path $sts2Path "mods"
$defaultUserRoot = Join-Path $env:APPDATA "SlayTheSpire2\CardUtilityStats"
$liveRunDataSource = $env:CARD_UTILITY_STATS_RUN_DATA_DIR
if ([string]::IsNullOrWhiteSpace($liveRunDataSource)) {
    $liveRunDataSource = Join-Path $defaultUserRoot "runs"
}

$driverScript = $env:CARD_UTILITY_STATS_LIVE_DRIVER
$metadata = [ordered]@{
    started_at = $startTime.ToString("o")
    scenario_path = $ScenarioPath
    scenario_manifest = $resolvedScenarioPath
    execute_live_driver = $ExecuteLiveDriver
    run_tests = $RunTests
    runner_name = $env:RUNNER_NAME
    runner_os = $env:RUNNER_OS
    git_sha = $env:GITHUB_SHA
    git_ref = $env:GITHUB_REF
    repository = $env:GITHUB_REPOSITORY
    sts2_path = $sts2Path
    run_data_source = $liveRunDataSource
    mods_path = $modsPath
    driver_script = $driverScript
}

$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $artifactRoot "run-metadata.json")

Push-Location $repoRoot
try {
    $testProject = Join-Path $repoRoot "Tests\CardUtilityStats.Core.Tests\CardUtilityStats.Core.Tests.csproj"
    $testResultsDir = Join-Path $logsDir "test-results"
    $testArgs = @(
        "test",
        $testProject,
        "-c", $Configuration,
        "--results-directory", $testResultsDir,
        "--logger", "trx;LogFileName=tests.trx"
    )
    $buildArgs = @(
        "build",
        "CardUtilityStats.csproj",
        "-c", $Configuration,
        "/p:ContinuousIntegrationBuild=true"
    )

    if (-not [string]::IsNullOrWhiteSpace($sts2Path)) {
        $testArgs += "/p:Sts2Path=$sts2Path"
        $buildArgs += "/p:Sts2Path=$sts2Path"
    }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "dotnet is not available on PATH for this worker. Install the .NET SDK or keep actions/setup-dotnet enabled."
    }

    if ($RunTests) {
        & dotnet @testArgs
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet test failed with exit code $LASTEXITCODE"
        }
    }

    & dotnet @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE"
    }

    $releaseOutput = Join-Path $repoRoot ("bin\" + $Configuration)
    Copy-IfExists -Source $releaseOutput -Destination (Join-Path $buildDir "loader-output") | Out-Null
    Copy-IfExists -Source (Join-Path $modsPath "CardUtilityStats") -Destination (Join-Path $buildDir "mods-deploy") | Out-Null

    if ($ExecuteLiveDriver) {
        if ([string]::IsNullOrWhiteSpace($driverScript)) {
            throw "CARD_UTILITY_STATS_LIVE_DRIVER is not set on this worker. Point it at the local STS2 automation script."
        }

        if (-not (Test-Path -LiteralPath $driverScript)) {
            throw "Live driver script '$driverScript' does not exist on this worker."
        }

        & $driverScript `
            -ScenarioPath $resolvedScenarioPath `
            -ArtifactRoot $driverOutputDir `
            -ScreenshotsDir $screenshotsDir `
            -LogsDir $logsDir `
            -RunDataDir $runDataDir `
            -Sts2Path $sts2Path

        if ($LASTEXITCODE -ne 0) {
            throw "Live driver failed with exit code $LASTEXITCODE"
        }
    }
    else {
        @(
            "Live driver execution was skipped for this dispatch.",
            "Set execute_live_driver=true when the worker-local automation script is ready."
        ) | Set-Content -LiteralPath (Join-Path $driverOutputDir "driver-skipped.txt")
    }

    if (Test-Path -LiteralPath $liveRunDataSource) {
        Get-ChildItem -LiteralPath $liveRunDataSource -File |
            Where-Object { $_.LastWriteTime -ge $startTime } |
            ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $runDataDir $_.Name) -Force
            }
    }

    $prefsPath = Join-Path $defaultUserRoot "prefs.json"
    if (Test-Path -LiteralPath $prefsPath) {
        Copy-Item -LiteralPath $prefsPath -Destination (Join-Path $runDataDir "prefs.json") -Force
    }
}
finally {
    Pop-Location
}
