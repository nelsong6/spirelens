using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Commands;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Track when a card is moved to the TOP of the draw pile from Hand or
/// Discard. Hooks <c>CardPileCmd.Add(CardModel, PileType, CardPilePosition, ...)</c>
/// as a prefix so we can read the card's current Pile (the SOURCE) before
/// the add mutates it.
///
/// Filtered to:
///   - newPileType == Draw AND position == Top (we only care about on-top placements)
///   - source pile == Hand OR Discard (the two interesting origins per Nelson)
///
/// Other source piles (Exhaust, Play) aren't counted. If that turns out to
/// be useful later we can extend.
/// </summary>
[HarmonyPatch(typeof(CardPileCmd), nameof(CardPileCmd.Add),
    new Type[] { typeof(CardModel), typeof(PileType), typeof(CardPilePosition), typeof(AbstractModel), typeof(bool) })]
public static class CardPlacedOnTopPatch
{
    [HarmonyPrefix]
    public static void Prefix(CardModel card, PileType newPileType, CardPilePosition position)
    {
        try
        {
            if (card == null) return;
            if (newPileType != PileType.Draw) return;
            if (position != CardPilePosition.Top) return;

            var sourcePile = card.Pile?.Type;
            if (sourcePile == PileType.Hand || sourcePile == PileType.Discard)
            {
                RunTracker.RecordPlacedOnTopOfDraw(card, sourcePile.Value);
            }
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"CardPlacedOnTopPatch failed: {e.Message}");
        }
    }
}
