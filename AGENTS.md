# AGENTS

This repo is a hot-reloadable Slay the Spire 2 mod focused on per-card attribution: not just what a card says it should do, but what it actually caused in the run.

## Mod Policy

The Slay the Spire 2 install (`D:\SteamLibrary\steamapps\common\Slay the Spire 2\mods\`) runs **only** the user's own mods plus their required prereqs. No third-party mods.

Allowed entries:

1. The user's own mods — currently **SpireLens**.
2. Required prereqs for (1) — currently **BaseLib** (Alchyr), which SpireLens depends on for Harmony patching and node factories.
3. Tooling prereqs required to validate (1) via the agentic issue-agent flow — currently **`SpireLensMcp`** (in-house fork at [`nelsong6/spire-lens-mcp`](https://github.com/nelsong6/spire-lens-mcp), source at `D:\repos\spire-lens-mcp\`, vendored from `Gennadiyev/STS2MCP` under MIT). Listens on `localhost:15526` exposing `/api/v1/singleplayer` and `/api/v1/multiplayer`; the Python MCP server in the same repo's `mcp/` directory connects to that endpoint and exposes ~50 game-control tools to Claude. Without it the issue-agent workflow's bridge-readiness probe fails before Claude launches. The original `kunology/STS2MCP` (mod ID `STS2_MCP`, at `D:\repos\STS2MCP\`) is on disk for reference but no longer the active install.

When inspecting `mods/`, treat any non-(SpireLens|BaseLib|SpireLensMcp) entry as a removal candidate. Don't recommend installing third-party mods even for diagnostics — prefer adding the diagnostic to SpireLens itself. Orphaned appdata under `%APPDATA%\SlayTheSpire2\` from removed third-party mods is also fair game to clean up, after inspecting contents (some folders, e.g. save-game backups, may have user value). Expected `Loaded N mods` line in the game log: **3** when SpireLensMcp is installed (BaseLib + SpireLens + SpireLensMcp), **2** otherwise.

## Current Truths

- Runtime is split into a stable loader and a hot-reloaded core.
  - [Loader/LoaderMain.cs](D:/repos/SpireLens/Loader/LoaderMain.cs:14) owns the long-lived bootstrap and `F5` reload flow.
  - [Core/CoreMain.cs](D:/repos/SpireLens/Core/CoreMain.cs:8) owns Harmony patch install/uninstall and re-entry on each reload.
- Persistence is combat-boundary based.
  - [Core/RunTracker.cs](D:/repos/SpireLens/Core/RunTracker.cs:18) buffers live combat data in `_pendingCombat`.
  - Nothing is promoted to the permanent run file until combat ends.
  - Reload between combats / between floors is supported and expected.
  - Mid-combat restore is intentionally out of scope.
- The persisted shape evolves additively without an explicit version number.
  - [Core/RunData.cs](D:/repos/SpireLens/Core/RunData.cs:1) is the source of truth for the current shape.
  - [Core/RunStorage.cs](D:/repos/SpireLens/Core/RunStorage.cs:1) detects the historic pooled shape structurally; everything else is current per-instance.
  - [Tests/SpireLens.Core.Tests/SchemaLoadingTests.cs](D:/repos/SpireLens/Tests/SpireLens.Core.Tests/SchemaLoadingTests.cs:1) and the checked-in fixtures pin known shapes that must remain loadable.
- Card identity is per physical card when the card has stable deck identity.
  - Instance numbers never get reused within a run.
  - Combat-generated cards that do not meaningfully exist in the deck may use pooled summaries instead of fake deck-instance identities.
- Attribution prefers observed outcomes over listed card text whenever the game can diverge from the card face.
  - Examples already in tree: actual energy gained, Regent stars spent/gained, forge granted, observed cards drawn, blocked draw attempts/reasons, successful self-summons to hand, Artifact-blocked debuffs, and downstream poison damage.
- Tooltip style is intentionally quiet.
  - Hand view stays compact.
  - Rows should be self-describing without noisy section headers.
  - Inline keyword icons are preferred when they improve scanability without making the layout louder.
  - When the game already has a recognizable asset for the stat, prefer that in-game icon over a generic label.

## Start Here

- Read [README.md](D:/repos/SpireLens/README.md:1) for the product-level overview.
- Read [docs/architecture.md](D:/repos/SpireLens/docs/architecture.md:1) for subsystem layout and data flow.
- Read [docs/sts2-runtime-primer.md](docs/sts2-runtime-primer.md) before changing card/relic attribution hooks; it captures stable Slay the Spire 2 lifecycle, combat-history, async hook, pile, and attribution timing behavior.
- For tracking behavior, start in [Core/RunTracker.cs](D:/repos/SpireLens/Core/RunTracker.cs:18).
- For tooltip/UI behavior, start in:
  - [Core/Patches/ViewStatsInjectorPatch.cs](D:/repos/SpireLens/Core/Patches/ViewStatsInjectorPatch.cs:11)
  - [Core/Patches/CardHoverTooltipPatch.cs](D:/repos/SpireLens/Core/Patches/CardHoverTooltipPatch.cs:11)

## When Changing Behavior

- If you add persisted fields:
  - keep them additive so old run files still load via missing-field defaults
  - add a fixture file under [Fixtures/RunSchema](D:/repos/SpireLens/Fixtures/RunSchema/README.md:1) capturing the new shape
  - update [SchemaLoadingTests.cs](D:/repos/SpireLens/Tests/SpireLens.Core.Tests/SchemaLoadingTests.cs:1) to assert the new shape loads and any new fields land where expected
- If you change tooltip presentation:
  - preserve the compact-vs-full distinction
  - keep labels self-describing
  - avoid adding loud headers unless they clearly earn their space
- If you add new attribution:
  - read [docs/sts2-runtime-primer.md](docs/sts2-runtime-primer.md) first
  - prefer empirical results over intent text
  - be explicit when attribution is heuristic, pooled, contributor-ledger based, or case-specific

## Useful Commands

- Build/tests:
  - `dotnet test D:\repos\SpireLens\Tests\SpireLens.Core.Tests\SpireLens.Core.Tests.csproj -c Debug`
- Focused schema tests:
  - `dotnet test D:\repos\SpireLens\Tests\SpireLens.Core.Tests\SpireLens.Core.Tests.csproj -c Debug --filter SchemaLoadingTests`
- Focused tooltip tests:
  - `dotnet test D:\repos\SpireLens\Tests\SpireLens.Core.Tests\SpireLens.Core.Tests.csproj -c Debug --filter PoisonTooltipTests`
