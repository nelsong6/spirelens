using System;
using System.Reflection;
using HarmonyLib;
using MegaCrit.Sts2.Core.Combat;
using MegaCrit.Sts2.Core.Hooks;

namespace SpireLens.Core.Patches;

/// <summary>
/// Arms the Orichalcum block-gain attribution window just before the relic's
/// end-of-turn check runs. If the player has no block, Orichalcum will gain
/// block and <see cref="HookAfterBlockGainedPatch"/> records the amount.
/// </summary>
[HarmonyPatch]
public static class OrichalcumBeforeTurnEndPatch
{
    private static MethodBase? TargetMethod()
    {
        var t = AccessTools.TypeByName("MegaCrit.Sts2.Core.Models.Relics.Orichalcum");
        return t == null ? null : AccessTools.Method(t, "BeforeTurnEnd");
    }

    [HarmonyPrefix]
    public static void Prefix(CombatSide side)
    {
        try
        {
            if (side != CombatSide.Player) return;
            RunTracker.ArmOrichalcumBlockAttribution();
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"OrichalcumBeforeTurnEndPatch.Prefix failed: {e.Message}");
        }
    }
}

/// <summary>
/// Clears an armed Orichalcum attribution window after the player's
/// end-of-turn hook sequence. Orichalcum's async hook can gain block after
/// the relic method has returned its task, so cleanup cannot live in the
/// relic postfix itself.
/// </summary>
[HarmonyPatch(typeof(Hook), nameof(Hook.AfterTurnEnd))]
public static class HookAfterTurnEndOrichalcumCleanupPatch
{
    [HarmonyPrefix]
    public static void Prefix(CombatSide side)
    {
        try
        {
            if (side != CombatSide.Player) return;
            RunTracker.DisarmOrichalcumBlockAttribution();
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"HookAfterTurnEndOrichalcumCleanupPatch failed: {e.Message}");
        }
    }
}
