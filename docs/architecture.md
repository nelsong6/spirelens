# Architecture

This codebase has two big goals:

1. stay hot-reload friendly during development
2. attribute run outcomes back to the card that actually caused them

## Runtime Topology

### Loader

- [Loader/LoaderMain.cs](../Loader/LoaderMain.cs) is the stable bootstrap loaded once by the game's mod manager.
- It owns the `F5` workflow:
  - copy the Core DLL to a fresh temp path
  - load that copy
  - call `CoreMain.Initialize()`
  - on reload, call the previous `CoreMain.Shutdown()` first
- It also owns the stable BaseLib boundary:
  - [Config/SpireLensConfig.cs](../Config/SpireLensConfig.cs) defines the BaseLib-backed mod settings UI
  - [Loader/RuntimeOptionsBridge.cs](../Loader/RuntimeOptionsBridge.cs) exposes a stable runtime-options bridge to the hot-reloaded Core
  - [Api/SpireLensApiRegistry.cs](../Api/SpireLensApiRegistry.cs) exposes a small public API surface other mods can call into
- The loader does not try to truly unload old contexts; it relies on explicit cleanup plus process-lifetime tolerance.

### Core

- [Core/CoreMain.cs](../Core/CoreMain.cs) is the hot-reloaded entry point.
- It applies Harmony patches, wires tracker hooks, resumes active run state after reload, and tears all of that back down on `Shutdown()`.
- The Core intentionally does not reference BaseLib directly anymore.
- Loader-owned config is consumed through [Core/RuntimeOptions.cs](../Core/RuntimeOptions.cs), which keeps the hot-reloaded assembly focused on domain logic instead of framework glue.

## Data Flow

### Live Tracking

- [Core/RunTracker.cs](../Core/RunTracker.cs) is the heart of the mod.
- Combat history entries and selected hook patches feed into the tracker.
- During combat, observations accumulate in `_pendingCombat`.
- On combat end, `_pendingCombat` is promoted into the committed run aggregates and saved.

This combat-boundary rule is important:

- between-combat reload is supported
- between-floor reload is supported
- mid-combat restore is intentionally unsupported

### Persistence

- [Core/RunData.cs](../Core/RunData.cs) defines the serialized run shape.
- [Core/RunStorage.cs](../Core/RunStorage.cs) handles load/save and resumability rules.
- Schema changes are additive when possible. The current schema is `v14`.

Historical compatibility is pinned by:

- [Fixtures/RunSchema](../Fixtures/RunSchema/README.md)
- [Tests/SpireLens.Core.Tests/SchemaLoadingTests.cs](../Tests/SpireLens.Core.Tests/SchemaLoadingTests.cs)

## Attribution Model

The project tries to answer "what actually happened because of this card?" rather than "what did the card text claim?"

Examples already implemented:

- direct attack damage, blocked damage, overkill, kills
- block gained / effective / wasted
- actual energy generated
- Regent stars spent / generated
- forge granted from cards
- observed cards drawn from draw effects
- blocked draw attempts, categorized blocked reasons, and effect-side downstream blocked counts
- successful self-summons to hand for recurring cards like Make It So
- effect applications credited back to the source card
- Artifact-blocked debuffs
- downstream poison damage and poison overkill
- stacked merged effects like Noxious Fumes preserve per-source contribution ledgers before their poison fanout is charged back into the poison ownership ledger

When attribution is not naturally one-card-to-one-outcome, the code prefers:

- observed outcomes over listed intent
- pooled summaries for combat-generated cards when they do not have stable deck identity
- explicitly heuristic handling instead of pretending certainty

## UI Surface

- [Core/Patches/ViewStatsInjectorPatch.cs](../Core/Patches/ViewStatsInjectorPatch.cs) injects the `View Stats` toggle into the deck view.
- [Core/Patches/CardHoverTooltipPatch.cs](../Core/Patches/CardHoverTooltipPatch.cs) builds compact and full tooltip bodies.
- [Core/StatsTooltip.cs](../Core/StatsTooltip.cs) renders the side tooltip panel.
- [Config/SpireLensConfig.cs](../Config/SpireLensConfig.cs) provides the persistent mod-settings UI for runtime display options.

Current UI conventions:

- hand tooltips stay compact
- deck-view tooltips can be fuller and include lineage/context
- rows should be self-describing
- loud section headers are discouraged unless they add real clarity
- inline icons are preferred for keyword-like effects when they improve scanning
- when the game already exposes a recognizable asset, prefer the in-game block/draw/energy/star iconography over generic text-only rows

## Generated And Non-Deck Cards

Not every card the player sees should be treated as a stable deck resident.

- stable deck cards use per-instance numbering
- removed cards remain viewable with their accumulated stats
- some combat-generated cards are better represented as pooled summaries than as fake permanent instances

That distinction matters for both tooltip wording and data integrity.

## If You Add A New Stat

Use this checklist:

1. decide whether the stat should be per-instance, pooled, or effect-oriented
2. record the observed game outcome, not just the requested amount, if those can diverge
3. update [RunData.cs](../Core/RunData.cs) if persistence changes
4. update fixtures under [Fixtures/RunSchema](../Fixtures/RunSchema/README.md)
5. update [SchemaLoadingTests.cs](../Tests/SpireLens.Core.Tests/SchemaLoadingTests.cs)
6. update tooltip rendering in [CardHoverTooltipPatch.cs](../Core/Patches/CardHoverTooltipPatch.cs) if the stat is user-facing
7. keep compact tooltip noise low
