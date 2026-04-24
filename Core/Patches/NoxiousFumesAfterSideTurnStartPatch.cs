using System;
using System.Reflection;
using HarmonyLib;

namespace SpireLens.Core.Patches;

/// <summary>
/// Arm a short-lived attribution window right as Noxious Fumes begins its
/// turn-start tick. The ensuing poison applications do not carry a card
/// source, so this hook lets the tracker route them back through the live
/// Noxious Fumes effect source before the normal poison ledger takes over.
/// </summary>
[HarmonyPatch]
public static class NoxiousFumesAfterSideTurnStartPatch
{
    private static MethodBase? TargetMethod()
    {
        var noxiousFumesType = AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Powers.NoxiousFumesPower");
        return noxiousFumesType == null ? null : AccessTools.Method(noxiousFumesType, "AfterSideTurnStart");
    }

    [HarmonyPrefix]
    public static void Prefix(object __instance)
    {
        try
        {
            if (__instance != null)
                RunTracker.NoteNoxiousFumesTick(__instance);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"NoxiousFumesAfterSideTurnStartPatch failed: {e.Message}");
        }
    }
}
