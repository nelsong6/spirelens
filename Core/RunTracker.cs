using System;
using System.Collections.Generic;
using System.Linq;
using MegaCrit.Sts2.Core.Combat;
using MegaCrit.Sts2.Core.Combat.History.Entries;
using MegaCrit.Sts2.Core.Entities.Cards;
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
    private static readonly object _lock = new();
    private static RunData? _currentRun;
    private static PendingCombat? _pendingCombat;

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

    // -------- Lifecycle callbacks --------

    private static void OnRunStarted(RunState runState)
    {
        lock (_lock)
        {
            // If a previous run was in progress (mod reload, unusual path), finalize it first.
            if (_currentRun != null)
            {
                _currentRun.EndedAt = Now();
                RunStorage.SaveAsync(_currentRun);
            }

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

            CoreMain.Logger.Info($"RunStarted: {_currentRun.RunId} character={_currentRun.Character} ascension={_currentRun.Ascension} game_start_time={_currentRun.GameStartTime}");
            RunStorage.SaveAsync(_currentRun);
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
            RunStorage.SaveAsync(_currentRun);

            // Clear state so the next OnRunStarted sees a clean slate.
            _currentRun = null;
            _pendingCombat = null;
        }
    }

    private static void OnCombatSetUp(CombatState state)
    {
        lock (_lock)
        {
            // Fresh pending buffer for this combat. Anything accumulated from a prior
            // combat that didn't get a CombatEnded (shouldn't happen but defensive) is dropped.
            _pendingCombat = new PendingCombat();
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

            // Promote pending buffer into the run's committed state.
            foreach (var (cardId, combatAgg) in _pendingCombat.CombatAggregates)
            {
                var runAgg = GetOrCreateAggregate(_currentRun, cardId);
                runAgg.Plays += combatAgg.Plays;
                runAgg.TotalIntended += combatAgg.TotalIntended;
                runAgg.TotalBlocked += combatAgg.TotalBlocked;
                runAgg.TotalOverkill += combatAgg.TotalOverkill;
                runAgg.TotalEffective += combatAgg.TotalEffective;
                runAgg.Kills += combatAgg.Kills;
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
            RunStorage.SaveAsync(_currentRun);
        }
    }

    // -------- Event observation (from CombatHistory.Add postfix) --------

    /// <summary>
    /// Route a freshly-added CombatHistoryEntry into the pending combat buffer.
    /// Only attack-relevant entries are consumed in M1; others will be handled
    /// by later milestones.
    /// </summary>
    public static void Observe(object entry)
    {
        try
        {
            switch (entry)
            {
                case CardPlayFinishedEntry cpf:
                    RecordCardPlay(cpf.CardPlay);
                    break;
                case DamageReceivedEntry dre when dre.CardSource != null:
                    RecordDamageFromCard(dre);
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
        string cardId = cardPlay.Card.Id.ToString();

        lock (_lock)
        {
            // Defensive: if CombatSetUp never fired (unusual), allocate lazily.
            _pendingCombat ??= new PendingCombat();

            GetOrCreateAggregate(_pendingCombat, cardId).Plays++;
            _pendingCombat.CombatEvents.Add(new CardEvent
            {
                T = Now(),
                Type = "card_played",
                CardId = cardId,
                Target = cardPlay.Target?.Monster?.Id.ToString(),
            });
        }
    }

    private static void RecordDamageFromCard(DamageReceivedEntry entry)
    {
        string cardId = entry.CardSource!.Id.ToString();
        var result = entry.Result;

        // Intended: total damage attempted, before block absorption.
        // Effective: damage that actually removed HP (unblocked minus overkill waste).
        int intended = result.BlockedDamage + result.UnblockedDamage;
        int effective = result.UnblockedDamage - result.OverkillDamage;

        lock (_lock)
        {
            _pendingCombat ??= new PendingCombat();

            var agg = GetOrCreateAggregate(_pendingCombat, cardId);
            agg.TotalIntended += intended;
            agg.TotalBlocked += result.BlockedDamage;
            agg.TotalOverkill += result.OverkillDamage;
            agg.TotalEffective += effective;
            if (result.WasTargetKilled) agg.Kills++;

            _pendingCombat.CombatEvents.Add(new CardEvent
            {
                T = Now(),
                Type = "damage_received",
                CardId = cardId,
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

    private static string Now() => DateTime.UtcNow.ToString("o");
}

/// <summary>
/// Holds per-combat stats and events while a combat is in progress.
/// Discarded if the combat doesn't finish cleanly; promoted into the run on CombatEnded.
/// </summary>
internal class PendingCombat
{
    public Dictionary<string, CardAggregate> CombatAggregates { get; } = new();
    public List<CardEvent> CombatEvents { get; } = new();
}
