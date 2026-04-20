using System;
using System.Collections.Generic;

namespace CardUtilityStats.Core;

/// <summary>
/// Serialized shape of one run's stats. Written to disk as JSON.
/// Schema changes MUST bump <see cref="SchemaVersion"/> and add migration.
/// See https://github.com/nelsong6/card-utility-stats/issues/4
/// </summary>
public class RunData
{
    public int SchemaVersion { get; set; } = 1;
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
}

/// <summary>Aggregated per-card attribution stats for this run.</summary>
public class CardAggregate
{
    public int Plays { get; set; }

    // M1: Attack attribution. Null/zero for non-attack cards.
    public int TotalIntended { get; set; }   // damage the card tried to deal (pre-block, pre-overkill)
    public int TotalBlocked { get; set; }    // damage absorbed by target block
    public int TotalOverkill { get; set; }   // damage past target HP (wasted)
    public int TotalEffective { get; set; }  // damage that actually moved HP (intended - blocked - overkill)
    public int Kills { get; set; }           // times the card landed a killing blow

    // M2: Block attribution (see issue #1 for heuristic). Null until M2.
    // M3: Utility closure (energy/draw). Null until M3.
}

/// <summary>
/// One entry in the full event log. Captures what the mod observed, not what the
/// external analysis will compute on top (that's the aggregates' job).
/// </summary>
public class CardEvent
{
    public string T { get; set; } = "";          // ISO-8601 UTC timestamp
    public string Type { get; set; } = "";       // "card_played" | "damage_received"
    public string CardId { get; set; } = "";

    // card_played fields
    public string? Target { get; set; }          // if the card targeted an enemy, their entity id (e.g. "KIN_PRIEST_0")

    // damage_received fields (only populated when Type == "damage_received" with a CardSource)
    public string? Receiver { get; set; }
    public int? Blocked { get; set; }
    public int? Unblocked { get; set; }
    public int? Overkill { get; set; }
    public bool? Killed { get; set; }
}
