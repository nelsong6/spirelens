using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using Godot;

namespace SpireLens.Core;

/// <summary>
/// Persists RunData to JSON on disk. Files land in Godot's user:// directory
/// (typically %APPDATA%/Godot/app_userdata/Slay the Spire 2/ on Windows), under
/// a SpireLens/runs/ subdirectory. One file per run, named by run_id.
///
/// Writes are fire-and-forget on a background task to avoid blocking the game.
/// Each save overwrites the full file — the in-memory RunData is always the
/// source of truth for the current run.
/// </summary>
public static class RunStorage
{
    private sealed class RunFileHeader
    {
        public long? GameStartTime { get; set; }
        public string RunId { get; set; } = "";
    }

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    /// <summary>Resolved absolute path to runs/ directory. Created on first save.</summary>
    public static string RunsDir => ProjectSettings.GlobalizePath("user://SpireLens/runs/");

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

    private static RunFileHeader? ReadHeader(string path)
    {
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<RunFileHeader>(json, Options);
    }

    /// <summary>
    /// Detects whether a stored run file uses the current per-instance shape.
    /// Per-instance files always carry <c>instance_numbers_by_def</c> or
    /// <c>def_counters</c> at the top level (the runtime serializes both, even
    /// when empty); the historic pooled shape predates both fields and lacks
    /// them entirely.
    /// </summary>
    private static bool HasPerInstanceShape(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object) return false;
        return root.TryGetProperty("instance_numbers_by_def", out _)
            || root.TryGetProperty("def_counters", out _);
    }

    private static LoadedRunFile? LoadKnownSchemaFile(string path)
    {
        string json;
        try
        {
            json = File.ReadAllText(path);
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"LoadKnownSchemaFile: cannot read {Path.GetFileName(path)}: {e.Message}");
            return null;
        }

        bool perInstance;
        try
        {
            perInstance = HasPerInstanceShape(json);
        }
        catch (JsonException e)
        {
            CoreMain.LogDebug($"LoadKnownSchemaFile: malformed JSON in {Path.GetFileName(path)}: {e.Message}");
            return null;
        }

        RunData? data;
        try
        {
            data = JsonSerializer.Deserialize<RunData>(json, Options);
        }
        catch (JsonException e)
        {
            CoreMain.LogDebug($"LoadKnownSchemaFile: deserialization failed for {Path.GetFileName(path)}: {e.Message}");
            return null;
        }
        if (data == null)
        {
            CoreMain.LogDebug($"LoadKnownSchemaFile: deserialization returned null for {Path.GetFileName(path)}");
            return null;
        }

        return new LoadedRunFile
        {
            SourcePath = path,
            SupportsResume = perInstance,
            HasPerInstanceIdentity = perInstance,
            CompatibilityNote = perInstance
                ? null
                : "File stores pooled per-definition aggregates only. " +
                  "Readable as historical data, but cannot rebuild current per-instance live state.",
            Data = data,
        };
    }

    private static RunData? LoadForResume(string path)
    {
        var loaded = LoadKnownSchemaFile(path);
        if (loaded == null) return null;
        if (loaded.SupportsResume) return loaded.Data;

        CoreMain.Logger.Warn(
            $"LoadForResume: {Path.GetFileName(path)} uses the historic pooled shape and is history-only. " +
            $"{loaded.CompatibilityNote}");
        return null;
    }

    /// <summary>
    /// Load a stored run file for historical viewing / analysis.
    ///
    /// Unlike hot-reload resume, this accepts the historic pooled shape. Callers
    /// must inspect <see cref="LoadedRunFile.HasPerInstanceIdentity"/> before
    /// assuming that aggregate keys look like "CARD#N" or that removed-card
    /// snapshots / resume metadata exist.
    /// </summary>
    public static LoadedRunFile? LoadHistorical(string path)
    {
        try
        {
            return LoadKnownSchemaFile(path);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"LoadHistorical failed for {Path.GetFileName(path)}: {e}");
            return null;
        }
    }

    /// <summary>
    /// Load a stored run file as hot-reload resume state.
    ///
    /// Public mainly so schema fixtures can exercise the exact same gating
    /// logic as live resume without needing to stand up a Godot runtime or a
    /// real <c>user://</c> runs directory.
    /// </summary>
    public static RunData? LoadResumable(string path)
    {
        try
        {
            return LoadForResume(path);
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"LoadResumable failed for {Path.GetFileName(path)}: {e}");
            return null;
        }
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
    public static RunData? FindByGameStartTime(long gameStartTime, out bool foundUnsupportedMatch)
    {
        foundUnsupportedMatch = false;
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
                    var header = ReadHeader(path);
                    if (header?.GameStartTime != gameStartTime) continue;

                    var data = LoadForResume(path);
                    if (data != null) return data;
                    foundUnsupportedMatch = true;
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

    /// <summary>
    /// Historical counterpart to <see cref="FindByGameStartTime"/>. Returns a
    /// loaded run file even when the source uses the historic pooled shape.
    /// </summary>
    public static LoadedRunFile? FindHistoricalByGameStartTime(long gameStartTime)
    {
        try
        {
            if (!Directory.Exists(RunsDir)) return null;

            var files = Directory.GetFiles(RunsDir, "*.json");
            Array.Sort(files, (a, b) => File.GetLastWriteTimeUtc(b).CompareTo(File.GetLastWriteTimeUtc(a)));

            foreach (var path in files)
            {
                try
                {
                    var header = ReadHeader(path);
                    if (header?.GameStartTime != gameStartTime) continue;
                    return LoadKnownSchemaFile(path);
                }
                catch (Exception e)
                {
                    CoreMain.LogDebug($"FindHistoricalByGameStartTime: skipping unreadable {Path.GetFileName(path)}: {e.Message}");
                }
            }
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"FindHistoricalByGameStartTime failed: {e}");
        }
        return null;
    }
}
