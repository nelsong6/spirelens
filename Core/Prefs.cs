using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Godot;

namespace CardUtilityStats.Core;

/// <summary>
/// Cross-reload user preferences. Lives on disk next to run files so it
/// survives Core hot reloads (static state resets every reload, so memory-
/// only preferences would get wiped on every F5).
///
/// Currently minimal — just the View Stats checkbox state. Expand as more
/// session-level preferences accumulate (sort preferences, display
/// toggles, etc.).
/// </summary>
public class Prefs
{
    [JsonPropertyName("view_stats_ticked")]
    public bool ViewStatsTicked { get; set; }
}

public static class PrefsStorage
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string Path => ProjectSettings.GlobalizePath("user://CardUtilityStats/prefs.json");

    public static Prefs Load()
    {
        try
        {
            if (File.Exists(Path))
                return JsonSerializer.Deserialize<Prefs>(File.ReadAllText(Path), Options) ?? new Prefs();
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PrefsStorage.Load failed: {e}");
        }
        return new Prefs();
    }

    public static void Save(Prefs prefs)
    {
        try
        {
            var dir = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(Path, JsonSerializer.Serialize(prefs, Options));
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"PrefsStorage.Save failed: {e}");
        }
    }
}
