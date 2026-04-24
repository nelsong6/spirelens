using System;
using System.Collections.Generic;
using HarmonyLib;
using MegaCrit.Sts2.Core.Commands;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Capture card removals so the aggregate can be flagged as Removed (for
/// the "what did I remove and how was it performing?" deck-view feature).
///
/// Hook surface: <c>CardPileCmd.RemoveFromDeck(IReadOnlyList&lt;CardModel&gt;, bool)</c>
/// — the list-based overload. The single-card overload forwards here, so
/// patching this one catches both call paths.
///
/// Prefix (not postfix): we want to capture the card BEFORE
/// <c>card.RemoveFromCurrentPile()</c> and <c>card.RemoveFromState()</c>
/// run. After those, the card's Pile is no longer Deck and various
/// properties transition — cleaner to read state beforehand.
/// </summary>
[HarmonyPatch(typeof(CardPileCmd), nameof(CardPileCmd.RemoveFromDeck),
    new Type[] { typeof(IReadOnlyList<CardModel>), typeof(bool) })]
public static class CardRemoveFromDeckPatch
{
    [HarmonyPrefix]
    public static void Prefix(IReadOnlyList<CardModel> cards)
    {
        try
        {
            foreach (var card in cards)
            {
                if (card != null) RunTracker.RecordRemoval(card);
            }
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"CardRemoveFromDeckPatch failed: {e.Message}");
        }
    }
}
