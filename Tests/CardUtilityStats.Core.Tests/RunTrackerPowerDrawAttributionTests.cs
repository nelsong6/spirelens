using System.Reflection;
using System.Runtime.CompilerServices;
using CardUtilityStats.Core;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Models;
using MegaCrit.Sts2.Core.Models.Powers;
using Xunit;

namespace CardUtilityStats.Core.Tests;

[Collection("RunTrackerSerial")]
public class RunTrackerPowerDrawAttributionTests
{
    private static readonly FieldInfo PendingCombatField =
        typeof(RunTracker).GetField("_pendingCombat", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("_pendingCombat not found.");

    private static readonly Type PendingCombatType =
        typeof(RunTracker).Assembly.GetType("CardUtilityStats.Core.PendingCombat")
        ?? throw new InvalidOperationException("PendingCombat type not found.");

    private static readonly PropertyInfo CombatAggregatesProperty =
        PendingCombatType.GetProperty("CombatAggregates", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("CombatAggregates not found.");

    private static readonly MethodInfo ResetCombatContextStateMethod =
        typeof(RunTracker).GetMethod("ResetCombatContextState", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("ResetCombatContextState not found.");

    private static readonly MethodInfo TrackPlayerPowerOwnershipLockedMethod =
        typeof(RunTracker).GetMethod("TrackPlayerPowerOwnershipLocked", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("TrackPlayerPowerOwnershipLocked not found.");

    private static readonly MethodInfo PushExecutionSourceMethod =
        typeof(RunTracker).GetMethod("PushExecutionSource", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("PushExecutionSource not found.");

    private static readonly MethodInfo PopExecutionSourceMethod =
        typeof(RunTracker).GetMethod("PopExecutionSource", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("PopExecutionSource not found.");

    private static readonly MethodInfo BeginHandDrawResolutionMethod =
        typeof(RunTracker).GetMethod("BeginHandDrawResolution", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("BeginHandDrawResolution not found.");

    private static readonly MethodInfo RecordHandDrawModificationMethod =
        typeof(RunTracker).GetMethod("RecordHandDrawModification", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("RecordHandDrawModification not found.");

    private static readonly MethodInfo FinalizeHandDrawResolutionMethod =
        typeof(RunTracker).GetMethod("FinalizeHandDrawResolution", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("FinalizeHandDrawResolution not found.");

    private static readonly MethodInfo CompletePendingHandDrawMethod =
        typeof(RunTracker).GetMethod("CompletePendingHandDraw", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("CompletePendingHandDraw not found.");

    private static readonly FieldInfo AbstractModelIdField =
        typeof(AbstractModel).GetField("<Id>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("AbstractModel.Id backing field not found.");

    private static readonly FieldInfo AbstractModelIsMutableField =
        typeof(AbstractModel).GetField("<IsMutable>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("AbstractModel.IsMutable backing field not found.");

    private static readonly FieldInfo CardOwnerField =
        typeof(CardModel).GetField("_owner", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("CardModel._owner not found.");

    private static readonly MethodInfo ModelDbGetIdMethod =
        typeof(ModelDb).GetMethod(nameof(ModelDb.GetId), BindingFlags.Public | BindingFlags.Static, null, [typeof(Type)], null)
        ?? throw new InvalidOperationException("ModelDb.GetId(Type) not found.");

    [Fact]
    public void DirectPowerDraw_AttachesAttemptAndDrawToApplyingCard()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = CreatePendingCombat();
        PendingCombatField.SetValue(null, pendingCombat);
        ResetTrackerState();

        try
        {
            var player = CreatePlayer();
            var power = CreatePowerModel(typeof(DarkEmbracePower));
            var drawnCard = CreateCardModel(player);

            TrackPowerOwnership(power, "CARD.DARK_EMBRACE#1", player);
            _ = PushExecutionSourceMethod.Invoke(null, new object?[] { power });

            try
            {
                RunTracker.NoteDrawAttempt(player, fromHandDraw: false);
                RunTracker.RecordDrawFromCard(drawnCard, fromHandDraw: false);
            }
            finally
            {
                _ = PopExecutionSourceMethod.Invoke(null, new object?[] { power });
            }

            var aggregates = GetAggregates(pendingCombat);
            var sourceAggregate = Assert.Contains("CARD.DARK_EMBRACE#1", aggregates);
            Assert.Equal(1, sourceAggregate.TimesCardsDrawAttempted);
            Assert.Equal(1, sourceAggregate.TimesCardsDrawn);

            var drawnAggregate = Assert.Single(aggregates, kv => kv.Key != "CARD.DARK_EMBRACE#1");
            Assert.Equal(1, drawnAggregate.Value.TimesDrawn);
        }
        finally
        {
            ResetTrackerState();
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void HandDrawPower_AttributesExtraTurnStartDrawsToApplyingCard()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = CreatePendingCombat();
        PendingCombatField.SetValue(null, pendingCombat);
        ResetTrackerState();

        try
        {
            var player = CreatePlayer();
            var power = CreatePowerModel(typeof(MachineLearningPower));

            TrackPowerOwnership(power, "CARD.MACHINE_LEARNING#1", player);
            BeginHandDrawResolution(player);
            RecordHandDrawModification(power, player, 5m, 7m);
            FinalizeHandDrawResolution(player);

            RunTracker.RecordDrawFromCard(CreateCardModel(player), fromHandDraw: true);
            RunTracker.RecordDrawFromCard(CreateCardModel(player), fromHandDraw: true);
            CompletePendingHandDraw(player);

            var sourceAggregate = Assert.Contains("CARD.MACHINE_LEARNING#1", GetAggregates(pendingCombat));
            Assert.Equal(2, sourceAggregate.TimesCardsDrawAttempted);
            Assert.Equal(2, sourceAggregate.TimesCardsDrawn);
            Assert.Equal(0, sourceAggregate.TimesCardsDrawBlocked);
        }
        finally
        {
            ResetTrackerState();
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void HandDrawPower_RecordsBlockedGapWhenLaterModifierCancelsExtraDraw()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = CreatePendingCombat();
        PendingCombatField.SetValue(null, pendingCombat);
        ResetTrackerState();

        try
        {
            var player = CreatePlayer();
            var drawPower = CreatePowerModel(typeof(MachineLearningPower));
            var blocker = CreatePowerModel(typeof(MindRotPower));

            TrackPowerOwnership(drawPower, "CARD.MACHINE_LEARNING#1", player);
            BeginHandDrawResolution(player);
            RecordHandDrawModification(drawPower, player, 5m, 7m);
            RecordHandDrawModification(blocker, player, 7m, 6m);
            FinalizeHandDrawResolution(player);

            RunTracker.RecordDrawFromCard(CreateCardModel(player), fromHandDraw: true);
            CompletePendingHandDraw(player);

            var sourceAggregate = Assert.Contains("CARD.MACHINE_LEARNING#1", GetAggregates(pendingCombat));
            Assert.Equal(2, sourceAggregate.TimesCardsDrawAttempted);
            Assert.Equal(1, sourceAggregate.TimesCardsDrawn);
            Assert.Equal(1, sourceAggregate.TimesCardsDrawBlocked);
            Assert.Single(sourceAggregate.BlockedDrawReasons.Values, reason => reason.Count > 0);
        }
        finally
        {
            ResetTrackerState();
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void HandDrawPower_UsesBlockedDrawHookForTurnStartNoDrawStylePrevention()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = CreatePendingCombat();
        PendingCombatField.SetValue(null, pendingCombat);
        ResetTrackerState();

        try
        {
            var player = CreatePlayer();
            var drawPower = CreatePowerModel(typeof(MachineLearningPower));
            var blocker = CreatePowerModel(typeof(MindRotPower));

            TrackPowerOwnership(drawPower, "CARD.MACHINE_LEARNING#1", player);
            BeginHandDrawResolution(player);
            RecordHandDrawModification(drawPower, player, 5m, 7m);
            FinalizeHandDrawResolution(player);

            RunTracker.RecordBlockedDrawAttempt(player, fromHandDraw: true, blocker);
            CompletePendingHandDraw(player);

            var sourceAggregate = Assert.Contains("CARD.MACHINE_LEARNING#1", GetAggregates(pendingCombat));
            Assert.Equal(2, sourceAggregate.TimesCardsDrawAttempted);
            Assert.Equal(0, sourceAggregate.TimesCardsDrawn);
            Assert.Equal(2, sourceAggregate.TimesCardsDrawBlocked);
            Assert.Equal(2, sourceAggregate.BlockedDrawReasons.Values.Sum(reason => reason.Count));
        }
        finally
        {
            ResetTrackerState();
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    private static object CreatePendingCombat()
    {
        return Activator.CreateInstance(PendingCombatType, nonPublic: true)
            ?? throw new InvalidOperationException("Failed to create PendingCombat.");
    }

    private static Dictionary<string, CardAggregate> GetAggregates(object pendingCombat)
    {
        return (Dictionary<string, CardAggregate>)(CombatAggregatesProperty.GetValue(pendingCombat)
            ?? throw new InvalidOperationException("CombatAggregates returned null."));
    }

    private static void ResetTrackerState()
    {
        _ = ResetCombatContextStateMethod.Invoke(null, null);
    }

    private static void TrackPowerOwnership(PowerModel power, string sourceInstanceId, Player player)
    {
        var effect = new AppliedEffectAggregate
        {
            EffectId = power.Id.ToString(),
            DisplayName = power.Id.Entry,
        };

        _ = TrackPlayerPowerOwnershipLockedMethod.Invoke(
            null,
            new object?[] { power, sourceInstanceId, effect, player });
    }

    private static void BeginHandDrawResolution(Player player)
    {
        _ = BeginHandDrawResolutionMethod.Invoke(null, new object?[] { player });
    }

    private static void RecordHandDrawModification(PowerModel power, Player player, decimal before, decimal after)
    {
        _ = RecordHandDrawModificationMethod.Invoke(null, new object?[] { power, player, before, after });
    }

    private static void FinalizeHandDrawResolution(Player player)
    {
        _ = FinalizeHandDrawResolutionMethod.Invoke(null, new object?[] { player });
    }

    private static void CompletePendingHandDraw(Player player)
    {
        _ = CompletePendingHandDrawMethod.Invoke(null, new object?[] { player });
    }

    private static Player CreatePlayer()
    {
        return (Player)RuntimeHelpers.GetUninitializedObject(typeof(Player));
    }

    private static CardModel CreateCardModel(Player owner)
    {
        var concreteCardType = typeof(CardModel).Assembly.GetTypes()
            .FirstOrDefault(type => typeof(CardModel).IsAssignableFrom(type) && !type.IsAbstract)
            ?? throw new InvalidOperationException("No concrete CardModel subtype found.");

        var card = (CardModel)RuntimeHelpers.GetUninitializedObject(concreteCardType);
        InitializeMutableModel(card, concreteCardType);
        CardOwnerField.SetValue(card, owner);
        return card;
    }

    private static PowerModel CreatePowerModel(Type powerType)
    {
        var power = (PowerModel)RuntimeHelpers.GetUninitializedObject(powerType);
        InitializeMutableModel(power, powerType);
        return power;
    }

    private static void InitializeMutableModel(AbstractModel model, Type concreteType)
    {
        var modelId = (ModelId)(ModelDbGetIdMethod.Invoke(null, new object?[] { concreteType })
            ?? throw new InvalidOperationException("ModelDb.GetId returned null."));

        AbstractModelIdField.SetValue(model, modelId);
        AbstractModelIsMutableField.SetValue(model, true);
    }
}
