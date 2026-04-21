using HarmonyLib;
using MegaCrit.Sts2.Core.Models.Powers;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Arms a short-lived attribution window for the passive poison applications
/// emitted by Noxious Fumes at turn start. The ensuing Poison power receives
/// do not carry a card source, so we map them back to the stacked Noxious
/// Fumes source ledger while this window is active.
/// </summary>
[HarmonyPatch(typeof(NoxiousFumesPower), nameof(NoxiousFumesPower.AfterSideTurnStart))]
public static class NoxiousFumesAfterSideTurnStartPatch
{
    [HarmonyPrefix]
    public static void Prefix(NoxiousFumesPower __instance)
    {
        try
        {
            RunTracker.NoteNoxiousFumesTick(__instance);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"NoxiousFumesAfterSideTurnStartPatch failed: {e.Message}");
        }
    }
}
