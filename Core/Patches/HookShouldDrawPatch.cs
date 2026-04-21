using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Hooks;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Capture the likely source card for an upcoming draw attempt before the
/// game actually emits <see cref="Hook.AfterCardDrawn"/>. Some card effects
/// resolve their draw after the play is already marked finished in combat
/// history, which means "currently resolving play" is too late for
/// attribution. <c>Hook.ShouldDraw</c> runs at the start of each draw
/// attempt, while the source context is still adjacent enough to recover.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.ShouldDraw))]
public static class HookShouldDrawPatch
{
    [HarmonyPrefix]
    public static void Prefix(Player player, bool fromHandDraw)
    {
        try
        {
            RunTracker.NoteDrawAttempt(player, fromHandDraw);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookShouldDrawPatch failed: {e.Message}");
        }
    }
}
