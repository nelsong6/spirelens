using HarmonyLib;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Marks the synthetic deck-view Shiv overlay as available once the run has
/// generated its first in-combat Shiv. We patch the generic generated-card
/// hook so all Shiv sources flow through one place.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterCardGeneratedForCombat))]
public static class HookAfterCardGeneratedForCombatPatch
{
    [HarmonyPostfix]
    public static void Postfix(CardModel card)
    {
        try
        {
            RunTracker.RecordShivGenerated(card);
            RunTracker.RecordSovereignBladeGenerated(card);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookAfterCardGeneratedForCombatPatch failed: {e.Message}");
        }
    }
}
