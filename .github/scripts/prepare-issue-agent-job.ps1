param(
    [Parameter(Mandatory = $true)][string]$CheckoutPath,
    [switch]$InstallMcp,
    [switch]$StartSts2
)

$ErrorActionPreference = 'Stop'

function Invoke-LoggedStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    # Wrap an unbounded sub-op with a BEGIN/END timestamped log line so a hang
    # always names itself in the GH Actions log instead of stalling silently.
    $start = Get-Date
    Write-Host ("::group::{0}" -f $Name)
    Write-Host ("[{0}] BEGIN: {1}" -f $start.ToString('o'), $Name)
    try {
        & $Body
        $secs = ((Get-Date) - $start).TotalSeconds
        Write-Host ("[{0}] END:   {1} ({2:N1}s)" -f (Get-Date).ToString('o'), $Name, $secs)
    } finally {
        Write-Host '::endgroup::'
    }
}

$repoRoot = Join-Path $env:GITHUB_WORKSPACE $CheckoutPath
if (-not (Test-Path -LiteralPath $repoRoot)) {
    throw "Issue-agent checkout was not found at '$repoRoot'."
}

function Add-PathCandidate {
    param(
        [System.Collections.Generic.List[string]]$Candidates,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $trimmed = $Path.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return }
    if (-not $Candidates.Contains($trimmed)) {
        $Candidates.Add($trimmed)
    }
}

function Resolve-Sts2GameDir {
    param([string]$RepoRoot)

    $gameDirCandidates = [System.Collections.Generic.List[string]]::new()
    Add-PathCandidate $gameDirCandidates $env:ISSUE_AGENT_STS2_GAME_DIR
    Add-PathCandidate $gameDirCandidates $env:CONFIGURED_STS2_GAME_DIR

    $mcpConfigPath = Join-Path $RepoRoot '.mcp.json'
    if (Test-Path -LiteralPath $mcpConfigPath) {
        try {
            $mcpConfig = Get-Content -LiteralPath $mcpConfigPath -Raw | ConvertFrom-Json
            $configuredGameDir = [string]$mcpConfig.mcpServers.'spire-lens-mcp'.env.STS2_GAME_DIR
            Add-PathCandidate $gameDirCandidates $configuredGameDir
        } catch {
            Write-Warning "Unable to read STS2_GAME_DIR from '$mcpConfigPath': $_"
        }
    }

    Add-PathCandidate $gameDirCandidates 'D:\Programs\SteamLibrary\steamapps\common\Slay the Spire 2'
    Add-PathCandidate $gameDirCandidates 'D:\SteamLibrary\steamapps\common\Slay the Spire 2'
    Add-PathCandidate $gameDirCandidates 'C:\Program Files (x86)\Steam\steamapps\common\Slay the Spire 2'
    Add-PathCandidate $gameDirCandidates 'C:\Program Files\Steam\steamapps\common\Slay the Spire 2'

    foreach ($candidate in $gameDirCandidates) {
        $sts2Dll = Join-Path $candidate 'data_sts2_windows_x86_64\sts2.dll'
        if (Test-Path -LiteralPath $sts2Dll) {
            $item = Get-Item -LiteralPath $sts2Dll
            Write-Host "Using STS2 game directory: $candidate"
            Write-Host "Using STS2 assembly: $sts2Dll"
            Write-Host "STS2 product version: $($item.VersionInfo.ProductVersion)"
            return $candidate
        }

        Write-Host "Skipping STS2 candidate without sts2.dll: $candidate"
    }

    throw "Unable to find sts2.dll in any configured STS2 game directory candidate: $($gameDirCandidates -join '; ')"
}

