using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Cancel the pending clear attribution when a retain-style effect prevents
/// block from being cleared.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterPreventingBlockClear))]
public static class HookAfterPreventingBlockClearPatch
{
    [HarmonyPostfix]
    public static void Postfix(AbstractModel preventer, Creature creature)
    {
        try
        {
            _ = preventer;
            RunTracker.NotePlayerBlockClearPrevented(creature);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"HookAfterPreventingBlockClearPatch failed: {e.Message}");
        }
    }
}
