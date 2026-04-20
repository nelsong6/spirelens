using System;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;
using Godot;
using MegaCrit.Sts2.Core.Logging;
using MegaCrit.Sts2.Core.Modding;
// Godot also has a type called Logger — explicit alias disambiguates.
using Logger = MegaCrit.Sts2.Core.Logging.Logger;

namespace CardUtilityStats.Loader;

/// <summary>
/// Stable bootstrap. This class never unloads — it's loaded by BaseLib once
/// at game startup via the standard [ModInitializer] contract. Its sole job
/// is to host the hot-reloadable Core in a collectible AssemblyLoadContext
/// and provide an F5 hotkey to reload.
///
/// Critically: we use <see cref="AssemblyLoadContext.LoadFromStream"/> after
/// pre-reading the DLL into memory, NOT LoadFromAssemblyPath. The latter
/// locks the file on Windows and would defeat the entire point — you
/// couldn't rebuild + redeploy Core while the game runs.
/// </summary>
[ModInitializer(nameof(Initialize))]
public partial class LoaderMain : Node
{
    public const string ModId = "CardUtilityStats";

    public static Logger Logger { get; } = new($"{ModId}.Loader", LogType.Generic);

    private static AssemblyLoadContext? _coreAlc;
    private static WeakReference? _coreAlcWeak;  // for verifying GC actually collected
    private static Assembly? _coreAssembly;
    private static Node? _inputNode;

    /// <summary>BaseLib entry point — called once on game startup.</summary>
    public static void Initialize()
    {
        Logger.Info($"Loader.Initialize starting (pid={System.Environment.ProcessId})");

        LoadCore();
        AttachInputListener();

        Logger.Info("Loader.Initialize complete — F5 to reload");
    }

    /// <summary>
    /// Load <c>CardUtilityStats.Core.dll</c> from our own mods directory into
    /// a fresh collectible ALC, then invoke <c>CoreMain.Initialize()</c> via
    /// reflection across the ALC boundary.
    /// </summary>
    public static void LoadCore()
    {
        if (_coreAlc != null)
        {
            Logger.Warn("LoadCore called while Core already loaded — ignoring");
            return;
        }

        var loaderDllPath = typeof(LoaderMain).Assembly.Location;
        var loaderDir = Path.GetDirectoryName(loaderDllPath);
        if (string.IsNullOrEmpty(loaderDir))
        {
            Logger.Error("Could not determine Loader DLL directory");
            return;
        }

        var corePath = Path.Combine(loaderDir, "CardUtilityStats.Core.dll");
        if (!File.Exists(corePath))
        {
            Logger.Error($"Core DLL not found at {corePath}");
            return;
        }

        _coreAlc = new AssemblyLoadContext("CardUtilityStats.Core", isCollectible: true);

        // Pre-read to memory so the file isn't locked during the load —
        // essential for dotnet build to overwrite Core.dll while we run.
        var bytes = File.ReadAllBytes(corePath);
        using (var ms = new MemoryStream(bytes))
        {
            _coreAssembly = _coreAlc.LoadFromStream(ms);
        }

        var coreType = _coreAssembly.GetType("CardUtilityStats.Core.CoreMain");
        if (coreType == null)
        {
            Logger.Error("CardUtilityStats.Core.CoreMain type not found in Core assembly");
            return;
        }

        var initMethod = coreType.GetMethod("Initialize", BindingFlags.Public | BindingFlags.Static);
        if (initMethod == null)
        {
            Logger.Error("CoreMain.Initialize method not found");
            return;
        }

        try
        {
            initMethod.Invoke(null, null);
            Logger.Info($"Core loaded (assembly={_coreAssembly.GetName().Name} v{_coreAssembly.GetName().Version})");
        }
        catch (TargetInvocationException tie)
        {
            Logger.Error($"Core.Initialize threw: {tie.InnerException}");
        }
    }

    /// <summary>
    /// Call Core's Shutdown() for cleanup, then unload the ALC. Forces a
    /// few GC passes afterward and reports whether the assembly was actually
    /// collected — a leaked ALC indicates some reference into the old Core
    /// survived (event subscription, Godot node, Harmony patch not removed).
    /// </summary>
    public static void UnloadCore()
    {
        if (_coreAlc == null || _coreAssembly == null)
        {
            Logger.Warn("UnloadCore called but Core not loaded");
            return;
        }

        // Best-effort Shutdown call.
        try
        {
            var coreType = _coreAssembly.GetType("CardUtilityStats.Core.CoreMain");
            var shutdownMethod = coreType?.GetMethod("Shutdown", BindingFlags.Public | BindingFlags.Static);
            shutdownMethod?.Invoke(null, null);
        }
        catch (Exception e)
        {
            Logger.Error($"Core.Shutdown threw (continuing unload): {e}");
        }

        _coreAssembly = null;
        _coreAlcWeak = new WeakReference(_coreAlc);
        _coreAlc.Unload();
        _coreAlc = null;

        // Give the GC several chances to reclaim the assembly.
        // If something's still holding a reference, this will still fail —
        // but reporting it out tells us to go debug.
        for (int i = 0; i < 10 && _coreAlcWeak.IsAlive; i++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
        }

        Logger.Info($"Core unloaded (ALC collected: {!_coreAlcWeak.IsAlive})");
    }

    /// <summary>Unload current Core, then load fresh. Triggered by F5.</summary>
    public static void ReloadCore()
    {
        Logger.Info("--- HOT RELOAD START ---");
        UnloadCore();
        LoadCore();
        Logger.Info("--- HOT RELOAD DONE ---");
    }

    private static void AttachInputListener()
    {
        // Must defer to the main thread — Initialize may be called before the
        // scene tree's root exists, and AddChild from off-thread is unsafe.
        var tree = Engine.GetMainLoop() as SceneTree;
        if (tree == null)
        {
            Logger.Error("Could not get SceneTree — hot-reload hotkey won't work");
            return;
        }

        _inputNode = new HotReloadInputNode { Name = "CardUtilityStatsHotReload" };
        tree.Root.CallDeferred(Node.MethodName.AddChild, _inputNode);
        Logger.Info("Hot-reload input listener attached (F5 to reload)");
    }
}
