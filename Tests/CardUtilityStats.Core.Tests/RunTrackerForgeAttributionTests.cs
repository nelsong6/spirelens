using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using CardUtilityStats.Core;
using MegaCrit.Sts2.Core.Models;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class RunTrackerForgeAttributionTests
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

    [Fact]
    public void RecordForgeGranted_AttributesPowerTriggeredForgeToOwningCard()
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
                EffectId = "POWER.FURNACE",
                DisplayName = "Furnace",
            };

            _ = TrackPlayerPowerOwnershipLockedMethod.Invoke(
                null,
                new object?[] { power, "CARD.FURNACE#1", effect });

            RunTracker.RecordForgeGranted(4m, forger: null, source: power);

            var aggregates = (Dictionary<string, CardAggregate>)(CombatAggregatesProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatAggregates returned null."));
            var aggregate = Assert.Contains("CARD.FURNACE#1", aggregates);
            Assert.Equal(4m, aggregate.TotalForgeGenerated);

            var events = (IEnumerable<CardEvent>)(CombatEventsProperty.GetValue(pendingCombat)
                ?? throw new InvalidOperationException("CombatEvents returned null."));
            var forgeEvent = Assert.Single(events);
            Assert.Equal("forge_gained", forgeEvent.Type);
            Assert.Equal("CARD.FURNACE#1", forgeEvent.CardId);
            Assert.Equal(4m, forgeEvent.ForgeGained);
        }
        finally
        {
            PendingCombatField.SetValue(null, previousPendingCombat);
        }
    }

    [Fact]
    public void RecordForgeGranted_IgnoresUnownedPowerSources()
    {
        var previousPendingCombat = PendingCombatField.GetValue(null);
        var pendingCombat = Activator.CreateInstance(PendingCombatType, nonPublic: true)
            ?? throw new InvalidOperationException("Failed to create PendingCombat.");
        PendingCombatField.SetValue(null, pendingCombat);

        try
        {
            var power = CreatePowerModel();

            RunTracker.RecordForgeGranted(4m, forger: null, source: power);

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

    private static PowerModel CreatePowerModel()
    {
        var concretePowerType = typeof(PowerModel).Assembly.GetTypes()
            .FirstOrDefault(type => typeof(PowerModel).IsAssignableFrom(type) && !type.IsAbstract)
            ?? throw new InvalidOperationException("No concrete PowerModel subtype found.");

        return (PowerModel)RuntimeHelpers.GetUninitializedObject(concretePowerType);
    }
}
