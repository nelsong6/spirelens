# Slay the Spire 2 Runtime Primer

This is the stable mental model future agents should read before changing card or relic attribution. It is not a replacement for source inspection. It is the map of the game/runtime facts that have been rediscovered often enough that they should be treated as durable context.

Primary local entry points after reading this:

- `Core/RunTracker.cs`: attribution state machine, pending combat buffer, persistence boundary, card identity, block/effect/poison ledgers.
- `Core/Patches/*.cs`: trusted hook surfaces and the timing assumptions behind them.
- `Core/RunData.cs`: persisted schema and what each aggregate field means.
- `docs/architecture.md`: SpireLens topology and product-level data flow.

## The Two Worlds

SpireLens always has to keep two worlds distinct:

1. The game's live runtime: Godot nodes, CombatManager, RunManager, CardModel objects, piles, hooks, combat history, powers, relics, and async model callbacks.
2. SpireLens' run record: committed `RunData`, pending combat aggregates/events, tooltip projections, and JSON persistence.

The live runtime is mutable and object-reference heavy. The persisted run record must be stable across hot reloads, combat transitions, and future schema additions. Most bugs come from accidentally treating one world as if it had the guarantees of the other.

A good rule: observe the game as late as needed to know what really happened, but record it in SpireLens as early as needed to preserve the source context before the game discards it.

## Threading And Async Shape

The game events SpireLens relies on fire on the main thread. `RunTracker` still uses a lock because save I/O is asynchronous and because the hot-reload lifecycle can cross visible state transitions.

Several STS2 hook methods are async or participate in async card/relic/power flows. SpireLens usually does not await them. Instead, patches capture a prefix or postfix observation at a point where the relevant fact is already true or the relevant source context has not yet been lost.

Important examples:

- `Hook.AfterCardDrawn` is async in the game, but a SpireLens prefix is enough because by the time this hook is invoked, the card is already in hand.
- `Hook.ShouldDraw` runs before the draw succeeds or fails, which makes it useful for source attribution and blocked-draw attempts.
- `Hook.AfterCardChangedPiles` observes the final pile result after a move/redirection, which is better than trusting the attempted move.
- Energy and star gain are captured with before/after snapshots on the actual player resource mutation methods, so the recorded amount is the applied delta.

Do not assume that a card's source context is still available when a visible outcome appears. Some effects finish the `CardPlay` history entry before their downstream action fully resolves.

## Hot Reload Lifecycle

The runtime is split into a stable loader and a hot-reloaded core.

- `Loader/LoaderMain.cs` is the long-lived bootstrap loaded by the mod manager.
- `Core/CoreMain.cs` is reloaded on F5. It installs Harmony patches, wires tracker hooks, resumes active run state, and cleans up on shutdown.
- `CoreMain.Initialize()` must allocate only things that `CoreMain.Shutdown()` can release.
- Shutdown order is deliberately UI teardown, tooltip teardown, event unsubscription, then Harmony unpatching.

Old core assemblies are orphaned rather than truly unloaded. That is acceptable only if the old assembly stops receiving callbacks. Any new event subscription, Godot node signal, Harmony patch, static callback, or UI node must have an explicit cleanup path.

When adding a hook:

- Make sure it is installed by Harmony patch discovery.
- Make sure it is removed by `UnpatchAll(_harmonyId)` or otherwise cleaned up.
- If it subscribes to game events or Godot signals directly, add teardown.
- If it creates UI nodes, make hot-reload reinjection and `QueueFree()` behavior explicit.

## Run And Combat Boundaries

SpireLens persistence is combat-boundary based.

- `RunManager.Instance.RunStarted` starts a new run record.
- `CombatManager.Instance.CombatSetUp` creates `_pendingCombat`.
- During combat, live observations accumulate in `_pendingCombat`.
- `CombatManager.Instance.CombatEnded` promotes pending aggregates/events into committed `RunData`, updates run metadata, saves, and clears `_pendingCombat`.
- Between-combat and between-floor reloads are supported.
- Mid-combat restore is intentionally out of scope.

