using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Players;

namespace SpireLens.Core.Patches;

/// <summary>
/// Track direct card-driven energy gain by patching the player's actual
/// <c>GainEnergy</c> mutation point. We capture the before/after pool so the
/// recorded amount is the REAL delta applied to the player, not just the
/// requested input amount.
///
/// Attribution is delegated to <see cref="RunTracker.RecordEnergyGained"/>,
/// which only records the gain if a card play is currently resolving and the
/// gaining PlayerCombatState belongs to that card's owner.
/// </summary>
[HarmonyPatch(typeof(PlayerCombatState), nameof(PlayerCombatState.GainEnergy))]
public static class PlayerGainEnergyPatch
{
    [HarmonyPrefix]
    public static void Prefix(PlayerCombatState __instance, out int __state)
    {
        __state = __instance.Energy;
    }

    [HarmonyPostfix]
    public static void Postfix(PlayerCombatState __instance, int __state)
    {
        try
        {
            int gained = __instance.Energy - __state;
            if (gained > 0) RunTracker.RecordEnergyGained(__instance, gained);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PlayerGainEnergyPatch failed: {e.Message}");
        }
    }
}
