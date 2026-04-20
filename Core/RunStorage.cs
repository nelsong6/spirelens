using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using Godot;

namespace CardUtilityStats.Core;

/// <summary>
/// Persists RunData to JSON on disk. Files land in Godot's user:// directory
/// (typically %APPDATA%/Godot/app_userdata/Slay the Spire 2/ on Windows), under
/// a CardUtilityStats/runs/ subdirectory. One file per run, named by run_id.
///
/// Writes are fire-and-forget on a background task to avoid blocking the game.
/// Each save overwrites the full file — the in-memory RunData is always the
/// source of truth for the current run.
/// </summary>
public static class RunStorage
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    /// <summary>Resolved absolute path to runs/ directory. Created on first save.</summary>
    public static string RunsDir => ProjectSettings.GlobalizePath("user://CardUtilityStats/runs/");

    /// <summary>Serialize and write the run data to disk without blocking the caller.</summary>
    public static void SaveAsync(RunData data)
    {
        // Snapshot-serialize on the calling thread so we don't race with further mutations.
        // (RunTracker holds the lock when it calls this; safe here.)
        string json = JsonSerializer.Serialize(data, Options);
        string path = Path.Combine(RunsDir, data.RunId + ".json");

        Task.Run(() =>
        {
            try
            {
                Directory.CreateDirectory(RunsDir);
                File.WriteAllText(path, json);
            }
            catch (Exception e)
            {
                CoreMain.Logger.Error($"RunStorage.SaveAsync failed: {e}");
            }
        });
    }
}
