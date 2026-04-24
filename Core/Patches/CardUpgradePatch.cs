using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Capture when a specific card instance gets upgraded mid-run. Every
/// <see cref="CardModel.UpgradeInternal"/> call increments
/// <c>CurrentUpgradeLevel</c> and fires the <c>Upgraded</c> event — we
/// postfix it so we can stamp a "card_upgraded" entry into the run's
/// event log alongside plays and damage.
///
/// Why this matters: some cards get cheaper when upgraded (Defect's
/// Coolheaded goes 1→0, Ironclad's Headbutt drops a cost, etc.). Our
/// energy-spent tracking already captures the post-upgrade cost reduction
/// via <c>Resources.EnergySpent</c>, but the UPGRADE ITSELF is a distinct
/// event — knowing when the upgrade happened (floor, combat count) is
/// useful for understanding the cost curve over a run: "I upgraded my
/// Strike at floor 6, so any play before that counted at full cost."
///
/// Hook scope: any upgrade path routes through <c>UpgradeInternal</c> —
/// rest-site upgrades, in-combat Armaments / Apotheosis, event rewards,
/// all of it. One hook, all upgrade sources covered.
///
/// Canonicalization: the card that gets upgraded might be a combat clone
/// or the deck original; <c>RunTracker.RecordUpgrade</c> resolves to the
/// canonical deck ref just like play and damage attribution, so the event
/// is always attributed to the same instance-id that hover shows.
/// </summary>
[HarmonyPatch(typeof(CardModel), nameof(CardModel.UpgradeInternal))]
public static class CardUpgradePatch
{
    [HarmonyPostfix]
    public static void Postfix(CardModel __instance)
    {
        try
        {
            RunTracker.RecordUpgrade(__instance);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"CardUpgradePatch failed: {e.Message}");
        }
    }
}
