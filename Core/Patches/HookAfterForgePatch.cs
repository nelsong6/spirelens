using HarmonyLib;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Preserve the originating card across Forge resolution so any immediate
/// follow-up draws can still be credited back to that card. Also marks the
/// deck-level Sovereign Blade overlay as available for the rest of the run
/// once Forge has fired.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterForge))]
public static class HookAfterForgePatch
{
    [HarmonyPostfix]
    public static void Postfix(AbstractModel source)
    {
        try
        {
            RunTracker.RecordSovereignBladeForged();
            RunTracker.NoteEffectSource(source);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookAfterForgePatch failed: {e.Message}");
        }
    }
}
