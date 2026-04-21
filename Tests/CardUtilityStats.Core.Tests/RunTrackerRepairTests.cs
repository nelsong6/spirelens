using CardUtilityStats.Core;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class RunTrackerRepairTests
{
    [Fact]
    public void RepairOffensiveDamageAggregatesFromEvents_RebuildsLethalOverkillDamage()
    {
        var run = new RunData();
        run.Aggregates["CARD.SOVEREIGN_BLADE#1"] = new CardAggregate
        {
            Plays = 1,
            TotalIntended = 1,
            TotalEffective = -22,
            TotalOverkill = 23,
            Kills = 1,
        };
        run.Events.Add(new CardEvent
        {
            Type = "damage_received",
            CardId = "CARD.SOVEREIGN_BLADE#1",
            Receiver = "MONSTER.GAS_BOMB",
            Blocked = 0,
            Unblocked = 1,
            Overkill = 23,
            Killed = true,
        });

        bool changed = RunTracker.RepairOffensiveDamageAggregatesFromEvents(run);

        var aggregate = run.Aggregates["CARD.SOVEREIGN_BLADE#1"];
        Assert.True(changed);
        Assert.Equal(24, aggregate.TotalIntended);
        Assert.Equal(1, aggregate.TotalEffective);
        Assert.Equal(23, aggregate.TotalOverkill);
        Assert.Equal(1, aggregate.Kills);
        Assert.Equal(1, aggregate.Plays);
    }
}
