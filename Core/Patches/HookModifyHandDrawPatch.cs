using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Hooks;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Bracket the game's turn-start hand-draw calculation so individual power
/// modifier patches can report their exact deltas into a single resolution
/// session before the actual hand-draw begins.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.ModifyHandDraw))]
public static class HookModifyHandDrawPatch
{
    [HarmonyPrefix]
    public static void Prefix(Player player)
    {
        try
        {
            RunTracker.BeginHandDrawResolution(player);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookModifyHandDrawPatch failed during prefix: {e.Message}");
        }
    }

    [HarmonyPostfix]
    public static void Postfix(Player player)
    {
        try
        {
            RunTracker.FinalizeHandDrawResolution(player);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookModifyHandDrawPatch failed during postfix: {e.Message}");
        }
    }
}
