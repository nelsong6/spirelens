using System;
using System.Collections.Generic;

namespace SpireLens.Core;

/// <summary>
/// Serialized shape of one run's stats. Written to disk as JSON.
///
/// The on-disk shape evolves additively: new persisted fields default safely
/// on missing-field deserialization, so older files continue to load without
/// an explicit version number. The historic pooled shape (aggregates keyed by
/// card definition id rather than per-instance id, written before
/// <see cref="InstanceNumbersByDef"/> and <see cref="DefCounters"/> existed)
/// is detected structurally by <see cref="RunStorage"/>; everything else is
/// the current per-instance shape.
/// </summary>
public class RunData
{
    public string RunId { get; set; } = "";
    public string StartedAt { get; set; } = "";  // ISO-8601 UTC
    public string UpdatedAt { get; set; } = "";
    public string? EndedAt { get; set; }
    public string? Character { get; set; }
    public int? Ascension { get; set; }
    public int? FloorReached { get; set; }
    public string Outcome { get; set; } = "in_progress";  // in_progress | win | loss | abandoned

    /// <summary>
    /// The game's own run identifier — Unix seconds of run start, sourced from
    /// <c>RunManager._startTime</c>. The game saves its run history to
    /// <c>{StartTime}.run</c>, so this field is the correlation key for M5
    /// (Run History integration): user clicks a past run in the game, the
    /// game knows its start_time, we find our file where <see cref="GameStartTime"/>
    /// matches. Our file name stays a GUID for identity independence.
    ///
    /// Null for runs created before this field was added or runs that observed
    /// combat before RunStarted fired (edge case — mod loaded mid-run).
    /// </summary>
    public long? GameStartTime { get; set; }

    /// <summary>Per-card aggregates. Keyed by card definition ID (e.g. "STRIKE_KIN"). Upgraded and base versions share a key for now; upgrade breakout is a future issue.</summary>
    public Dictionary<string, CardAggregate> Aggregates { get; set; } = new();

    /// <summary>Full per-event log for later deep analysis. One entry per card play + one entry per damage-received-from-card.</summary>
    public List<CardEvent> Events { get; set; } = new();

    /// <summary>Per-relic stat aggregates. Keyed by relic id (e.g. "RELIC.BAG_OF_MARBLES").</summary>
    public Dictionary<string, RelicAggregate> RelicAggregates { get; set; } = new();

    /// <summary>
    /// Snapshot of per-instance number assignments, serialized so that hot
    /// reload mid-run can resume with the same numbers instead of losing
    /// the CardModel-ref → number mapping (which only lives in memory on
    /// the soon-to-be-orphaned Core assembly).
    ///
    /// Format: <c>{def_id → [number, number, ...]}</c> where the list is
    /// ordered by each card's current deck-rank among cards of the same
    /// def_id. Example: if the deck has 4 Strikes with instance numbers
    /// #1, #2, #4, #5 (because #3 was Smith'd), this stores
    /// <c>{"STRIKE": [1, 2, 4, 5]}</c>.
    ///
    /// On resume: walk the live deck, compute each card's
    /// (def_id, rank-among-same-def), look up the number, repopulate
    /// <c>RunTracker._instanceNumbers</c>. Removal-safe because rank is
    /// relative to the CURRENT deck composition.
    ///
    /// Presence of this field (or <see cref="DefCounters"/>) at the top
    /// level of an on-disk JSON file is also the structural marker that
    /// the file uses the per-instance shape. Files predating per-instance
    /// identity lack both fields entirely.
    /// </summary>
    public Dictionary<string, List<int>> InstanceNumbersByDef { get; set; } = new();

    /// <summary>
    /// Snapshot of the monotonic per-def counters. Preserves the invariant
    /// that numbers never get reused across hot reload — if the saved state
    /// had Strike #1..#5 and #3 was removed, <c>DefCounters["STRIKE"] == 5</c>,
    /// so the next added Strike becomes #6 (not a recycled #3).
    /// </summary>
    public Dictionary<string, int> DefCounters { get; set; } = new();

