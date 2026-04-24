using System.Collections;
using System.Reflection;
using SpireLens.Core;
using Xunit;

namespace SpireLens.Core.Tests;

public class NoxiousFumesContributionTests
{
    private static readonly MethodInfo AllocateMethod =
        typeof(RunTracker).GetMethod("TryAllocateNoxiousFumesContributions", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("TryAllocateNoxiousFumesContributions not found.");

    private static readonly Type WindowType =
        typeof(RunTracker).Assembly.GetType("SpireLens.Core.PendingNoxiousFumesApplicationWindow", throwOnError: true)
        ?? throw new InvalidOperationException("PendingNoxiousFumesApplicationWindow type not found.");

    private static readonly Type ShareType =
        typeof(RunTracker).Assembly.GetType("SpireLens.Core.NoxiousFumesContributionShare", throwOnError: true)
        ?? throw new InvalidOperationException("NoxiousFumesContributionShare type not found.");

    [Fact]
    public void Allocate_SplitsAcrossTrackedContributors()
    {
        var window = CreateWindow(("CARD.NOXIOUS_FUMES#1", 2m), ("CARD.NOXIOUS_FUMES#2", 3m));

        var (allocated, unattributed) = Allocate(window, 5m);

        Assert.Equal(0m, unattributed);
        Assert.Equal(2m, allocated["CARD.NOXIOUS_FUMES#1"]);
        Assert.Equal(3m, allocated["CARD.NOXIOUS_FUMES#2"]);
    }

    [Fact]
    public void Allocate_LeavesRemainderUnattributed_WhenTrackedTotalIsLowerThanRequested()
    {
        var window = CreateWindow(("CARD.NOXIOUS_FUMES#1", 2m), ("CARD.NOXIOUS_FUMES#2", 3m));

        var (allocated, unattributed) = Allocate(window, 6m);

        Assert.Equal(1m, unattributed);
        Assert.Equal(2m, allocated["CARD.NOXIOUS_FUMES#1"]);
        Assert.Equal(3m, allocated["CARD.NOXIOUS_FUMES#2"]);
    }

    [Fact]
    public void Allocate_ScalesContributorsDown_WhenTrackedTotalExceedsRequested()
    {
        var window = CreateWindow(("CARD.NOXIOUS_FUMES#1", 2m), ("CARD.NOXIOUS_FUMES#2", 3m));

        var (allocated, unattributed) = Allocate(window, 4m);

        Assert.Equal(0m, unattributed);
        Assert.Equal(1.6m, allocated["CARD.NOXIOUS_FUMES#1"]);
        Assert.Equal(2.4m, allocated["CARD.NOXIOUS_FUMES#2"]);
    }

    private static object CreateWindow(params (string CardInstanceId, decimal Amount)[] shares)
    {
        var window = Activator.CreateInstance(WindowType)
            ?? throw new InvalidOperationException("Failed to create pending Noxious Fumes window.");
        var contributions = (IList)(WindowType.GetProperty("Contributions")?.GetValue(window)
            ?? throw new InvalidOperationException("Contributions property not found."));

        foreach (var (cardInstanceId, amount) in shares)
        {
            var share = Activator.CreateInstance(ShareType)
                ?? throw new InvalidOperationException("Failed to create contribution share.");
            ShareType.GetProperty("CardInstanceId")?.SetValue(share, cardInstanceId);
            ShareType.GetProperty("Amount")?.SetValue(share, amount);
            contributions.Add(share);
        }

        return window;
    }

    private static (Dictionary<string, decimal> Allocated, decimal Unattributed) Allocate(object window, decimal requestedAmount)
    {
        var args = new object?[] { window, requestedAmount, null, 0m };
        var allocated = (bool)(AllocateMethod.Invoke(null, args)
            ?? throw new InvalidOperationException("TryAllocateNoxiousFumesContributions returned null."));
        Assert.True(allocated);

        var result = new Dictionary<string, decimal>(StringComparer.Ordinal);
        var allocations = (IEnumerable)(args[2] ?? throw new InvalidOperationException("Allocations out param was null."));
        foreach (var allocation in allocations)
        {
            var allocationType = allocation.GetType();
            var cardInstanceId = (string?)(allocationType.GetProperty("CardInstanceId")?.GetValue(allocation))
                ?? throw new InvalidOperationException("Allocation CardInstanceId missing.");
            var amount = (decimal)(allocationType.GetProperty("Amount")?.GetValue(allocation)
                ?? throw new InvalidOperationException("Allocation Amount missing."));
            result[cardInstanceId] = amount;
        }

        return (result, (decimal)(args[3] ?? 0m));
    }
}
