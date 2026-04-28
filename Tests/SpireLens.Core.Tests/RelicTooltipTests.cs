using System.Reflection;
using SpireLens.Core;
using SpireLens.Core.Patches;
using Xunit;

namespace SpireLens.Core.Tests;

public class RelicTooltipTests
{
    private static readonly MethodInfo BuildBodyBBCodeMethod =
        typeof(RelicHoverShowPatch).GetMethod("BuildBodyBBCode", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("BuildBodyBBCode not found.");

    [Fact]
    public void BuildBodyBBCode_RendersLetterOpenerStats()
    {
        var aggregate = new RelicAggregate
        {
            TimesActivated = 2,
            TotalAttemptedDamage = 30,
            TotalTargets = 6,
        };

        var text = (string)(BuildBodyBBCodeMethod.Invoke(null, new object?[] { aggregate })
            ?? throw new InvalidOperationException("BuildBodyBBCode returned null."));

        Assert.Contains("Times activated", text);
        Assert.Contains("[b]2[/b]", text);
        Assert.Contains("Attempted damage", text);
        Assert.Contains("[b]30[/b]", text);
    }

    [Fact]
    public void BuildBodyBBCode_SkipsEmptyAggregate()
    {
        var text = (string)(BuildBodyBBCodeMethod.Invoke(null, new object?[] { new RelicAggregate() })
            ?? throw new InvalidOperationException("BuildBodyBBCode returned null."));

        Assert.Equal("", text);
    }
}