This distinction is easy to blur because tooltips merge committed and pending data for immediate display. That merged view is for UI only. The permanent run file is not promoted until combat ends.

When implementing new combat attribution, write it into `_pendingCombat` first unless the event is truly outside combat, such as card arrival/removal/upgrade lineage. Promotion should stay centralized at combat end.

## RunStarted Is Not Deck-Ready

Do not use `RunStarted` as the source of truth for starter deck population.

Earlier code tried to walk `player.Deck.Cards` at `RunStarted`, but fresh runs had a timing race: the deck was not always populated yet. The durable hook is `CardPile.AddInternal` filtered to `PileType.Deck`, implemented by `CardEnterDeckPatch`.

`CardPile.AddInternal` catches:

- starter deck population,
- Ascender's Bane / ascension curse insertion,
- reward cards,
- shop cards,
- event grants,
- other permanent deck entries routed through deck pile mutation.

For card arrival metadata, prefer the game's `CardModel.FloorAddedToDeck` when present. The game sets it to floor 1 for starters and current floor for mid-run additions. If it is null, SpireLens falls back to the current run floor when possible.

## Card Identity

Card identity is per physical card when a card has stable deck identity.

Key facts:

- Combat cards are often clones of permanent deck cards.
- Combat clones point back to the deck original through `CardModel.DeckVersion`.
- Deck-view cards are already the original and usually have `DeckVersion == null`.
- `RunTracker.Canonical(card)` uses `card.DeckVersion ?? card` so combat-time and hover-time references converge.
- Aggregates are keyed as `{card_definition_id}#{monotonic_number}`.
- The monotonic number is per card definition and is never reused within a run.
- Removed cards keep their aggregate and removal snapshot rather than being deleted.

Do not key long-lived attribution by raw `CardModel` reference unless you are inside a live-only ledger that will never cross reload or persistence boundaries. References are useful inside a single combat; persisted data needs stable string keys.

Non-assigning lookups matter. Hovering a preview/template card should not burn a new instance number. Paths that merely display a card should use non-assigning lookup behavior; paths that observe a real deck entry or real play may assign.

## Piles And Card Movement

Permanent deck membership is not the same thing as a card's current combat pile.

During combat, a deck card may be in draw, hand, discard, exhaust, play, or another transient pile. The permanent deck view still wants the same physical instance identity. Conversely, combat-generated cards may exist only for a combat and should not always pretend to be permanent deck members.

Useful pile facts in this repo:

- `CardPile.AddInternal` filtered to `PileType.Deck` means permanent deck entry.
- `CardPileCmd.RemoveFromDeck` prefix captures removal before the game detaches the card and mutates its state.
- `CardPileCmd.Add(card, PileType.Draw, CardPilePosition.Top, ...)` prefix can classify top-of-draw placements by reading the source pile before mutation.
- `Hook.AfterCardChangedPiles` is the generic post-mutation observation point for final pile results.

For redirections, prefer final pile observation. A card can attempt to move to hand but land elsewhere because the hand is full or because another game rule intervenes.

## Combat History

`CombatHistory.Add(entry)` is the broadest combat observation point. `CombatHistoryAddPatch` postfixes it and forwards each typed entry to `RunTracker.Observe(entry)` after the entry has been appended, which means the entry survived the game's own logic and is real.

This is a good master hook for entries that reliably reach `Add`, such as many card plays, damage entries, block entries, and power entries.

But do not assume every small `CombatHistory.*` wrapper is safe to patch. The repo has a documented draw trap:

- `CombatHistory.CardDrawn` is tiny and can be JIT-inlined.
- Harmony patches on that wrapper did not fire in diagnostic runs.
- `CardDrawnEntry` also did not appear through the generic `Observe` distribution during confirmed draws.
- The reliable draw hook is `Hook.AfterCardDrawn`, not `CombatHistory.CardDrawn`.

