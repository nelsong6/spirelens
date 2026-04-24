using System.Reflection;
using SpireLens.Core;
using Xunit;

namespace SpireLens.Core.Tests;

public class RunTrackerAggregateTests
{
    private static readonly MethodInfo CloneAggregateMethod =
        typeof(RunTracker).GetMethod("CloneAggregate", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("CloneAggregate not found.");

    private static readonly MethodInfo MergeAggregateIntoMethod =
        typeof(RunTracker).GetMethod("MergeAggregateInto", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("MergeAggregateInto not found.");

    [Fact]
    public void CloneAggregate_CopiesForgeGeneratedAndTimesSummonedToHand()
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
    public void MergeAggregateInto_AddsForgeGeneratedAndTimesSummonedToHand()
    {
        var target = new CardAggregate
        {
            TimesSummonedToHand = 1,
            TotalForgeGenerated = 5m,
        };
        var source = new CardAggregate
        {
            TimesSummonedToHand = 2,
            TotalForgeGenerated = 4m,
        };

        _ = MergeAggregateIntoMethod.Invoke(null, new object?[] { target, source });

        Assert.Equal(3, target.TimesSummonedToHand);
        Assert.Equal(9m, target.TotalForgeGenerated);
    }
}
