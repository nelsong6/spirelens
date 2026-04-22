using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using CardUtilityStats.Core;
using CardUtilityStats.Core.Patches;
using MegaCrit.Sts2.Core.Combat;
using MegaCrit.Sts2.Core.Combat.History;
using MegaCrit.Sts2.Core.Combat.History.Entries;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Models;
using MegaCrit.Sts2.Core.Models.Powers;
using MegaCrit.Sts2.Core.ValueProps;
using Xunit;

namespace CardUtilityStats.Core.Tests;

[Collection("RunTrackerSerial")]
public class RunTrackerPowerDamageAttributionTests
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

    private static readonly PropertyInfo CombatEventsProperty =
        PendingCombatType.GetProperty("CombatEvents", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("CombatEvents not found.");

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

    private static readonly MethodInfo RecordDamageFromCardMethod =
        typeof(RunTracker).GetMethod("RecordDamageFromCard", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("RecordDamageFromCard not found.");

    private static readonly FieldInfo AbstractModelIdField =
        typeof(AbstractModel).GetField("<Id>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("AbstractModel.Id backing field not found.");

    private static readonly FieldInfo AbstractModelIsMutableField =
        typeof(AbstractModel).GetField("<IsMutable>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("AbstractModel.IsMutable backing field not found.");

    private static readonly FieldInfo PowerModelOwnerField =
        typeof(PowerModel).GetField("_owner", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("PowerModel._owner not found.");

    private static readonly FieldInfo CreaturePlayerField =
        typeof(Creature).GetField("<Player>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("Creature.Player backing field not found.");

    private static readonly MethodInfo ModelDbGetIdMethod =
        typeof(ModelDb).GetMethod(nameof(ModelDb.GetId), BindingFlags.Public | BindingFlags.Static, null, [typeof(Type)], null)
        ?? throw new InvalidOperationException("ModelDb.GetId(Type) not found.");

    private static readonly FieldInfo PowerExecutionSourceTargetMethodNamesField =
        typeof(PowerExecutionSourcePatch).GetField("TargetMethodNames", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("PowerExecutionSourcePatch.TargetMethodNames not found.");

    [Fact]
    public void RecordDamageFromCard_AttributesEnemyDamageFromOwnedPowerSource()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = CreatePendingCombat();
        PendingCombatField.SetValue(null, pendingCombat);
        ResetTrackerState();

        try
        {
            var player = CreatePlayer();
            var playerCreature = CreatePlayerCreature(player);
            var enemy = CreateEnemyCreature();
            var sourcePower = CreatePowerModel(typeof(BlackHolePower), playerCreature);
            var entry = CreateDamageEntry(
                receiver: enemy,
                dealer: playerCreature,
                cardSource: null,
                blockedDamage: 2,
                unblockedDamage: 5,
                overkillDamage: 1,
                killed: true);

            TrackPowerOwnership(sourcePower, "CARD.BLACK_HOLE#1", player);
            _ = PushExecutionSourceMethod.Invoke(null, new object?[] { sourcePower });

            try
            {
                var recorded = (bool)(RecordDamageFromCardMethod.Invoke(null, new object?[] { entry }) ?? false);
                Assert.True(recorded);
            }
            finally
            {
                _ = PopExecutionSourceMethod.Invoke(null, new object?[] { sourcePower });
            }

            var aggregate = Assert.Contains("CARD.BLACK_HOLE#1", GetAggregates(pendingCombat));
            Assert.Equal(8, aggregate.TotalIntended);
            Assert.Equal(2, aggregate.TotalBlocked);
            Assert.Equal(5, aggregate.TotalEffective);
            Assert.Equal(1, aggregate.TotalOverkill);
            Assert.Equal(1, aggregate.Kills);

            var damageEvent = Assert.Single(GetEvents(pendingCombat));
            Assert.Equal("damage_received", damageEvent.Type);
            Assert.Equal("CARD.BLACK_HOLE#1", damageEvent.CardId);
        }
        finally
        {
            ResetTrackerState();
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void RecordDamageFromCard_AttributesSelfDamageFromOwnedPowerSource()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = CreatePendingCombat();
        PendingCombatField.SetValue(null, pendingCombat);
        ResetTrackerState();

        try
        {
            var player = CreatePlayer();
            var playerCreature = CreatePlayerCreature(player);
            var sourcePower = CreatePowerModel(typeof(InfernoPower), playerCreature);
            var entry = CreateDamageEntry(
                receiver: playerCreature,
                dealer: playerCreature,
                cardSource: null,
                blockedDamage: 0,
                unblockedDamage: 3,
                overkillDamage: 0,
                killed: false);

            TrackPowerOwnership(sourcePower, "CARD.INFERNO#1", player);
            _ = PushExecutionSourceMethod.Invoke(null, new object?[] { sourcePower });

            try
            {
                var recorded = (bool)(RecordDamageFromCardMethod.Invoke(null, new object?[] { entry }) ?? false);
                Assert.True(recorded);
            }
            finally
            {
                _ = PopExecutionSourceMethod.Invoke(null, new object?[] { sourcePower });
            }

            var aggregate = Assert.Contains("CARD.INFERNO#1", GetAggregates(pendingCombat));
            Assert.Equal(3, aggregate.TotalHpLost);
            Assert.Equal(0, aggregate.TotalIntended);

            var damageEvent = Assert.Single(GetEvents(pendingCombat));
            Assert.Equal("damage_received", damageEvent.Type);
            Assert.Equal("CARD.INFERNO#1", damageEvent.CardId);
        }
        finally
        {
            ResetTrackerState();
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void RecordDamageFromCard_IgnoresUnownedPowerSources()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = CreatePendingCombat();
        PendingCombatField.SetValue(null, pendingCombat);
        ResetTrackerState();

        try
        {
            var player = CreatePlayer();
            var playerCreature = CreatePlayerCreature(player);
            var enemy = CreateEnemyCreature();
            var sourcePower = CreatePowerModel(typeof(BlackHolePower), playerCreature);
            var entry = CreateDamageEntry(
                receiver: enemy,
                dealer: playerCreature,
                cardSource: null,
                blockedDamage: 0,
                unblockedDamage: 4,
                overkillDamage: 0,
                killed: false);

            _ = PushExecutionSourceMethod.Invoke(null, new object?[] { sourcePower });

            try
            {
                var recorded = (bool)(RecordDamageFromCardMethod.Invoke(null, new object?[] { entry }) ?? false);
                Assert.False(recorded);
            }
            finally
            {
                _ = PopExecutionSourceMethod.Invoke(null, new object?[] { sourcePower });
            }

            Assert.Empty(GetAggregates(pendingCombat));
            Assert.Empty(GetEvents(pendingCombat));
        }
        finally
        {
            ResetTrackerState();
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void PowerExecutionSourcePatch_TargetMethodNames_IncludeDamageHooks()
    {
        var targetMethodNames = Assert.IsAssignableFrom<IEnumerable<string>>(
            PowerExecutionSourceTargetMethodNamesField.GetValue(null));

        Assert.Contains("AfterPlayerTurnStart", targetMethodNames);
        Assert.Contains("AfterStarsGained", targetMethodNames);
        Assert.Contains("AfterCardGeneratedForCombat", targetMethodNames);
        Assert.Contains("AfterTurnEndLate", targetMethodNames);
        Assert.Contains("BeforeTurnEnd", targetMethodNames);
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

    private static IEnumerable<CardEvent> GetEvents(object pendingCombat)
    {
        return (IEnumerable<CardEvent>)(CombatEventsProperty.GetValue(pendingCombat)
            ?? throw new InvalidOperationException("CombatEvents returned null."));
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

    private static Player CreatePlayer()
    {
        return (Player)RuntimeHelpers.GetUninitializedObject(typeof(Player));
    }

    private static Creature CreatePlayerCreature(Player player)
    {
        var creature = (Creature)RuntimeHelpers.GetUninitializedObject(typeof(Creature));
        CreaturePlayerField.SetValue(creature, player);
        return creature;
    }

    private static Creature CreateEnemyCreature()
    {
        return (Creature)RuntimeHelpers.GetUninitializedObject(typeof(Creature));
    }

    private static PowerModel CreatePowerModel(Type powerType, Creature owner)
    {
        var power = (PowerModel)RuntimeHelpers.GetUninitializedObject(powerType);
        InitializeMutableModel(power, powerType);
        PowerModelOwnerField.SetValue(power, owner);
        return power;
    }

    private static DamageReceivedEntry CreateDamageEntry(
        Creature receiver,
        Creature? dealer,
        CardModel? cardSource,
        int blockedDamage,
        int unblockedDamage,
        int overkillDamage,
        bool killed)
    {
        var result = new DamageResult(receiver, default(ValueProp))
        {
            BlockedDamage = blockedDamage,
            UnblockedDamage = unblockedDamage,
            OverkillDamage = overkillDamage,
            WasTargetKilled = killed,
        };

        return new DamageReceivedEntry(
            result,
            receiver,
            dealer,
            cardSource,
            roundNumber: 1,
            currentSide: CombatSide.Player,
            history: (CombatHistory)RuntimeHelpers.GetUninitializedObject(typeof(CombatHistory)));
    }

    private static void InitializeMutableModel(AbstractModel model, Type concreteType)
    {
        var modelId = (ModelId)(ModelDbGetIdMethod.Invoke(null, new object?[] { concreteType })
            ?? throw new InvalidOperationException("ModelDb.GetId returned null."));

        AbstractModelIdField.SetValue(model, modelId);
        AbstractModelIsMutableField.SetValue(model, true);
    }
}
