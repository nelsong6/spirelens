using HarmonyLib;
using MegaCrit.Sts2.Core.Models.Powers;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Arms the next unattributed damage event for this creature as a poison tick
/// so downstream poison damage can be charged back through the target's poison
/// source ledger instead of falling on the floor as CardSource=null damage.
/// </summary>
[HarmonyPatch(typeof(PoisonPower), nameof(PoisonPower.AfterSideTurnStart))]
public static class PoisonAfterSideTurnStartPatch
{
    [HarmonyPrefix]
    public static void Prefix(PoisonPower __instance)
    {
        try
        {
            RunTracker.NotePoisonTick(__instance);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"PoisonAfterSideTurnStartPatch failed: {e.Message}");
        }
    }
}
