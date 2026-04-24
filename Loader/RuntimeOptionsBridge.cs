using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using BaseLib.Config;
using SpireLens.Config;
using Godot;

namespace SpireLens.Loader;

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
        if (SpireLensConfig.ViewStatsToggleEnabled == isEnabled) return;

        SpireLensConfig.ViewStatsToggleEnabled = isEnabled;
        ModConfig.SaveDebounced<SpireLensConfig>();
    }

    private static RuntimeOptionsSnapshot CreateSnapshot()
    {
        return new RuntimeOptionsSnapshot
        {
            ViewStatsToggleEnabled = SpireLensConfig.ViewStatsToggleEnabled,
            ShowRemovedCardsInDeckView = SpireLensConfig.ShowRemovedCardsInDeckView,
            ShowHandTooltips = SpireLensConfig.ShowHandTooltips,
            EnableDebugLogging = SpireLensConfig.EnableDebugLogging,
        };
    }

    private static void MigrateLegacyPrefsIfNeeded()
    {
        if (SpireLensConfig.LegacyPrefsMigrated) return;

        try
        {
            var legacyPath = ProjectSettings.GlobalizePath("user://SpireLens/prefs.json");
            if (File.Exists(legacyPath))
            {
                var json = File.ReadAllText(legacyPath);
                var legacyPrefs = JsonSerializer.Deserialize<LegacyPrefs>(json, LegacyPrefsOptions);
                if (legacyPrefs != null)
                {
                    SpireLensConfig.ViewStatsToggleEnabled = legacyPrefs.ViewStatsTicked;
                }
            }
        }
        catch (Exception e)
        {
            LoaderMain.Logger.Error($"RuntimeOptionsBridge migration failed: {e}");
        }

        SpireLensConfig.LegacyPrefsMigrated = true;
        ModConfig.SaveDebounced<SpireLensConfig>();
    }

    private sealed class LegacyPrefs
    {
        [JsonPropertyName("view_stats_ticked")]
        public bool ViewStatsTicked { get; set; }
    }
}
