using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using BaseLib.Config;
using CardUtilityStats.Config;
using Godot;

namespace CardUtilityStats.Loader;

public sealed class RuntimeOptionsSnapshot
{
    public bool ViewStatsToggleEnabled { get; set; }
    public bool ShowRemovedCardsInDeckView { get; set; } = true;
    public bool ShowHandTooltips { get; set; } = true;
    public bool EnableDebugLogging { get; set; }
}

public static class RuntimeOptionsBridge
{
    private static readonly JsonSerializerOptions JsonOptions = new();
    private static readonly JsonSerializerOptions LegacyPrefsOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public static void Initialize()
    {
        MigrateLegacyPrefsIfNeeded();
    }

    public static string GetCurrentOptionsJson()
    {
        return JsonSerializer.Serialize(CreateSnapshot(), JsonOptions);
    }

    public static void SetViewStatsToggleEnabled(bool isEnabled)
    {
        if (CardUtilityStatsConfig.ViewStatsToggleEnabled == isEnabled) return;

        CardUtilityStatsConfig.ViewStatsToggleEnabled = isEnabled;
        ModConfig.SaveDebounced<CardUtilityStatsConfig>();
    }

    private static RuntimeOptionsSnapshot CreateSnapshot()
    {
        return new RuntimeOptionsSnapshot
        {
            ViewStatsToggleEnabled = CardUtilityStatsConfig.ViewStatsToggleEnabled,
            ShowRemovedCardsInDeckView = CardUtilityStatsConfig.ShowRemovedCardsInDeckView,
            ShowHandTooltips = CardUtilityStatsConfig.ShowHandTooltips,
            EnableDebugLogging = CardUtilityStatsConfig.EnableDebugLogging,
        };
    }

    private static void MigrateLegacyPrefsIfNeeded()
    {
        if (CardUtilityStatsConfig.LegacyPrefsMigrated) return;

        try
        {
            var legacyPath = ProjectSettings.GlobalizePath("user://CardUtilityStats/prefs.json");
            if (File.Exists(legacyPath))
            {
                var json = File.ReadAllText(legacyPath);
                var legacyPrefs = JsonSerializer.Deserialize<LegacyPrefs>(json, LegacyPrefsOptions);
                if (legacyPrefs != null)
                {
                    CardUtilityStatsConfig.ViewStatsToggleEnabled = legacyPrefs.ViewStatsTicked;
                }
            }
        }
        catch (Exception e)
        {
            LoaderMain.Logger.Error($"RuntimeOptionsBridge migration failed: {e}");
        }

        CardUtilityStatsConfig.LegacyPrefsMigrated = true;
        ModConfig.SaveDebounced<CardUtilityStatsConfig>();
    }

    private sealed class LegacyPrefs
    {
        [JsonPropertyName("view_stats_ticked")]
        public bool ViewStatsTicked { get; set; }
    }
}
