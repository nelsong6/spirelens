using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Hooks;

namespace SpireLens.Core.Patches;

/// <summary>
/// Captures player block gains that occur while the Orichalcum attribution
/// window is armed, attributing them to the relic's end-of-turn effect.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterBlockGained))]
public static class HookAfterBlockGainedPatch
{
    [HarmonyPostfix]
    public static void Postfix(Creature creature, decimal amount)
    {
        try
        {
            if (creature == null || !creature.IsPlayer) return;
            RunTracker.RecordOrichalcumBlockGained((int)amount);
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"HookAfterBlockGainedPatch failed: {e.Message}");
        }
    }
}
