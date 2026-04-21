using HarmonyLib;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// Marks supported combat-only pooled deck-view cards (currently Shiv and
/// Soul) as available once the run generates them. We patch the generic
/// generated-card hook so all sources flow through one place.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterCardGeneratedForCombat))]
public static class HookAfterCardGeneratedForCombatPatch
{
    [HarmonyPostfix]
    public static void Postfix(CardModel card)
    {
        try
        {
            RunTracker.RecordSupplementalDeckViewCardGenerated(card);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"HookAfterCardGeneratedForCombatPatch failed: {e.Message}");
        }
    }
}