When a future stat seems obvious from combat history but never appears, suspect inlining, alternate code paths, or late async flow. Add a focused diagnostic hook only long enough to prove the path, then promote the reliable hook or document the trap.

## Card Play Timing

A card play has at least three useful phases for stats:

1. The card play is recognized and source context is available.
2. The card's immediate costs/effects mutate resources, piles, powers, block, damage, etc.
3. Downstream effects may continue after the play is already considered finished by some history APIs.

`CardPlay.Resources.EnergySpent` and star spend are the source of truth for actual cost paid, not printed card cost. This captures cost reduction, free plays, X-cost behavior, and modifiers.

For source context, `RunTracker` keeps notions like current player card play, recently completed player card play, pending draw source, pending effect source, and history counts. These are deliberately temporal and should be handled carefully. When adding a stat, ask:

- Is the source card still current at the outcome hook?
- If not, can the source be captured before the outcome and resolved after it?
- Is there a recent-completed play fallback, and how many history entries should it remain valid for?
- Could an enemy, relic, or power produce the same outcome without a card source?

Do not casually widen temporal attribution windows. A wide window can make unrelated follow-up effects look card-caused.

## Damage Attribution

For direct card damage, `DamageReceivedEntry` is the important observed outcome.

Enemy damage totals are computed from the game-reported pieces:

- `BlockedDamage`: damage absorbed by target block.
- `UnblockedDamage`: HP actually lost.
- `OverkillDamage`: attempted damage beyond lethal.

SpireLens definitions:

- intended damage = blocked + unblocked + overkill,
- effective damage = unblocked,
- blocked = blocked,
- overkill = overkill,
- kill = `WasTargetKilled`.

Effective damage is the user-facing total damage because it is the HP actually removed. Intended damage is useful internally and for waste percentages.

Known trap: an attack can play and produce no damage event, for example if the target is already dead/not fully removed or if no damage is actually received. Tooltip code treats a played attack with zero intended damage as a real but zero-damage case rather than inventing damage.

Player self-damage is tracked as HP lost from playing a card and uses observed unblocked damage after reductions. That is the real cost, not the text value.

## Block Attribution

Block has two different stats:

- block gained: what a card added to the player's block pool,
- block effective/wasted: what that block later absorbed or failed to absorb.

The game has one block pool, not per-card block. SpireLens uses a provenance ledger inside `_pendingCombat.PlayerBlockLedger`.

The current mental model:

- When a card grants block, add a `BlockChunk` with a source card instance and sequence.
- When incoming damage consumes block, absorbed block is charged through the ledger in FIFO order.
- When block clears/expires unused, wasted block is charged through surviving ledger chunks in LIFO order, matching the idea that later overfill was more likely redundant.
- Retain/prevent-clear effects must cancel pending clear attribution.

Relevant hooks:

- block gained comes from observed combat outcomes in `RunTracker.Observe` / block entries,
- `Hook.ShouldClearBlock` arms a possible clear with the current player block amount,
- `Hook.AfterBlockCleared` confirms clear and attributes waste,
- `Hook.AfterPreventingBlockClear` cancels the armed clear.

When changing block logic, be explicit that effective/wasted block is heuristic ledger attribution, not a game-native per-card truth.

## Draw Attribution

Draw stats have three related but different signals:

- this card was drawn (`TimesDrawn`),
- this card caused other cards to be drawn (`TimesCardsDrawn`),
- this card attempted draws that were blocked or redirected (`TimesCardsDrawAttempted`, `TimesCardsDrawBlocked`, `BlockedDrawReasons`).

Reliable hooks:

