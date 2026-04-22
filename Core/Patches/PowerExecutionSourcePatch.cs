using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using HarmonyLib;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Preserve the currently-executing power across async hook continuations so
/// delayed follow-on effects can still be credited to the card that applied
/// that power. This now feeds both resource attribution and direct power-
/// driven draw attribution.
/// </summary>
[HarmonyPatch]
public static class PowerExecutionSourcePatch
{
    private static readonly HashSet<string> TargetMethodNames = new(StringComparer.Ordinal)
    {
        "AfterCardDrawn",
        "AfterCardPlayed",
        "AfterCardExhausted",
        "AfterDamageReceived",
        "AfterEnergyReset",
        "AfterEnergySpent",
        "AfterPowerAmountChanged",
        "AfterTurnEnd",
        "BeforeCardPlayed",
    };

    public static IEnumerable<MethodBase> TargetMethods()
    {
        return typeof(PowerModel).Assembly.GetTypes()
            .Where(type => typeof(PowerModel).IsAssignableFrom(type) && !type.IsAbstract)
            .SelectMany(type => type.GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
            .Where(method => !method.IsAbstract && TargetMethodNames.Contains(method.Name))
            .Cast<MethodBase>();
    }

    [HarmonyPrefix]
    public static void Prefix(PowerModel __instance)
    {
        RunTracker.PushExecutionSource(__instance);
    }

    [HarmonyPostfix]
    public static void Postfix(PowerModel __instance)
    {
        RunTracker.PopExecutionSource(__instance);
    }
}
