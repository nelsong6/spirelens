[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestDir,

    [string]$Sts2Path = ""
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

function Write-ScenarioLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[{0}] {1}" -f (Get-Date).ToString("s"), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:ScenarioLogPath -Value $line
}

function Get-Sts2Process {
    return Get-Process -Name "SlayTheSpire2" -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Stop-Sts2Processes {
    $processes = @(Get-Process -Name "SlayTheSpire2" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        Write-ScenarioLog "Stopping existing STS2 process $($process.Id) for a clean run."
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-SteamAppIdFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GamePath
    )

    $appIdPath = Join-Path $GamePath "steam_appid.txt"
    if (-not (Test-Path -LiteralPath $appIdPath)) {
        Set-Content -LiteralPath $appIdPath -Value "2868840"
        Write-ScenarioLog "Created '$appIdPath' for direct STS2 launch."
    }
}

function Wait-Sts2Window {
    param(
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Sts2Process
        if ($process -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $process
        }

        Start-Sleep -Seconds 2
    }

    return Get-Sts2Process
}

function Capture-Screen {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [System.Diagnostics.Process]$Process = $null
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ("Sts2WindowApi" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Sts2WindowApi
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, UInt32 uFlags);

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const UInt32 SWP_NOSIZE = 0x0001;
    public const UInt32 SWP_NOMOVE = 0x0002;
    public const UInt32 SWP_SHOWWINDOW = 0x0040;

    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@
    }

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($Process -and $Process.MainWindowHandle -ne [IntPtr]::Zero) {
        if ($env:CARD_UTILITY_STATS_MINIMIZE_DESKTOP_FOR_CAPTURE -ne "false") {
            try {
                (New-Object -ComObject Shell.Application).MinimizeAll()
                Start-Sleep -Milliseconds 500
            }
            catch {
                Write-ScenarioLog "MinimizeAll before capture failed: $($_.Exception.Message)"
            }
        }

        [Sts2WindowApi]::ShowWindow($Process.MainWindowHandle, 9) | Out-Null
        [Sts2WindowApi]::SetWindowPos(
            $Process.MainWindowHandle,
            [Sts2WindowApi]::HWND_TOPMOST,
            0,
            0,
            0,
            0,
            [Sts2WindowApi]::SWP_NOMOVE -bor [Sts2WindowApi]::SWP_NOSIZE -bor [Sts2WindowApi]::SWP_SHOWWINDOW
        ) | Out-Null
        [Sts2WindowApi]::SetForegroundWindow($Process.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 750

        $rect = New-Object Sts2WindowApi+RECT
        if ([Sts2WindowApi]::GetWindowRect($Process.MainWindowHandle, [ref]$rect)) {
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            if ($width -gt 0 -and $height -gt 0) {
                $bounds = New-Object System.Drawing.Rectangle $rect.Left, $rect.Top, $width, $height
            }
        }
    }

    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($Process -and $Process.MainWindowHandle -ne [IntPtr]::Zero) {
            [Sts2WindowApi]::SetWindowPos(
                $Process.MainWindowHandle,
                [Sts2WindowApi]::HWND_NOTOPMOST,
                0,
                0,
                0,
                0,
                [Sts2WindowApi]::SWP_NOMOVE -bor [Sts2WindowApi]::SWP_NOSIZE
            ) | Out-Null
        }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Copy-NewFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDir,

        [DateTime]$Since = [DateTime]::MinValue,

        [string]$Filter = "*"
    )

    if (-not (Test-Path -LiteralPath $SourceDir)) {
        return
    }

    New-Directory -Path $DestinationDir | Out-Null
    Get-ChildItem -LiteralPath $SourceDir -File -Filter $Filter |
        Where-Object { $_.LastWriteTime -ge $Since } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $DestinationDir $_.Name) -Force
        }
}

$requestPath = Join-Path $RequestDir "request.json"
$resultPath = Join-Path $RequestDir "result.json"
$request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
$startedAt = Get-Date

if ([string]::IsNullOrWhiteSpace($Sts2Path)) {
    $Sts2Path = $request.sts2_path
}

$logsDir = New-Directory -Path $request.artifacts.logs
$screenshotsDir = New-Directory -Path $request.artifacts.screenshots
$runDataDir = New-Directory -Path $request.artifacts.run_data
$driverOutputDir = New-Directory -Path $request.artifacts.driver_output
$script:ScenarioLogPath = Join-Path $logsDir "interactive-scenario-driver.log"

$warnings = New-Object System.Collections.Generic.List[string]
$captures = New-Object System.Collections.Generic.List[object]
$scenarioName = $request.scenario.name
$exePath = Join-Path $Sts2Path "SlayTheSpire2.exe"

