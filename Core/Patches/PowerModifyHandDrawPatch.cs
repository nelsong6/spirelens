using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Observe concrete power overrides of <c>ModifyHandDraw</c> so we can record
/// the exact integer draw delta each owned power contributes to the turn-
/// start hand-draw calculation.
/// </summary>
[HarmonyPatch]
public static class PowerModifyHandDrawPatch
{
    public static IEnumerable<MethodBase> TargetMethods()
    {
        return typeof(PowerModel).Assembly.GetTypes()
            .Where(type => typeof(PowerModel).IsAssignableFrom(type) && !type.IsAbstract)
            .Select(type => type.GetMethod(
                nameof(AbstractModel.ModifyHandDraw),
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly,
                binder: null,
                [typeof(Player), typeof(decimal)],
                modifiers: null))
            .Where(method => method != null)
            .Cast<MethodBase>();
    }

    [HarmonyPostfix]
    public static void Postfix(PowerModel __instance, Player player, decimal count, decimal __result)
    {
        try
        {
            RunTracker.RecordHandDrawModification(__instance, player, count, __result);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PowerModifyHandDrawPatch failed: {e.Message}");
        }
    }
}
