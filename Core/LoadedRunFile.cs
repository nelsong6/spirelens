namespace SpireLens.Core;

/// <summary>
/// Result of loading a stored run file from disk.
///
/// The payload is always a <see cref="RunData"/> instance so callers can use a
/// single data model, but the flags tell them whether the source file carried
/// per-instance identity and whether it is safe to treat as hot-reload resume
/// state.
/// </summary>
public sealed class LoadedRunFile
{
    public string SourcePath { get; init; } = "";
    public int SourceSchemaVersion { get; init; }
    public bool SupportsResume { get; init; }
    public bool HasPerInstanceIdentity { get; init; }
    public string? CompatibilityNote { get; init; }
    public RunData Data { get; init; } = new();

    public bool IsLegacy => SourceSchemaVersion != RunData.CurrentSchemaVersion;
}
