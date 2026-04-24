using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Observe the post-mutation pile-change hook so redirected draw attempts can
/// still be counted on the source card while card-specific recurrence only
/// counts real arrivals in Hand. The game can redirect a would-be draw or
/// summon somewhere else without a dedicated veto hook, so we need the final
/// pile result to tell those cases apart.
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
