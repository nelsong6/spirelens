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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
}

function Show-Sts2BridgeDiagnostics {
    param([string]$GameDir)

    Write-Host '--- SpireLensMcpBridge diagnostics ---'
    Write-Host "Process identity: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "APPDATA=$env:APPDATA"
    Write-Host "LOCALAPPDATA=$env:LOCALAPPDATA"

    Write-Host 'Installed mods:'
    $modsDir = Join-Path $GameDir 'mods'
    if (Test-Path -LiteralPath $modsDir) {
        Get-ChildItem -LiteralPath $modsDir -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "  $(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.Name) ($(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.FullName))" }
        Get-ChildItem -LiteralPath $modsDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.Name -match 'SpireLens|BaseLib|Mcp|Bridge|\.json$|\.conf
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
 } |
            Sort-Object FullName |
            ForEach-Object { Write-Host "  file $(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.FullName) len=$(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.Length) mtime=$(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.LastWriteTime.ToString('o'))" }
    } else {
        Write-Host "  mods directory not found: $modsDir"
    }

    Write-Host 'STS2 processes visible to runner:'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') } |
        ForEach-Object {
            Write-Host "  $(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.Name) pid=$(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.ProcessId) session=$(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.SessionId) path=$(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.ExecutablePath)"
        }

    $candidateLogDirs = @(
        (Join-Path $env:APPDATA 'SlayTheSpire2\logs'),
        (Join-Path $env:LOCALAPPDATA 'SlayTheSpire2\logs'),
        'C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\SlayTheSpire2\logs',
        'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\SlayTheSpire2\logs',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\SlayTheSpire2\logs',
        'C:\Windows\System32\config\systemprofile\AppData\Local\SlayTheSpire2\logs'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
) } | Select-Object -Unique

    foreach ($logDir in $candidateLogDirs) {
        Write-Host "Checking log dir: $logDir"
        if (-not (Test-Path -LiteralPath $logDir)) {
            Write-Host '  not found or not accessible'
            continue
        }

        Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 3 |
            ForEach-Object {
                Write-Host "  log $(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.FullName) mtime=$(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.LastWriteTime.ToString('o')) len=$(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.Length)"
                try {
                    Get-Content -LiteralPath param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.FullName -Tail 160 -ErrorAction Stop |
                        Where-Object { param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
 -match 'SpireLens|Mcp|Bridge|BaseLib|mod|Mod|HttpListener|Failed|Exception|ERROR|WARN|Loaded' } |
                        ForEach-Object { Write-Host "    param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
" }
                } catch {
                    Write-Host "    unable to read log: $(param(
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

    $gameDirWithSlash = $GameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
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

    Write-Warning "STS2 bridge still answered ping after waiting $TimeoutSeconds second(s) for shutdown. Continuing with restart."
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
        try {
            Write-Host "Stopping $($process.Name) pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        } catch {
            Write-Warning "Unable to stop $($process.Name) pid=$($process.ProcessId): $($_.Exception.Message)"
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

    $launcher = Join-Path $GameDir 'launch_opengl.bat'
    if (Test-Path -LiteralPath $launcher) {
        Write-Host "Launching STS2 through '$launcher'."
        Start-Process -FilePath $launcher -WorkingDirectory $GameDir | Out-Null
        return
    }

    $exePath = Join-Path $GameDir 'SlayTheSpire2.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Unable to find SlayTheSpire2.exe under '$GameDir'."
    }

    Write-Host "Launching STS2 through '$exePath' with arguments '$Arguments'."
    Start-Process -FilePath $exePath -ArgumentList $Arguments -WorkingDirectory $GameDir | Out-Null
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
.Exception.Message)"
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
