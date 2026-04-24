using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using SpireLens.Core;
using SpireLens.Core.Patches;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Models;
using Xunit;

namespace SpireLens.Core.Tests;

public class BlockTooltipTests
{
    private static readonly MethodInfo GetBlockStatLabelMethod =
        typeof(CardHoverShowPatch).GetMethod("GetBlockStatLabel", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("GetBlockStatLabel not found.");

    private static readonly MethodInfo GetDrawStatLabelMethod =
        typeof(CardHoverShowPatch).GetMethod("GetDrawStatLabel", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("GetDrawStatLabel not found.");

    private static readonly MethodInfo GetEnergyStatLabelMethod =
        typeof(CardHoverShowPatch).GetMethod("GetEnergyStatLabel", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("GetEnergyStatLabel not found.");

    private static readonly MethodInfo GetStarStatLabelMethod =
        typeof(CardHoverShowPatch).GetMethod("GetStarStatLabel", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("GetStarStatLabel not found.");

    private static readonly MethodInfo GetForgeStatLabelMethod =
        typeof(CardHoverShowPatch).GetMethod("GetForgeStatLabel", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("GetForgeStatLabel not found.");

    private static readonly MethodInfo AppendCompactBodyMethod =
        typeof(CardHoverShowPatch).GetMethod("AppendCompactBody", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("AppendCompactBody not found.");

    private static readonly MethodInfo AppendCardDrawStatsMethod =
        typeof(CardHoverShowPatch).GetMethod("AppendCardDrawStats", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("AppendCardDrawStats not found.");

    [Fact]
    public void GetBlockStatLabel_UsesShieldIcon()
    {
        var label = (string)(GetBlockStatLabelMethod.Invoke(null, new object?[] { "gained" })
            ?? throw new InvalidOperationException("GetBlockStatLabel returned null."));

        Assert.Equal("[img=16x16]res://images/ui/combat/block.png[/img] gained", label);
    }

    [Fact]
    public void AppendCompactBody_UsesShieldIconForBlockRows()
    {
        var cardModel = CreateCardModel(CardType.Skill);
        var agg = new CardAggregate
        {
            Plays = 2,
            TimesDrawn = 3,
            TotalBlockGained = 9,
        };

        var sb = new StringBuilder();
        _ = AppendCompactBodyMethod.Invoke(null, new object?[] { sb, cardModel, agg });
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/ui/combat/block.png[/img] gained", text);
        Assert.Contains("[b]9[/b]", text);
    }

    [Fact]
    public void GetDrawStatLabel_UsesDrawCardsNextTurnPowerIcon()
    {
        var label = (string)(GetDrawStatLabelMethod.Invoke(null, new object?[] { "cards drawn" })
            ?? throw new InvalidOperationException("GetDrawStatLabel returned null."));

        Assert.Equal("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] cards drawn", label);
    }

    [Fact]
    public void GetDrawStatLabel_UsesDrawCardsNextTurnPowerIconForBlockedRows()
    {
        var label = (string)(GetDrawStatLabelMethod.Invoke(null, new object?[] { "draws blocked" })
            ?? throw new InvalidOperationException("GetDrawStatLabel returned null."));

        Assert.Equal("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] draws blocked", label);
    }

    [Fact]
    public void GetDrawStatLabel_UsesDrawCardsNextTurnPowerIconForAttemptedRows()
    {
        var label = (string)(GetDrawStatLabelMethod.Invoke(null, new object?[] { "drawn / tried" })
            ?? throw new InvalidOperationException("GetDrawStatLabel returned null."));

        Assert.Equal("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] drawn / tried", label);
    }

    [Fact]
    public void GetEnergyStatLabel_UsesEnergyPotionIcon()
    {
        var label = (string)(GetEnergyStatLabelMethod.Invoke(null, new object?[] { "gained" })
            ?? throw new InvalidOperationException("GetEnergyStatLabel returned null."));

        Assert.Equal("[img=16x16]res://images/atlases/potion_atlas.sprites/energy_potion.tres[/img] gained", label);
    }

    [Fact]
    public void GetStarStatLabel_UsesStarIcon()
    {
        var label = (string)(GetStarStatLabelMethod.Invoke(null, new object?[] { "gained" })
            ?? throw new InvalidOperationException("GetStarStatLabel returned null."));

        Assert.Equal("[img=16x16]res://images/packed/sprite_fonts/star_icon.png[/img] gained", label);
    }

    [Fact]
    public void GetForgeStatLabel_UsesQuietTextLabel()
    {
        var label = (string)(GetForgeStatLabelMethod.Invoke(null, new object?[] { "gained" })
            ?? throw new InvalidOperationException("GetForgeStatLabel returned null."));

        Assert.Equal("Forge gained", label);
    }

    [Fact]
    public void AppendCompactBody_UsesDrawPowerIconForUnplayableDrawRows()
    {
        var cardModel = CreateCardModel(CardType.Curse);
        var agg = new CardAggregate
        {
            TimesDrawn = 4,
        };

        var sb = new StringBuilder();
        _ = AppendCompactBodyMethod.Invoke(null, new object?[] { sb, cardModel, agg });
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] drawn", text);
        Assert.Contains("[b]4[/b]", text);
    }

    [Fact]
    public void AppendCompactBody_UsesEnergyPotionIconForEnergyRows()
    {
        var cardModel = CreateCardModel(CardType.Skill);
        var agg = new CardAggregate
        {
            Plays = 2,
            TimesDrawn = 3,
            TotalEnergyGenerated = 2,
        };

        var sb = new StringBuilder();
        _ = AppendCompactBodyMethod.Invoke(null, new object?[] { sb, cardModel, agg });
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/potion_atlas.sprites/energy_potion.tres[/img] gained", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendCompactBody_UsesStarIconForStarRows()
    {
        var cardModel = CreateCardModel(CardType.Skill);
        var agg = new CardAggregate
        {
            Plays = 2,
            TimesDrawn = 3,
            TotalStarsGenerated = 2,
        };

        var sb = new StringBuilder();
        _ = AppendCompactBodyMethod.Invoke(null, new object?[] { sb, cardModel, agg });
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/packed/sprite_fonts/star_icon.png[/img] gained", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendCompactBody_UsesQuietTextForForgeRows()
    {
        var cardModel = CreateCardModel(CardType.Skill);
        var agg = new CardAggregate
        {
            Plays = 2,
            TimesDrawn = 3,
            TotalForgeGenerated = 6m,
        };

        var sb = new StringBuilder();
        _ = AppendCompactBodyMethod.Invoke(null, new object?[] { sb, cardModel, agg });
        var text = sb.ToString();

        Assert.Contains("Forge gained", text);
        Assert.DoesNotContain("[img=16x16]", text);
        Assert.Contains("[b]6[/b]", text);
    }

    [Fact]
    public void AppendCardDrawStats_ShowsActualVersusAttemptedWhenGapExists()
    {
        var agg = new CardAggregate
        {
            TimesCardsDrawn = 1,
            TimesCardsDrawAttempted = 3,
            BlockedDrawReasons =
            {
                ["effect:POWER.NO_DRAW"] = new BlockedDrawReasonAggregate
                {
                    ReasonId = "effect:POWER.NO_DRAW",
                    DisplayName = "No Draw",
                    Count = 2,
                }
            }
        };

        var sb = new StringBuilder();
        _ = AppendCardDrawStatsMethod.Invoke(null, new object?[] { sb, agg });
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] drawn / tried", text);
        Assert.Contains("[b]1/3[/b]", text);
        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] blocked by No Draw", text);
        Assert.Contains("[b]2[/b]", text);
    }

    [Fact]
    public void AppendCardDrawStats_FallsBackToLegacyBlockedGapWhenAttemptedIsMissing()
    {
        var agg = new CardAggregate
        {
            TimesCardsDrawn = 0,
            TimesCardsDrawBlocked = 3,
        };

        var sb = new StringBuilder();
        _ = AppendCardDrawStatsMethod.Invoke(null, new object?[] { sb, agg });
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] drawn / tried", text);
        Assert.Contains("[b]0/3[/b]", text);
        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] blocked by other", text);
    }

    [Fact]
    public void AppendCardDrawStats_ShowsHandFullReasonWhenCategorized()
    {
        var agg = new CardAggregate
        {
            TimesCardsDrawn = 1,
            TimesCardsDrawAttempted = 3,
            BlockedDrawReasons =
            {
                ["full_hand"] = new BlockedDrawReasonAggregate
                {
                    ReasonId = "full_hand",
                    DisplayName = "hand full",
                    Count = 2,
                }
            }
        };

        var sb = new StringBuilder();
        _ = AppendCardDrawStatsMethod.Invoke(null, new object?[] { sb, agg });
        var text = sb.ToString();

        Assert.Contains("[img=16x16]res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres[/img] blocked by hand full", text);
        Assert.Contains("[b]2[/b]", text);
    }
    private static CardModel CreateCardModel(CardType type)
    {
        var concreteCardType = typeof(CardModel).Assembly.GetTypes()
            .FirstOrDefault(t => typeof(CardModel).IsAssignableFrom(t) && !t.IsAbstract)
            ?? throw new InvalidOperationException("No concrete CardModel subtype found.");
        var card = (CardModel)RuntimeHelpers.GetUninitializedObject(concreteCardType);

        var typeField = typeof(CardModel).GetField("<Type>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("CardModel.Type backing field not found.");
        typeField.SetValue(card, type);

        var keywordsField = typeof(CardModel).GetField("_keywords", BindingFlags.Instance | BindingFlags.NonPublic);
        if (keywordsField != null && keywordsField.GetValue(card) == null)
        {
            object? emptyKeywords = keywordsField.FieldType.IsArray
                ? Array.CreateInstance(keywordsField.FieldType.GetElementType()
                    ?? throw new InvalidOperationException("Keywords element type not found."), 0)
                : Activator.CreateInstance(keywordsField.FieldType);

            if (emptyKeywords != null)
                keywordsField.SetValue(card, emptyKeywords);
        }

        return card;
    }
}
