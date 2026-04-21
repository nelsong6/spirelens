using System;
using System.Collections.Generic;
using System.Linq;
using MegaCrit.Sts2.Core.Combat;
using MegaCrit.Sts2.Core.Combat.History.Entries;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Entities.Powers;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Models;
using MegaCrit.Sts2.Core.Models.Powers;
using MegaCrit.Sts2.Core.Rooms;
using MegaCrit.Sts2.Core.Runs;

namespace CardUtilityStats.Core;

/// <summary>
/// Tracks the current run's stats in memory and commits them to disk at
/// combat boundaries.
///
/// Key rule (per Nelson): nothing is written to the permanent run file until
/// a combat *finishes*. During combat, card plays and damage events accumulate
/// in <see cref="_pendingCombat"/> only. On <c>CombatEnded</c> we promote the
/// pending buffer into the run's committed aggregates + event log and save.
/// On run start the previous run (if any) is finalized first.
///
/// Thread safety: game events all fire on the main thread. We still lock
/// defensively since file I/O is on a background task.
///
/// Milestone scope:
///   M1 (this file):     card plays + attack damage attribution
///   M2 (future):        block attribution (per issue #1 heuristic)
///   M3 (future):        energy / draw closure
/// </summary>
public static class RunTracker
{
    private const string ShivDefinitionId = "CARD.SHIV";
    private const string ShivGeneratedEventType = "shiv_generated";

    private static readonly object _lock = new();
    private static RunData? _currentRun;
    private static PendingCombat? _pendingCombat;
    private static CardPlay? _currentPlayerCardPlay;
    private static CardPlay? _recentCompletedPlayerCardPlay;
    private static int _recentCompletedPlayerCardPlayHistoryCount;
    private static CardModel? _pendingDrawSourceCard;
    private static CardModel? _pendingEffectSourceCard;
    private static int _pendingEffectSourceHistoryCount;
    private static readonly List<PendingPowerChangeAttempt> _pendingPowerChangeAttempts = new();
    private static int _pendingPlayerBlockClearAmount;
    private static bool _pendingPlayerBlockClearArmed;
    private static bool _shivAvailableThisRun;
    private static CardModel? _shivDeckViewCard;

    // Per-instance identity. Every physical card in the player's deck gets
    // a stable number the first time we observe it — NOT just when it's
    // played. Two reasons Nelson insisted on this:
    //   1. Hover-before-play: unplayed cards still need a stable identifier.
    //      If "Strike #1" only gets assigned on first play, the same physical
    //      card appears as "Strike" then jumps to "Strike #1" mid-run — and
    //      a different Strike that got played first would steal the "#1".
    //   2. Removal-safe: if Strike #2 is removed from the deck (Smith, etc.)
    //      and later a new Strike is added, the new one is Strike #3 (or
    //      whatever's next on the monotonic counter), NOT a renumbered #2.
    //      Numbers are never reused, so accumulated stats never silently
    //      migrate to a different physical card.
    //
    // Numbers are assigned by:
    //   - RunStarted: walk the starting deck in order → Strike #1, #2, #3...
    //   - Lazy on first touch (hover or play): catches cards added mid-run
    //     via rewards, shops, events. Numbers keep incrementing monotonically.
    private static readonly Dictionary<CardModel, int> _instanceNumbers = new();
    // Monotonic counter per card definition — so 3 Strikes become #1/#2/#3.
    // Never decremented. If a Strike is removed, the counter stays put; the
    // next added Strike gets the NEXT number, not a reused old one.
    private static readonly Dictionary<string, int> _defCounters = new();

    /// <summary>
    /// Wire up game event subscriptions. Called by <see cref="CoreMain.Initialize"/>
    /// on first load and each hot-reload. Safe to call before CombatManager/RunManager
    /// singletons receive their first state — we subscribe to events, not read state eagerly.
    /// </summary>
    public static void InitializeHooks()
    {
        RunManager.Instance.RunStarted += OnRunStarted;
        CombatManager.Instance.CombatSetUp += OnCombatSetUp;
        CombatManager.Instance.CombatEnded += OnCombatEnded;
        CoreMain.Logger.Info("CardUtilityStats hooks wired (RunStarted, CombatSetUp, CombatEnded).");
    }

    /// <summary>
    /// Unsubscribe from the game's events before the assembly unloads.
    /// Essential for hot-reload — otherwise RunManager and CombatManager
    /// hold delegate references back into this (old) assembly, preventing
    /// ALC collection and leaking the assembly on every reload.
    /// </summary>
    public static void TeardownHooks()
    {
        RunManager.Instance.RunStarted -= OnRunStarted;
        CombatManager.Instance.CombatSetUp -= OnCombatSetUp;
        CombatManager.Instance.CombatEnded -= OnCombatEnded;
        CoreMain.Logger.Info("CardUtilityStats hooks unwired.");
    }

    /// <summary>Exposed read-only for diagnostics and (future) UI reads.</summary>
    public static RunData? Current
    {
        get { lock (_lock) return _currentRun; }
    }

    /// <summary>
    /// Resolve any CardModel (combat clone or deck original) to its canonical
    /// per-deck reference. Combat clones have <c>DeckVersion</c> set to the
    /// original deck card by <c>Player.PopulateCombatState</c>
    /// (<c>cardModel.DeckVersion = item</c>). Deck-view cards ARE the original,
    /// so <c>DeckVersion</c> is null — the card itself is canonical.
    ///
    /// Using this as our dict key is what makes play-time (combat clone) and
    /// hover-time (deck original) lookups converge. Without it, ref-keyed
    /// dictionaries always miss because they see two different objects for
    /// what the player perceives as the same physical card.
    /// </summary>
    private static CardModel Canonical(CardModel card) => card.DeckVersion ?? card;

    /// <summary>
    /// Effective aggregate for a specific card instance — committed run-level
    /// stats PLUS whatever's in the current combat's pending buffer. Keyed by
    /// CardModel reference (stable within a run) through our instance-id map.
    /// Returns null if we haven't tracked this specific card yet.
    /// </summary>
    public static CardAggregate? GetEffectiveAggregate(CardModel card)
    {
        lock (_lock)
        {
            if (IsShivDeckViewCardLocked(card))
                return GetShivDeckViewAggregateLocked();

            // Non-assigning: if the card isn't tracked (preview/template
            // not yet a real deck member), return null so the tooltip
            // shows the empty-aggregate layout without creating a spurious
            // instance number. Tracked cards (in deck or played as
            // ephemeral) resolve normally.
            if (!TryGetInstanceId(card, out var instanceId)) return null;

            CardAggregate? result = null;

            if (_currentRun != null && _currentRun.Aggregates.TryGetValue(instanceId, out var committed))
                result = CloneAggregate(committed);

            if (_pendingCombat != null && _pendingCombat.CombatAggregates.TryGetValue(instanceId, out var pending))
            {
                result ??= new CardAggregate();
                MergeAggregateInto(result, pending);
            }

            return result;
        }
    }

    /// <summary>
    /// The instance number for a card for UI display purposes — derived from
    /// the card's position in the player's deck among other cards of the same
    /// definition. Stable across a run, doesn't depend on play order or on
    /// our own tracking state. If two Strikes are in the deck, the first in
    /// deck order is "Strike 1" and the second is "Strike 2", regardless of
    /// whether either has been played yet.
    ///
    /// In-combat subtlety: during combat, cards are distributed across the
    /// draw/hand/discard/exhaust/play piles and may NOT be in player.Deck at
    /// the moment of hover (depends on the game's internal bookkeeping). We
    /// enumerate all piles so the numbering stays consistent mid-combat too.
    ///
    /// Returns 0 if the card isn't found anywhere (shouldn't happen in
    /// practice unless it's been fully removed from the run).
    /// </summary>
    public static int GetInstanceNumber(CardModel card)
    {
        if (card == null) return 0;
        lock (_lock)
        {
            // NON-assigning lookup. Only cards that have actually entered
            // the deck (via CardEnterDeckPatch) or been played (via Record
            // paths) have numbers. Hovering a preview/template card that
            // hasn't entered the deck returns 0, which the tooltip
            // renders as "Strike" with no instance number — we don't
            // want to burn monotonic counters on UI previews.
            var key = Canonical(card);
            return _instanceNumbers.TryGetValue(key, out var existing) ? existing : 0;
        }
    }

    public static bool IsShivDeckViewCard(CardModel card)
    {
        if (card == null) return false;
        lock (_lock) return IsShivDeckViewCardLocked(card);
    }

    private static bool IsShivDeckViewCardLocked(CardModel card)
    {
        return _shivDeckViewCard != null
            && ReferenceEquals(Canonical(card), _shivDeckViewCard);
    }

    private static CardAggregate? GetShivDeckViewAggregateLocked()
    {
        CardAggregate? pooled = null;

        if (_currentRun != null)
            pooled = CardAggregatePooler.PoolByDefinition(_currentRun.Aggregates, ShivDefinitionId);

        if (_pendingCombat != null)
        {
            var pending = CardAggregatePooler.PoolByDefinition(
                _pendingCombat.CombatAggregates,
                ShivDefinitionId);
            if (pending != null)
            {
                pooled ??= new CardAggregate();
                CardAggregatePooler.MergeInto(pooled, pending);
            }
        }

        return pooled;
    }