- `Hook.AfterCardDrawn` records that a card arrived in hand/draw flow. `fromHandDraw` distinguishes turn-start automatic draw from effect-side draw.
- `Hook.ShouldDraw` prefix notes draw attempts while source context is still recoverable.
- `Hook.ShouldDraw` postfix records blocked attempts when result is false and exposes the blocking modifier.
- `Hook.AfterCardChangedPiles` can identify final pile result for redirected movement.

Do not derive draw solely from play counts. A card can be drawn and not played; a draw effect can attempt to draw and be blocked by No Draw, hand size, or other prevention.

Blocked draw reason rows should stay explanatory rather than pretending full certainty. Known buckets include No Draw, hand full, and other/uncategorized.

## Energy, Stars, And Forge

For resource generation, record the actual mutation, not card text.

Energy:

- Hook `PlayerCombatState.GainEnergy`.
- Prefix captures before value.
- Postfix computes positive delta and attributes to the currently resolving card owned by that player.

Stars:

- Hook `PlayerCombatState.GainStars` the same way.
- Star spend is from actual play resources, not listed star cost.

Forge:

- Hook `Hook.AfterForge`.
- Record actual forge amount, forger, and source.
- This also preserves effect source context for immediate follow-up effects and marks Sovereign Blade overlay availability.

For UI, energy/star spent rows intentionally appear only when empirical variance exists or when the resource is otherwise interesting. Absence of a row usually means actual spend matched expected listed cost across plays.

## Effects And Powers

Power/effect attribution needs two layers:

1. Application attribution: which card caused a power/effect to be applied and for how much.
2. Downstream attribution: what that applied effect later caused, if observable and meaningful.

`PowerReceivedEntry` and related hooks can record applications when card source is available. But receiver-side modifiers can change or eliminate the application.

Artifact-blocked debuffs require a before/after pair:

- `Hook.BeforePowerAmountChanged` captures attempted power, amount, target, applier, and card source before receiver-side modifiers.
- `Hook.ModifyPowerAmountReceived` postfix sees the final result and modifiers. If requested amount was reduced to zero by Artifact, SpireLens can still credit the blocked attempt to the source card.

Do not record only successful applications. A debuff eaten by Artifact is still an important thing the card caused, and it should surface as blocked/stripped rather than disappearing.

## Poison And Other Downstream Damage

Poison demonstrates the core challenge of downstream attribution: the damage tick often arrives with `CardSource == null`, but users care which card originally applied the poison.

Current poison model:

- Poison applications are recorded as applied effects on the source card.
- `_pendingCombat.PoisonOwnershipByTarget` tracks ownership shares by target and source effect.
- `PoisonPower.AfterSideTurnStart` arms a one-shot attribution window for the target.
- The next null-source damage on that target can be recognized as poison tick damage and charged through the poison ownership ledger.
- Damage and overkill from poison ticks are added back into the source effect summary.

Noxious Fumes has an extra wrinkle:

- It is a power that later applies poison without direct card source on each application.
- `NoxiousFumesPower.AfterSideTurnStart` arms a short attribution window.
- Contribution ledgers preserve which source card owns the Fumes effect before the poison fanout is added to poison ownership.

When adding another downstream effect stat, follow the poison pattern only if there is a reliable arming event and a narrow enough outcome window. Anonymous damage or anonymous pile movement without a narrow source window should not be guessed broadly.

## Relic Attribution

Relics are not cards, but many relic stats use the same runtime lessons.

Combat-start relics often hook relic model callbacks directly by type name with `AccessTools.TypeByName`, then filter on side and round:

- Bag of Marbles: `BeforeSideTurnStart`, `CombatSide.Player`, `RoundNumber == 1`, count alive enemies, record Vulnerable applied.
- Red Mask: same shape, record Weak applied.

This is intentionally outcome-shaped but still simple. It assumes the relic applies one stack to each alive enemy at combat start. If a future relic has prevention/modifier interactions, use the same observed-result discipline as cards rather than only counting targets.

