using System;
using System.Reflection;
using HarmonyLib;
using MegaCrit.Sts2.Core.Combat;

namespace SpireLens.Core.Patches;

/// <summary>
/// Records Akabeko's combat-start Vigor gain so the relic tooltip can show
/// total Vigor gained across the run.
/// </summary>
[HarmonyPatch]
public static class AkabekoBeforeSideTurnStartPatch
{
    private const int VigorAmount = 8;

    private static MethodBase? TargetMethod()
    {
        var t = AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Relics.Akabeko");
        return t == null ? null : AccessTools.Method(t, "BeforeSideTurnStart");
    }

    [HarmonyPostfix]
    public static void Postfix(CombatSide side, ICombatState combatState)
    {
        try
        {
            if (side != CombatSide.Player) return;
            if (combatState == null) return;
            if (combatState.RoundNumber != 1) return;

            RunTracker.RecordAkabekoVigorGained(VigorAmount);
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"AkabekoBeforeSideTurnStartPatch failed: {e.Message}");
        }
    }
}
