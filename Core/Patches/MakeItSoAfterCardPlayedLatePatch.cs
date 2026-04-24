using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Models.Cards;

namespace SpireLens.Core.Patches;

/// <summary>
/// Make It So does its self-recurrence in <c>AfterCardPlayedLate</c> by
/// checking how many Skill cards have finished this turn and then calling
/// <c>CardPileCmd.Add(this, PileType.Hand)</c> on every threshold. We arm a
/// one-shot marker here, then resolve it later from the generic
/// pile-changed hook once we know whether the card really arrived in Hand.
/// </summary>
[HarmonyPatch(typeof(MakeItSo), nameof(MakeItSo.AfterCardPlayedLate))]
public static class MakeItSoAfterCardPlayedLatePatch
{
    [HarmonyPrefix]
    public static void Prefix(MakeItSo __instance, CardPlay cardPlay)
    {
        try
        {
            if (__instance == null || cardPlay == null) return;
            RunTracker.NoteMakeItSoSummonAttempt(__instance, cardPlay);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"MakeItSoAfterCardPlayedLatePatch failed: {e.Message}");
        }
    }
}
