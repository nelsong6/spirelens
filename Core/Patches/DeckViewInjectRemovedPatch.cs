using System;
using System.Linq;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Nodes.Screens;

namespace SpireLens.Core.Patches;

/// <summary>
/// Extend the deck-view display with supplemental cards when our ViewStats
/// checkbox is ticked. Harmony prefix on <c>NDeckViewScreen.DisplayCards</c>
/// mutates the screen's private <c>_cards</c> list (via Publicizer access)
/// to append removed-card refs plus synthetic pooled deck-level meta cards
/// like Shiv and Sovereign Blade before the grid renders them.
///
/// Why prefix not postfix: the grid's <c>SetCards</c> call uses <c>_cards</c>
/// directly as its source. Mutating before the body runs is simpler than
/// trying to re-trigger a render after the fact.
///
/// The appended cards still have valid <c>CardModel</c> refs because
/// <c>CardModel.RemoveFromState</c> only sets <c>HasBeenRemovedFromState</c>
/// (a flag) — it doesn't free the object. The grid renders them normally;
/// the hover tooltip fires via the existing <c>NCardHolder.CreateHoverTips</c>
/// patch and shows our stats including the "Removed floor X" lineage line
/// or the supplemental pooled-card banner for Shiv/Sovereign Blade.
///
/// Gate: only appends if the ViewStats checkbox is currently ticked. If the
/// tickbox isn't injected yet (deck view never opened this session), behaves
/// as if unchecked — removed cards stay hidden. Toggle live-updates via the
/// deck-view re-render wired up in <see cref="ViewStatsInjectorPatch"/>.
/// </summary>
[HarmonyPatch(typeof(NDeckViewScreen), nameof(NDeckViewScreen.DisplayCards))]
public static class DeckViewInjectRemovedPatch
{
    [HarmonyPrefix]
    public static void Prefix(NDeckViewScreen __instance)
    {
        try
        {
            // Reset _cards from the live pile every call. Previously we
            // only APPENDED to _cards when the checkbox was ticked — but
            // untick events also call DisplayCards, and without the reset
            // the previously-appended removed-card refs stayed in the list.
            // Resetting here guarantees clean state every render: the list
            // reflects the current deck plus (if ticked) our supplemental refs.
            //
            // Safe to reset: the grid's sort logic reads _sortingPriority
            // (a separate field on the screen), not the order of _cards.
            __instance._cards = __instance._pile.Cards.ToList();

            RuntimeOptionsProvider.Refresh();
            if (!RuntimeOptionsProvider.Current.ShowRemovedCardsInDeckView) return;

            var tickbox = ViewStatsInjectorPatch.LastInjectedTickbox;
            if (tickbox == null || !tickbox.IsTicked) return;

            var supplemental = RunTracker.GetSupplementalDeckViewCards();
            if (supplemental.Count == 0) return;

            int appended = 0;
            foreach (var card in supplemental)
            {
                if (card != null && !__instance._cards.Contains(card))
                {
                    __instance._cards.Add(card);
                    appended++;
                }
            }

            CoreMain.LogDebug($"DeckViewInject: appended {appended} supplemental cards to deck view");
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"DeckViewInjectRemovedPatch failed: {e.Message}");
        }
    }
}
