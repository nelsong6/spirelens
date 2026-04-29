using System;
using System.Reflection;
using HarmonyLib;
using MegaCrit.Sts2.Core.Combat;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Hooks;
using MegaCrit.Sts2.Core.Models;

namespace SpireLens.Core.Patches;

/// <summary>
/// Arms the Akabeko Vigor attribution window at the start of each combat
/// (round 1, player side). The ensuing VigorPower application is captured
/// by <see cref="HookBeforePowerAmountChangedAkabekoPatch"/>.
/// </summary>
[HarmonyPatch]
public static class AkabekoAfterSideTurnStartPatch
{
    private static MethodBase? TargetMethod()
    {
        var t = AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Relics.Akabeko");
        return t == null ? null : AccessTools.Method(t, "AfterSideTurnStart");
    }

    [HarmonyPrefix]
    public static void Prefix(CombatSide side, ICombatState combatState)
    {
        try
        {
            if (side != CombatSide.Player) return;
            if (combatState?.RoundNumber != 1) return;
            RunTracker.ArmAkabekoVigorAttribution();
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"AkabekoAfterSideTurnStartPatch.Prefix failed: {e.Message}");
        }
    }
}

/// <summary>
/// Records player VigorPower gains while the Akabeko attribution window is
/// armed, attributing them to the relic's combat-start effect.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.BeforePowerAmountChanged))]
public static class HookBeforePowerAmountChangedAkabekoPatch
{
    private static readonly Type? VigorPowerType =
        AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Powers.VigorPower");

    [HarmonyPostfix]
    public static void Postfix(PowerModel power, decimal amount, Creature target)
    {
        try
        {
            if (VigorPowerType == null) return;
            if (target == null || !target.IsPlayer) return;
            if (amount <= 0) return;
            if (!VigorPowerType.IsInstanceOfType(power)) return;
            RunTracker.RecordAkabekoVigorGained((int)amount);
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"HookBeforePowerAmountChangedAkabekoPatch failed: {e.Message}");
        }
    }
}