    // (Intentionally no PendingCombat field — pending-combat persistence
    // was explored and rejected. Rule-of-use: F5 between combats, not
    // during. Rest/shop/event/reward rooms are all safe because
    // _pendingCombat is null outside of active combat. See git history
    // on 2026-04-20 for the full PendingCombatSnapshot approach if we
    // ever decide to re-enable mid-combat persistence.)
}

/// <summary>Aggregated per-card attribution stats for this run.</summary>
public class CardAggregate
{
    public int Plays { get; set; }

    // M1: Attack attribution. Null/zero for non-attack cards.
    public int TotalIntended { get; set; }   // damage the card tried to deal (pre-block, including overkill)
    public int TotalBlocked { get; set; }    // damage absorbed by target block
    public int TotalOverkill { get; set; }   // damage past target HP (wasted)
    public int TotalEffective { get; set; }  // damage that actually moved HP (observed unblocked damage)
    public int Kills { get; set; }           // times the card landed a killing blow

    // M3a: Energy spent. Sum of CardPlay.Resources.EnergySpent across every
    // play of this card instance. Uses EnergySpent (actual energy paid) not
    // EnergyValue (listed cost) so cost modifiers like Mummified Hand show
    // up correctly — a Strike played from Hand at 0 cost counts 0 here.
    // Average is derived on the display side via TotalEnergySpent / Plays.
    public int TotalEnergySpent { get; set; }

    // M3j: Energy generated directly by this card while it is resolving.
    // Sourced from PlayerCombatState.GainEnergy, attributed to the currently-
    // resolving card play. Tracks the ACTUAL amount added to the pool after
    // clamping / prevention, not the raw text on the card, so "gain 1" under
    // a no-energy-gain effect correctly records 0.
    public int TotalEnergyGenerated { get; set; }

    // M3k: Regent star spend / generation mirrors the energy fields above,
    // but for the character's separate star resource.
    public int TotalStarsSpent { get; set; }
    public int TotalStarsGenerated { get; set; }

    // M3l: Forge granted directly by this card while it is resolving.
    // Stored as decimal because forge values are sourced from the game's
    // dynamic vars / command path, which are decimal-backed even when most
    // current cards use whole numbers.
    public decimal TotalForgeGenerated { get; set; }

    // M2a: Block gained (how much block this card contributed over the run,
    // summed across plays). M2b extends this with absorbed/wasted splits
    // using an ordered provenance ledger for the player's block pool.
    public int TotalBlockGained { get; set; }
    public int TotalBlockEffective { get; set; }
    public int TotalBlockWasted { get; set; }

    // M3c: Draw count. Every time this card instance gets drawn — at
    // turn start or via card-effect draw ("draw 2 cards"). Shows up-
    // stream of plays: you can't play a card without drawing it first,
    // so TimesDrawn >= Plays always. Useful for efficiency signals like
    // "drew 10 times, played 4" (you've been stuck with dead draws).
    public int TimesDrawn { get; set; }

    // M3e: Discarded count. Every time this card goes to the discard
    // pile — end-of-turn (still in hand), mid-combat discard effects,
    // etc. Meaningful signal when high relative to plays ("I keep
    // discarding this without playing it").
    public int TimesDiscarded { get; set; }

    // M3f: Pile-top placement counts. Tracks when THIS card gets placed
    // on top of the draw pile from specific sources. Useful for cards
    // that manipulate draw order (Shining Strike's self-retain after
    // play, Finisher effects putting attacks back on top, etc.).
    //   FromHand: card was in hand, got moved to top of draw (retain-style)
    //   FromDiscard: card was in discard pile, got moved to top of draw
    //     ("from graveyard" in player parlance)
    public int TimesPlacedOnTopFromHand { get; set; }
    public int TimesPlacedOnTopFromDiscard { get; set; }

    // M3g: Exhaust attribution. When THIS card's play caused OTHER cards
    // to be exhausted. Covers Havoc (exhausts the auto-played card), Fiend
    // Fire (exhausts the hand), Second Wind (exhausts non-attacks), etc.
    // Self-exhaust (card exhausts itself after play) is NOT counted here
    // — different signal, different meaning.
    public int TimesExhaustedOtherCards { get; set; }

