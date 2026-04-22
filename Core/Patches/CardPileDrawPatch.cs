using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Commands;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.GameActions.Multiplayer;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Flush any unconsumed extra turn-start draw attempts after the game's
/// hand-draw command finishes so they cannot leak into a later draw action.
/// Leftover attempts are recorded as blocked "other" gaps.
/// </summary>
[HarmonyPatch(typeof(CardPileCmd), nameof(CardPileCmd.Draw),
    [typeof(PlayerChoiceContext), typeof(decimal), typeof(Player), typeof(bool)])]
public static class CardPileDrawPatch
{
    [HarmonyPostfix]
    public static void Postfix(Player player, bool fromHandDraw)
    {
        try
        {
            if (!fromHandDraw) return;
            RunTracker.CompletePendingHandDraw(player);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"CardPileDrawPatch failed: {e.Message}");
        }
    }
}
