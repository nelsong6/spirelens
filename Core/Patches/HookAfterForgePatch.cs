using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Track forge granted by the originating card, preserve that source across
/// Forge resolution so immediate follow-up effects can still be credited back
/// correctly, and mark the deck-level Sovereign Blade overlay once Forge has
/// fired for the run.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterForge))]
public static class HookAfterForgePatch
{
    [HarmonyPostfix]
    public static void Postfix(decimal amount, Player forger, AbstractModel? source)
    {
        try
        {
            RunTracker.RecordForgeGranted(amount, forger, source);
            RunTracker.RecordSovereignBladeForged();
            RunTracker.NoteEffectSource(source);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookAfterForgePatch failed: {e.Message}");
        }
    }
}
