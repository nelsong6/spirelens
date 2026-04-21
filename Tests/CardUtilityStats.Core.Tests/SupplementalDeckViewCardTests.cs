using System.Reflection;
using System.Runtime.CompilerServices;
using CardUtilityStats.Core;
using MegaCrit.Sts2.Core.Models;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class SupplementalDeckViewCardTests
{
    private const BindingFlags StaticFlags = BindingFlags.Static | BindingFlags.NonPublic;

    [Fact]
    public void RecordSupplementalDeckViewCardGenerated_AssignsStableIdentityToSoulWithoutCreatingStats()
    {
        ResetRunTrackerState();
        var soul = CreateCardModel("CARD.SOUL");

        RunTracker.RecordSupplementalDeckViewCardGenerated(soul);

        Assert.Equal(1, RunTracker.GetInstanceNumber(soul));
        Assert.Null(RunTracker.GetEffectiveAggregate(soul));
        Assert.Equal("Reflects All Soul Usage", RunTracker.GetSupplementalDeckViewTooltipNoteForDefinition("CARD.SOUL"));
    }

    [Fact]
    public void RecordSupplementalDeckViewCardGenerated_AssignsDistinctNumbersAcrossSouls()
    {
        ResetRunTrackerState();
        var firstSoul = CreateCardModel("CARD.SOUL");
        var secondSoul = CreateCardModel("CARD.SOUL");

        RunTracker.RecordSupplementalDeckViewCardGenerated(firstSoul);
        RunTracker.RecordSupplementalDeckViewCardGenerated(secondSoul);

        Assert.Equal(1, RunTracker.GetInstanceNumber(firstSoul));
        Assert.Equal(2, RunTracker.GetInstanceNumber(secondSoul));
    }

    [Fact]
    public void RecordSupplementalDeckViewCardGenerated_IgnoresUntrackedCards()
    {
        ResetRunTrackerState();
        var strike = CreateCardModel("CARD.STRIKE_NECROBINDER");

        RunTracker.RecordSupplementalDeckViewCardGenerated(strike);

        Assert.Equal(0, RunTracker.GetInstanceNumber(strike));
        Assert.Null(RunTracker.GetEffectiveAggregate(strike));
        Assert.Null(RunTracker.GetSupplementalDeckViewTooltipNoteForDefinition("CARD.STRIKE_NECROBINDER"));
    }

    [Fact]
    public void GetSupplementalDeckViewTooltipNoteForDefinition_ReturnsConfiguredNotes()
    {
        Assert.Equal("Reflects All Shiv Usage", RunTracker.GetSupplementalDeckViewTooltipNoteForDefinition("CARD.SHIV"));
        Assert.Equal("Reflects All Soul Usage", RunTracker.GetSupplementalDeckViewTooltipNoteForDefinition("CARD.SOUL"));
    }

    private static void ResetRunTrackerState()
    {
        SetStaticField("_currentRun", null);
        SetStaticField("_pendingCombat", null);
        SetStaticField("_currentPlayerCardPlay", null);
        SetStaticField("_recentCompletedPlayerCardPlay", null);
        SetStaticField("_recentCompletedPlayerCardPlayHistoryCount", 0);
        SetStaticField("_pendingDrawSourceCard", null);
        SetStaticField("_pendingEffectSourceCard", null);
        SetStaticField("_pendingEffectSourceHistoryCount", 0);
        SetStaticField("_pendingPlayerBlockClearAmount", 0);
        SetStaticField("_pendingPlayerBlockClearArmed", false);

        ClearStaticCollection("_pendingPowerChangeAttempts");
        ClearStaticCollection("_instanceNumbers");
        ClearStaticCollection("_defCounters");
        ClearStaticCollection("_supplementalDeckViewAvailableDefinitions");
        ClearStaticCollection("_supplementalDeckViewCards");
    }

    private static void ClearStaticCollection(string fieldName)
    {
        var value = typeof(RunTracker).GetField(fieldName, StaticFlags)?.GetValue(null)
            ?? throw new InvalidOperationException($"RunTracker.{fieldName} not found.");
        value.GetType().GetMethod("Clear", Type.EmptyTypes)?.Invoke(value, null);
    }

    private static void SetStaticField(string fieldName, object? value)
    {
        var field = typeof(RunTracker).GetField(fieldName, StaticFlags)
            ?? throw new InvalidOperationException($"RunTracker.{fieldName} not found.");
        field.SetValue(null, value);
    }

    private static CardModel CreateCardModel(string definitionId)
    {
        var concreteCardType = typeof(CardModel).Assembly.GetTypes()
            .FirstOrDefault(t => typeof(CardModel).IsAssignableFrom(t) && !t.IsAbstract)
            ?? throw new InvalidOperationException("No concrete CardModel subtype found.");
        var card = (CardModel)RuntimeHelpers.GetUninitializedObject(concreteCardType);

        var idField = FindInstanceField(typeof(CardModel), "<Id>k__BackingField")
            ?? throw new InvalidOperationException("CardModel.Id backing field not found.");
        idField.SetValue(card, ModelId.Deserialize(definitionId));

        var keywordsField = FindInstanceField(typeof(CardModel), "_keywords");
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

    private static FieldInfo? FindInstanceField(Type type, string fieldName)
    {
        for (var current = type; current != null; current = current.BaseType)
        {
            var field = current.GetField(fieldName, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
            if (field != null)
                return field;
        }

        return null;
    }
}
