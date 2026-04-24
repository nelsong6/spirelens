using System;
using System.Reflection;
using HarmonyLib;

namespace SpireLens.Core.Patches;

/// <summary>
/// Arm a one-shot attribution window right as Poison begins its start-of-turn
/// tick for a creature. The resulting DamageReceivedEntry often arrives with
/// CardSource=null, so we need this hook to recognize the next null-source hit
/// on that creature as poison instead of generic anonymous damage.
/// </summary>
[HarmonyPatch]
public static class PoisonPowerAfterSideTurnStartPatch
{
    private static MethodBase? TargetMethod()
    {
        var poisonType = AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Powers.PoisonPower");
        return poisonType == null ? null : AccessTools.Method(poisonType, "AfterSideTurnStart");
    }

    [HarmonyPrefix]
    public static void Prefix(object __instance)
    {
        try
        {
            if (__instance != null)
                RunTracker.NotePoisonTickStarting(__instance);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PoisonPowerAfterSideTurnStartPatch failed: {e.Message}");
        }
    }
}