    // M3g2: How often THIS card itself got exhausted, regardless of cause.
    // Useful for exhaust-tag cards, ephemeral generated cards, and effects
    // that consume a card from hand/discard. Shown only when > 0 on the
    // full tooltip.
    public int TimesExhausted { get; set; }

    // M3h: Player HP loss from playing this card. Tracks Ironclad-style
    // self-damage (Hemokinesis, Offering, Combust tick, etc.). Uses the
    // damage's UnblockedDamage, which is POST-reduction — so Tungsten Rod
    // / buffer effects naturally show up as less HP loss. That's the
    // truth of "what did this card actually cost me", not what its
    // listed damage says.
    public int TotalHpLost { get; set; }

    // M3i: Draw attribution. When THIS card's play causes OTHER cards to
    // be drawn. Signal for draw-enabler cards (Prepared, Coolheaded,
    // Acrobatics etc. depending on the character). Excludes turn-start
    // auto-draw via the game's FromHandDraw flag.
    public int TimesCardsDrawn { get; set; }

    // M3i1: Total card draw attempts caused by THIS card's play, regardless
    // of whether each draw actually succeeded. Lets the tooltip show the gap
    // between "tried to draw X" and "actually drew Y" without caring whether
    // the miss came from No Draw, full hand fallback, or another prevention
    // path.
    public int TimesCardsDrawAttempted { get; set; }

    // M3i2: Blocked draw attribution. When THIS card's play ATTEMPTS to draw
    // cards but a draw-prevention hook vetoes the attempt (Battle Trance,
    // future "can't draw" effects, etc.). Counts blocked cards separately
    // from successful draws so draw cards don't silently look like they drew
    // zero when the game explicitly prevented them.
    public int TimesCardsDrawBlocked { get; set; }

    // M3i3: Categorized blocked-draw reasons for THIS card's draw attempts.
    // Keeps the card-side gap explainable without caring about the exact
    // blocker implementation: No Draw, hand full, or an "other" bucket when
    // the game prevented the draw for some reason we didn't categorize yet.
    public Dictionary<string, BlockedDrawReasonAggregate> BlockedDrawReasons { get; set; } = new();

    // M3m: Successful self-summons into Hand. Counts actual arrivals in
    // Hand, not mere attempts, so hand-full redirects to Discard stay out
    // of this number.
    public int TimesSummonedToHand { get; set; }

    // M4a: Effect / power application summary for this specific card
    // instance. First pass tracks ONLY that the card caused a power/effect
    // to be applied, not what the downstream effect later did. Keyed by the
    // game's power id (e.g. "POWER.NECROBINDER_TRIGGER"), with localized
    // display text cached for tooltip rendering.
    public Dictionary<string, AppliedEffectAggregate> AppliedEffects { get; set; } = new();

    // M3d: Per-instance lineage (when the card entered the deck and at
    // what upgrade level). Lets us distinguish between "card arrived
    // upgraded" (bought from a shop pre-upgraded, event reward, etc.) and
    // "card upgraded during the run" (rest site / Armaments etc.).
    //
    //   FloorAdded:         CardModel.FloorAddedToDeck snapshot at first
    //                       observation. Null = starting deck (the game
    //                       leaves this null for the initial 5).
    //   InitialUpgradeLevel: CurrentUpgradeLevel at first observation.
    //                       If > 0, the card arrived already upgraded.
    //
    // Subsequent upgrades are recorded in the Events log as "card_upgraded"
    // entries with Floor + UpgradeLevel, so the tooltip can render a full
    // lineage like "Arrived: floor 3, +1" followed by "Upgraded: floor 6 → +2".
    public int? FloorAdded { get; set; }
    public int InitialUpgradeLevel { get; set; }

