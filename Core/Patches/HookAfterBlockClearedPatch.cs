using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Hooks;

namespace SpireLens.Core.Patches;

/// <summary>
/// Attribute block that vanished unused when the player's block pool is
/// explicitly cleared.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterBlockCleared))]
public static class HookAfterBlockClearedPatch
{
    [HarmonyPostfix]
    public static void Postfix(Creature creature)
    {
        try
        {
            RunTracker.NotePlayerBlockCleared(creature);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"HookAfterBlockClearedPatch failed: {e.Message}");
        }
    }
}
