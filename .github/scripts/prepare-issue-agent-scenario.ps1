param(
    [Parameter(Mandatory = $true)]
    [string]$TestPlanPath,
    [Parameter(Mandatory = $true)]
    [string]$McpConfigPath,
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,
    [Parameter(Mandatory = $true)]
    [string]$ValidationArtifactDir,
    [Parameter(Mandatory = $true)]
    [string]$IssueNumber
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0  # uninitialized vars + method-syntax misuse; kept off v3 because optional JSON access patterns (e.g. $result.usage.input_tokens) would throw

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

function Write-SetupArtifact {
    param([hashtable]$Data)
    New-Item -ItemType Directory -Force -Path $ValidationArtifactDir | Out-Null
    $path = Join-Path $ValidationArtifactDir 'issue-agent-scenario-setup.json'
    [System.IO.File]::WriteAllText($path, ($Data | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-McpServerConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "MCP config not found: $Path" }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $server = $config.mcpServers.'spire-lens-mcp'
    if ($null -eq $server) { throw "MCP config does not define spire-lens-mcp." }
    return $server
}

function Get-McpDirectory {
    param([object]$Server)
    $args = @($Server.args)
    for ($i = 0; $i -lt $args.Count - 1; $i++) {
        if ([string]$args[$i] -eq '--directory') { return [string]$args[$i + 1] }
    }
    throw "Unable to find '--directory' in spire-lens-mcp args."
}

function Invoke-McpPython {
    param(
        [string]$McpDirectory,
        [string]$Mode,
        [string]$SetupPath,
        [string]$OutputPath
    )

    $python = @'
import asyncio
import importlib.util
import json
import sys
from pathlib import Path

mode = sys.argv[1]
setup_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
server_path = Path.cwd() / "server.py"
spec = importlib.util.spec_from_file_location("spire_lens_mcp_server", server_path)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(data):
    output_path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def parse_tool_json(text, tool_name):
    try:
        data = json.loads(text)
    except Exception as exc:
        raise RuntimeError(f"{tool_name} returned non-JSON: {text[:500]}") from exc
    if data.get("status") == "error":
        raise RuntimeError(f"{tool_name} failed: {data}")
    return data


def normalize_setup_id(value, prefix):
    text = str(value or "").strip().upper()
    marker = f"{prefix}."
    return text[len(marker):] if text.startswith(marker) else text


def iter_visible_cards(state):
    player = state.get("player") if isinstance(state, dict) else {}
    if not isinstance(player, dict):
        return
    for pile in ("hand", "draw_pile", "discard_pile", "exhaust_pile"):
        cards = player.get(pile)
        if not isinstance(cards, list):
            continue
        for index, card in enumerate(cards):
            if isinstance(card, dict):
                yield pile, index, card


def assert_loaded_state_matches_setup(setup, state):
    if not isinstance(state, dict):
        raise RuntimeError("Loaded game state was not a JSON object.")

    state_type = state.get("state_type")
    if setup.get("next_normal_encounter") and state_type != "monster":
        raise RuntimeError(
            f"Scenario declared next_normal_encounter={setup.get('next_normal_encounter')!r} "
            f"but loaded state_type={state_type!r}, not monster."
        )

    deprecated_cards = []
    for pile, index, card in iter_visible_cards(state):
        name = str(card.get("name") or "")
        description = str(card.get("description") or "")
        if name.lower() == "deprecated card" or "card was removed in a recent update" in description.lower():
            deprecated_cards.append({"pile": pile, "index": index, "name": name, "description": description})
    if deprecated_cards:
        raise RuntimeError(
            "Scenario loaded Deprecated Card placeholders, which means the scenario deck contains invalid card ids: "
            + json.dumps(deprecated_cards, ensure_ascii=False)
        )

    player = state.get("player") if isinstance(state.get("player"), dict) else {}
    relics = player.get("relics") if isinstance(player.get("relics"), list) else []
    present_relic_ids = {
        normalize_setup_id(relic.get("id"), "RELIC")
        for relic in relics
        if isinstance(relic, dict)
    }
    expected_relics = []
    if isinstance(setup.get("relics"), list):
        expected_relics.extend(setup.get("relics") or [])
    if isinstance(setup.get("add_relics"), list):
        expected_relics.extend(setup.get("add_relics") or [])
    for relic_id in expected_relics:
        normalized = normalize_setup_id(relic_id, "RELIC")
        if normalized and normalized not in present_relic_ids:
            raise RuntimeError(
                f"Scenario expected relic {relic_id!r}, but loaded relic ids were {sorted(present_relic_ids)}."
            )

    removed_relics = setup.get("remove_relics") if isinstance(setup.get("remove_relics"), list) else []
    for relic_id in removed_relics:
        normalized = normalize_setup_id(relic_id, "RELIC")
        if normalized and normalized in present_relic_ids:
            raise RuntimeError(f"Scenario removed relic {relic_id!r}, but it is still present after load.")

    return {
        "status": "ok",
        "state_type": state_type,
        "deprecated_card_count": len(deprecated_cards),
        "present_relic_ids": sorted(present_relic_ids),
    }


async def materialize_only():
    setup = read_json(setup_path)
    kwargs = {
        "base_name": setup["base_save_name"],
        "scenario_name": setup["scenario_name"],
        "deck": setup.get("deck"),
        "add_cards": setup.get("add_cards"),
        "remove_cards": setup.get("remove_cards"),
        "relics": setup.get("relics"),
        "add_relics": setup.get("add_relics"),
        "remove_relics": setup.get("remove_relics"),
        "gold": setup.get("gold"),
        "current_hp": setup.get("current_hp"),
        "max_hp": setup.get("max_hp"),
        "max_energy": setup.get("max_energy"),
        "next_normal_encounter": setup.get("next_normal_encounter"),
    }
    materialized = parse_tool_json(await server.materialize_scenario_save(**kwargs), "materialize_scenario_save")
    write_json({
        "status": "pass",
        "mode": mode,
        "scenario_setup": setup,
        "materialized": materialized,
    })


async def install_only():
    existing = read_json(output_path) if output_path.exists() else {"status": "pass"}
    setup = read_json(setup_path)
    installed = parse_tool_json(await server.install_save_as_current(setup["scenario_name"], "scenario"), "install_save_as_current")
    existing["status"] = "pass"
    existing["mode"] = mode
    existing["scenario_setup"] = setup
    existing["installed"] = installed
    write_json(existing)


async def materialize_install():
    await materialize_only()
    existing = read_json(output_path)
    setup = read_json(setup_path)
    installed = parse_tool_json(await server.install_save_as_current(setup["scenario_name"], "scenario"), "install_save_as_current")
    existing.update({
        "installed": installed,
    })
    write_json(existing)


async def validate_load():
    existing = read_json(output_path) if output_path.exists() else {"status": "pass"}
    setup = read_json(setup_path)
    # Launching through Steam can leave the remote mirror populated while the
    # AppData working save is absent. Install again after the bridge is ready so
    # the in-game saved-run loader and validator see the same current_run.save.
    live_installed = parse_tool_json(await server.install_save_as_current(setup["scenario_name"], "scenario"), "install_save_as_current")
    validate = parse_tool_json(await server.validate_current_run_save(), "validate_current_run_save")
    menu_state = None
    stable_menu_polls = 0
    for _ in range(30):
        menu_state = parse_tool_json(await server.get_game_state("json"), "get_game_state")
        if menu_state.get("state_type") == "menu":
            stable_menu_polls += 1
            if stable_menu_polls >= 3:
                break
        else:
            stable_menu_polls = 0
        await asyncio.sleep(1.0)
    if stable_menu_polls < 3:
        raise RuntimeError(f"Game did not reach a stable menu state before loading scenario save: {menu_state}")
    # The MCP bridge comes up before STS2 has fully settled its startup/menu
    # coroutines. Loading immediately can cancel LaunchMainMenu/logo startup and
    # make STS2 show its generic startup-error popup even though combat loads.
    await asyncio.sleep(3.0)
    loaded = parse_tool_json(await server.load_current_run_save(), "load_current_run_save")
    state = None
    for _ in range(40):
        state = parse_tool_json(await server.get_game_state("json"), "get_game_state")
        state_type = state.get("state_type")
        if state_type not in (None, "menu", "unknown", "loading"):
            if state_type != "monster":
                break
            battle = state.get("battle") or {}
            if battle.get("enemies"):
                break
        await asyncio.sleep(0.5)
    existing["live_installed"] = live_installed
    existing["validated"] = validate
    existing["pre_load_menu_state"] = menu_state
    existing["loaded"] = loaded
    existing["mode"] = mode
    existing["game_state"] = state
    existing["state_type"] = state.get("state_type") if state else None
    existing["loaded_character_id"] = (state or {}).get("character_id") or (state or {}).get("player", {}).get("character_id")
    existing["scenario_state_validation"] = assert_loaded_state_matches_setup(setup, state)
    write_json(existing)


if mode == "materialize_install":
    asyncio.run(materialize_install())
elif mode == "materialize_only":
    asyncio.run(materialize_only())
elif mode == "install_only":
    asyncio.run(install_only())
elif mode == "validate_load":
    asyncio.run(validate_load())
else:
    raise SystemExit(f"unknown mode: {mode}")
'@

    $scriptPath = Join-Path $env:TEMP ('prepare-issue-agent-scenario-' + [guid]::NewGuid().ToString() + '.py')
    try {
        [System.IO.File]::WriteAllText($scriptPath, $python, (New-Object System.Text.UTF8Encoding($false)))
        & uv run --directory $McpDirectory python $scriptPath $Mode $SetupPath $OutputPath
        if ($LASTEXITCODE -ne 0) { throw "MCP Python helper failed in mode '$Mode'." }
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

$artifact = [ordered]@{
    layer = 'scenario_setup'
    status = 'abort'
    abort_reason = $null
    retryable = $true
    human_action_required = $false
    notes = ''
    issue_number = [int]$IssueNumber
}

try {
    if (-not (Test-Path -LiteralPath $TestPlanPath)) { throw "Test plan artifact not found: $TestPlanPath" }
    $testPlan = Get-Content -LiteralPath $TestPlanPath -Raw | ConvertFrom-Json
    $setup = $testPlan.scenario_setup
    if ($null -eq $setup) {
        throw "Test plan did not include scenario_setup. Refusing to spend verification LLM time without a deterministic scenario."
    }
    foreach ($required in @('base_save_name', 'scenario_name', 'deck')) {
        if ($null -eq $setup.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$setup.$required)) {
            throw "scenario_setup.$required is required."
        }
    }

    $setupPath = Join-Path $ValidationArtifactDir 'issue-agent-scenario-setup-input.json'
    New-Item -ItemType Directory -Force -Path $ValidationArtifactDir | Out-Null
    [System.IO.File]::WriteAllText($setupPath, ($setup | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))

    $server = Get-McpServerConfig -Path $McpConfigPath
    $mcpDirectory = Get-McpDirectory -Server $server
    $outputPath = Join-Path $ValidationArtifactDir 'issue-agent-scenario-setup.json'

    Invoke-LoggedStep -Name 'Restart STS2 (materialize phase)' -Body {
        & (Join-Path $RepoRoot '.github\scripts\restart-sts2.ps1') -Mode Restart -McpConfigPath $McpConfigPath -StartupTimeoutSeconds 90 -ShutdownTimeoutSeconds 45
    }
    Invoke-LoggedStep -Name 'MCP materialize_only' -Body {
        Invoke-McpPython -McpDirectory $mcpDirectory -Mode 'materialize_only' -SetupPath $setupPath -OutputPath $outputPath
    }
    Invoke-LoggedStep -Name 'Stop STS2 before save install' -Body {
        & (Join-Path $RepoRoot '.github\scripts\restart-sts2.ps1') -Mode Stop -McpConfigPath $McpConfigPath -ShutdownTimeoutSeconds 45
    }
    Invoke-LoggedStep -Name 'MCP install_only' -Body {
        Invoke-McpPython -McpDirectory $mcpDirectory -Mode 'install_only' -SetupPath $setupPath -OutputPath $outputPath
    }
    Invoke-LoggedStep -Name 'Restart STS2 (validate phase)' -Body {
        & (Join-Path $RepoRoot '.github\scripts\restart-sts2.ps1') -Mode Restart -McpConfigPath $McpConfigPath -StartupTimeoutSeconds 90 -ShutdownTimeoutSeconds 45
    }
    Invoke-LoggedStep -Name 'MCP validate_load' -Body {
        Invoke-McpPython -McpDirectory $mcpDirectory -Mode 'validate_load' -SetupPath $setupPath -OutputPath $outputPath
    }

    $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    if ([string]$result.status -ne 'pass') { throw "Scenario setup did not pass." }
    if ([string]::IsNullOrWhiteSpace([string]$result.state_type) -or [string]$result.state_type -in @('menu', 'unknown', 'loading')) {
        throw "Scenario loaded into unexpected state_type='$($result.state_type)'."
    }
    if ([string]$result.state_type -eq 'monster') {
        $battle = $result.game_state.battle
        if ($null -eq $battle -or $null -eq $battle.enemies -or @($battle.enemies).Count -eq 0) {
            throw "Scenario reached monster state before active battle details were available."
        }

    }

    Write-Host "Scenario setup ready: $($setup.scenario_name), state_type=$($result.state_type)."
} catch {
    $artifact.abort_reason = 'scenario_setup_failed'
    $artifact.notes = $_.Exception.Message
    $path = Write-SetupArtifact -Data $artifact
    Write-Error "Issue-agent scenario setup failed. Wrote $path. $($_.Exception.Message)"
}
