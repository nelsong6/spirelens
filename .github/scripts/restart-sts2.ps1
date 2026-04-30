param(
    [ValidateSet('Restart', 'Stop')]
    [string]$Mode = 'Restart',
    [Parameter(Mandatory = $true)]
    [string]$McpConfigPath,
    [int]$StartupTimeoutSeconds = 240,
    [int]$ShutdownTimeoutSeconds = 45,
    [string]$LaunchArguments = '--rendering-driver opengl3',
    [string]$BridgeHost = '127.0.0.1',
    [int]$BridgePort = 15526
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0  # uninitialized vars + method-syntax misuse; kept off v3 because optional JSON access patterns (e.g. $result.usage.input_tokens) would throw

function Get-Sts2GameDir {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "MCP config was not found at '$ConfigPath'."
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $server = $config.mcpServers.'spire-lens-mcp'
    if ($null -eq $server -or $null -eq $server.env -or [string]::IsNullOrWhiteSpace([string]$server.env.STS2_GAME_DIR)) {
        throw "MCP config '$ConfigPath' does not define mcpServers.spire-lens-mcp.env.STS2_GAME_DIR."
    }

    $gameDir = [string]$server.env.STS2_GAME_DIR
    if (-not (Test-Path -LiteralPath $gameDir)) {
        throw "Configured STS2 game directory does not exist: '$gameDir'."
    }

    return [System.IO.Path]::GetFullPath($gameDir).TrimEnd('\')
}

function Get-Sts2Processes {
    param([string]$GameDir)

    # Was: Get-CimInstance Win32_Process | Where-Object { ... }.
    # Get-CimInstance wedges in the GH Actions runner context (likely Session 0
    # / service-context WMI/DCOM quirk; see spirelens#162). Get-Process avoids
    # WMI/DCOM entirely. Returns wrapped objects preserving the Name (with .exe
    # suffix) and ProcessId fields the existing callers consume; the underlying
    # System.Diagnostics.Process is exposed as .Process so Stop-Sts2 can
    # WaitForExit on it.
    $prefix = $GameDir.TrimEnd('\') + '\'
    Get-Process -Name 'SlayTheSpire2','crashpad_handler' -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $path = $_.MainModule.FileName
                -not [string]::IsNullOrWhiteSpace($path) -and
                $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            } catch {
                $false
            }
        } |
        ForEach-Object {
            $execPath = try { $_.MainModule.FileName } catch { $null }
            [pscustomobject]@{
                Name           = "$($_.ProcessName).exe"
                ProcessId      = $_.Id
                ExecutablePath = $execPath
                SessionId      = $_.SessionId
                Process        = $_
            }
        }
}

function Invoke-BridgePing {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 2000
    )

    # SpireLensMcpBridge exposes an HTTP server on this port; the index route
    # answers with `{"message": "Hello from SpireLensMcpBridge v...", "status": "ok"}`.
    $uri = "http://${HostName}:${Port}/"
    $timeoutSec = [int][Math]::Max(1, [Math]::Ceiling($TimeoutMilliseconds / 1000.0))

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $timeoutSec -ErrorAction Stop
        $status = [string]$response.status
        if ($status -eq 'ok') {
            return @{ ok = $true; response = $response }
        }
        return @{ ok = $false; error = "unexpected bridge status '$status'"; response = $response }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

function Wait-BridgeUnavailable {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ping = Invoke-BridgePing -HostName $HostName -Port $Port -TimeoutMilliseconds 1000
        if (-not $ping.ok) {
            return
        }
        Start-Sleep -Seconds 1
    }

    Write-Warning "SpireLensMcpBridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
}

function Stop-Sts2 {
    param(
        [string]$GameDir,
        [int]$TimeoutSeconds,
        [string]$HostName,
        [int]$Port
    )

    $processes = @(Get-Sts2Processes -GameDir $GameDir)
    if ($processes.Count -eq 0) {
        Write-Host 'No existing STS2 process found for this game directory.'
        return
    }

    foreach ($process in $processes) {
        Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
            if ($process.Process) { $process.Process.WaitForExit(5000) | Out-Null }
        } catch {
            Write-Warning "Stop-Process failed for $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
        }
        if ($process.Process -and -not $process.Process.HasExited) {
            Write-Warning "Stop-Process didn't terminate $($process.Name) pid=$($process.ProcessId) within 5s; escalating to taskkill /F /T"
            & taskkill.exe /F /T /PID ([int]$process.ProcessId) 2>$null
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-Sts2Processes -GameDir $GameDir).Count -eq 0) {
            Wait-BridgeUnavailable -HostName $HostName -Port $Port -TimeoutSeconds 10
            Write-Host 'Existing STS2 process stopped.'
            return
        }
        Start-Sleep -Seconds 1
    }

    $remaining = @(Get-Sts2Processes -GameDir $GameDir | ForEach-Object { "$($_.Name) pid=$($_.ProcessId)" }) -join ', '
    throw "Timed out waiting for STS2 to stop. Remaining processes: $remaining"
}