    private static bool HasShivDataLocked()
    {
        if (_currentRun?.Events.Any(e => e.Type == ShivGeneratedEventType) == true)
            return true;

        if (_pendingCombat?.CombatEvents.Any(e => e.Type == ShivGeneratedEventType) == true)
            return true;

        if (_currentRun?.Aggregates.Keys.Any(key =>
                CardAggregatePooler.IsAggregateForDefinition(key, ShivDefinitionId)) == true)
            return true;

        if (_pendingCombat?.CombatAggregates.Keys.Any(key =>
                CardAggregatePooler.IsAggregateForDefinition(key, ShivDefinitionId)) == true)
            return true;

        return false;
    }

    private static void RefreshShivAvailabilityLocked()
    {
        _shivAvailableThisRun = HasShivDataLocked();
        if (!_shivAvailableThisRun)
            _shivDeckViewCard = null;
    }

    private static CardModel? GetShivDeckViewCardLocked()
    {
        if (!_shivAvailableThisRun) return null;
        if (_shivDeckViewCard != null) return _shivDeckViewCard;

        try
        {
            var modelId = ModelId.Deserialize(ShivDefinitionId);
            _shivDeckViewCard = ModelDb.GetById<CardModel>(modelId).ToMutable();
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"GetShivDeckViewCardLocked failed: {e.Message}");
        }

