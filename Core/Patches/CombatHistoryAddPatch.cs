using HarmonyLib;
using MegaCrit.Sts2.Core.Combat.History;

namespace SpireLens.Core.Patches;

/// <summary>
/// Single master hook into the combat history dispatch.
///
/// Every event the game emits during combat — cards played, damage dealt,
/// block gained, cards drawn, energy spent, orbs channeled — flows through
/// the private <c>CombatHistory.Add(entry)</c> method. A postfix there sees
/// the fully-typed entry object after it's been appended to the history list,
/// giving the tracker a single observation point for everything.
///
/// Private-method patching: Harmony's string-name form ("Add") bypasses the
/// normal access checks. The Publicizer (see csproj) additionally lets our
/// code *reference* private game members elsewhere; together the two let us
/// read private state without reflection.
/// </summary>
[HarmonyPatch(typeof(CombatHistory), "Add")]
public static class CombatHistoryAddPatch
{
    // Postfix runs after the entry is already appended to CombatHistory._entries,
    // so we know the entry survived the game's own logic and is "real."
    [HarmonyPostfix]
    public static void Postfix(CombatHistoryEntry entry)
    {
        RunTracker.Observe(entry);
    }
}
