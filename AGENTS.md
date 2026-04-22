# AGENTS

This repo is a hot-reloadable Slay the Spire 2 mod focused on per-card attribution: not just what a card says it should do, but what it actually caused in the run.

## Current Truths

- Runtime is split into a stable loader and a hot-reloaded core.
  - [Loader/LoaderMain.cs](D:/repos/CardUtilityStats/Loader/LoaderMain.cs:14) owns the long-lived bootstrap and `F5` reload flow.
  - [Core/CoreMain.cs](D:/repos/CardUtilityStats/Core/CoreMain.cs:8) owns Harmony patch install/uninstall and re-entry on each reload.
- Persistence is combat-boundary based.
  - [Core/RunTracker.cs](D:/repos/CardUtilityStats/Core/RunTracker.cs:18) buffers live combat data in `_pendingCombat`.
  - Nothing is promoted to the permanent run file until combat ends.
  - Reload between combats / between floors is supported and expected.
  - Mid-combat restore is intentionally out of scope.
- The data model is additive through schema `v10`.
  - [Core/RunData.cs](D:/repos/CardUtilityStats/Core/RunData.cs:13) is the source of truth for the current schema.
  - [Tests/CardUtilityStats.Core.Tests/SchemaLoadingTests.cs](D:/repos/CardUtilityStats/Tests/CardUtilityStats.Core.Tests/SchemaLoadingTests.cs:1) and the checked-in fixtures pin what remains resumable.
- Card identity is per physical card when the card has stable deck identity.
  - Instance numbers never get reused within a run.
  - Combat-generated cards that do not meaningfully exist in the deck may use pooled summaries instead of fake deck-instance identities.
- Attribution prefers observed outcomes over listed card text whenever the game can diverge from the card face.
  - Examples already in tree: actual energy gained, Regent stars spent/gained, forge granted, observed cards drawn, successful self-summons to hand, Artifact-blocked debuffs, and downstream poison damage.
- Tooltip style is intentionally quiet.
  - Hand view stays compact.
  - Rows should be self-describing without noisy section headers.
  - Inline keyword icons are preferred when they improve scanability without making the layout louder.
  - When the game already has a recognizable asset for the stat, prefer that in-game icon over a generic label.

## Start Here

- Read [README.md](D:/repos/CardUtilityStats/README.md:1) for the product-level overview.
- Read [docs/architecture.md](D:/repos/CardUtilityStats/docs/architecture.md:1) for subsystem layout and data flow.
- For tracking behavior, start in [Core/RunTracker.cs](D:/repos/CardUtilityStats/Core/RunTracker.cs:18).
- For tooltip/UI behavior, start in:
  - [Core/Patches/ViewStatsInjectorPatch.cs](D:/repos/CardUtilityStats/Core/Patches/ViewStatsInjectorPatch.cs:11)
  - [Core/Patches/CardHoverTooltipPatch.cs](D:/repos/CardUtilityStats/Core/Patches/CardHoverTooltipPatch.cs:11)

## When Changing Behavior

- If you add persisted fields:
  - bump `RunData.CurrentSchemaVersion`
  - add or update fixture files under [Fixtures/RunSchema](D:/repos/CardUtilityStats/Fixtures/RunSchema/README.md:1)
  - update [SchemaLoadingTests.cs](D:/repos/CardUtilityStats/Tests/CardUtilityStats.Core.Tests/SchemaLoadingTests.cs:1)
- If you change tooltip presentation:
  - preserve the compact-vs-full distinction
  - keep labels self-describing
  - avoid adding loud headers unless they clearly earn their space
- If you add new attribution:
  - prefer empirical results over intent text
  - be explicit when attribution is heuristic, pooled, contributor-ledger based, or case-specific

## Useful Commands

- Build/tests:
  - `dotnet test D:\repos\CardUtilityStats\Tests\CardUtilityStats.Core.Tests\CardUtilityStats.Core.Tests.csproj -c Debug`
- Focused schema tests:
  - `dotnet test D:\repos\CardUtilityStats\Tests\CardUtilityStats.Core.Tests\CardUtilityStats.Core.Tests.csproj -c Debug --filter SchemaLoadingTests`
- Focused tooltip tests:
  - `dotnet test D:\repos\CardUtilityStats\Tests\CardUtilityStats.Core.Tests\CardUtilityStats.Core.Tests.csproj -c Debug --filter PoisonTooltipTests`