Relic aggregates live in `RunData.RelicAggregates`, keyed by relic id. Fields are shared across relics; each relic uses only relevant fields.

## Generated And Supplemental Cards

Not every visible card should become a permanent per-instance deck card.

Patterns already in use:

- Stable deck cards get normal instance ids.
- Removed deck cards keep stats and render via removed-card overlay.
- Combat-generated cards can get per-observed identities if they are actually played/tracked.
- Some generated cards are better represented as pooled deck-view summaries.

Examples:

- Shiv data is pooled under a synthetic deck-view Shiv overlay once a Shiv has been generated.
- Sovereign Blade gets a supplemental pooled deck-view overlay once forged/generated behavior makes it relevant.

Use pooled summaries when a card does not meaningfully exist as a stable deck resident and per-copy identities would mislead the user.

## UI Timing And Tooltip Surfaces

Card stats are exposed through Godot UI patches, not through game combat state alone.

Important surfaces:

- `ViewStatsInjectorPatch` hooks `NCardsViewScreen.ConnectSignals`, gates to `NDeckViewScreen`, clones the existing View Upgrades tickbox, rewires duplicated node internals, persists preference, and reinjects on hot reload if the deck view is already open.
- `CardHoverTooltipPatch` hooks `NCardHolder.CreateHoverTips` and `ClearHoverTips` to show/hide the SpireLens tooltip.
- Hand hovers are compact unless verbose hand stats are enabled.
- Deck view and other card-view hovers can show full lineage and stat breakdown.
- Tooltip aggregate display merges committed run data plus current pending combat so combat stats appear immediately.

Do not treat UI merged aggregate as proof that a combat has been saved. It is a presentation merge.

When modifying tooltip rows:

- Preserve compact-vs-full distinction.
- Keep rows self-describing without loud section headers unless they genuinely reduce confusion.
- Prefer game icon assets for recognizable concepts like block/draw/energy/stars/effects.
- Avoid creating instance numbers from hover-only preview/template cards.

## Persistence And Schema

`RunData` is the serialized shape. Schema changes must be additive when possible and must update fixtures/tests.

Current persistence facts:

- One run file per run under Godot `user://SpireLens/runs/`.
- File name is SpireLens run id, not the game's run-history file name.
- `GameStartTime` stores the game's run identifier (`RunManager._startTime`) so SpireLens can correlate with game run history and resume active runs after hot reload.
- `RunStorage.SaveAsync` serializes on the caller thread while `RunTracker` holds its lock, then writes on a background task.
- v1 pooled files are historical-only because they cannot rebuild per-instance live state.
- v2+ per-instance schemas are intended to remain resumable when later fields are additive.

For new persisted fields:

- bump `RunData.CurrentSchemaVersion`,
- document the version in `RunData.cs`,
- ensure old files deserialize with safe defaults,
- update fixtures under `Fixtures/RunSchema`,
- update `SchemaLoadingTests`,
- update tooltip/tests if user-facing.

## Choosing A Hook

Use this decision order when adding a stat:

1. Prefer an observed outcome hook over card text or intent.
2. If the observed outcome lacks source context, capture the source earlier and resolve it later through a narrow pending window.
3. If a high-level combat-history wrapper is tiny, beware JIT inlining; prefer a substantive `Hook.*` method or actual mutation point.
4. If the game method mutates a value, use prefix/postfix before/after snapshots to record actual delta.
5. If an action can be redirected, use a final post-mutation hook for the result.
6. If the outcome is heuristic, label the implementation and tooltip behavior as heuristic.
7. If no narrow source window exists, do not guess. Prefer no attribution or a pooled/unknown bucket.

Good hook surfaces already proven useful:

