using System;
using System.Collections.Generic;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Detect when receiver-side power modifiers, specifically Artifact, reduce an
/// attempted debuff to zero. At this point we still know the original
/// requested amount, the target, and the list of modifiers that touched it,
/// which is enough to distinguish "Artifact ate it" from ordinary successful
/// power application.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.ModifyPowerAmountReceived))]
public static class HookModifyPowerAmountReceivedPatch
{
    [HarmonyPostfix]
    public static void Postfix(
        PowerModel canonicalPower,
        Creature target,
        decimal amount,
        Creature? giver,
        ref IEnumerable<AbstractModel>? modifiers,
        decimal __result)
    {
        try
        {
            if (canonicalPower == null || target == null) return;
            RunTracker.RecordArtifactBlockedDebuffAttempt(
                canonicalPower,
                target,
                amount,
                giver,
                modifiers,
                __result);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"HookModifyPowerAmountReceivedPatch failed: {e.Message}");
        }
    }
}
