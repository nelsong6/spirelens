using SpireLens.Core;
using Xunit;

namespace SpireLens.Core.Tests;

public class CardAggregatePoolerTests
{
    [Fact]
    public void PoolByDefinition_MergesOnlyMatchingShivInstances()
    {
        var first = new CardAggregate
        {
            Plays = 1,
            TotalEffective = 4,
            TotalBlocked = 1,
            TimesExhausted = 1,
            TimesCardsDrawAttempted = 3,
            TimesCardsDrawBlocked = 2,
        };
        first.AppliedEffects["POWER.ARTIFACT"] = new AppliedEffectAggregate
        {
            EffectId = "POWER.ARTIFACT",
            DisplayName = "Artifact",
            TimesBlockedByArtifact = 1,
            TotalAmountBlockedByArtifact = 1m,
            TotalTriggeredCardsDrawBlocked = 2,
        };
        first.BlockedDrawReasons["effect:POWER.NO_DRAW"] = new BlockedDrawReasonAggregate
        {
            ReasonId = "effect:POWER.NO_DRAW",
            DisplayName = "No Draw",
            Count = 2,
        };

        var second = new CardAggregate
        {
            Plays = 2,
            TotalEffective = 11,
            TotalBlocked = 2,
            TimesExhausted = 2,
            TimesCardsDrawAttempted = 1,
            TimesCardsDrawBlocked = 1,
        };
        second.AppliedEffects["POWER.VULNERABLE"] = new AppliedEffectAggregate
        {
            EffectId = "POWER.VULNERABLE",
            DisplayName = "Vulnerable",
            TimesApplied = 2,
            TotalAmountApplied = 4m,
        };
        second.BlockedDrawReasons["full_hand"] = new BlockedDrawReasonAggregate
        {
            ReasonId = "full_hand",
            DisplayName = "Hand full",
            Count = 1,
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
        Assert.Equal(4, pooled.TimesCardsDrawAttempted);
        Assert.Equal(3, pooled.TimesCardsDrawBlocked);
        Assert.Equal(2, pooled.BlockedDrawReasons["effect:POWER.NO_DRAW"].Count);
        Assert.Equal(1, pooled.BlockedDrawReasons["full_hand"].Count);

        var artifact = pooled.AppliedEffects["POWER.ARTIFACT"];
        Assert.Equal(1, artifact.TimesBlockedByArtifact);
        Assert.Equal(1m, artifact.TotalAmountBlockedByArtifact);
        Assert.Equal(2, artifact.TotalTriggeredCardsDrawBlocked);

        var vulnerable = pooled.AppliedEffects["POWER.VULNERABLE"];
        Assert.Equal(2, vulnerable.TimesApplied);
        Assert.Equal(4m, vulnerable.TotalAmountApplied);
    }

    [Fact]
    public void PoolByDefinition_MergesOnlyMatchingSovereignBladeInstances()
    {
        var first = new CardAggregate
        {
            Plays = 1,
            TotalEffective = 6,
            TotalBlocked = 2,
            TimesCardsDrawn = 1,
            TotalForgeGenerated = 2m,
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
            TotalForgeGenerated = 5m,
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
        Assert.Equal(7m, pooled.TotalForgeGenerated);

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
                new KeyValuePair<string, CardAggregate>("CARD.STRIKE_SILENT#1", new CardAggregate()),
            },
            "CARD.SHIV");

        Assert.Null(pooled);
    }
}