        return _shivDeckViewCard;
    }

    /// <summary>
    /// Core assignment primitive. Returns the stable 1-based instance
    /// number for this card, assigning on first call and caching thereafter.
    /// Counter is per-card-definition so 3 Strikes become #1/#2/#3 even
    /// if the deck also has 4 Defends (those are DEFEND#1..#4 separately).
    ///
    /// Always keyed by the canonical deck ref. Combat-time clones resolve
    /// back to their deck original via <c>DeckVersion</c>, so playing a
    /// card and hovering it afterward converge on the same number.
    /// </summary>
    private static int GetOrAssignNumber(CardModel card)
    {
        var key = Canonical(card);
        if (_instanceNumbers.TryGetValue(key, out var existing)) return existing;

        var defId = key.Id.ToString();
        _defCounters.TryGetValue(defId, out var n);
        n++;
        _defCounters[defId] = n;
        _instanceNumbers[key] = n;
        StampArrival(key, n);

        return n;
    }

    /// <summary>
    /// Called from <see cref="Patches.CardEnterDeckPatch"/> whenever a card
    /// enters the player's Deck pile — starter-deck population, reward/shop
    /// acquisitions, event grants, Ascender's Bane, all routed through
    /// <c>CardPile.AddInternal</c>. We just need to trigger number assignment
    /// and arrival stamping; everything downstream is automatic.
    ///
    /// This replaces the earlier "walk the deck at RunStarted" approach,
    /// which had a race condition where the deck wasn't yet populated when
    /// the RunStarted event fired on fresh runs.
    /// </summary>
    public static void RecordCardEntered(CardModel card)
    {
        lock (_lock) { GetOrAssignNumber(card); }
    }

    /// <summary>
    /// Record when and at what upgrade level a card was first seen.
    /// Creates a bare aggregate entry if one doesn't exist yet for this
    /// instance, so the lineage info is preserved even for cards that
    /// never get played. No-op if <c>_currentRun</c> isn't set yet (pre-
    /// RunStarted edge case — rare).
    /// </summary>
    private static void StampArrival(CardModel card, int number)
    {
        if (_currentRun == null) return;
        var instanceId = $"{card.Id}#{number}";
        if (_currentRun.Aggregates.ContainsKey(instanceId)) return;  // already stamped

        // FloorAddedToDeck is the game's own truth, set in multiple places:
        //   - Player.PopulateStartingDeck: hard-coded to 1 for all starters
        //   - Mid-run adds (rewards, shops, events): set to the current floor
        //   - Card transforms that create new refs: may leave null
        //   - Ephemeral combat-only cards (Souls, Shivs): null (never enter deck)
        //
        // Fallback for null: use current floor. This matters for transformed
        // cards (the ref didn't enter the deck via the normal populate path)
        // and ephemeral cards observed via play/draw. For cards that DID enter
        // the deck properly, FloorAddedToDeck will never be null.
        int? floorAdded = card.FloorAddedToDeck;
        if (floorAdded == null)
        {
            try { floorAdded = RunManager.Instance?.State?.TotalFloor; }
            catch { /* leave null if RunManager state isn't ready */ }
        }

        _currentRun.Aggregates[instanceId] = new CardAggregate
        {
            FloorAdded = floorAdded,
            InitialUpgradeLevel = card.CurrentUpgradeLevel,
        };
    }

    /// <summary>
    /// Get-or-assign the full string instance id ("STRIKE#3" format) used
    /// as the aggregates dictionary key and the on-disk identifier. Only
    /// call from paths that SHOULD create new instance numbers — i.e. combat
    /// Record paths where an ephemeral card (Soul/Shiv/generated) being
    /// observed deserves a fresh number even if it never entered the deck.
    /// For non-assigning contexts (hover, upgrade, removal), use
    /// <see cref="TryGetInstanceId"/>.
    /// </summary>
    private static string GetOrAssignInstanceId(CardModel card)
    {
        var n = GetOrAssignNumber(card);
        var defId = Canonical(card).Id.ToString();
        return $"{defId}#{n}";
    }

    /// <summary>
    /// Non-assigning lookup — returns false if the card hasn't been observed
    /// via a deck-entry or play path. Lets upgrade/removal/hover handlers
    /// check "have we seen this card?" without burning monotonic counters
    /// on preview/template/preview-UI card observations.
    /// </summary>
    private static bool TryGetInstanceId(CardModel card, out string instanceId)
    {
        var key = Canonical(card);
        if (_instanceNumbers.TryGetValue(key, out var n))
        {
            instanceId = $"{key.Id}#{n}";
            return true;
        }
        instanceId = "";
        return false;
    }


    /// <summary>
    /// Snapshot the current <c>_instanceNumbers</c> map into the format that
    /// survives serialization: <c>{def_id → [number, number, ...]}</c> ordered
    /// by current deck-rank among same-def cards. Called before every save.
    ///
    /// The snapshot is derived (not primary) data — it's reconstructible
    /// from <c>_instanceNumbers</c> + the live deck. We keep primary in-memory
    /// and snapshot to disk only for resume-after-reload.
    /// </summary>
    private static Dictionary<string, List<int>> CaptureInstanceNumbersByDeckRank()
    {
        var result = new Dictionary<string, List<int>>();
        try
        {
            var player = RunManager.Instance.State?.Players.FirstOrDefault();
            if (player?.Deck == null) return result;
            foreach (var card in player.Deck.Cards)
            {
                var key = Canonical(card);
                if (!_instanceNumbers.TryGetValue(key, out var n)) continue;
                var defId = key.Id.ToString();
                if (!result.TryGetValue(defId, out var list))
                {
                    list = new List<int>();
                    result[defId] = list;
                }
                list.Add(n);
            }
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"CaptureInstanceNumbersByDeckRank failed: {e.Message}");
        }
        return result;
    }

    /// <summary>
    /// Populate the snapshot fields on <c>_currentRun</c> and save. Single
    /// gateway for all persistence paths — if you want to save, call this
    /// instead of <c>RunStorage.SaveAsync</c> directly, so the snapshot is
    /// always fresh on disk.
    /// </summary>
    private static void SaveCurrentRun()
    {
        if (_currentRun == null) return;
        _currentRun.InstanceNumbersByDef = CaptureInstanceNumbersByDeckRank();
        _currentRun.DefCounters = new Dictionary<string, int>(_defCounters);
        RunStorage.SaveAsync(_currentRun);
    }

    private static void ResetCombatContextState()
    {
        _currentPlayerCardPlay = null;
        _recentCompletedPlayerCardPlay = null;
        _recentCompletedPlayerCardPlayHistoryCount = 0;
        _pendingDrawSourceCard = null;
        _pendingEffectSourceCard = null;
        _pendingEffectSourceHistoryCount = 0;
        _pendingPowerChangeAttempts.Clear();
        _pendingPlayerBlockClearAmount = 0;
        _pendingPlayerBlockClearArmed = false;
    }

    /// <summary>
    /// On Core assembly reload, detect if the game is in an active run and,
    /// if so, load the matching run file from disk and rebuild the
    /// CardModel → number mapping so stats attribution continues uninterrupted.
    ///
    /// Matching key is <c>RunManager._startTime</c> (Unix seconds of run
    /// start) — stable across our reloads because the game's RunManager
    /// lives in the game's assembly, not ours. Our saved run file records
    /// this in <c>RunData.GameStartTime</c> on every save, so we can scan
    /// the runs/ dir and find our in-progress record.
    ///
    /// If no active run, no-op — next <c>OnRunStarted</c> will set things
    /// up fresh when a run begins.
    ///
    /// If the game IS in a run but no saved file matches (e.g. the user
    /// played through several combats before first installing this mod),
    /// also no-op — we start tracking fresh from the next combat, which
    /// loses history but doesn't crash.
    /// </summary>
    public static void TryResumeActiveRun()
    {
        lock (_lock)
        {
            try
            {
                var runState = RunManager.Instance.State;
                if (runState == null)
                {
                    CoreMain.LogDebug("TryResumeActiveRun: no active RunState; nothing to resume");
                    return;
                }

                var gameStartTime = RunManager.Instance._startTime;
                if (gameStartTime == 0)
                {
                    CoreMain.LogDebug("TryResumeActiveRun: _startTime is 0; nothing to resume");
                    return;
                }

                var saved = RunStorage.FindByGameStartTime(gameStartTime, out var foundUnsupportedMatch);
                if (saved == null)
                {
                    if (foundUnsupportedMatch)
                    {
                        CoreMain.Logger.Info(
                            $"TryResumeActiveRun: found saved run for game_start_time={gameStartTime}, " +
                            "but its schema is not resumable into current live tracking");
                    }
                    else
                    {
                        CoreMain.Logger.Info(
                            $"TryResumeActiveRun: no saved run matches game_start_time={gameStartTime}; " +
                            "tracking will begin fresh on next combat");
                    }
                    return;
                }

                _currentRun = saved;
                _pendingCombat = null;
                _instanceNumbers.Clear();
                _defCounters.Clear();
                _shivDeckViewCard = null;

                // Restore monotonic counters first so any lazy-assign after
                // this picks up the next unused number (not a conflict).
                if (saved.DefCounters != null)
                {
                    foreach (var kv in saved.DefCounters) _defCounters[kv.Key] = kv.Value;
                }

                // Rebuild the ref → number map by walking the live deck in
                // its current order. For each card, count its rank among
                // same-def cards and look up the saved number at that rank.
                //
                // Removal-safe: if the player Smith'd Strike #3, the saved
                // list for STRIKE is [1, 2, 4, 5] — rank 0 → #1, rank 1 →
                // #2, rank 2 → #4 (the old #4, correctly), rank 3 → #5.
                var player = runState.Players.FirstOrDefault();
                int restored = 0, unmatched = 0;
                if (player?.Deck != null && saved.InstanceNumbersByDef != null)
                {
                    var rankCounters = new Dictionary<string, int>();
                    foreach (var card in player.Deck.Cards)
                    {
                        var key = Canonical(card);
                        var defId = key.Id.ToString();
                        rankCounters.TryGetValue(defId, out var rank);
                        rankCounters[defId] = rank + 1;

                        if (saved.InstanceNumbersByDef.TryGetValue(defId, out var list) && rank < list.Count)
                        {
                            _instanceNumbers[key] = list[rank];
                            restored++;
                        }
                        else
                        {
                            // Card in deck that wasn't in the saved snapshot — probably
                            // added between the last save and the hot reload. Lazy-assign
                            // via counter (which is already restored above).
                            GetOrAssignNumber(key);
                            unmatched++;
                        }
                    }
                }

                // Reconstruct refs for REMOVED cards. These aren't in
                // player.Deck.Cards anymore, so the deck walk above didn't
                // find them. But they still need entries in _instanceNumbers
                // so GetRemovedCards() can surface them for the deck-view
                // injection.
                //
                // State-accurate reconstruction: we snapshot the card's
                // full SerializableCard state at removal time (upgrade
                // level, enchantment, etc.) and use CardModel.FromSerializable
                // to rebuild a ref matching the removed card's state.
                // If no snapshot exists (aggregate from a pre-snapshot
                // build), fall back to a canonical ref via ModelDb.
                int reconstructedRemoved = 0;
                if (_currentRun.Aggregates != null)
                {
                    foreach (var kv in _currentRun.Aggregates)
                    {
                        if (!kv.Value.Removed) continue;
                        var hashIdx = kv.Key.LastIndexOf('#');
                        if (hashIdx < 0) continue;
                        if (!int.TryParse(kv.Key.Substring(hashIdx + 1), out var num)) continue;
                        var defIdStr = kv.Key.Substring(0, hashIdx);
                        try
                        {
                            CardModel reconstructed;
                            if (kv.Value.RemovedSnapshot != null)
                            {
                                reconstructed = CardModel.FromSerializable(kv.Value.RemovedSnapshot);
                            }
                            else
                            {
                                var modelId = MegaCrit.Sts2.Core.Models.ModelId.Deserialize(defIdStr);
                                reconstructed = MegaCrit.Sts2.Core.Models.ModelDb.GetById<CardModel>(modelId).ToMutable();
                            }
                            _instanceNumbers[reconstructed] = num;
                            reconstructedRemoved++;
                        }
                        catch (Exception e)
                        {
                            CoreMain.LogDebug($"TryResumeActiveRun: couldn't reconstruct {kv.Key}: {e.Message}");
                        }
                    }
                }

                CoreMain.Logger.Info(
                    $"TryResumeActiveRun: resumed run_id={_currentRun.RunId} " +
                    $"game_start_time={gameStartTime} aggregates={_currentRun.Aggregates?.Count ?? 0} " +
                    $"reconstructed_removed={reconstructedRemoved} " +
                    $"restored_numbers={restored} unmatched_in_deck={unmatched}");

                RefreshShivAvailabilityLocked();
            }
            catch (Exception e)
            {
                CoreMain.Logger.Error($"TryResumeActiveRun failed: {e}");
            }
        }
    }

    // -------- Lifecycle callbacks --------

    private static void OnRunStarted(RunState runState)
    {
        lock (_lock)
        {
            // If a previous run was in progress (mod reload, unusual path), finalize it first.
            if (_currentRun != null)
            {
                _currentRun.EndedAt = Now();
                SaveCurrentRun();
            }

            // Per-instance identity is per-run. Clear assignments so the next
            // run's Strike #1 is genuinely "this new run's first Strike,"
            // not a hangover from a previous run.
            _instanceNumbers.Clear();
            _defCounters.Clear();
            ResetCombatContextState();
            _shivAvailableThisRun = false;
            _shivDeckViewCard = null;

            string now = Now();
            _currentRun = new RunData
            {
                RunId = Guid.NewGuid().ToString("N"),
                StartedAt = now,
                UpdatedAt = now,
                Character = runState.Players.FirstOrDefault()?.Character?.Id.ToString(),
                Ascension = runState.AscensionLevel,
                FloorReached = runState.TotalFloor,
                // Publicizer gives us the private _startTime field. This is the
                // game's own run identifier — matches the filename it uses for
                // its run-history save ({StartTime}.run). Enables M5 correlation.
                GameStartTime = RunManager.Instance._startTime,
            };
            _pendingCombat = null;

            // Note: deck cards are NOT walked here. The RunStarted event
            // fires before the game finishes populating player.Deck.Cards
            // on fresh runs, so walking now would miss the starters. Instead
            // we observe each card as it enters via CardEnterDeckPatch, which
            // catches starter population, mid-run acquisitions, and
            // Ascender's Bane uniformly.

            CoreMain.Logger.Info($"RunStarted: {_currentRun.RunId} character={_currentRun.Character} ascension={_currentRun.Ascension} game_start_time={_currentRun.GameStartTime}");
            SaveCurrentRun();
        }
    }

    /// <summary>
    /// Called from the RunManager.OnEnded postfix. Stamps the final outcome and
    /// EndedAt on the current run, persists it, and nulls the tracker state so
    /// the next RunStarted starts fresh.
    ///
    /// Outcome priority (matches the game's own truth):
    ///   abandoned   — user chose Abandon Run (IsAbandoned)
    ///   win         — cleared final act boss (isVictory && !IsAbandoned)
    ///   loss        — player died (neither of the above)
    /// </summary>
    public static void OnRunEnded(string outcome)
    {
        lock (_lock)
        {
            if (_currentRun == null) return;

            _currentRun.Outcome = outcome;
            _currentRun.EndedAt = Now();
            _currentRun.UpdatedAt = _currentRun.EndedAt;

            // Capture final floor too — run could have ended mid-combat (loss)
            // with map position already advanced, or mid-rest, etc.
            var runState = RunManager.Instance.State;
            if (runState != null)
            {
                _currentRun.FloorReached = runState.TotalFloor;
            }

            CoreMain.Logger.Info($"RunEnded: {_currentRun.RunId} outcome={outcome} floor={_currentRun.FloorReached}");
            SaveCurrentRun();

            // Clear state so the next OnRunStarted sees a clean slate.
            _currentRun = null;
            _pendingCombat = null;
            ResetCombatContextState();
            _shivAvailableThisRun = false;
            _shivDeckViewCard = null;
        }
    }

    private static void OnCombatSetUp(CombatState state)
    {
        lock (_lock)
        {
            // Fresh pending buffer for this combat. Anything accumulated from a prior
            // combat that didn't get a CombatEnded (shouldn't happen but defensive) is dropped.
            _pendingCombat = new PendingCombat();
            ResetCombatContextState();
        }
    }

    private static void OnCombatEnded(CombatRoom room)
    {
        lock (_lock)
        {
            if (_pendingCombat == null) return;  // nothing to commit

            // Lazy run creation: if events came in before RunStarted ever fired
            // (e.g. mod loaded mid-run), create a minimal run record now so we
            // don't drop the combat's data.
            _currentRun ??= new RunData
            {
                RunId = Guid.NewGuid().ToString("N"),
                StartedAt = Now(),
                UpdatedAt = Now(),
            };

            // Surviving player block at combat end never absorbed future
            // damage, so treat any remaining ledger as wasted before
            // promoting the combat aggregates into the run.
            AttributeUnusedBlockLocked(TotalTrackedPlayerBlockLocked());

            // Promote pending buffer into the run's committed state.
            foreach (var (cardId, combatAgg) in _pendingCombat.CombatAggregates)
            {
                var runAgg = GetOrCreateAggregate(_currentRun, cardId);
                MergeAggregateInto(runAgg, combatAgg);
            }
            _currentRun.Events.AddRange(_pendingCombat.CombatEvents);

            // Refresh run-level metadata from the current game state (floor may have advanced).
            var runState = RunManager.Instance.State;
            if (runState != null)
            {
                _currentRun.FloorReached = runState.TotalFloor;
                _currentRun.Ascension ??= runState.AscensionLevel;
                _currentRun.Character ??= runState.Players.FirstOrDefault()?.Character?.Id.ToString();
            }
            _currentRun.UpdatedAt = Now();

            _pendingCombat = null;
            ResetCombatContextState();
            SaveCurrentRun();
        }
    }

    // -------- Event observation (from CombatHistory.Add postfix) --------

    /// <summary>
    /// Route a freshly-added CombatHistoryEntry into the pending combat buffer.
    /// Only attack-relevant entries are consumed in M1; others will be handled
    /// by later milestones.
    /// </summary>
    private static int _observeCount;
    private static readonly Dictionary<string, int> _typeCountDiag = new();
    public static void Observe(object entry)
    {
        try
        {
            var n = System.Threading.Interlocked.Increment(ref _observeCount);

            // Debug-level: per-event trace. Silent in production, verbose
            // when CUS_DEBUG is set.
            CoreMain.LogDebug($"Observe #{n}: {entry.GetType().Name}");

            // Temporary diagnostic for draw-tracking bug. Logs the first
            // 500 entries per Core load, every CardDrawnEntry always, and a
            // type-count summary every 50 entries so we can spot whether
            // CardDrawnEntry ever shows up in the distribution.
            var typeName = entry.GetType().Name;
            _typeCountDiag.TryGetValue(typeName, out var typeN);
            _typeCountDiag[typeName] = typeN + 1;
            if (entry is CardDrawnEntry || entry is CardPlayFinishedEntry || n <= 500 || n % 500 == 0)
                CoreMain.Logger.Info($"[CUS-diag] Observe #{n}: {typeName}");
            if (n % 50 == 0)
            {
                var counts = string.Join(", ", _typeCountDiag.OrderBy(kv => kv.Key)
                    .Select(kv => $"{kv.Key}={kv.Value}"));
                CoreMain.Logger.Info($"[CUS-diag] types-so-far (n={n}): {counts}");
            }

            switch (entry)
            {
                case CardPlayStartedEntry cps when cps.CardPlay != null:
                    NoteCardPlayStarted(cps.CardPlay);
                    break;
                case CardPlayFinishedEntry cpf:
                    var card = cpf.CardPlay?.Card;
                    // Log both the raw (clone) hash and canonical (deck) hash.
                    // At hover time, the deck view sees canonicalHash — matching
                    // the two is how we verify the DeckVersion-based key works.
                    CoreMain.LogDebug($"  -> RecordCardPlay '{card?.Title ?? "?"}' hash={card?.GetHashCode()} canonicalHash={(card == null ? 0 : Canonical(card).GetHashCode())}");
                    if (cpf.CardPlay != null) NoteCardPlayFinished(cpf.CardPlay);
                    RecordCardPlay(cpf.CardPlay);
                    break;
                case CardDrawnEntry cde:
                    // Diagnostic always-on while we're validating draw tracking.
                    // If we're seeing this line in logs, the hook works. If we're
                    // not, CombatHistory.Add postfix isn't firing for draws (unusual).
                    CoreMain.Logger.Info($"CardDrawnEntry card='{cde.Card?.Title ?? "null"}' fromHandDraw={cde.FromHandDraw}");
                    if (cde.Card != null) RecordCardDrawn(cde);
                    break;
                case CardDiscardedEntry cdisc when cdisc.Card != null:
                    RecordCardDiscarded(cdisc.Card);
                    break;
                case CardExhaustedEntry cex when cex.Card != null:
                    RecordCardExhausted(cex.Card);
                    break;
                case BlockGainedEntry bge:
                    RecordBlockGainedEntry(bge);
                    break;
                case DamageReceivedEntry dre:
                    if (dre.Receiver.IsPlayer)
                        RecordPlayerBlockedDamage(dre);

                    if (dre.CardSource != null)
                    {
                        CoreMain.LogDebug($"  -> RecordDamage from '{dre.CardSource.Title}' intended={dre.Result.BlockedDamage + dre.Result.UnblockedDamage} canonicalHash={Canonical(dre.CardSource).GetHashCode()}");
                        RecordDamageFromCard(dre);
                    }
                    else
                    {
                        if (!dre.Receiver.IsPlayer)
                        {
                            // Diagnostic: the game emitted a DamageReceivedEntry
                            // but didn't attribute it to a card. We silently dropped
                            // these before, but it caused ambiguity — hovering a
                            // card showed "Played 1" with no damage stats, and we
                            // couldn't tell if the game emitted null-source damage
                            // we dropped, or didn't emit anything at all. Always-on
                            // (not CUS_DEBUG-gated) because these should be rare
                            // and when they happen we want to know without the user
                            // having to reproduce under a debug flag.
                            var recvDesc = DescribeCreature(dre.Receiver);
                            var dealerDesc = DescribeCreature(dre.Dealer);
                            CoreMain.Logger.Info(
                                $"DamageReceivedEntry CardSource=null " +
                                $"receiver={recvDesc} dealer={dealerDesc} " +
                                $"blocked={dre.Result.BlockedDamage} unblocked={dre.Result.UnblockedDamage} " +
                                $"overkill={dre.Result.OverkillDamage} killed={dre.Result.WasTargetKilled}");
                        }
                    }
                    break;
                case PowerReceivedEntry pre when pre.Power != null:
                    RecordPowerReceived(pre);
                    break;
            }
        }
        catch (Exception e)
        {
            // Never let tracker exceptions escape into the game loop.
            CoreMain.Logger.Error($"RunTracker.Observe failed: {e}");
        }
    }

    private static void RecordCardPlay(CardPlay cardPlay)
    {
        lock (_lock)
        {
            // Defensive: if CombatSetUp never fired (unusual), allocate lazily.
            _pendingCombat ??= new PendingCombat();

            // Per-instance tracking: each physical card in the deck gets its
            // own aggregates bucket. First play assigns its instance id.
            var instanceId = GetOrAssignInstanceId(cardPlay.Card);

            var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
            agg.Plays++;
            // Energy spent = actual energy paid this play, accounting for any
            // cost modifiers (Mummified Hand / similar making a card free
            // still counts 0 here, which is what we want — the card DIDN'T
            // cost you energy this play). EnergyValue would be the listed
            // cost, but that's less useful for "how much does this card
            // actually cost me on average" analysis.
            agg.TotalEnergySpent += cardPlay.Resources.EnergySpent;

            _pendingCombat.CombatEvents.Add(new CardEvent
            {
                T = Now(),
                Type = "card_played",
                CardId = instanceId,
                Target = cardPlay.Target?.Monster?.Id.ToString(),
                EnergySpent = cardPlay.Resources.EnergySpent,
            });
        }
    }

    private static void NoteCardPlayStarted(CardPlay cardPlay)
    {
        lock (_lock)
        {
            _currentPlayerCardPlay = cardPlay;
            _recentCompletedPlayerCardPlay = null;
            _recentCompletedPlayerCardPlayHistoryCount = 0;
            _pendingDrawSourceCard = null;
            _pendingEffectSourceCard = null;
            _pendingEffectSourceHistoryCount = 0;
        }
    }

    private static void NoteCardPlayFinished(CardPlay cardPlay)
    {
        lock (_lock)
        {
            if (_currentPlayerCardPlay?.Card != null
                && cardPlay.Card != null
                && ReferenceEquals(Canonical(_currentPlayerCardPlay.Card), Canonical(cardPlay.Card)))
            {
                _currentPlayerCardPlay = null;
            }

            _recentCompletedPlayerCardPlay = cardPlay;
            _recentCompletedPlayerCardPlayHistoryCount = CombatManager.Instance?.History?.Entries?.Count() ?? 0;
        }
    }

    /// <summary>
    /// Record energy added to the player's pool while a card is currently
    /// resolving. Called from <see cref="Patches.PlayerGainEnergyPatch"/>,
    /// which patches <c>PlayerCombatState.GainEnergy</c> and forwards the
    /// ACTUAL post-clamp delta rather than the requested amount.
    ///
    /// Attribution rule: only count gains that happen during a live
    /// CardPlayStartedEntry → CardPlayFinishedEntry window, and only if the
    /// resolving card's owner matches the PlayerCombatState being modified.
    /// This keeps relic / power / start-of-turn gains out of the card stat.
    /// </summary>
    public static void RecordEnergyGained(MegaCrit.Sts2.Core.Entities.Players.PlayerCombatState combatState, int amount)
    {
        if (amount <= 0) return;

        lock (_lock)
        {
            try
            {
                var causingPlay = FindCurrentlyResolvingCardPlay();
                if (causingPlay?.Card == null) return;

                var sourceCard = causingPlay.Card;
                var targetPlayer = combatState._player;
                if (targetPlayer != null && sourceCard.Owner != null
                    && !ReferenceEquals(sourceCard.Owner, targetPlayer))
                    return;

                _pendingCombat ??= new PendingCombat();
                var instanceId = GetOrAssignInstanceId(sourceCard);
                var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
                agg.TotalEnergyGenerated += amount;

                _pendingCombat.CombatEvents.Add(new CardEvent
                {
                    T = Now(),
                    Type = "energy_gained",
                    CardId = instanceId,
                    EnergyGained = amount,
                });
            }
            catch (Exception e)
            {
                CoreMain.LogDebug($"RecordEnergyGained failed: {e.Message}");
            }
        }
    }

    /// <summary>
    /// Log a card upgrade to the run's event stream. Called from the
    /// <see cref="Patches.CardUpgradePatch"/> Harmony postfix — fires for
    /// every upgrade path (rest site, Armaments in combat, events that
    /// grant upgrades, Apotheosis, etc.).
    ///
    /// Events go into <c>_currentRun.Events</c> directly, not the pending
    /// combat buffer, because upgrades can happen outside combat (rest
    /// sites, events). They'd be lost if routed through <c>_pendingCombat</c>
    /// when there's no active combat to commit from.
    /// </summary>
    /// <summary>
    /// Log a card removal from the deck. Called from the
    /// <see cref="Patches.CardRemoveFromDeckPatch"/> prefix so we see the
    /// card BEFORE its pile transitions — cleaner state to read.
    ///
    /// Marks the aggregate's Removed flag and stamps the floor. The card
    /// stays in <c>_currentRun.Aggregates</c> with its accumulated stats;
    /// the UI filters/displays it separately based on the Removed flag.
    /// </summary>
    public static void RecordRemoval(CardModel card)
    {
        lock (_lock)
        {
            if (_currentRun == null) return;

            // Non-assigning: if we haven't seen this card enter the deck,
            // don't create a number just to mark it removed. Removing an
            // untracked card is a no-op for our data model (nothing to
            // update). Shouldn't happen in practice — every card that gets
            // removed must have entered the deck at some point.
            if (!TryGetInstanceId(card, out var instanceId)) return;
            var floor = RunManager.Instance.State?.TotalFloor;

            if (_currentRun.Aggregates.TryGetValue(instanceId, out var agg))
            {
                agg.Removed = true;
                agg.RemovedAtFloor = floor;

                // Snapshot the card's full state (upgrade, enchantment,
                // props, floor_added) so we can reconstruct a matching
                // CardModel ref on hot reload. The game's own
                // ToSerializable() handles this cleanly.
                try { agg.RemovedSnapshot = Canonical(card).ToSerializable(); }
                catch (Exception e) { CoreMain.LogDebug($"RecordRemoval: ToSerializable failed: {e.Message}"); }
            }

            _currentRun.Events.Add(new CardEvent
            {
                T = Now(),
                Type = "card_removed",
                CardId = instanceId,
                Floor = floor,
            });

            CoreMain.Logger.Info($"card_removed: {instanceId} floor={floor}");

            // Save immediately — removals happen OUTSIDE combat (Smith, events,
            // rest-site interactions, curse dispose). Without saving here, the
            // flag lives only in memory and would be lost on F5 between the
            // removal and the next CombatEnded. Removals are infrequent so
            // the I/O cost is negligible.
            SaveCurrentRun();
        }
    }

    public static void RecordUpgrade(CardModel card)
    {
        lock (_lock)
        {
            // Lazy run-creation guard — upgrade could fire before RunStarted
            // if the mod hot-loaded mid-run and missed the signal. We still
            // want to record the event.
            _currentRun ??= new RunData
            {
                RunId = Guid.NewGuid().ToString("N"),
                StartedAt = Now(),
                UpdatedAt = Now(),
            };

            // Non-assigning: skip upgrades on cards we haven't seen enter
            // the deck. This is what fixes the "starters begin at #5" bug
            // — the game fires UpgradeInternal on template/preview cards
            // at run init, and we'd previously assign them fresh numbers,
            // burning the counter before real starters arrived. Now we
            // silently ignore those.
            if (!TryGetInstanceId(card, out var instanceId)) return;
            var canonical = Canonical(card);
            var newLevel = canonical.CurrentUpgradeLevel;
            var floor = RunManager.Instance.State?.TotalFloor;

            _currentRun.Events.Add(new CardEvent
            {
                T = Now(),
                Type = "card_upgraded",
                CardId = instanceId,
                Floor = floor,
                UpgradeLevel = newLevel,
            });

            // Diagnostic for card-transform-on-upgrade investigation. Logs:
            //   - raw and canonical hashes so we can tell if the upgraded ref
            //     is the same object we saw pre-upgrade (in-place) or a
            //     different object (ref swap / transformation).
            //   - whether the ref is currently in player.Deck.Cards — a
            //     transformation would replace the deck member, so the
            //     POST-upgrade ref should be the one in the deck.
            //   - the card's FloorAddedToDeck, to see if transformed cards
            //     inherit it or start fresh.
            var deckCardCount = -1;
            bool inDeck = false;
            try
            {
                var player = RunManager.Instance.State?.Players.FirstOrDefault();
                if (player?.Deck?.Cards != null)
                {
                    deckCardCount = player.Deck.Cards.Count;
                    foreach (var dc in player.Deck.Cards)
                    {
                        if (ReferenceEquals(Canonical(dc), canonical)) { inDeck = true; break; }
                    }
                }
            }
            catch { }

            CoreMain.Logger.Info(
                $"card_upgraded: {instanceId} level={newLevel} floor={floor} " +
                $"rawHash={card.GetHashCode()} canonicalHash={canonical.GetHashCode()} " +
                $"deckVerNull={card.DeckVersion == null} inDeck={inDeck} " +
                $"floorAddedToDeck={canonical.FloorAddedToDeck}");

            // Save immediately — upgrades mostly happen at campfires,
            // OUTSIDE combat. Without saving here, the upgrade event lives
            // only in memory and is lost on F5 before the next CombatEnded.
            SaveCurrentRun();
        }
    }

    /// <summary>
    /// Return the list of CardModel refs that have been marked Removed
    /// this run. Used by the deck-view injection to surface removed cards
    /// alongside current deck cards. Refs remain valid after removal —
    /// CardModel.RemoveFromState only sets a flag, doesn't free the object.
    /// </summary>
    public static IReadOnlyList<CardModel> GetRemovedCards()
    {
        lock (_lock)
        {
            return GetRemovedCardsLocked();
        }
    }

    private static List<CardModel> GetRemovedCardsLocked()
    {
        if (_currentRun == null) return new List<CardModel>();

        var result = new List<CardModel>();
        foreach (var kv in _instanceNumbers)
        {
            var instanceId = $"{kv.Key.Id}#{kv.Value}";
            if (_currentRun.Aggregates.TryGetValue(instanceId, out var agg) && agg.Removed)
            {
                result.Add(kv.Key);
            }
        }

        return result;
    }

    /// <summary>
    /// Additional cards to surface in the full-deck screen when ViewStats is
    /// enabled. Today that includes removed cards plus the synthetic
    /// deck-level Shiv once the run has generated one.
    /// </summary>
    public static IReadOnlyList<CardModel> GetSupplementalDeckViewCards()
    {
        lock (_lock)
        {
            RefreshShivAvailabilityLocked();

            var result = GetRemovedCardsLocked();

            var shiv = GetShivDeckViewCardLocked();
            if (shiv != null && !result.Contains(shiv))
                result.Add(shiv);

            return result;
        }
    }

    /// <summary>
    /// Return all upgrade events for a given card instance, in chronological
    /// order (oldest first). Used by the tooltip to render the lineage:
    /// "Received: floor 3 → Upgraded: floor 6 → +1".
    /// Returns empty if the card has no upgrade events or isn't tracked.
    /// </summary>
    public static IReadOnlyList<CardEvent> GetUpgradeEvents(CardModel card)
    {
        lock (_lock)
        {
            if (_currentRun == null) return Array.Empty<CardEvent>();
            var key = Canonical(card);
            if (!_instanceNumbers.TryGetValue(key, out var n)) return Array.Empty<CardEvent>();
            var instanceId = $"{key.Id}#{n}";

            var result = new List<CardEvent>();
            foreach (var e in _currentRun.Events)
            {
                if (e.Type == "card_upgraded" && e.CardId == instanceId) result.Add(e);
            }
            return result;
        }
    }

    private static void RecordCardDrawn(CardDrawnEntry entry)
    {
        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();
            var instanceId = GetOrAssignInstanceId(entry.Card);
            var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
            agg.TimesDrawn++;

            // Don't bloat the events log with a draw entry per card draw —
            // every combat draws ~5 cards/turn × ~5-10 turns so we'd emit
            // 25-50 events just for draws. Aggregate counter is enough.
            // If per-draw forensics becomes useful later, add it here.
        }
    }

    /// <summary>
    /// Direct-path draw attribution, called from
    /// <see cref="Patches.HookAfterCardDrawnPatch"/>. The generic
    /// <c>CombatHistory.Add</c> hook misses draws because
    /// <c>CombatHistory.CardDrawn</c> gets JIT-inlined at the
    /// <c>CardPileCmd.Draw</c> call site, which bypasses the Harmony patch.
    /// Hooking <c>Hook.AfterCardDrawn</c> (a larger method that isn't
    /// inlined) gives us a reliable attribution point; this method does
    /// the same work as <see cref="RecordCardDrawn"/> but takes the bare
    /// <c>CardModel</c> since there's no <c>CardDrawnEntry</c> on the
    /// <c>AfterCardDrawn</c> code path.
    /// </summary>
    /// <summary>
    /// Record a card being placed on top of the draw pile from Hand or
    /// Discard. Fired from <see cref="Patches.CardPlacedOnTopPatch"/>.
    /// </summary>
    public static void RecordPlacedOnTopOfDraw(CardModel card, MegaCrit.Sts2.Core.Entities.Cards.PileType sourcePile)
    {
        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();
            var instanceId = GetOrAssignInstanceId(card);
            var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
            if (sourcePile == MegaCrit.Sts2.Core.Entities.Cards.PileType.Hand)
                agg.TimesPlacedOnTopFromHand++;
            else if (sourcePile == MegaCrit.Sts2.Core.Entities.Cards.PileType.Discard)
                agg.TimesPlacedOnTopFromDiscard++;
        }
    }

    private static void RecordCardDiscarded(CardModel card)
    {
        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();
            var instanceId = GetOrAssignInstanceId(card);
            var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
            agg.TimesDiscarded++;
        }
    }

    /// <summary>
    /// When a card is exhausted, find the currently-resolving player card
    /// play (if any) and attribute the exhaust to that play's card —
    /// unless it's a self-exhaust (card exhausting itself post-play),
    /// which we deliberately don't count. Useful for cards like Havoc,
    /// Fiend Fire, Second Wind that exhaust OTHER cards.
    /// </summary>
    private static void RecordCardExhausted(CardModel exhaustedCard)
    {
        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();
            var exhaustedId = GetOrAssignInstanceId(exhaustedCard);
            var exhaustedAgg = GetOrCreateAggregate(_pendingCombat, exhaustedId);
            exhaustedAgg.TimesExhausted++;

            try
            {
                var causingPlay = FindCurrentlyResolvingCardPlay();
                if (causingPlay?.Card == null) return;

                // Skip self-exhaust — "exhausted OTHER cards" is the stat.
                if (ReferenceEquals(Canonical(causingPlay.Card), Canonical(exhaustedCard))) return;
                var instanceId = GetOrAssignInstanceId(causingPlay.Card);
                var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
                agg.TimesExhaustedOtherCards++;
            }
            catch (Exception e)
            {
                CoreMain.LogDebug($"RecordCardExhausted failed: {e.Message}");
            }
        }
    }

    /// <summary>
    /// Walk combat history backwards to find the latest CardPlayStartedEntry
    /// whose matching CardPlayFinishedEntry hasn't fired yet — i.e. the play
    /// currently mid-resolution. Returns null if no play is active.
    /// Used for attributing side-effect events (exhausts, draws) to the
    /// card that caused them, since the game's entries for those effects
    /// don't include a CardPlay reference.
    /// </summary>
    private static CardPlay? FindCurrentlyResolvingCardPlay()
    {
        if (_currentPlayerCardPlay?.Card != null) return _currentPlayerCardPlay;

        var history = CombatManager.Instance?.History;
        if (history == null) return null;
        CardPlay? result = null;
        foreach (var e in history.Entries.Reverse())
        {
            if (e is CardPlayFinishedEntry) return null;  // nothing in progress
            if (e is CardPlayStartedEntry cps) { result = cps.CardPlay; break; }
        }
        return result;
    }

    public static void NoteDrawAttempt(Player player, bool fromHandDraw)
    {
        lock (_lock)
        {
            if (fromHandDraw)
            {
                _pendingDrawSourceCard = null;
                return;
            }

            try
            {
                _pendingDrawSourceCard = FindLikelyDrawSourceCard(player);
            }
            catch (Exception e)
            {
                _pendingDrawSourceCard = null;
                CoreMain.LogDebug($"NoteDrawAttempt failed: {e.Message}");
            }
        }
    }

    public static void NoteEffectSource(AbstractModel? source)
    {
        lock (_lock)
        {
            if (source is CardModel sourceCard)
            {
                _pendingEffectSourceCard = Canonical(sourceCard);
                _pendingEffectSourceHistoryCount = CombatManager.Instance?.History?.Entries?.Count() ?? 0;
            }
        }
    }

    public static void RecordShivGenerated(CardModel? card)
    {
        if (card == null) return;

        lock (_lock)
        {
            if (!string.Equals(Canonical(card).Id.ToString(), ShivDefinitionId, StringComparison.Ordinal))
                return;

            _shivAvailableThisRun = true;

            _currentRun ??= new RunData
            {
                RunId = Guid.NewGuid().ToString("N"),
                StartedAt = Now(),
                UpdatedAt = Now(),
            };
            _pendingCombat ??= new PendingCombat();

            bool alreadyRecorded =
                _currentRun.Events.Any(e => e.Type == ShivGeneratedEventType) ||
                _pendingCombat.CombatEvents.Any(e => e.Type == ShivGeneratedEventType);
            if (alreadyRecorded) return;

            _pendingCombat.CombatEvents.Add(new CardEvent
            {
                T = Now(),
                Type = ShivGeneratedEventType,
                CardId = ShivDefinitionId,
                Floor = RunManager.Instance.State?.TotalFloor,
            });
        }
    }

    public static void NotePowerAmountChangeAttempt(
        PowerModel power,
        decimal amount,
        Creature target,
        Creature? applier,
        CardModel? cardSource)
    {
        lock (_lock)
        {
            _pendingPowerChangeAttempts.Add(new PendingPowerChangeAttempt
            {
                Power = power,
                Target = target,
                Applier = applier,
                RequestedAmount = amount,
                CardSource = cardSource != null ? Canonical(cardSource) : null,
            });
        }
    }

    public static void RecordArtifactBlockedDebuffAttempt(
        PowerModel canonicalPower,
        Creature target,
        decimal requestedAmount,
        Creature? applier,
        IEnumerable<AbstractModel>? modifiers,
        decimal modifiedAmount)
    {
        lock (_lock)
        {
            var attempt = TakePendingPowerChangeAttemptLocked(canonicalPower, target, applier, requestedAmount);

            if (modifiedAmount != 0m) return;
            if (canonicalPower.GetTypeForAmount(requestedAmount) != PowerType.Debuff) return;
            if (!WasArtifactBlock(target, modifiers)) return;

            var sourceCard = ResolvePowerChangeSourceCardLocked(attempt, applier);
            if (sourceCard == null)
            {
                CoreMain.LogDebug(
                    $"Artifact-blocked debuff unattributed power={canonicalPower.Id} amount={requestedAmount} " +
                    $"target={DescribeCreature(target)} applier={DescribeCreature(applier)}");
                return;
            }

            _pendingCombat ??= new PendingCombat();
            var instanceId = GetOrAssignInstanceId(sourceCard);
            var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
            var effect = GetOrCreateAppliedEffect(agg, canonicalPower);
            effect.TimesBlockedByArtifact++;
            effect.TotalAmountBlockedByArtifact += requestedAmount;
        }
    }

    private static PendingPowerChangeAttempt? TakePendingPowerChangeAttemptLocked(
        PowerModel power,
        Creature target,
        Creature? applier,
        decimal requestedAmount)
    {
        for (int i = _pendingPowerChangeAttempts.Count - 1; i >= 0; i--)
        {
            var attempt = _pendingPowerChangeAttempts[i];
            if (!ReferenceEquals(attempt.Power, power)) continue;
            if (!ReferenceEquals(attempt.Target, target)) continue;
            if (!ReferenceEquals(attempt.Applier, applier)) continue;
            if (attempt.RequestedAmount != requestedAmount) continue;

            _pendingPowerChangeAttempts.RemoveAt(i);
            return attempt;
        }

        for (int i = _pendingPowerChangeAttempts.Count - 1; i >= 0; i--)
        {
            var attempt = _pendingPowerChangeAttempts[i];
            if (!ReferenceEquals(attempt.Power, power)) continue;
            if (!ReferenceEquals(attempt.Target, target)) continue;

            _pendingPowerChangeAttempts.RemoveAt(i);
            return attempt;
        }

        return null;
    }

    private static CardModel? ResolvePowerChangeSourceCardLocked(
        PendingPowerChangeAttempt? attempt,
        Creature? applier)
    {
        if (attempt?.CardSource != null) return attempt.CardSource;

        var applierPlayer = applier?.Player;
        if (applierPlayer != null && _pendingEffectSourceCard != null && IsOwnedBy(_pendingEffectSourceCard, applierPlayer))
        {
            int historyCount = CombatManager.Instance?.History?.Entries?.Count() ?? 0;
            if (historyCount == _pendingEffectSourceHistoryCount)
                return _pendingEffectSourceCard;
        }

        var causingPlay = FindCurrentlyResolvingCardPlay();
        if (causingPlay?.Card != null) return Canonical(causingPlay.Card);

        if (_recentCompletedPlayerCardPlay?.Card != null)
        {
            int historyCount = CombatManager.Instance?.History?.Entries?.Count() ?? 0;
            if (historyCount == _recentCompletedPlayerCardPlayHistoryCount)
                return Canonical(_recentCompletedPlayerCardPlay.Card);
        }

        return null;
    }

    private static bool WasArtifactModifier(IEnumerable<AbstractModel>? modifiers)
    {
        if (modifiers == null) return false;
        foreach (var modifier in modifiers)
        {
            if (modifier is ArtifactPower) return true;
        }
        return false;
    }

    private static bool WasArtifactBlock(Creature target, IEnumerable<AbstractModel>? modifiers)
    {
        if (WasArtifactModifier(modifiers)) return true;

        try
        {
            return target.HasPower(ModelDb.GetId(typeof(ArtifactPower)));
        }
        catch
        {
            return false;
        }
    }

    private static CardModel? FindLikelyBlockSourceCard(Creature receiver)
    {
        var targetPlayer = receiver.Player;
        if (targetPlayer == null) return null;

        var causingPlay = FindCurrentlyResolvingCardPlay();
        if (causingPlay?.Card != null && IsOwnedBy(causingPlay.Card, targetPlayer))
            return Canonical(causingPlay.Card);

        if (_recentCompletedPlayerCardPlay?.Card != null && IsOwnedBy(_recentCompletedPlayerCardPlay.Card, targetPlayer))
        {
            int historyCount = CombatManager.Instance?.History?.Entries?.Count() ?? 0;
            if (historyCount <= _recentCompletedPlayerCardPlayHistoryCount + 1)
                return Canonical(_recentCompletedPlayerCardPlay.Card);
        }

        return null;
    }

    private static CardModel? FindLikelyDrawSourceCard(Player targetPlayer)
    {
        if (_pendingEffectSourceCard != null && IsOwnedBy(_pendingEffectSourceCard, targetPlayer))
        {
            int historyCount = CombatManager.Instance?.History?.Entries?.Count() ?? 0;
            if (historyCount == _pendingEffectSourceHistoryCount)
                return _pendingEffectSourceCard;
        }

        var causingPlay = FindCurrentlyResolvingCardPlay();
        if (causingPlay?.Card != null && IsOwnedBy(causingPlay.Card, targetPlayer))
            return Canonical(causingPlay.Card);

        if (_recentCompletedPlayerCardPlay?.Card != null && IsOwnedBy(_recentCompletedPlayerCardPlay.Card, targetPlayer))
        {
            int historyCount = CombatManager.Instance?.History?.Entries?.Count() ?? 0;
            if (historyCount == _recentCompletedPlayerCardPlayHistoryCount)
                return Canonical(_recentCompletedPlayerCardPlay.Card);
        }

        return null;
    }

    private static bool IsOwnedBy(CardModel card, Player targetPlayer)
    {
        if (targetPlayer == null) return true;
        if (card.Owner == null) return true;
        return ReferenceEquals(card.Owner, targetPlayer);
    }

    public static void RecordDrawFromCard(CardModel card, bool fromHandDraw)
    {
        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();
            var instanceId = GetOrAssignInstanceId(card);
            var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
            agg.TimesDrawn++;

            // If the draw is NOT a turn-start hand-draw (fromHandDraw=true
            // means turn-start), it was caused by some card's play effect.
            // Attribute to the currently-resolving play so that card can
            // show "drew N cards this run" in its stats. Skip self-draw
            // (drawing a card that happens to be the one being played)
            // since that's uncommon and introduces noise.
            if (!fromHandDraw)
            {
                try
                {
                    var sourceCard = _pendingDrawSourceCard;
                    if (sourceCard == null)
                    {
                        var causingPlay = FindCurrentlyResolvingCardPlay();
                        sourceCard = causingPlay?.Card;
                    }

                    if (sourceCard != null
                        && !ReferenceEquals(Canonical(sourceCard), Canonical(card)))
                    {
                        var causerId = GetOrAssignInstanceId(sourceCard);
                        var causerAgg = GetOrCreateAggregate(_pendingCombat, causerId);
                        causerAgg.TimesCardsDrawn++;
                    }
                }
                catch (Exception e)
                {
                    CoreMain.LogDebug($"RecordDrawFromCard attribution failed: {e.Message}");
                }
            }
        }
    }

    private static void RecordPowerReceived(PowerReceivedEntry entry)
    {
        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();

            try
            {
                var causingPlay = FindCurrentlyResolvingCardPlay();
                if (causingPlay?.Card == null)
                {
                    CoreMain.LogDebug(
                        $"PowerReceivedEntry unattributed power={entry.Power.Id} amount={entry.Amount} " +
                        $"applier={DescribeCreature(entry.Applier)}");
                    return;
                }

                var instanceId = GetOrAssignInstanceId(causingPlay.Card);
                var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
                var effect = GetOrCreateAppliedEffect(agg, entry.Power);
                effect.TimesApplied++;
                effect.TotalAmountApplied += entry.Amount;
            }
            catch (Exception e)
            {
                CoreMain.LogDebug($"RecordPowerReceived failed: {e.Message}");
            }
        }
    }

    private static void RecordBlockGainedEntry(BlockGainedEntry entry)
    {
        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();

            string? instanceId = null;
            if (entry.CardPlay?.Card != null)
            {
                instanceId = GetOrAssignInstanceId(entry.CardPlay.Card);
            }
            else if (entry.Receiver.IsPlayer)
            {
                var fallbackCard = FindLikelyBlockSourceCard(entry.Receiver);
                if (fallbackCard != null)
                    instanceId = GetOrAssignInstanceId(fallbackCard);
            }

            if (instanceId != null)
            {
                var agg = GetOrCreateAggregate(_pendingCombat, instanceId);
                agg.TotalBlockGained += entry.Amount;

                _pendingCombat.CombatEvents.Add(new CardEvent
                {
                    T = Now(),
                    Type = "block_gained",
                    CardId = instanceId,
                    Blocked = entry.Amount,
                });
            }
            else if (entry.Receiver.IsPlayer)
            {
                var recvDesc = DescribeCreature(entry.Receiver);
                CoreMain.LogDebug(
                    $"BlockGainedEntry unattributed receiver={recvDesc} amount={entry.Amount}");
            }

            if (entry.Receiver.IsPlayer)
            {
                AppendPlayerBlockChunkLocked(instanceId, entry.Amount);
                ReconcilePlayerBlockLedgerLocked(entry.Receiver);
            }
        }
    }

    private static void RecordPlayerBlockedDamage(DamageReceivedEntry entry)
    {
        if (!entry.Receiver.IsPlayer) return;

        int blocked = entry.Result.BlockedDamage;
        if (blocked <= 0) return;

        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();
            AttributeBlockedDamageLocked(blocked);
            ReconcilePlayerBlockLedgerLocked(entry.Receiver);
        }
    }

    public static void NotePotentialPlayerBlockClear(Creature creature)
    {
        lock (_lock)
        {
            if (!creature.IsPlayer) return;
            _pendingPlayerBlockClearAmount = Math.Max(0, creature.Block);
            _pendingPlayerBlockClearArmed = _pendingPlayerBlockClearAmount > 0;
        }
    }

    public static void NotePlayerBlockClearPrevented(Creature creature)
    {
        lock (_lock)
        {
            if (!creature.IsPlayer) return;
            ClearPendingPlayerBlockClearLocked();
        }
    }

    public static void NotePlayerBlockCleared(Creature creature)
    {
        lock (_lock)
        {
            if (!creature.IsPlayer) return;

            if (_pendingCombat == null)
            {
                ClearPendingPlayerBlockClearLocked();
                return;
            }

            int actualRemaining = Math.Max(0, creature.Block);
            int removed = _pendingPlayerBlockClearArmed
                ? Math.Max(0, _pendingPlayerBlockClearAmount - actualRemaining)
                : TotalTrackedPlayerBlockLocked();

            AttributeUnusedBlockLocked(removed);
            ReconcilePlayerBlockLedgerLocked(creature);
            ClearPendingPlayerBlockClearLocked();
        }
    }

    private static void AppendPlayerBlockChunkLocked(string? cardInstanceId, int amount)
    {
        if (_pendingCombat == null || amount <= 0) return;

        _pendingCombat.PlayerBlockLedger.Add(new BlockChunk
        {
            CardInstanceId = cardInstanceId,
            Remaining = amount,
            Sequence = _pendingCombat.NextBlockSequence++,
        });
    }

    private static void AttributeBlockedDamageLocked(int blocked)
    {
        if (_pendingCombat == null || blocked <= 0) return;

        int remainingToAttribute = blocked;
        for (int i = 0; i < _pendingCombat.PlayerBlockLedger.Count && remainingToAttribute > 0; i++)
        {
            var chunk = _pendingCombat.PlayerBlockLedger[i];
            if (chunk.Remaining <= 0) continue;

            int consumed = Math.Min(chunk.Remaining, remainingToAttribute);
            chunk.Remaining -= consumed;
            remainingToAttribute -= consumed;

            if (chunk.CardInstanceId != null)
            {
                var agg = GetOrCreateAggregate(_pendingCombat, chunk.CardInstanceId);
                agg.TotalBlockEffective += consumed;
            }
        }

        _pendingCombat.PlayerBlockLedger.RemoveAll(chunk => chunk.Remaining <= 0);
    }

    private static void AttributeUnusedBlockLocked(int unusedBlockToRemove)
    {
        if (_pendingCombat == null || unusedBlockToRemove <= 0) return;

        for (int i = _pendingCombat.PlayerBlockLedger.Count - 1; i >= 0 && unusedBlockToRemove > 0; i--)
        {
            var chunk = _pendingCombat.PlayerBlockLedger[i];
            if (chunk.Remaining <= 0) continue;

            int wasted = Math.Min(chunk.Remaining, unusedBlockToRemove);
            chunk.Remaining -= wasted;
            unusedBlockToRemove -= wasted;

            if (chunk.CardInstanceId != null)
            {
                var agg = GetOrCreateAggregate(_pendingCombat, chunk.CardInstanceId);
                agg.TotalBlockWasted += wasted;
            }
        }

        _pendingCombat.PlayerBlockLedger.RemoveAll(chunk => chunk.Remaining <= 0);
    }

    private static int TotalTrackedPlayerBlockLocked()
    {
        return _pendingCombat?.PlayerBlockLedger.Sum(chunk => chunk.Remaining) ?? 0;
    }

    private static void ReconcilePlayerBlockLedgerLocked(Creature creature)
    {
        if (_pendingCombat == null || !creature.IsPlayer) return;

        int actualBlock = Math.Max(0, creature.Block);
        int trackedBlock = TotalTrackedPlayerBlockLocked();

        if (trackedBlock > actualBlock)
        {
            AttributeUnusedBlockLocked(trackedBlock - actualBlock);
        }
        else if (trackedBlock < actualBlock)
        {
            AppendPlayerBlockChunkLocked(cardInstanceId: null, amount: actualBlock - trackedBlock);
        }
    }

    private static void ClearPendingPlayerBlockClearLocked()
    {
        _pendingPlayerBlockClearAmount = 0;
        _pendingPlayerBlockClearArmed = false;
    }

    private static void RecordDamageFromCard(DamageReceivedEntry entry)
    {
        var result = entry.Result;

        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();
            var instanceId = GetOrAssignInstanceId(entry.CardSource!);
            var agg = GetOrCreateAggregate(_pendingCombat, instanceId);

            if (entry.Receiver.IsPlayer)
            {
                // Self-damage (Hemokinesis, Offering, Combust tick, etc.).
                // We track HP actually lost (UnblockedDamage), which is
                // POST-reduction — Tungsten Rod / buffer effects naturally
                // show up as less HP loss. That's what the user wants to
                // see: what did this card really cost me?
                agg.TotalHpLost += result.UnblockedDamage;
            }
            else
            {
                // Enemy damage — offensive stats.
                int intended = result.BlockedDamage + result.UnblockedDamage;
                int effective = result.UnblockedDamage - result.OverkillDamage;
                agg.TotalIntended += intended;
                agg.TotalBlocked += result.BlockedDamage;
                agg.TotalOverkill += result.OverkillDamage;
                agg.TotalEffective += effective;
                if (result.WasTargetKilled) agg.Kills++;
            }

            _pendingCombat.CombatEvents.Add(new CardEvent
            {
                T = Now(),
                Type = "damage_received",
                CardId = instanceId,
                Receiver = entry.Receiver.IsPlayer
                    ? entry.Receiver.Player?.Character?.Id.ToString()
                    : entry.Receiver.Monster?.Id.ToString(),
                Blocked = result.BlockedDamage,
                Unblocked = result.UnblockedDamage,
                Overkill = result.OverkillDamage,
                Killed = result.WasTargetKilled,
            });
        }
    }

    // -------- Helpers --------

    private static CardAggregate GetOrCreateAggregate(PendingCombat pending, string cardId)
    {
        if (!pending.CombatAggregates.TryGetValue(cardId, out var agg))
        {
            agg = new CardAggregate();
            pending.CombatAggregates[cardId] = agg;
        }
        return agg;
    }

    private static CardAggregate GetOrCreateAggregate(RunData run, string cardId)
    {
        if (!run.Aggregates.TryGetValue(cardId, out var agg))
        {
            agg = new CardAggregate();
            run.Aggregates[cardId] = agg;
        }
        return agg;
    }

    private static CardAggregate CloneAggregate(CardAggregate source)
    {
        var clone = new CardAggregate
        {
            Plays = source.Plays,
            TotalIntended = source.TotalIntended,
            TotalBlocked = source.TotalBlocked,
            TotalOverkill = source.TotalOverkill,
            TotalEffective = source.TotalEffective,
            Kills = source.Kills,
            TotalEnergySpent = source.TotalEnergySpent,
            TotalEnergyGenerated = source.TotalEnergyGenerated,
            TotalBlockGained = source.TotalBlockGained,
            TotalBlockEffective = source.TotalBlockEffective,
            TotalBlockWasted = source.TotalBlockWasted,
            TimesDrawn = source.TimesDrawn,
            TimesDiscarded = source.TimesDiscarded,
            TimesPlacedOnTopFromHand = source.TimesPlacedOnTopFromHand,
            TimesPlacedOnTopFromDiscard = source.TimesPlacedOnTopFromDiscard,
            TimesExhaustedOtherCards = source.TimesExhaustedOtherCards,
            TimesExhausted = source.TimesExhausted,
            TotalHpLost = source.TotalHpLost,
            TimesCardsDrawn = source.TimesCardsDrawn,
            FloorAdded = source.FloorAdded,
            InitialUpgradeLevel = source.InitialUpgradeLevel,
            Removed = source.Removed,
            RemovedAtFloor = source.RemovedAtFloor,
            RemovedSnapshot = source.RemovedSnapshot,
        };
        MergeAppliedEffectsInto(clone.AppliedEffects, source.AppliedEffects);
        return clone;
    }

    private static void MergeAggregateInto(CardAggregate target, CardAggregate source)
    {
        target.Plays += source.Plays;
        target.TotalIntended += source.TotalIntended;
        target.TotalBlocked += source.TotalBlocked;
        target.TotalOverkill += source.TotalOverkill;
        target.TotalEffective += source.TotalEffective;
        target.Kills += source.Kills;
        target.TotalEnergySpent += source.TotalEnergySpent;
        target.TotalEnergyGenerated += source.TotalEnergyGenerated;
        target.TotalBlockGained += source.TotalBlockGained;
        target.TotalBlockEffective += source.TotalBlockEffective;
        target.TotalBlockWasted += source.TotalBlockWasted;
        target.TimesDrawn += source.TimesDrawn;
        target.TimesDiscarded += source.TimesDiscarded;
        target.TimesPlacedOnTopFromHand += source.TimesPlacedOnTopFromHand;
        target.TimesPlacedOnTopFromDiscard += source.TimesPlacedOnTopFromDiscard;
        target.TimesExhaustedOtherCards += source.TimesExhaustedOtherCards;
        target.TimesExhausted += source.TimesExhausted;
        target.TotalHpLost += source.TotalHpLost;
        target.TimesCardsDrawn += source.TimesCardsDrawn;
        MergeAppliedEffectsInto(target.AppliedEffects, source.AppliedEffects);
    }

    private static void MergeAppliedEffectsInto(
        Dictionary<string, AppliedEffectAggregate> target,
        Dictionary<string, AppliedEffectAggregate> source)
    {
        foreach (var kv in source)
        {
            if (!target.TryGetValue(kv.Key, out var effect))
            {
                effect = new AppliedEffectAggregate
                {
                    EffectId = kv.Value.EffectId,
                    DisplayName = kv.Value.DisplayName,
                    IconPath = kv.Value.IconPath,
                };
                target[kv.Key] = effect;
            }

            effect.TimesApplied += kv.Value.TimesApplied;
            effect.TotalAmountApplied += kv.Value.TotalAmountApplied;
            effect.TimesBlockedByArtifact += kv.Value.TimesBlockedByArtifact;
            effect.TotalAmountBlockedByArtifact += kv.Value.TotalAmountBlockedByArtifact;
            if (string.IsNullOrWhiteSpace(effect.DisplayName) && !string.IsNullOrWhiteSpace(kv.Value.DisplayName))
                effect.DisplayName = kv.Value.DisplayName;
            if (string.IsNullOrWhiteSpace(effect.IconPath) && !string.IsNullOrWhiteSpace(kv.Value.IconPath))
                effect.IconPath = kv.Value.IconPath;
        }
    }

    private static AppliedEffectAggregate GetOrCreateAppliedEffect(CardAggregate agg, PowerModel power)
    {
        var effectId = power.Id.ToString();
        if (!agg.AppliedEffects.TryGetValue(effectId, out var effect))
        {
            effect = new AppliedEffectAggregate
            {
                EffectId = effectId,
                DisplayName = GetPowerDisplayName(power),
                IconPath = !string.IsNullOrWhiteSpace(power.IconPath) ? power.IconPath : power.PackedIconPath,
            };
            agg.AppliedEffects[effectId] = effect;
        }
        return effect;
    }

    private static string GetPowerDisplayName(PowerModel power)
    {
        try
        {
            var title = power.Title.GetFormattedText();
            if (!string.IsNullOrWhiteSpace(title)) return title;
        }
        catch { }
        try
        {
            var title = power.Title.GetRawText();
            if (!string.IsNullOrWhiteSpace(title)) return title;
        }
        catch { }
        return power.Id.ToString();
    }

    private static string Now() => DateTime.UtcNow.ToString("o");

    /// <summary>
    /// Compact description of a Creature for diagnostic logs. Returns
    /// "player/CHARACTER.DEFECT" or "MONSTER.LEAF_SLIME_M" or "null" so
    /// log lines stay greppable alongside the events JSON.
    /// </summary>
    private static string DescribeCreature(MegaCrit.Sts2.Core.Entities.Creatures.Creature? c)
    {
        if (c == null) return "null";
        try
        {
            if (c.IsPlayer) return $"player/{c.Player?.Character?.Id}";
            return c.Monster?.Id.ToString() ?? "monster?";
        }
        catch
        {
            return "err";
        }
    }
}

/// <summary>
/// Holds per-combat stats and events while a combat is in progress.
/// Discarded if the combat doesn't finish cleanly; promoted into the run on CombatEnded.
/// </summary>
internal class PendingCombat
{
    public Dictionary<string, CardAggregate> CombatAggregates { get; } = new();
    public List<CardEvent> CombatEvents { get; } = new();
    public List<BlockChunk> PlayerBlockLedger { get; } = new();
    public int NextBlockSequence { get; set; }
}

internal sealed class BlockChunk
{
    public string? CardInstanceId { get; init; }
    public int Remaining { get; set; }
    public int Sequence { get; init; }
    public bool CountsForCardStats => CardInstanceId != null;
}

internal sealed class PendingPowerChangeAttempt
{
    public required PowerModel Power { get; init; }
    public required Creature Target { get; init; }
    public Creature? Applier { get; init; }
    public required decimal RequestedAmount { get; init; }
    public CardModel? CardSource { get; init; }
}
