using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Track forge granted by the originating card and preserve that source across
/// Forge resolution so immediate follow-up effects can still be credited back
/// correctly. This covers cards like Refine Blade directly, while still
/// preserving the older "forge in between play and draw" attribution fix.
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
            RunTracker.NoteEffectSource(source);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookAfterForgePatch failed: {e.Message}");
        }
    }
}
