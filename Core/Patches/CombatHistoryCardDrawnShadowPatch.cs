using HarmonyLib;
using MegaCrit.Sts2.Core.Combat.History;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Diagnostic-only shadow hook on <c>CombatHistory.CardDrawn</c>. Paired
/// with the generic <see cref="CombatHistoryAddPatch"/> to answer: does
/// the draw method fire but somehow fail to route through <c>Add</c>?
///
/// If the log shows <c>[CUS-shadow] CardDrawn...</c> lines but no matching
/// <c>[CUS-diag] Observe #.. CardDrawnEntry</c> lines, then <c>Add</c>'s
/// postfix is being silently skipped for draws — either Harmony's pattern
/// matching missed the inner \`Add\` call because it's inlined, or there's
/// a different code path. Either way, this shadow hook is an independent
/// backup channel. We can make it the primary path in a follow-up if
/// <c>Add</c> proves unreliable.
///
/// Intentionally does NOT call RunTracker.RecordCardDrawn — we want to
/// preserve the single-path attribution flow. This is pure logging for
/// now. If we later decide to promote this to the primary draw hook, we'd
/// remove the draw case from the generic switch in Observe.
/// </summary>
[HarmonyPatch(typeof(CombatHistory), nameof(CombatHistory.CardDrawn))]
public static class CombatHistoryCardDrawnShadowPatch
{
    [HarmonyPostfix]
    public static void Postfix(CardModel card, bool fromHandDraw)
    {
        try
        {
            CoreMain.Logger.Info(
                $"[CUS-shadow] CombatHistory.CardDrawn fired card='{card?.Title ?? "null"}' fromHandDraw={fromHandDraw}");
        }
        catch { /* defensive — diagnostic must never crash */ }
    }
}
