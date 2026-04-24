using HarmonyLib;
using MegaCrit.Sts2.Core.Runs;

namespace SpireLens.Core.Patches;

/// <summary>
/// Universal run-end hook. Supersedes the earlier attempt on
/// RunManager.OnEnded, which only covered in-game death and in-game victory —
/// missing the main-menu abandon path (NMainMenu.AbandonRun operates directly
/// on the save file without going through RunManager).
///
/// <c>RunHistoryUtilities.CreateRunHistoryEntry</c> is the single
/// funnel that all three terminal paths go through:
///   - Victory:       RunManager.OnEnded -> CreateRunHistoryEntry(..., victory=true, ...)
///   - Death:         CreatureCmd.Kill (all players) -> RunManager.OnEnded -> CreateRunHistoryEntry(..., victory=false, isAbandoned=false, ...)
///   - Main-menu abandon: NMainMenu.AbandonRun -> CreateRunHistoryEntry(..., victory=false, isAbandoned=true, ...)
///
/// The parameter names on the public method give us outcome directly:
///   abandoned   isAbandoned == true (highest priority)
///   win         victory == true
///   loss        neither
///
/// Called as a Prefix with no return-value manipulation so we don't affect
/// the game's own run history creation. Runs before the game's own side
/// effects (saves, achievements upload), which is fine — the call is
/// guaranteed to proceed regardless.
/// </summary>
[HarmonyPatch(typeof(RunHistoryUtilities), nameof(RunHistoryUtilities.CreateRunHistoryEntry))]
public static class RunHistoryUtilitiesCreateEntryPatch
{
    [HarmonyPostfix]
    public static void Postfix(bool victory, bool isAbandoned)
    {
        string outcome;
        if (isAbandoned) outcome = "abandoned";
        else if (victory) outcome = "win";
        else outcome = "loss";

        RunTracker.OnRunEnded(outcome);
    }
}
