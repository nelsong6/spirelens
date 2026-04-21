using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Players;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Track direct card-driven star gain by patching the player's actual
/// <c>GainStars</c> mutation point. We capture the before/after pool so the
/// recorded amount is the REAL delta applied to the player, not just the
/// requested input amount.
/// </summary>
[HarmonyPatch(typeof(PlayerCombatState), nameof(PlayerCombatState.GainStars))]
public static class PlayerGainStarsPatch
{
    [HarmonyPrefix]
    public static void Prefix(PlayerCombatState __instance, out int __state)
    {
        __state = __instance.Stars;
    }

    [HarmonyPostfix]
    public static void Postfix(PlayerCombatState __instance, int __state)
    {
        try
        {
            int gained = __instance.Stars - __state;
            if (gained > 0) RunTracker.RecordStarsGained(__instance, gained);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PlayerGainStarsPatch failed: {e.Message}");
        }
    }
}
