using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text;
using Godot;
using HarmonyLib;
using MegaCrit.Sts2.Core.Localization;
using MegaCrit.Sts2.Core.Nodes.Relics;

namespace SpireLens.Core.Patches;

[HarmonyPatch]
public static class RelicHoverShowPatch
{
    private const string LetterOpenerRelicId = "LETTER_OPENER";

    public static IEnumerable<MethodBase> TargetMethods()
    {
        var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        var basicFocus = typeof(NRelicBasicHolder).GetMethod("OnFocus", flags);
        if (basicFocus != null) yield return basicFocus;

        var inventoryFocus = typeof(NRelicInventoryHolder).GetMethod("OnFocus", flags);
        if (inventoryFocus != null && inventoryFocus.DeclaringType != basicFocus?.DeclaringType)
            yield return inventoryFocus;
    }

    [HarmonyPostfix]
    public static void Postfix(object __instance)
    {
        try
        {
            RuntimeOptionsProvider.Refresh();
            var tickbox = ViewStatsInjectorPatch.LastInjectedTickbox;
            var viewStatsEnabled = tickbox?.IsTicked ?? RuntimeOptionsProvider.Current.ViewStatsToggleEnabled;
            if (!viewStatsEnabled) return;

            if (__instance is not Control holder) return;

            var relicModel = GetRelicModel(holder);
            var relicId = NormalizeRelicId(GetMemberText(GetMemberValue(relicModel, "Id")));
            if (!string.Equals(relicId, LetterOpenerRelicId, StringComparison.OrdinalIgnoreCase))
                return;

            var aggregate = RunTracker.GetEffectiveRelicAggregate(relicId);
            var body = BuildBodyBBCode(aggregate);
            if (string.IsNullOrWhiteSpace(body)) return;

            var title = GetMemberText(GetMemberValue(relicModel, "Title"));
            if (string.IsNullOrWhiteSpace(title)) title = "Letter Opener";

            var tree = Engine.GetMainLoop() as SceneTree;
            if (tree == null) return;

            StatsTooltip.Show(tree, holder, title, "SpireLens", body);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"RelicHoverShow failed: {e.Message}");
        }
    }

    private static string BuildBodyBBCode(RelicAggregate? aggregate)
    {
        if (aggregate == null || (aggregate.TimesActivated <= 0 && aggregate.TotalAttemptedDamage <= 0))
            return "";

        var sb = new StringBuilder();
        Row3(sb, "Times activated", aggregate.TimesActivated.ToString(), "");
        Row3(sb, "Attempted damage", aggregate.TotalAttemptedDamage.ToString(), "");
        return sb.ToString();
    }

    private static void Row3(StringBuilder sb, string label, string value, string pct)
    {
        sb.Append("[table=3]");
        sb.Append($"[cell expand=4 padding=0,0,12,0][color=#e0e0e0]{label}[/color][/cell]");
        sb.Append($"[cell expand=1 padding=0,0,12,0][right][b]{value}[/b][/right][/cell]");
        sb.Append($"[cell expand=1 padding=0,0,4,0][right][color=#b5b5b5]{pct}[/color][/right][/cell]");
        sb.Append("[/table]\n");
    }

    private static object? GetRelicModel(object holder)
    {
        var relic = GetMemberValue(holder, "Relic");
        return GetMemberValue(relic, "Model");
    }

    private static object? GetMemberValue(object? source, string memberName)
    {
        if (source == null) return null;

        var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        var type = source.GetType();
        var property = type.GetProperty(memberName, flags);
        if (property?.CanRead == true)
        {
            try { return property.GetValue(source); }
            catch { }
        }

        var field = type.GetField(memberName, flags);
        if (field != null)
        {
            try { return field.GetValue(source); }
            catch { }
        }

        return null;
    }

    private static string? GetMemberText(object? value)
    {
        try
        {
            if (value == null) return null;
            if (value is LocString locString) return locString.GetFormattedText();

            var entry = GetMemberValue(value, "Entry");
            if (entry != null) return entry.ToString();

            return value.ToString();
        }
        catch
        {
            return null;
        }
    }

    private static string NormalizeRelicId(string? relicId)
    {
        var normalized = (relicId ?? "").Trim();
        if (normalized.StartsWith("RELIC.", StringComparison.OrdinalIgnoreCase))
            normalized = normalized["RELIC.".Length..];
        return normalized.ToUpperInvariant();
    }
}

[HarmonyPatch]
public static class RelicHoverHidePatch
{
    public static IEnumerable<MethodBase> TargetMethods()
    {
        var flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
        var basicUnfocus = typeof(NRelicBasicHolder).GetMethod("OnUnfocus", flags);
        if (basicUnfocus != null) yield return basicUnfocus;

        var inventoryUnfocus = typeof(NRelicInventoryHolder).GetMethod("OnUnfocus", flags);
        if (inventoryUnfocus != null && inventoryUnfocus.DeclaringType != basicUnfocus?.DeclaringType)
            yield return inventoryUnfocus;
    }

    [HarmonyPostfix]
    public static void Postfix()
    {
        try { StatsTooltip.Hide(); }
        catch (Exception e) { CoreMain.Logger.Error($"RelicHoverHide failed: {e.Message}"); }
    }
}
