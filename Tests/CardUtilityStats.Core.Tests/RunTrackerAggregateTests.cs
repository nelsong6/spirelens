using System.Reflection;
using CardUtilityStats.Core;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class RunTrackerAggregateTests
{
    private static readonly MethodInfo CloneAggregateMethod =
        typeof(RunTracker).GetMethod("CloneAggregate", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("CloneAggregate not found.");

    private static readonly MethodInfo MergeAggregateIntoMethod =
        typeof(RunTracker).GetMethod("MergeAggregateInto", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("MergeAggregateInto not found.");

    [Fact]
    public void CloneAggregate_CopiesTimesSummonedToHand()
    {
        var source = new CardAggregate
        {
            TimesSummonedToHand = 2,
            TotalForgeGenerated = 9m,
        };

        var clone = (CardAggregate)(CloneAggregateMethod.Invoke(null, new object?[] { source })
            ?? throw new InvalidOperationException("CloneAggregate returned null."));

        Assert.Equal(2, clone.TimesSummonedToHand);
        Assert.Equal(9m, clone.TotalForgeGenerated);
    }

    [Fact]
    public void MergeAggregateInto_AddsTimesSummonedToHand()
    {
        var target = new CardAggregate
        {
            TimesSummonedToHand = 1,
        };
        var source = new CardAggregate
        {
            TimesSummonedToHand = 2,
        };

        _ = MergeAggregateIntoMethod.Invoke(null, new object?[] { target, source });

        Assert.Equal(3, target.TimesSummonedToHand);
    }
}
