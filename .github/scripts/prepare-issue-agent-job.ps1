param(
    [Parameter(Mandatory = $true)][string]$CheckoutPath,
    [switch]$InstallMcp,
    [switch]$StartSts2
)

$ErrorActionPreference = 'Stop'

$repoRoot = Join-Path $env:GITHUB_WORKSPACE $CheckoutPath
if (-not (Test-Path -LiteralPath $repoRoot)) {
    throw "Issue-agent checkout was not found at '$repoRoot'."
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

"CLAUDE_CLI_PATH=$claudePath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
"ISSUE_AGENT_REPO_ROOT=$repoRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
"ISSUE_AGENT_BUILD_ROOT=$buildRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append

if (-not $InstallMcp) { return }

$mcpRoot = 'D:\repos\spire-lens-mcp'
$mcpRepo = 'https://github.com/nelsong6/spire-lens-mcp.git'

if (Test-Path -LiteralPath (Join-Path $mcpRoot '.git')) {
    git -C $mcpRoot fetch --prune origin main
    git -C $mcpRoot checkout main
    git -C $mcpRoot pull --ff-only origin main
} else {
    $parent = Split-Path -Parent $mcpRoot
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    git clone $mcpRepo $mcpRoot
}

if ($LASTEXITCODE -ne 0) {
    throw "Unable to refresh SpireLens MCP checkout at '$mcpRoot'."
}

uv run --directory (Join-Path $mcpRoot 'mcp') python -m py_compile server.py

$gameDir = 'D:\Programs\SteamLibrary\steamapps\common\Slay the Spire 2'
$buildScript = Join-Path $mcpRoot 'build.ps1'
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "SpireLens MCP build script was not found at '$buildScript'."
}

& $buildScript -GameDir $gameDir -Configuration Release
if ($LASTEXITCODE -ne 0) {
    throw 'SpireLens MCP build failed.'
}

$modsDir = Join-Path $gameDir 'mods'
New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

$staleMcpFolder = Join-Path $modsDir 'SpireLensMcp'
if (Test-Path -LiteralPath $staleMcpFolder) {
    Remove-Item -LiteralPath $staleMcpFolder -Recurse -Force -ErrorAction Stop
}

$gameDirWithSlash = $gameDir.TrimEnd('\') + '\'
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @('SlayTheSpire2.exe', 'crashpad_handler.exe') -and
    -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
    ([string]$_.ExecutablePath).StartsWith($gameDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

Copy-Item -LiteralPath (Join-Path $mcpRoot 'out\SpireLensMcp\SpireLensMcp.dll') -Destination (Join-Path $modsDir 'SpireLensMcp.dll') -Force
Copy-Item -LiteralPath (Join-Path $mcpRoot 'mod_manifest.json') -Destination (Join-Path $modsDir 'SpireLensMcp.json') -Force

if (-not $StartSts2) { return }

$restartScript = Join-Path $repoRoot '.github\scripts\restart-sts2.ps1'
if (-not (Test-Path -LiteralPath $restartScript)) {
    throw "STS2 restart script was not found at '$restartScript'."
}

& $restartScript `
    -Mode Restart `
    -McpConfigPath (Join-Path $repoRoot '.mcp.json') `
    -StartupTimeoutSeconds 60 `
    -ShutdownTimeoutSeconds 45
