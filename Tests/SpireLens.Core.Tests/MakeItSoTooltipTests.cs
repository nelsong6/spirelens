using System.Reflection;
using System.Text;
using SpireLens.Core;
using SpireLens.Core.Patches;
using Xunit;

namespace SpireLens.Core.Tests;

public class MakeItSoTooltipTests
{
    private static readonly MethodInfo AppendMakeItSoStatsMethod =
        typeof(CardHoverShowPatch).GetMethod(
            "AppendMakeItSoStats",
            BindingFlags.NonPublic | BindingFlags.Static,
            binder: null,
            types: new[] { typeof(StringBuilder), typeof(CardAggregate), typeof(bool), typeof(int?), typeof(int) },
            modifiers: null)
        ?? throw new InvalidOperationException("AppendMakeItSoStats overload not found.");

    [Fact]
    public void AppendMakeItSoStats_RendersLiveTriggerProgress()
    {
        var sb = new StringBuilder();

        _ = AppendMakeItSoStatsMethod.Invoke(null, new object?[] { sb, new CardAggregate(), false, 2, 3 });
        var text = sb.ToString();

        Assert.Contains("Skills this turn", text);
        Assert.Contains("[b]2/3[/b]", text);
    }

    [Fact]
    public void AppendMakeItSoStats_FullViewRendersTriggerCount()
    {
        var sb = new StringBuilder();
        var agg = new CardAggregate
        {
            TimesSummonedToHand = 2,
        };

        _ = AppendMakeItSoStatsMethod.Invoke(null, new object?[] { sb, agg, false, null, 0 });
        var text = sb.ToString();

        Assert.Contains("Times triggered", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendMakeItSoStats_CompactViewSkipsTriggerCount()
    {
        var sb = new StringBuilder();
        var agg = new CardAggregate
        {
            TimesSummonedToHand = 2,
        };

        _ = AppendMakeItSoStatsMethod.Invoke(null, new object?[] { sb, agg, true, null, 0 });
        var text = sb.ToString();

        Assert.DoesNotContain("Times triggered", text);
    }
}
