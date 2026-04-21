# CardUtilityStats

Per-card attribution stats mod for [Slay the Spire 2](https://store.steampowered.com/app/2868840/Slay_the_Spire_2/). For every card you play, tracks what actually happened — effective damage vs. overkill, block that absorbed vs. wasted, drawn cards played vs. idle, energy generated vs. unused.

**Status:** Dev build — M1 through M5a shipped (damage attribution, intended block, energy/draw, in-game UI, removed-card viewing). Not yet published to Nexus (M6).

## Why

Existing stats mods answer "how often did I *pick* this card" ([SlayTheStats](https://www.nexusmods.com/slaythespire2/mods/349)) or "how much value did this *relic* provide" ([Relic Stats](https://www.nexusmods.com/slaythespire2/mods/327)). Nothing tracks how much of what each card *attempted* actually mattered. A 6-damage Strike into a 4-HP enemy and a 6-damage Strike into a fresh elite look the same on a play counter, but they have very different value.

## What it tracks (target design)

**Attack cards** — four numbers per play:

- `raw_damage_intended` — damage the card tried to deal (after buffs/debuffs)
- `blocked_by_target` — enemy block that absorbed some
- `overkill` — damage past enemy HP (wasted)
- `effective_damage` — what actually counted

**Block cards** — how much of the generated block actually absorbed incoming damage vs. expired unused. Per-card block attribution uses a heuristic (see [issue #1](https://github.com/nelsong6/card-utility-stats/issues/1)).

**Utility cards** — closure tracking:

- Energy generated: was it spent or end-of-turn wasted?
- Cards drawn: were they played this turn/run or sit in hand?

## How you'd use it

A **"View Stats"** checkbox sits next to the game's existing "View Upgrades" toggle on the in-run deck view. When ticked, hovering a card shows a side-panel tooltip with per-instance stats (plays, damage, block gained, energy spent, etc.) — coexists with the game's built-in hover tips rather than replacing them. Hand hovers get a compact version; deck-view hovers get the full elaborate view.

The checkbox also toggles a **removed-card overlay**: cards you've removed this run (Smith, events, curse dispose) appear inline in the deck grid, marked with a red "Card Removed" banner in their tooltip so you can review their stats post-removal. Checkbox state persists across hot reloads via a small `prefs.json`.

Available only on in-run deck-view surfaces for now (not Compendium — lifetime aggregation is deferred, see [issue #2](https://github.com/nelsong6/card-utility-stats/issues/2)).

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| **M1** | Attack damage attribution — the 4 numbers above | ✅ [#5](https://github.com/nelsong6/card-utility-stats/issues/5) |
| **M2a** | Intended block (how much this card contributed) | ✅ |
| **M2b** | Block absorption (effective vs wasted) — needs heuristic | [#14](https://github.com/nelsong6/card-utility-stats/issues/14) |
| **M3** | Utility card closure (energy spent, draw count) | ✅ [#7](https://github.com/nelsong6/card-utility-stats/issues/7) |
| **M4** | In-game UI: "View Stats" checkbox on deck view | ✅ [#8](https://github.com/nelsong6/card-utility-stats/issues/8) |
| **M5a** | Removed-card viewing in deck view | ✅ |
| **M5b** | Run History integration — browse past-run stats | [#9](https://github.com/nelsong6/card-utility-stats/issues/9) |
| **M6** | Publish v0.1 to Nexus | — |

Additional shipped: discard count, pile-top placements (from hand / from discard), exhaust-others attribution, HP-lost from self-damage cards, cards-drawn attribution.

Open: [#10 Run outcome detection](https://github.com/nelsong6/card-utility-stats/issues/10) — non-blocking for M1–M3, required before M6.

## Storage

Per-run JSON files at `%APPDATA%/SlayTheSpire2/CardUtilityStats/runs/<run-id>.json` (Godot's `user://` path). Contains both aggregated stats (fast for UI) and a full event log (one entry per card-played / damage-received / card-upgraded / block-gained / card-removed event, for future analysis). Schema versioned — see [issue #4](https://github.com/nelsong6/card-utility-stats/issues/4). Session preferences (checkbox state) at `prefs.json` in the same dir.

## Requirements

- Slay the Spire 2 (tested against v0.103.2)
- [BaseLib](https://www.nexusmods.com/slaythespire2/mods/103) — required dependency

## Install

Drop `CardUtilityStats.dll` and `CardUtilityStats.json` (and `CardUtilityStats.pck` once UI lands) into `<game install>/mods/`. Requires BaseLib.

## Build from source

**Prereqs:** .NET 9 SDK, Slay the Spire 2 installed locally.

```sh
# If the path discovery in Sts2PathDiscovery.props doesn't find your game,
# create Directory.Build.props with your path:
cat > Directory.Build.props <<'XML'
<Project>
    <PropertyGroup>
        <Sts2Path>D:/SteamLibrary/steamapps/common/Slay the Spire 2</Sts2Path>
    </PropertyGroup>
</Project>
XML

dotnet build -c Release
```

The build's `CopyToModsFolderOnBuild` target auto-deploys the `.dll` and manifest to `<game>/mods/CardUtilityStats/`. No manual copy step.

## Credits

- Scaffolded from [Alchyr/ModTemplate-StS2](https://github.com/Alchyr/ModTemplate-StS2)
- Concept inspired by the gap between pick-rate trackers and actual-impact tracking
- BaseLib by [Alchyr](https://www.nexusmods.com/slaythespire2/mods/103)

## License

MIT.
