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

    private static readonly MethodInfo CloneRelicAggregateMethod =
        typeof(RunTracker).GetMethod("CloneRelicAggregate", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("CloneRelicAggregate not found.");

    private static readonly MethodInfo MergeRelicAggregateIntoMethod =
        typeof(RunTracker).GetMethod("MergeRelicAggregateInto", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("MergeRelicAggregateInto not found.");

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

    [Fact]
    public void CloneRelicAggregate_CopiesLetterOpenerFields()
    {
        var source = new RelicAggregate
        {
            TimesActivated = 2,
            TotalAttemptedDamage = 30,
            TotalTargets = 6,
        };

        var clone = (RelicAggregate)(CloneRelicAggregateMethod.Invoke(null, new object?[] { source })
            ?? throw new InvalidOperationException("CloneRelicAggregate returned null."));

        Assert.Equal(2, clone.TimesActivated);
        Assert.Equal(30, clone.TotalAttemptedDamage);
        Assert.Equal(6, clone.TotalTargets);
    }

    [Fact]
    public void MergeRelicAggregateInto_AddsLetterOpenerFields()
    {
        var target = new RelicAggregate
        {
            TimesActivated = 1,
            TotalAttemptedDamage = 10,
            TotalTargets = 2,
        };
        var source = new RelicAggregate
        {
            TimesActivated = 2,
            TotalAttemptedDamage = 30,
            TotalTargets = 6,
        };

        _ = MergeRelicAggregateIntoMethod.Invoke(null, new object?[] { target, source });

        Assert.Equal(3, target.TimesActivated);
        Assert.Equal(40, target.TotalAttemptedDamage);
        Assert.Equal(8, target.TotalTargets);
    }
}
