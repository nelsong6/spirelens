using MegaCrit.Sts2.Core.Logging;

namespace SpireLens.Core;

/// <summary>
/// Logger wrapper that is safe to reference outside a live Godot/game runtime.
///
/// In normal mod execution, <see cref="ActivateGameLogger"/> upgrades it to the
/// game's logger so output lands in godot.log. In tests / offline utilities, it
/// falls back to console logging instead of crashing during Godot static init.
/// </summary>
public sealed class SafeLogger
{
    private readonly string _name;
    private readonly LogType _logType;
    private Logger? _inner;

    public SafeLogger(string name, LogType logType)
    {
        _name = name;
        _logType = logType;
    }

    public void ActivateGameLogger()
    {
        if (_inner != null) return;

        try
        {
            _inner = new Logger(_name, _logType);
        }
        catch
        {
            // Tests and standalone tooling run without a live Godot runtime.
            // Keep the wrapper usable there instead of crashing.
            _inner = null;
        }
    }

    public void Info(string message)
    {
        if (_inner != null) _inner.Info(message);
        else Console.WriteLine($"[{_name}] INFO {message}");
    }

    public void Warn(string message)
    {
        if (_inner != null) _inner.Warn(message);
        else Console.WriteLine($"[{_name}] WARN {message}");
    }

    public void Error(string message)
    {
        if (_inner != null) _inner.Error(message);
        else Console.Error.WriteLine($"[{_name}] ERROR {message}");
    }
}
