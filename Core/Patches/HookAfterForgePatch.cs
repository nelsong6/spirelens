using HarmonyLib;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Preserve the originating card across Forge resolution so any immediate
/// follow-up draws can still be credited back to that card. This covers
/// cards like Spoils of Battle where Forge resolves in between the play
/// and the subsequent draw effect.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterForge))]
public static class HookAfterForgePatch
{
    [HarmonyPostfix]
    public static void Postfix(AbstractModel source)
    {
        try
        {
            RunTracker.NoteEffectSource(source);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookAfterForgePatch failed: {e.Message}");
        }
    }
}
