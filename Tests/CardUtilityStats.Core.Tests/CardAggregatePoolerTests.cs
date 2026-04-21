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
            TotalEffective = 4,
            TotalBlocked = 1,
            TimesExhausted = 1,
        };
        first.AppliedEffects["POWER.ARTIFACT"] = new AppliedEffectAggregate
        {
            EffectId = "POWER.ARTIFACT",
            DisplayName = "Artifact",
            TimesBlockedByArtifact = 1,
            TotalAmountBlockedByArtifact = 1m,
        };

        var second = new CardAggregate
        {
            Plays = 2,
            TotalEffective = 11,
            TotalBlocked = 2,
            TimesExhausted = 2,
        };
        second.AppliedEffects["POWER.VULNERABLE"] = new AppliedEffectAggregate
        {
            EffectId = "POWER.VULNERABLE",
            DisplayName = "Vulnerable",
            TimesApplied = 2,
            TotalAmountApplied = 4m,
        };

        var otherDefinition = new CardAggregate
        {
            Plays = 99,
            TotalEffective = 999,
            TimesExhausted = 99,
        };

        var pooled = CardAggregatePooler.PoolByDefinition(
            new[]
            {
                new KeyValuePair<string, CardAggregate>("CARD.SHIV#1", first),
                new KeyValuePair<string, CardAggregate>("CARD.SHIV#2", second),
                new KeyValuePair<string, CardAggregate>("CARD.STRIKE_SILENT#1", otherDefinition),
            },
            "CARD.SHIV");

        Assert.NotNull(pooled);
        Assert.Equal(3, pooled!.Plays);
        Assert.Equal(15, pooled.TotalEffective);
        Assert.Equal(3, pooled.TotalBlocked);
        Assert.Equal(3, pooled.TimesExhausted);

        var artifact = pooled.AppliedEffects["POWER.ARTIFACT"];
        Assert.Equal(1, artifact.TimesBlockedByArtifact);
        Assert.Equal(1m, artifact.TotalAmountBlockedByArtifact);

        var vulnerable = pooled.AppliedEffects["POWER.VULNERABLE"];
        Assert.Equal(2, vulnerable.TimesApplied);
        Assert.Equal(4m, vulnerable.TotalAmountApplied);
    }

    [Fact]
    public void PoolByDefinition_ReturnsNullWhenDefinitionIsAbsent()
    {
        var pooled = CardAggregatePooler.PoolByDefinition(
            new[]
            {
                new KeyValuePair<string, CardAggregate>("CARD.STRIKE_SILENT#1", new CardAggregate()),
            },
            "CARD.SHIV");

        Assert.Null(pooled);
    }
}