    // M5a: Removal tracking. When a card is removed from the deck (Smith,
    // event, curse-dispose, etc.), we mark the aggregate rather than
    // delete it — so the user can browse "what did I remove this run and
    // how was it performing?" via the deck-view injection.
    //   Removed: true once the card left the permanent deck
    //   RemovedAtFloor: floor the removal happened on
    //   RemovedSnapshot: the card's full serializable state at removal —
    //     upgrade level, enchantment, props, etc. Used on resume to
    //     reconstruct a CardModel ref matching the removed card's state
    //     (via CardModel.FromSerializable) so the deck-view injection
    //     renders it correctly post-reload.
    public bool Removed { get; set; }
    public int? RemovedAtFloor { get; set; }
    public MegaCrit.Sts2.Core.Saves.Runs.SerializableCard? RemovedSnapshot { get; set; }

    // M3c: Draw count attribution. Null until M3c.
}

/// <summary>
/// First-pass effect/power tracking credited back to a card instance.
/// Keeps enough display metadata for tooltip rendering without forcing the
/// UI to re-query live game state for historical runs.
/// </summary>
public class AppliedEffectAggregate
{
    public string EffectId { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public string? IconPath { get; set; }
    public int TimesApplied { get; set; }
    public decimal TotalAmountApplied { get; set; }
    public int TimesBlockedByArtifact { get; set; }
    public decimal TotalAmountBlockedByArtifact { get; set; }
    public decimal TotalTriggeredEffectiveDamage { get; set; }
    public decimal TotalTriggeredOverkill { get; set; }
    public int TotalTriggeredCardsDrawBlocked { get; set; }
}

public class BlockedDrawReasonAggregate
{
    public string ReasonId { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public int Count { get; set; }
}

/// <summary>
/// Aggregated stats for a single relic across this run.
/// Fields are shared across relics; each relic uses only the fields relevant to it.
/// </summary>
public class RelicAggregate
{
    // Total enemies across all combats this run that had a debuff applied
    // by this relic at combat start.
    public int EnemiesAffected { get; set; }

    // Total Vulnerable stacks applied by this relic across all combats.
    // Used by Bag of Marbles (1 Vulnerable per enemy).
    public int VulnerableApplied { get; set; }

    // Total Weak stacks applied by this relic across all combats.
    // Used by Red Mask (1 Weak per enemy at combat start).
    public int WeakApplied { get; set; }

    // Total additional cards drawn by this relic across the run.
    // Used by Pocketwatch (draws 3 extra cards when 3 or fewer cards were played last turn).
    public int AdditionalCardsDrawn { get; set; }

    // Total block gained from this relic across all combats.
    // Used by Orichalcum (gains block at end of turn when player has no block).
    public int AdditionalBlockGained { get; set; }

    // Total Vigor gained from this relic across all combats.
    // Used by Akabeko (gains 8 Vigor at the start of each combat).
    public int VigorGained { get; set; }
}

/// <summary>
/// One entry in the full event log. Captures what the mod observed, not what the
/// external analysis will compute on top (that's the aggregates' job).
/// </summary>
public class CardEvent
{
    public string T { get; set; } = "";          // ISO-8601 UTC timestamp
    public string Type { get; set; } = "";       // "card_played" | "damage_received" | "energy_gained" | "stars_gained" | "forge_gained"
    public string CardId { get; set; } = "";

    // card_played fields
    public string? Target { get; set; }          // if the card targeted an enemy, their entity id (e.g. "KIN_PRIEST_0")
    public int? EnergySpent { get; set; }        // actual energy paid for this play (accounts for cost modifiers)
    public int? EnergyGained { get; set; }       // actual energy added to the pool while this card was resolving
    public int? StarsSpent { get; set; }         // actual stars paid for this play
    public int? StarsGained { get; set; }        // actual stars added while this card was resolving
    public decimal? ForgeGained { get; set; }    // actual forge added while this card was resolving

    // card_upgraded fields (and general-purpose: Floor also stamped on
    // other event types when useful). UpgradeLevel is the NEW level AFTER
    // the upgrade (post-increment); Floor is RunManager.State.TotalFloor
    // at the moment the upgrade fired.
    public int? Floor { get; set; }
    public int? UpgradeLevel { get; set; }

    // damage_received fields (only populated when Type == "damage_received" with a CardSource)
    public string? Receiver { get; set; }
    public int? Blocked { get; set; }
    public int? Unblocked { get; set; }
    public int? Overkill { get; set; }
    public bool? Killed { get; set; }
}
