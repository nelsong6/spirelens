using HarmonyLib;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Primary hook for per-card draw attribution. Deliberately NOT on
/// <c>CombatHistory.CardDrawn</c> or the generic <c>CombatHistory.Add</c>
/// because the JIT inlines <c>CombatHistory.CardDrawn</c> (it's a two-line
/// wrapper), which bypasses Harmony patches at that call site. Diagnostic
/// runs proved this: the shadow hook on <c>CardDrawn</c> never fired and
/// <c>CardDrawnEntry</c> never appeared in <c>Observe</c>'s type-count
/// distribution, even during combats with confirmed draws.
///
/// <see cref="Hook.AfterCardDrawn"/> is the next step in the same draw
/// loop — it iterates every game model and calls their
/// <c>AfterCardDrawnEarly</c> / <c>AfterCardDrawn</c> virtuals. That
/// iteration is substantive enough the JIT won't inline it, so our patch
/// lands reliably. It's also async but with no complex return value we
/// care about — a prefix is enough since by the time Hook.AfterCardDrawn
/// is invoked, the card is already in the hand pile.
///
/// Signature: <c>Hook.AfterCardDrawn(CombatState, PlayerChoiceContext, CardModel, bool)</c>.
/// We pull <c>card</c> and <c>fromHandDraw</c> and forward to the tracker.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterCardDrawn))]
public static class HookAfterCardDrawnPatch
{
    [HarmonyPrefix]
    public static void Prefix(CardModel card, bool fromHandDraw)
    {
        try
        {
            if (card == null) return;
            RunTracker.RecordDrawFromCard(card, fromHandDraw);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookAfterCardDrawnPatch failed: {e.Message}");
        }
    }
}
