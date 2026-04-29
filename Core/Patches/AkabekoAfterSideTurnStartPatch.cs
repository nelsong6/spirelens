using System;
using System.Reflection;
using HarmonyLib;
using MegaCrit.Sts2.Core.Combat;
using MegaCrit.Sts2.Core.Models.Relics;

namespace SpireLens.Core.Patches;

/// <summary>
/// Records Akabeko's combat-start Vigor gain so the relic tooltip can show
/// total Vigor gained across the run.
/// </summary>
[HarmonyPatch]
public static class AkabekoAfterSideTurnStartPatch
{
    private static MethodBase? TargetMethod()
    {
        var t = AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Relics.Akabeko");
        return t == null ? null : AccessTools.Method(t, "AfterSideTurnStart");
    }

    [HarmonyPostfix]
    public static void Postfix(Akabeko __instance, CombatSide side, ICombatState combatState)
    {
        try
        {
            if (side != CombatSide.Player) return;
            if (combatState == null) return;
            if (combatState.RoundNumber != 1) return;

            int vigorAmount = __instance.DynamicVars["VigorPower"]?.IntValue ?? 8;
            RunTracker.RecordAkabekoVigorGained(vigorAmount);
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"AkabekoAfterSideTurnStartPatch failed: {e.Message}");
        }
    }
}
