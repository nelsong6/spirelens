using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Observe every card as it enters the deck, via a postfix on
/// <c>CardPile.AddInternal</c> filtered on <c>Type == Deck</c>.
///
/// This replaces the earlier "walk player.Deck.Cards at RunStarted" approach,
/// which had a timing race: on fresh runs the deck wasn't yet populated when
/// our hook fired, so starters got lazy-assigned later with wrong floor info.
///
/// Hooking AddInternal catches:
///   - Starter-deck population (<c>Player.PopulateStartingDeck</c> →
///     <c>PopulateDeck</c> → <c>Deck.AddInternal(card, -1, silent)</c>)
///   - Ascension curse (<c>AscensionManager</c> adds Ascender's Bane
///     via <c>player.Deck.AddInternal(ascendersBane, ...)</c>)
///   - Reward / shop / event cards (routed through
///     <c>CardPileCmd.Add → pile.AddInternal</c> eventually)
///
/// Whatever floor is appropriate is already set on
/// <c>CardModel.FloorAddedToDeck</c> by the game (Player.cs PopulateStartingDeck
/// sets it to 1 for starters; mid-run adds get the current floor). Our
/// <c>StampArrival</c> reads that field directly.
/// </summary>
[HarmonyPatch(typeof(CardPile), nameof(CardPile.AddInternal))]
public static class CardEnterDeckPatch
{
    [HarmonyPostfix]
    public static void Postfix(CardPile __instance, CardModel card)
    {
        try
        {
            // Filter: only the player's Deck pile. Every other pile type
            // (Hand/Draw/Discard/Exhaust/Play) goes through AddInternal
            // too during combat, and we don't want to treat those as
            // "entered the permanent deck".
            if (__instance.Type != PileType.Deck) return;
            if (card == null) return;

            RunTracker.RecordCardEntered(card);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"CardEnterDeckPatch failed: {e.Message}");
        }
    }
}