function Start-Sts2 {
    param(
        [string]$GameDir,
        [string]$Arguments
    )

    $launchTask = [string]$env:ISSUE_AGENT_STS2_LAUNCH_TASK
    if (-not [string]::IsNullOrWhiteSpace($launchTask)) {
        Write-Host "Launching STS2 through scheduled task '$launchTask'."
        & schtasks.exe /Run /TN $launchTask | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Scheduled task '$launchTask' failed to start STS2."
        }
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (Test-Path -LiteralPath $exePath) {
        Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
        Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
        return
    }

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through fallback batch launcher '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir -WindowStyle Minimized | Out-Null
        return
    }

    throw "Unable to find SlayTheSpire2.exe or launch_opengl.bat under '$GameDir'."
}

function Get-Sts2LogDirs {
    @(
        (Join-Path $env:APPDATA 'SlayTheSpire2\logs'),
        (Join-Path $env:LOCALAPPDATA 'SlayTheSpire2\logs'),
        'C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\SlayTheSpire2\logs',
        'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\SlayTheSpire2\logs',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\SlayTheSpire2\logs',
        'C:\Windows\System32\config\systemprofile\AppData\Local\SlayTheSpire2\logs'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

function Copy-Sts2DiagnosticArtifacts {
    param([string]$GameDir)

    $artifactRoot = $env:VALIDATION_ARTIFACT_DIR
    if ([string]::IsNullOrWhiteSpace($artifactRoot) -and -not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $artifactRoot = Join-Path $env:RUNNER_TEMP 'sts2-artifacts'
    }
    if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
        return
    }

    $diagRoot = Join-Path $artifactRoot 'sts2-startup-diagnostics'
    $logsRoot = Join-Path $diagRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null

    $snapshotPath = Join-Path $diagRoot 'startup-diagnostics.txt'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("timestamp=$((Get-Date).ToString('o'))")
    $lines.Add("identity=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)")
    $lines.Add("gameDir=$GameDir")
    $lines.Add("APPDATA=$env:APPDATA")
    $lines.Add("LOCALAPPDATA=$env:LOCALAPPDATA")
    $lines.Add("RUNNER_TEMP=$env:RUNNER_TEMP")
    $lines.Add('')
    $lines.Add('STS2 processes:')
    # Was: Get-CimInstance Win32_Process — drops CommandLine here, but
    # Get-CimInstance is the call that wedges in this runner's context (see
    # spirelens#162) and this diagnostic block runs in failure paths where we
    # most need it not to also hang.
    Get-Process -Name 'SlayTheSpire2','crashpad_handler' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $execPath = try { $_.MainModule.FileName } catch { '<unavailable>' }
            $lines.Add("  $($_.ProcessName).exe pid=$($_.Id) session=$($_.SessionId) path=$execPath")
        }

    $lines.Add('')
    $lines.Add('Installed mods:')
    $modsDir = Join-Path $GameDir 'mods'
    if (Test-Path -LiteralPath $modsDir) {
        Get-ChildItem -LiteralPath $modsDir -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object { $lines.Add("  $($_.FullName) len=$($_.Length) mtime=$($_.LastWriteTime.ToString('o'))") }
    } else {
        $lines.Add("  mods directory not found: $modsDir")
    }
    $lines | Set-Content -LiteralPath $snapshotPath -Encoding UTF8

    $index = 0
    foreach ($logDir in Get-Sts2LogDirs) {
        if (-not (Test-Path -LiteralPath $logDir)) {
            continue
        }

        $safeName = ($logDir -replace '[:\\/ ]', '_').Trim('_')
        $targetDir = Join-Path $logsRoot $safeName
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

        Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 8 |
            ForEach-Object {
                $index += 1
                $targetName = ('{0:000}-{1}' -f $index, $_.Name)
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $targetDir $targetName) -Force -ErrorAction SilentlyContinue
            }
    }

    Write-Host "Saved STS2 startup diagnostic artifacts under '$diagRoot'."
}

