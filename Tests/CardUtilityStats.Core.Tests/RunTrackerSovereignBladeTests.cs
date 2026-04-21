using CardUtilityStats.Core;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class RunTrackerSovereignBladeTests
{
    [Fact]
    public void TryInferSovereignBladeDefinitionIdFromAggregateKeys_UsesAggregatePrefixWhenForgedEventIsBlank()
    {
        var definitionId = RunTracker.TryInferSovereignBladeDefinitionIdFromAggregateKeys(
            new[]
            {
                "CARD.STRIKE_REGENT#1",
                "CARD.SOVEREIGN_BLADE#2",
            });

        Assert.Equal("CARD.SOVEREIGN_BLADE", definitionId);
    }

    [Fact]
    public void TryInferSovereignBladeDefinitionIdFromAggregateKeys_ReturnsNullForUnrelatedCards()
    {
        var definitionId = RunTracker.TryInferSovereignBladeDefinitionIdFromAggregateKeys(
            new[]
            {
                "CARD.STRIKE_REGENT#1",
                "CARD.BLADE_DANCE#1",
            });

        Assert.Null(definitionId);
    }
}
