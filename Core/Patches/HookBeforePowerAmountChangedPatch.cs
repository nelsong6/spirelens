using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Capture the full source context for an incoming power application BEFORE
/// receiver-side modifiers like Artifact adjust the amount. The follow-up
/// postfix on <see cref="Hook.ModifyPowerAmountReceived"/> can then decide
/// whether the attempt was fully blocked and still credit it back to the
/// originating card.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.BeforePowerAmountChanged))]
public static class HookBeforePowerAmountChangedPatch
{
    [HarmonyPrefix]
    public static void Prefix(
        PowerModel power,
        decimal amount,
        Creature target,
        Creature? applier,
        CardModel? cardSource)
    {
        try
        {
            if (power == null || target == null) return;
            RunTracker.NotePowerAmountChangeAttempt(power, amount, target, applier, cardSource);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"HookBeforePowerAmountChangedPatch failed: {e.Message}");
        }
    }
}
