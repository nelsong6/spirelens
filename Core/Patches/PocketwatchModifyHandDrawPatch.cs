using System;
using System.Reflection;
using HarmonyLib;

namespace SpireLens.Core.Patches;

/// <summary>
/// Records additional cards drawn by Pocketwatch's turn-start bonus so the
/// relic tooltip can show the total draw contribution across the run.
///
/// Pocketwatch.ModifyHandDraw returns the modified draw count; when the
/// "played 3 or fewer cards last turn" condition is met the return value
/// exceeds the incoming count by 3. The difference is the relic's bonus.
/// </summary>
[HarmonyPatch]
public static class PocketwatchModifyHandDrawPatch
{
    private static MethodBase? TargetMethod()
    {
        var t = AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Relics.Pocketwatch");
        return t == null ? null : AccessTools.Method(t, "ModifyHandDraw");
    }

    [HarmonyPostfix]
    public static void Postfix(decimal count, decimal __result)
    {
        try
        {
            var added = __result - count;
            if (added <= 0m) return;
            RunTracker.RecordPocketwatchDraw((int)added);
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"PocketwatchModifyHandDrawPatch failed: {e.Message}");
        }
    }
}
