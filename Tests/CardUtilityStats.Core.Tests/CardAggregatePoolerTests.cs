using CardUtilityStats.Core;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class CardAggregatePoolerTests
{
    [Fact]
    public void PoolByDefinition_MergesOnlyMatchingDefinitionInstances()
    {
        var first = new CardAggregate
        {
            Plays = 1,
            TotalEffective = 6,
            TotalBlocked = 2,
            TimesCardsDrawn = 1,
        };
        first.AppliedEffects["POWER.FORGE"] = new AppliedEffectAggregate
        {
            EffectId = "POWER.FORGE",
            DisplayName = "Forge",
            TimesApplied = 1,
            TotalAmountApplied = 2m,
        };

        var second = new CardAggregate
        {
            Plays = 2,
            TotalEffective = 9,
            TotalBlocked = 1,
            TimesCardsDrawn = 3,
        };
        second.AppliedEffects["POWER.FORGE"] = new AppliedEffectAggregate
        {
            EffectId = "POWER.FORGE",
            DisplayName = "Forge",
            TimesApplied = 2,
            TotalAmountApplied = 5m,
        };
        second.AppliedEffects["POWER.BLADE"] = new AppliedEffectAggregate
        {
            EffectId = "POWER.BLADE",
            DisplayName = "Blade",
            TimesApplied = 1,
            TotalAmountApplied = 1m,
        };

        var otherDefinition = new CardAggregate
        {
            Plays = 99,
            TotalEffective = 999,
            TimesCardsDrawn = 99,
        };

        var pooled = CardAggregatePooler.PoolByDefinition(
            new[]
            {
                new KeyValuePair<string, CardAggregate>("CARD.SOVEREIGN_BLADE#1", first),
                new KeyValuePair<string, CardAggregate>("CARD.SOVEREIGN_BLADE#2", second),
                new KeyValuePair<string, CardAggregate>("CARD.STRIKE_KIN#1", otherDefinition),
            },
            "CARD.SOVEREIGN_BLADE");

        Assert.NotNull(pooled);
        Assert.Equal(3, pooled!.Plays);
        Assert.Equal(15, pooled.TotalEffective);
        Assert.Equal(3, pooled.TotalBlocked);
        Assert.Equal(4, pooled.TimesCardsDrawn);

        var forge = pooled.AppliedEffects["POWER.FORGE"];
        Assert.Equal(3, forge.TimesApplied);
        Assert.Equal(7m, forge.TotalAmountApplied);

        var blade = pooled.AppliedEffects["POWER.BLADE"];
        Assert.Equal(1, blade.TimesApplied);
        Assert.Equal(1m, blade.TotalAmountApplied);
    }

    [Fact]
    public void PoolByDefinition_ReturnsNullWhenDefinitionIsAbsent()
    {
        var pooled = CardAggregatePooler.PoolByDefinition(
            new[]
            {
                new KeyValuePair<string, CardAggregate>("CARD.STRIKE_KIN#1", new CardAggregate()),
            },
            "CARD.SOVEREIGN_BLADE");

        Assert.Null(pooled);
    }
}
