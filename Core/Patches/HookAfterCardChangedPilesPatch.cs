using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Observe the post-mutation pile-change hook so card-specific recurrence can
/// count only successful arrivals in Hand, not attempts that got redirected
/// elsewhere by the game (for example because the hand was full).
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterCardChangedPiles))]
public static class HookAfterCardChangedPilesPatch
{
    [HarmonyPrefix]
    public static void Prefix(CardModel card, PileType oldPile)
    {
        try
        {
            if (card == null) return;
            RunTracker.RecordCardChangedPiles(card, oldPile);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"HookAfterCardChangedPilesPatch failed: {e.Message}");
        }
    }
}