try {
    Write-ScenarioLog "Starting interactive scenario request '$($request.id)' for '$scenarioName'."

    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "SlayTheSpire2.exe was not found at '$exePath'."
    }
    Ensure-SteamAppIdFile -GamePath $Sts2Path

    $process = Get-Sts2Process
    if ($process) {
        $reuseExisting = $env:CARD_UTILITY_STATS_REUSE_STS2 -eq "true"
        if ($reuseExisting) {
            Write-ScenarioLog "Attached to existing STS2 process $($process.Id)."
        }
        else {
            Stop-Sts2Processes
            $process = $null
        }
    }

    if (-not $process) {
        $renderingArgs = $env:CARD_UTILITY_STATS_STS2_ARGS
        if ([string]::IsNullOrWhiteSpace($renderingArgs)) {
            $renderingArgs = "--rendering-driver opengl3"
        }

        $useSteam = $env:CARD_UTILITY_STATS_STS2_USE_STEAM -eq "true"
        $steamExe = $env:CARD_UTILITY_STATS_STEAM_EXE
        if ([string]::IsNullOrWhiteSpace($steamExe)) {
            $steamExe = "C:\Program Files (x86)\Steam\steam.exe"
        }

        if ($useSteam -and (Test-Path -LiteralPath $steamExe)) {
            $steamArgs = "-applaunch 2868840 $renderingArgs"
            Write-ScenarioLog "Launching STS2 through Steam from '$steamExe' with args '$steamArgs'."
            Start-Process -FilePath $steamExe -ArgumentList $steamArgs | Out-Null
        }
        else {
            Write-ScenarioLog "Launching STS2 directly from '$exePath' with args '$renderingArgs'."
            Start-Process -FilePath $exePath -WorkingDirectory $Sts2Path -ArgumentList $renderingArgs | Out-Null
        }
    }

    $process = Wait-Sts2Window -TimeoutSeconds 120
    if (-not $process) {
        throw "STS2 process did not start."
    }

    if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        $warnings.Add("STS2 process is running, but no main window handle was detected before capture.")
    }
    else {
        Write-ScenarioLog "STS2 window detected for process $($process.Id)."
    }

    $warmupSeconds = 20
    if (-not [string]::IsNullOrWhiteSpace($env:CARD_UTILITY_STATS_CAPTURE_WARMUP_SECONDS)) {
        $warmupSeconds = [int]$env:CARD_UTILITY_STATS_CAPTURE_WARMUP_SECONDS
    }
    Write-ScenarioLog "Waiting $warmupSeconds second(s) before first capture."
    Start-Sleep -Seconds $warmupSeconds

    $captureNames = @("launch")
    if ($request.scenario.driver -and $request.scenario.driver.capture) {
        $captureNames += @($request.scenario.driver.capture | ForEach-Object { [string]$_ })
    }

    $captureIndex = 0
    foreach ($captureName in $captureNames) {
        if ($captureIndex -gt 0) {
            Start-Sleep -Seconds 3
        }

        $safeCaptureName = ($captureName -replace "[^A-Za-z0-9_.-]", "-").Trim("-")
        if ([string]::IsNullOrWhiteSpace($safeCaptureName)) {
            $safeCaptureName = "capture-$captureIndex"
        }

        $screenshotPath = Join-Path $screenshotsDir ("{0:00}-{1}.png" -f $captureIndex, $safeCaptureName)
        try {
            $process.Refresh()
            Capture-Screen -Path $screenshotPath -Process $process
            $captures.Add([ordered]@{
                name = $captureName
                path = $screenshotPath
                captured_at = (Get-Date).ToString("o")
            }) | Out-Null
            Write-ScenarioLog "Captured screenshot '$screenshotPath'."
        }
        catch {
            $warnings.Add("Screenshot '$captureName' failed: $($_.Exception.Message)")
            Write-ScenarioLog "Screenshot '$captureName' failed: $($_.Exception.Message)"
        }

        $captureIndex++
    }

    $userRoot = Join-Path $env:APPDATA "SlayTheSpire2"
    Copy-NewFiles -SourceDir (Join-Path $userRoot "logs") -DestinationDir $logsDir -Since $startedAt -Filter "godot*.log"
    Copy-NewFiles -SourceDir (Join-Path $userRoot "CardUtilityStats\runs") -DestinationDir $runDataDir -Since $startedAt -Filter "*.json"

    $prefsPath = Join-Path $userRoot "CardUtilityStats\prefs.json"
    if (Test-Path -LiteralPath $prefsPath) {
        Copy-Item -LiteralPath $prefsPath -Destination (Join-Path $runDataDir "prefs.json") -Force
    }

    $hasMcp = -not [string]::IsNullOrWhiteSpace([string]$request.options.mcp_endpoint)
    $requiresScenarioAutomation = [bool]$request.options.require_scenario_automation
    $mode = if ($hasMcp) { "mcp-configured-launch-smoke" } else { "launch-smoke" }

    if (-not $hasMcp) {
        $warnings.Add("No CARD_UTILITY_STATS_MCP_ENDPOINT is configured; the driver launched/captured STS2 but did not perform scenario-specific navigation.")
    }

    $status = if ($requiresScenarioAutomation -and -not $hasMcp) { "failure" } elseif ($warnings.Count -gt 0) { "warning" } else { "success" }
    $message = if ($status -eq "failure") {
        "Scenario automation was required, but no MCP endpoint is configured."
    }
    else {
        "STS2 launch/capture bridge completed."
    }

    $result = [ordered]@{
        request_id = $request.id
        status = $status
        mode = $mode
        message = $message
        scenario_name = $scenarioName
        started_at = $startedAt.ToString("o")
        completed_at = (Get-Date).ToString("o")
        sts2_process_id = $process.Id
        screenshots = $captures
        warnings = @($warnings)
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $driverOutputDir "interactive-driver-result.json")
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath

    if ($status -eq "failure") {
        exit 1
    }

    exit 0
}
catch {
    $result = [ordered]@{
        request_id = $request.id
        status = "failure"
        mode = "launch-smoke"
        message = $_.Exception.Message
        scenario_name = $scenarioName
        started_at = $startedAt.ToString("o")
        completed_at = (Get-Date).ToString("o")
        warnings = @($warnings)
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $driverOutputDir "interactive-driver-result.json")
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath
    Write-ScenarioLog "Interactive scenario failed: $($_.Exception.Message)"
    exit 1
}
