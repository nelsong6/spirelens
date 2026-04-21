using System.Reflection;
using System.Text;
using CardUtilityStats.Core;
using CardUtilityStats.Core.Patches;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class PoisonTooltipTests
{
    private static readonly MethodInfo AppendDedicatedPoisonStatsMethod =
        typeof(CardHoverShowPatch).GetMethod("AppendDedicatedPoisonStats", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("AppendDedicatedPoisonStats not found.");

    private static readonly MethodInfo AppendAppliedEffectsMethod =
        typeof(CardHoverShowPatch).GetMethod("AppendAppliedEffects", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("AppendAppliedEffects not found.");

    private static readonly MethodInfo AppendArtifactBlockedSummaryMethod =
        typeof(CardHoverShowPatch).GetMethod("AppendArtifactBlockedSummary", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("AppendArtifactBlockedSummary not found.");

    [Fact]
    public void AppendDedicatedPoisonStats_FullViewCombinesPoisonTotals()
    {
        var agg = new CardAggregate
        {
            Plays = 4,
            TotalPoisonDamageDealt = 7m,
            AppliedEffects =
            {
                ["POWER.POISON"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.POISON",
                    DisplayName = "Poison",
                    TimesApplied = 3,
                    TotalAmountApplied = 9m,
                    TimesBlockedByArtifact = 1,
                    TotalAmountBlockedByArtifact = 2m,
                },
                ["POWER.POISON_SPLASH"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.POISON_SPLASH",
                    DisplayName = "Poison",
                    TimesApplied = 1,
                    TotalAmountApplied = 3m,
                },
                ["POWER.WEAK"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.WEAK",
                    DisplayName = "Weak",
                    TimesApplied = 2,
                    TotalAmountApplied = 4m,
                },
            }
        };

        var sb = new StringBuilder();
        var rendered = AppendDedicatedPoisonStats(sb, agg, compact: false);
        var text = sb.ToString();

        Assert.True(rendered);
        Assert.Contains("Poison applied", text);
        Assert.Contains("Total poison", text);
        Assert.Contains("[b]12[/b]", text);
        Assert.Contains("Avg poison", text);
        Assert.Contains("[b]3[/b]", text);
        Assert.Contains("Applications", text);
        Assert.Contains("[b]4[/b]", text);
        Assert.Contains("Poison damage", text);
        Assert.Contains("[b]7[/b]", text);
        Assert.Contains("Avg poison dmg", text);
        Assert.Contains("[b]1.75[/b]", text);
        Assert.Contains("Blocked by Artifact", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendDedicatedPoisonStats_CompactViewShowsPoisonDamageWhenPresent()
    {
        var agg = new CardAggregate
        {
            TotalPoisonDamageDealt = 5m,
            AppliedEffects =
            {
                ["POWER.POISON"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.POISON",
                    DisplayName = "Poison",
                    TimesApplied = 2,
                    TotalAmountApplied = 6m,
                },
            }
        };

        var sb = new StringBuilder();
        var rendered = AppendDedicatedPoisonStats(sb, agg, compact: true);
        var text = sb.ToString();

        Assert.True(rendered);
        Assert.Contains("Poison applied", text);
        Assert.Contains("Poison damage", text);
        Assert.Contains("[b]5[/b]", text);
    }

    [Fact]
    public void AppendAppliedEffects_ExcludesPoisonWhenDedicatedSectionIsShown()
    {
        var agg = new CardAggregate
        {
            AppliedEffects =
            {
                ["POWER.POISON"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.POISON",
                    DisplayName = "Poison",
                    TimesApplied = 2,
                    TotalAmountApplied = 5m,
                },
                ["POWER.WEAK"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.WEAK",
                    DisplayName = "Weak",
                    TimesApplied = 1,
                    TotalAmountApplied = 2m,
                },
            }
        };

        var sb = new StringBuilder();
        AppendAppliedEffects(sb, agg, compact: false, excludePoison: true);
        var text = sb.ToString();

        Assert.Contains("Effects applied", text);
        Assert.Contains("Weak", text);
        Assert.DoesNotContain("Poison", text);
    }

    [Fact]
    public void AppendArtifactBlockedSummary_ExcludesPoisonWhenDedicatedSectionIsShown()
    {
        var agg = new CardAggregate
        {
            AppliedEffects =
            {
                ["POWER.POISON"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.POISON",
                    DisplayName = "Poison",
                    TimesBlockedByArtifact = 1,
                    TotalAmountBlockedByArtifact = 2m,
                },
                ["POWER.WEAK"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.WEAK",
                    DisplayName = "Weak",
                    TimesBlockedByArtifact = 1,
                    TotalAmountBlockedByArtifact = 1m,
                },
            }
        };

        var sb = new StringBuilder();
        AppendArtifactBlockedSummary(sb, agg, excludePoison: true);
        var text = sb.ToString();

        Assert.Contains("[b]1[/b]", text);
        Assert.DoesNotContain("amt", text);
    }

    private static bool AppendDedicatedPoisonStats(StringBuilder sb, CardAggregate agg, bool compact)
    {
        return (bool)(AppendDedicatedPoisonStatsMethod.Invoke(null, new object?[] { sb, agg, compact })
            ?? throw new InvalidOperationException("AppendDedicatedPoisonStats returned null."));
    }

    private static void AppendAppliedEffects(StringBuilder sb, CardAggregate agg, bool compact, bool excludePoison)
    {
        _ = AppendAppliedEffectsMethod.Invoke(null, new object?[] { sb, agg, compact, excludePoison });
    }

    private static void AppendArtifactBlockedSummary(StringBuilder sb, CardAggregate agg, bool excludePoison)
    {
        _ = AppendArtifactBlockedSummaryMethod.Invoke(null, new object?[] { sb, agg, excludePoison });
    }
}
