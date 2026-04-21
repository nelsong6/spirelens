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

    /// <summary>
    /// Scan the runs/ directory for a JSON file whose <c>GameStartTime</c>
    /// matches the supplied value. Used by <see cref="RunTracker.TryResumeActiveRun"/>
    /// on hot reload: the game's <c>RunManager._startTime</c> is stable
    /// across our Core assembly reload, so we match on that to find the
    /// run file we were writing to before the reload.
    ///
    /// Returns null if no match or if the directory doesn't exist yet.
    /// Malformed / unreadable files are skipped, not fatal.
    /// </summary>
    public static RunData? FindByGameStartTime(long gameStartTime)
    {
        try
        {
            if (!Directory.Exists(RunsDir)) return null;

            // Sort newest-first so if multiple files match (shouldn't happen
            // but defensive), we pick the most recent.
            var files = Directory.GetFiles(RunsDir, "*.json");
            Array.Sort(files, (a, b) => File.GetLastWriteTimeUtc(b).CompareTo(File.GetLastWriteTimeUtc(a)));

            foreach (var path in files)
            {
                try
                {
                    var json = File.ReadAllText(path);
                    var data = JsonSerializer.Deserialize<RunData>(json, Options);
                    if (data?.GameStartTime == gameStartTime) return data;
                }
                catch (Exception e)
                {
                    CoreMain.LogDebug($"FindByGameStartTime: skipping unreadable {Path.GetFileName(path)}: {e.Message}");
                }
            }
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"FindByGameStartTime failed: {e}");
        }
        return null;
    }
}
