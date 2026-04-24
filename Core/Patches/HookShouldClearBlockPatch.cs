using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Hooks;

namespace SpireLens.Core.Patches;

/// <summary>
/// Capture the player's current block just before the game decides whether
/// it should be cleared. Paired with <see cref="HookAfterBlockClearedPatch"/>
/// and <see cref="HookAfterPreventingBlockClearPatch"/>.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.ShouldClearBlock))]
public static class HookShouldClearBlockPatch
{
    [HarmonyPrefix]
    public static void Prefix(Creature creature)
    {
        try
        {
            RunTracker.NotePotentialPlayerBlockClear(creature);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"HookShouldClearBlockPatch failed: {e.Message}");
        }
    }
}
