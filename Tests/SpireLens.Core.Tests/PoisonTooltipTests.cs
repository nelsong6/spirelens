using System.Reflection;
using System.Text;
using SpireLens.Core;
using SpireLens.Core.Patches;
using Xunit;

namespace SpireLens.Core.Tests;

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
            AppliedEffects =
            {
                ["POWER.POISON"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.POISON",
                    DisplayName = "Poison",
                    IconPath = "res://art/powers/poison.png",
                    TimesApplied = 3,
                    TotalAmountApplied = 9m,
                    TimesBlockedByArtifact = 1,
                    TotalAmountBlockedByArtifact = 2m,
                    TotalTriggeredEffectiveDamage = 8m,
                    TotalTriggeredOverkill = 1m,
                },
                ["POWER.POISON_SPLASH"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.POISON_SPLASH",
                    DisplayName = "Poison",
                    IconPath = "res://art/powers/poison.png",
                    TimesApplied = 1,
                    TotalAmountApplied = 3m,
                    TotalTriggeredEffectiveDamage = 4m,
                    TotalTriggeredOverkill = 1m,
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
        Assert.DoesNotContain("[color=#b5b5b5]Poison applied[/color]", text);
        Assert.Contains("[img=16x16]res://art/powers/poison.png[/img] total applied", text);
        Assert.Contains("[b]12[/b]", text);
        Assert.Contains("avg applied", text);
        Assert.Contains("[b]3[/b]", text);
        Assert.Contains("applications", text);
        Assert.Contains("[b]4[/b]", text);
        Assert.Contains("damage", text);
        Assert.Contains("[b]12[/b]", text);
        Assert.Contains("avg damage", text);
        Assert.Contains("overkill", text);
        Assert.Contains("[b]2[/b]", text);
        Assert.Contains("blocked by Artifact", text);
        Assert.Contains("[b]2[/b]", text);
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

    [Fact]
    public void AppendAppliedEffects_UsesEffectIconForEnergyEffects()
    {
        var agg = new CardAggregate
        {
            AppliedEffects =
            {
                ["POWER.ENERGY_NEXT_TURN"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.ENERGY_NEXT_TURN",
                    DisplayName = "Energy Next Turn",
                    IconPath = "res://images/atlases/power_atlas.sprites/energy_next_turn_power.tres",
                    TimesApplied = 1,
                    TotalAmountApplied = 2m,
                },
            }
        };

        var sb = new StringBuilder();
        AppendAppliedEffects(sb, agg, compact: false, excludePoison: false);
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/energy_next_turn_power.tres[/img] Energy Next Turn", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendAppliedEffects_UsesEffectIconForStarEffects()
    {
        var agg = new CardAggregate
        {
            AppliedEffects =
            {
                ["POWER.STAR_NEXT_TURN"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.STAR_NEXT_TURN",
                    DisplayName = "Star Next Turn",
                    IconPath = "res://images/atlases/power_atlas.sprites/star_next_turn_power.tres",
                    TimesApplied = 1,
                    TotalAmountApplied = 2m,
                },
            }
        };

        var sb = new StringBuilder();
        AppendAppliedEffects(sb, agg, compact: false, excludePoison: false);
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/star_next_turn_power.tres[/img] Star Next Turn", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendAppliedEffects_ShowsDownstreamBlockedDrawsForNoDraw()
    {
        var agg = new CardAggregate
        {
            AppliedEffects =
            {
                ["POWER.NO_DRAW"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.NO_DRAW",
                    DisplayName = "No Draw",
                    IconPath = "res://images/atlases/power_atlas.sprites/no_draw_power.tres",
                    TimesApplied = 1,
                    TotalAmountApplied = 1m,
                    TotalTriggeredCardsDrawBlocked = 2,
                },
            }
        };

        var sb = new StringBuilder();
        AppendAppliedEffects(sb, agg, compact: false, excludePoison: false);
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/no_draw_power.tres[/img] No Draw", text);
        Assert.Contains("[b]1[/b]", text);
        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] cards blocked", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendAppliedEffects_UsesPowerIconForNoxiousFumes()
    {
        var agg = new CardAggregate
        {
            AppliedEffects =
            {
                ["POWER.NOXIOUS_FUMES"] = new AppliedEffectAggregate
                {
                    EffectId = "POWER.NOXIOUS_FUMES",
                    DisplayName = "Noxious Fumes",
                    IconPath = "res://art/powers/noxious_fumes.png",
                    TimesApplied = 1,
                    TotalAmountApplied = 3m,
                },
            }
        };

        var sb = new StringBuilder();
        AppendAppliedEffects(sb, agg, compact: false, excludePoison: false);
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://art/powers/noxious_fumes.png[/img] Noxious Fumes", text);
        Assert.Contains("[b]3[/b]", text);
    }

    [Fact]
    public void AppendDedicatedPoisonStats_CompactViewDoesNotHidePoisonOnlyArtifactBlocks()
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
            }
        };

        var sb = new StringBuilder();
        var rendered = AppendDedicatedPoisonStats(sb, agg, compact: true);
        var text = sb.ToString();

        Assert.False(rendered);
        Assert.DoesNotContain("Poison applied", text);
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
