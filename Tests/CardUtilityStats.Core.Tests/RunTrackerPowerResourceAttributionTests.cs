using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using CardUtilityStats.Core;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Models;
using Xunit;

namespace CardUtilityStats.Core.Tests;

[Collection("RunTrackerSerial")]
public class RunTrackerPowerResourceAttributionTests
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

    private static readonly MethodInfo TrackPlayerPowerOwnershipLockedMethod =
        typeof(RunTracker).GetMethod("TrackPlayerPowerOwnershipLocked", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("TrackPlayerPowerOwnershipLocked not found.");

    private static readonly MethodInfo PushExecutionSourceMethod =
        typeof(RunTracker).GetMethod("PushExecutionSource", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("PushExecutionSource not found.");

    private static readonly MethodInfo PopExecutionSourceMethod =
        typeof(RunTracker).GetMethod("PopExecutionSource", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("PopExecutionSource not found.");

    [Fact]
    public void RecordEnergyGained_AttributesOwnedPowerSourceToTheApplyingCard()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = Activator.CreateInstance(PendingCombatType, nonPublic: true)
            ?? throw new InvalidOperationException("Failed to create PendingCombat.");
        PendingCombatField.SetValue(null, pendingCombat);

        try
        {
            var power = CreatePowerModel();
            var effect = new AppliedEffectAggregate
            {
                EffectId = "POWER.ENERGY_NEXT_TURN",
                DisplayName = "Energy Next Turn",
            };

            _ = TrackPlayerPowerOwnershipLockedMethod.Invoke(
                null,
                new object?[] { power, "CARD.OUTMANEUVER#1", effect, null });
            _ = PushExecutionSourceMethod.Invoke(null, new object?[] { power });

            try
            {
                RunTracker.RecordEnergyGained(CreatePlayerCombatState(), 2);
            }
            finally
            {
                _ = PopExecutionSourceMethod.Invoke(null, new object?[] { power });
            }

            var aggregates = (Dictionary<string, CardAggregate>)(CombatAggregatesProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatAggregates returned null."));
            var aggregate = Assert.Contains("CARD.OUTMANEUVER#1", aggregates);
            Assert.Equal(2, aggregate.TotalEnergyGenerated);

            var events = (IEnumerable<CardEvent>)(CombatEventsProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatEvents returned null."));
            var energyEvent = Assert.Single(events);
            Assert.Equal("energy_gained", energyEvent.Type);
            Assert.Equal("CARD.OUTMANEUVER#1", energyEvent.CardId);
            Assert.Equal(2, energyEvent.EnergyGained);
        }
        finally
        {
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void RecordStarsGained_AttributesOwnedPowerSourceToTheApplyingCard()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = Activator.CreateInstance(PendingCombatType, nonPublic: true)
            ?? throw new InvalidOperationException("Failed to create PendingCombat.");
        PendingCombatField.SetValue(null, pendingCombat);

        try
        {
            var power = CreatePowerModel();
            var effect = new AppliedEffectAggregate
            {
                EffectId = "POWER.STAR_NEXT_TURN",
                DisplayName = "Star Next Turn",
            };

            _ = TrackPlayerPowerOwnershipLockedMethod.Invoke(
                null,
                new object?[] { power, "CARD.HIDDEN_CACHE#1", effect, null });
            _ = PushExecutionSourceMethod.Invoke(null, new object?[] { power });

            try
            {
                RunTracker.RecordStarsGained(CreatePlayerCombatState(), 3);
            }
            finally
            {
                _ = PopExecutionSourceMethod.Invoke(null, new object?[] { power });
            }

            var aggregates = (Dictionary<string, CardAggregate>)(CombatAggregatesProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatAggregates returned null."));
            var aggregate = Assert.Contains("CARD.HIDDEN_CACHE#1", aggregates);
            Assert.Equal(3, aggregate.TotalStarsGenerated);

            var events = (IEnumerable<CardEvent>)(CombatEventsProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatEvents returned null."));
            var starsEvent = Assert.Single(events);
            Assert.Equal("stars_gained", starsEvent.Type);
            Assert.Equal("CARD.HIDDEN_CACHE#1", starsEvent.CardId);
            Assert.Equal(3, starsEvent.StarsGained);
        }
        finally
        {
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void RecordEnergyGained_IgnoresUnownedPowerSources()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = Activator.CreateInstance(PendingCombatType, nonPublic: true)
            ?? throw new InvalidOperationException("Failed to create PendingCombat.");
        PendingCombatField.SetValue(null, pendingCombat);

        try
        {
            var power = CreatePowerModel();

            _ = PushExecutionSourceMethod.Invoke(null, new object?[] { power });

            try
            {
                RunTracker.RecordEnergyGained(CreatePlayerCombatState(), 2);
            }
            finally
            {
                _ = PopExecutionSourceMethod.Invoke(null, new object?[] { power });
            }

            var aggregates = (Dictionary<string, CardAggregate>)(CombatAggregatesProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatAggregates returned null."));
            var events = (IEnumerable<CardEvent>)(CombatEventsProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatEvents returned null."));

            Assert.Empty(aggregates);
            Assert.Empty(events);
        }
        finally
        {
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    private static PlayerCombatState CreatePlayerCombatState()
    {
        return (PlayerCombatState)RuntimeHelpers.GetUninitializedObject(typeof(PlayerCombatState));
    }

    private static PowerModel CreatePowerModel()
    {
        var concretePowerType = typeof(PowerModel).Assembly.GetTypes()
            .FirstOrDefault(type => typeof(PowerModel).IsAssignableFrom(type) && !type.IsAbstract)
            ?? throw new InvalidOperationException("No concrete PowerModel subtype found.");

        return (PowerModel)RuntimeHelpers.GetUninitializedObject(concretePowerType);
    }
}