- `CombatHistory.Add`: broad real-entry observation point.
- `Hook.AfterCardDrawn`: reliable card draw arrival.
- `Hook.ShouldDraw`: draw attempts and blocked draw modifier.
- `Hook.AfterCardChangedPiles`: final pile result.
- `PlayerCombatState.GainEnergy`: actual energy delta.
- `PlayerCombatState.GainStars`: actual star delta.
- `Hook.AfterForge`: actual forge gain/source.
- `Hook.BeforePowerAmountChanged`: attempted power application context.
- `Hook.ModifyPowerAmountReceived`: final modified power amount and blockers.
- `Hook.ShouldClearBlock`, `Hook.AfterBlockCleared`, `Hook.AfterPreventingBlockClear`: block expiry/waste window.
- `CardPile.AddInternal` filtered to Deck: permanent card entry.
- `CardPileCmd.RemoveFromDeck` prefix: permanent card removal.
- `CardModel.UpgradeInternal` postfix: upgrades from all sources.
- Specific power/relic methods via `AccessTools.TypeByName`: useful when no public compile-time type is safe or when patching optional/specific models.

## Diagnostic Habits

When a new stat does not work, first determine which of these failed:

- The patch did not install.
- The target method never fires for this mechanic.
- The target fires but before/after timing is wrong.
- The outcome has no card source at that point.
- The source card is a combat clone and was not canonicalized.
- The event occurred outside `_pendingCombat`.
- The data is pending but tooltip reads only committed data.
- The data was recorded but schema/default/merge omitted it.
- The stat is correct but compact tooltip intentionally hides it.

`CoreMain.Initialize()` logs Harmony-patched methods for diagnostics. Use that list to confirm a hook exists before chasing tracker logic.

For source/context debugging, log compact identifiers that line up with JSON events: card id, instance id, card hash, `DeckVersion` status, creature id, history count, current/pending play, and current floor.

## Common Future-Agent Questions

Where do I start for a card stat?

- Find the observed runtime outcome first. Search patches for the closest hook. Then add a `RunTracker` record method and a persisted aggregate if needed.

Where do I start for a relic stat?

- Identify whether it fires at combat start, turn start, damage, block, draw, or resource mutation. Direct relic model callbacks are acceptable when the behavior is specific and stable; otherwise prefer common observed hooks.

How do I know whether a stat belongs to a card instance, pooled generated summary, effect summary, or relic aggregate?

- Stable physical deck card: per-instance card aggregate.
- Combat-generated card with no meaningful deck identity: pooled generated summary or ephemeral aggregate, depending on UI semantics.
- Power/debuff whose later ticks matter: applied effect summary plus downstream ledger if reliably attributable.
- Relic-owned behavior: relic aggregate.

Can I save mid-combat state for reload?

- No, not under the current contract. Pending combat is intentionally not persisted. Keep mid-combat display as pending-only and commit at combat end.

Can I read card text to infer behavior?

- Avoid it. The project goal is observed outcomes. Text can guide which hook to investigate, but not be the source of truth when the game can diverge.

Can I assume `CardSource` is present?

- No. Direct card damage often has it; downstream power damage often does not. Poison is the canonical example of needing an ownership ledger.

Can I assume the current card play is still current?

- No. Some effects resolve after card play history has advanced. Use pending source context only with narrow windows.

Can I patch a private method?

- Yes. Harmony string-name patching and the Publicizer setup make private members accessible where needed. Still document why that method is stable enough to depend on.

Can I patch a tiny wrapper?

- Be suspicious. `CombatHistory.CardDrawn` was unreliable because it could be inlined. Prefer non-trivial hooks or mutation points.

## Maintenance Contract For This Document

Update this primer whenever you learn a durable runtime fact that a future agent would otherwise rediscover. Good candidates:

- a hook that proved reliable or unreliable,
- a timing window around async card/relic/power behavior,
- a source-context trap,
- a canonicalization/pile identity trap,
- a combat-history entry semantic,
- a UI lifecycle quirk,
- a persistence/resume invariant.

Do not turn this into a changelog. Keep it focused on stable game/runtime mechanics and the attribution implications of those mechanics.