function New-JobMcpConfig {
    param(
        [string]$RepoRoot,
        [string]$GameDir
    )

    $sourceMcpConfigPath = Join-Path $RepoRoot '.mcp.json'
    if (-not (Test-Path -LiteralPath $sourceMcpConfigPath)) {
        throw "MCP config template was not found at '$sourceMcpConfigPath'."
    }

    $mcpConfig = Get-Content -LiteralPath $sourceMcpConfigPath -Raw | ConvertFrom-Json

    $server = $mcpConfig.mcpServers.'spire-lens-mcp'
    if ($null -eq $server) {
        throw "MCP config template '$sourceMcpConfigPath' does not define mcpServers.spire-lens-mcp."
    }
    if ($null -eq $server.env) {
        $server | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
    }
    if ($server.env.PSObject.Properties.Name -contains 'STS2_GAME_DIR') {
        $server.env.STS2_GAME_DIR = $GameDir
    } else {
        $server.env | Add-Member -NotePropertyName STS2_GAME_DIR -NotePropertyValue $GameDir
    }

    $mcpConfigRoot = Join-Path $env:RUNNER_TEMP "issue-agent-mcp"
    New-Item -ItemType Directory -Force -Path $mcpConfigRoot | Out-Null
    $safeCheckoutName = ([IO.Path]::GetFileName($CheckoutPath) -replace '[^A-Za-z0-9._-]', '-')
    $jobMcpConfigPath = Join-Path $mcpConfigRoot "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)-$safeCheckoutName.mcp.json"
    [System.IO.File]::WriteAllText(
        $jobMcpConfigPath,
        ($mcpConfig | ConvertTo-Json -Depth 20),
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host "Generated per-job MCP config: $jobMcpConfigPath"
    Write-Host "Per-job MCP config STS2_GAME_DIR: $GameDir"
    return $jobMcpConfigPath
}

$candidates = @()
if (-not [string]::IsNullOrWhiteSpace($env:CONFIGURED_CLAUDE_CLI_PATH)) {
    $candidates += $env:CONFIGURED_CLAUDE_CLI_PATH
}

$candidates += @(
    'D:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe',
    'C:\automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe',
    (Join-Path $env:USERPROFILE 'automation\claude-code\node_modules\@anthropic-ai\claude-code\bin\claude.exe'),
    (Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe')
)

$claudePath = $candidates |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } |
    Select-Object -First 1

if (-not $claudePath) {
    throw "Claude Code CLI was not found. Set ISSUE_AGENT_CLAUDE_CLI_PATH or install Claude under a documented default location."
}

$buildRoot = Join-Path $env:RUNNER_TEMP ("issue-agent-build\$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)-$([IO.Path]::GetFileName($CheckoutPath))")
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

"CLAUDE_CLI_PATH=$claudePath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8NoBOM -Append
"ISSUE_AGENT_REPO_ROOT=$repoRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8NoBOM -Append
"ISSUE_AGENT_BUILD_ROOT=$buildRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8NoBOM -Append

$gameDir = Resolve-Sts2GameDir -RepoRoot $repoRoot
$sts2DataDir = Join-Path $gameDir 'data_sts2_windows_x86_64'
$jobMcpConfigPath = New-JobMcpConfig -RepoRoot $repoRoot -GameDir $gameDir

"ISSUE_AGENT_STS2_GAME_DIR=$gameDir" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8NoBOM -Append
"ISSUE_AGENT_STS2_DATA_DIR=$sts2DataDir" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8NoBOM -Append
"ISSUE_AGENT_MCP_CONFIG_PATH=$jobMcpConfigPath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8NoBOM -Append

if (-not $InstallMcp) { return }

$mcpRoot = 'D:\repos\spire-lens-mcp'
$mcpRepo = 'https://github.com/nelsong6/spire-lens-mcp.git'

if (Test-Path -LiteralPath (Join-Path $mcpRoot '.git')) {
    Invoke-LoggedStep -Name 'git fetch spire-lens-mcp' -Body {
        git -C $mcpRoot fetch --prune origin main
    }
    Invoke-LoggedStep -Name 'git checkout main (spire-lens-mcp)' -Body {
        git -C $mcpRoot checkout main
    }
    Invoke-LoggedStep -Name 'git pull spire-lens-mcp' -Body {
        git -C $mcpRoot pull --ff-only origin main
    }
} else {
    $parent = Split-Path -Parent $mcpRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Invoke-LoggedStep -Name 'git clone spire-lens-mcp' -Body {
        git clone $mcpRepo $mcpRoot
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "Unable to refresh SpireLens MCP checkout at '$mcpRoot'."
}

Invoke-LoggedStep -Name 'uv run python py_compile server.py' -Body {
    uv run --directory (Join-Path $mcpRoot 'mcp') python -m py_compile server.py
}

$buildScript = Join-Path $mcpRoot 'build.ps1'
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "SpireLens MCP build script was not found at '$buildScript'."
}

Invoke-LoggedStep -Name 'Build SpireLensMcp DLL' -Body {
    & $buildScript -GameDir $gameDir -Configuration Release
    if ($LASTEXITCODE -ne 0) {
        throw 'SpireLens MCP build failed.'
    }
}

$modsDir = Join-Path $gameDir 'mods'
New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

$staleMcpFolder = Join-Path $modsDir 'SpireLensMcp'
if (Test-Path -LiteralPath $staleMcpFolder) {
    Remove-Item -LiteralPath $staleMcpFolder -Recurse -Force -ErrorAction Stop
}

Invoke-LoggedStep -Name 'Stop existing STS2 processes' -Body {
    $gameDirWithSlash = $gameDir.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object {
        Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

Invoke-LoggedStep -Name 'Deploy SpireLensMcp into mods/' -Body {
    Copy-Item -LiteralPath (Join-Path $mcpRoot 'out\SpireLensMcp\SpireLensMcp.dll') -Destination (Join-Path $modsDir 'SpireLensMcp.dll') -Force
    Copy-Item -LiteralPath (Join-Path $mcpRoot 'mod_manifest.json') -Destination (Join-Path $modsDir 'SpireLensMcp.json') -Force
}

if (-not $StartSts2) { return }

$restartScript = Join-Path $repoRoot '.github\scripts\restart-sts2.ps1'
if (-not (Test-Path -LiteralPath $restartScript)) {
    throw "STS2 restart script was not found at '$restartScript'."
}

Invoke-LoggedStep -Name 'Restart STS2 and wait for bridge' -Body {
    & $restartScript `
        -Mode Restart `
        -McpConfigPath $jobMcpConfigPath `
        -StartupTimeoutSeconds 60 `
        -ShutdownTimeoutSeconds 45
}