function Show-Sts2BridgeDiagnostics {
    param([string]$GameDir)

    Copy-Sts2DiagnosticArtifacts -GameDir $GameDir

    Write-Host '--- SpireLensMcpBridge diagnostics ---'
    Write-Host "Process identity: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "APPDATA=$env:APPDATA"
    Write-Host "LOCALAPPDATA=$env:LOCALAPPDATA"

    Write-Host 'Installed mods:'
    $modsDir = Join-Path $GameDir 'mods'
    if (Test-Path -LiteralPath $modsDir) {
        Get-ChildItem -LiteralPath $modsDir -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "  dir $($_.Name) path=$($_.FullName)" }
        Get-ChildItem -LiteralPath $modsDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'SpireLens|BaseLib|Mcp|Bridge|\.json$|\.conf$' } |
            Sort-Object FullName |
            ForEach-Object { Write-Host "  file $($_.FullName) len=$($_.Length) mtime=$($_.LastWriteTime.ToString('o'))" }
    } else {
        Write-Host "  mods directory not found: $modsDir"
    }

    Write-Host 'STS2 processes visible to runner:'
    Get-Process -Name 'SlayTheSpire2','crashpad_handler' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $execPath = try { $_.MainModule.FileName } catch { '<unavailable>' }
            Write-Host "  $($_.ProcessName).exe pid=$($_.Id) session=$($_.SessionId) path=$execPath"
        }

    foreach ($logDir in Get-Sts2LogDirs) {
        Write-Host "Checking log dir: $logDir"
        if (-not (Test-Path -LiteralPath $logDir)) {
            Write-Host '  not found or not accessible'
            continue
        }

        Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 3 |
            ForEach-Object {
                Write-Host "  log $($_.FullName) mtime=$($_.LastWriteTime.ToString('o')) len=$($_.Length)"
                try {
                    Get-Content -LiteralPath $_.FullName -Tail 160 -ErrorAction Stop |
                        Where-Object { $_ -match 'SpireLens|Mcp|Bridge|BaseLib|mod|Mod|HttpListener|Failed|Exception|ERROR|WARN|Loaded' } |
                        ForEach-Object { Write-Host "    $_" }
                } catch {
                    Write-Host "    unable to read log: $($_.Exception.Message)"
                }
            }
    }

    Write-Host '--- end SpireLensMcpBridge diagnostics ---'
}

function Wait-Sts2Ready {
    param(
        [string]$GameDir,
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = 'not attempted'
    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-Sts2Processes -GameDir $GameDir | Where-Object { $_.Name -eq 'SlayTheSpire2.exe' })
        if ($processes.Count -gt 0) {
            $ping = Invoke-BridgePing -HostName $HostName -Port $Port -TimeoutMilliseconds 2500
            if ($ping.ok) {
                Write-Host "SpireLensMcpBridge is ready on ${HostName}:${Port}."
                return
            }
            $lastError = [string]$ping.error
            Write-Host "Waiting for SpireLensMcpBridge readiness: $lastError"
        } else {
            $lastError = 'SlayTheSpire2.exe is not running yet'
            Write-Host 'Waiting for SlayTheSpire2.exe to start.'
        }
        Start-Sleep -Seconds 3
    }

    Show-Sts2BridgeDiagnostics -GameDir $GameDir
    throw "Timed out waiting $TimeoutSeconds second(s) for SpireLensMcpBridge readiness. Last status: $lastError"
}

$gameDir = Get-Sts2GameDir -ConfigPath $McpConfigPath
Write-Host "Using STS2 game directory: $gameDir"

Stop-Sts2 -GameDir $gameDir -TimeoutSeconds $ShutdownTimeoutSeconds -HostName $BridgeHost -Port $BridgePort

if ($Mode -eq 'Stop') {
    Write-Host 'STS2 stop-only mode complete.'
    return
}

Start-Sts2 -GameDir $gameDir -Arguments $LaunchArguments
Wait-Sts2Ready -GameDir $gameDir -HostName $BridgeHost -Port $BridgePort -TimeoutSeconds $StartupTimeoutSeconds
Write-Host 'STS2 restart complete.'
