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
        public int SchemaVersion { get; set; }
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

    private static RunData? DeserializeRunData(string path)
    {
        var json = File.ReadAllText(path);
        var data = JsonSerializer.Deserialize<RunData>(json, Options);
        if (data == null)
        {
            CoreMain.LogDebug($"DeserializeRunData: deserialization returned null for {Path.GetFileName(path)}");
            return null;
        }
        return data;
    }

    private static LoadedRunFile? LoadKnownSchemaFile(string path, RunFileHeader? header)
    {
        header ??= ReadHeader(path);
        if (header == null)
        {
            CoreMain.LogDebug($"LoadKnownSchemaFile: unreadable header in {Path.GetFileName(path)}");
            return null;
        }

        switch (header.SchemaVersion)
        {
            case 1:
            {
                var data = DeserializeRunData(path);
                if (data == null) return null;
                return new LoadedRunFile
                {
                    SourcePath = path,
                    SourceSchemaVersion = 1,
                    SupportsResume = false,
                    HasPerInstanceIdentity = false,
                    CompatibilityNote =
                        "Schema v1 stores pooled per-definition aggregates only. " +
                        "It is readable as historical data, but it cannot rebuild current per-instance live state.",
                    Data = data,
                };
            }

            case 2:
            case 3:
            case 4:
            case 5:
            case 6:
            case 7:
            case 8:
            case 9:
            case 10:
            case 11:
            case 12:
            case 13:
            case 14:
            case RunData.CurrentSchemaVersion:
            {
                var data = DeserializeRunData(path);
                if (data == null) return null;
                return new LoadedRunFile
                {
                    SourcePath = path,
                    SourceSchemaVersion = header.SchemaVersion,
                    SupportsResume = true,
                    HasPerInstanceIdentity = true,
                    CompatibilityNote = header.SchemaVersion == RunData.CurrentSchemaVersion
                        ? null
                        : $"Schema v{header.SchemaVersion} remains resumable under v{RunData.CurrentSchemaVersion} because newer fields are additive.",
                    Data = data,
                };
            }

            default:
                CoreMain.Logger.Warn(
                    $"LoadKnownSchemaFile: {Path.GetFileName(path)} uses unsupported schema v{header.SchemaVersion}. " +
                    $"Current known schema is v{RunData.CurrentSchemaVersion}.");
                return null;
        }
    }

    private static RunData? LoadForResume(string path, RunFileHeader? header)
    {
        var loaded = LoadKnownSchemaFile(path, header);
        if (loaded == null) return null;
        if (loaded.SupportsResume) return loaded.Data;

        CoreMain.Logger.Warn(
            $"LoadForResume: {Path.GetFileName(path)} is schema v{loaded.SourceSchemaVersion} and is history-only. " +
            $"{loaded.CompatibilityNote}");
        return null;
    }

    /// <summary>
    /// Load a stored run file for historical viewing / analysis.
    ///
    /// Unlike hot-reload resume, this accepts legacy pooled files. Callers must
    /// inspect <see cref="LoadedRunFile.HasPerInstanceIdentity"/> before
    /// assuming that aggregate keys look like "CARD#N" or that removed-card
    /// snapshots / resume metadata exist.
    /// </summary>
    public static LoadedRunFile? LoadHistorical(string path)
    {
        try
        {
            return LoadKnownSchemaFile(path, header: null);
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
            return LoadForResume(path, header: null);
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

                    var data = LoadForResume(path, header);
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
    /// loaded run file even when the source schema is legacy pooled v1, as long
    /// as the file is still a known schema.
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
                    return LoadKnownSchemaFile(path, header);
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
