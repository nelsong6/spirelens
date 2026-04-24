using System;
using System.Text.Json.Serialization;

namespace SpireLens.Core;

/// <summary>
/// Compatibility shim for the old deck-view toggle persistence path.
/// The injected deck-view UI still reads and writes PrefsStorage, but the
/// actual persisted state now lives in the loader-side BaseLib config.
/// </summary>
public class Prefs
{
    [JsonPropertyName("view_stats_ticked")]
    public bool ViewStatsTicked { get; set; }
}

public static class PrefsStorage
{
    public static Prefs Load()
    {
        try
        {
            var options = RuntimeOptionsProvider.Refresh();
            return new Prefs { ViewStatsTicked = options.ViewStatsToggleEnabled };
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PrefsStorage.Load failed: {e}");
            return new Prefs();
        }
    }

    public static void Save(Prefs prefs)
    {
        try
        {
            RuntimeOptionsProvider.SetViewStatsToggleEnabled(prefs.ViewStatsTicked);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PrefsStorage.Save failed: {e}");
        }
    }
}
