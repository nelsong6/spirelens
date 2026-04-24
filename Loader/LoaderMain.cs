using System;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;
using System.Threading;
using BaseLib.Config;
using SpireLens.Config;
using Godot;
using MegaCrit.Sts2.Core.Logging;
using MegaCrit.Sts2.Core.Modding;
// Godot also has a type called Logger — explicit alias disambiguates.
using Logger = MegaCrit.Sts2.Core.Logging.Logger;

namespace SpireLens.Loader;

/// <summary>
/// Stable bootstrap. This class never unloads — it's loaded once
/// at game startup by the game's mod manager via the standard [ModInitializer]
/// contract. It owns the BaseLib-backed config/runtime boundary and hosts
/// the hot-reloadable Core with an F5 hotkey to reload.
///
/// Model: BepInEx ScriptEngine pattern.
///
/// On each load (including the first), we:
///   1. Copy Core.dll from mods/SpireLens/ to a temp path with a
///      unique per-load filename. This keeps the file in mods/ unlocked so
///      'dotnet build' can overwrite it while the game runs.
///   2. Load the temp copy via LoadFromAssemblyPath into a fresh
///      (non-collectible) AssemblyLoadContext. Unique context name per load.
///   3. Invoke CoreMain.Initialize() via reflection.
///
/// On reload, we additionally:
///   0. Call the previous Core's CoreMain.Shutdown() so it cleans up its
///      Harmony patches, event subscriptions, and injected UI nodes. Without
///      this, the orphaned assembly continues to receive callbacks as a
///      phantom running alongside the fresh copy.
///
/// We do NOT try to unload the old context. Each reload leaves behind a few
/// dozen KB of orphaned assembly metadata. Memory stays flat enough for dev
/// sessions (you'll restart the game for unrelated reasons long before this
/// matters — 1000 reloads ≈ 50MB in a 2GB game process).
///
/// Why not collectible ALC? Microsoft's own runtime team acknowledges the
/// model is fundamentally flawed for cases where every dependency must be
/// collectible-safe (dotnet/runtime#45285). Harmony, Publicizer, BaseLib,
/// and Godot's native bridge aren't, and we got SIGSEGV on any sts2 type
/// reference when the ALC was collectible. See commit history for the
/// research trail.
/// </summary>
[ModInitializer(nameof(Initialize))]
public partial class LoaderMain : Node
{
    public const string ModId = "SpireLens";

    public static Logger Logger { get; } = new($"{ModId}.Loader", LogType.Generic);

    // File-based diag log — survives hard crashes since File.AppendAllText flushes.
    private static readonly string _diagLog = Path.Combine(Path.GetTempPath(), "spirelens-loader-diag.log");
    private static void D(string msg)
    {
        try { File.AppendAllText(_diagLog, $"{DateTime.UtcNow:o} {msg}\n"); } catch { }
    }

    private static AssemblyLoadContext? _currentContext;
    private static Assembly? _currentAssembly;
    private static int _reloadCounter;
    private static string? _currentTempPath;
    private static Node? _inputNode;

    /// <summary>Mod entry point — called once on game startup.</summary>
    public static void Initialize()
    {
        D("Initialize entry");
        Logger.Info($"Loader.Initialize starting (pid={System.Environment.ProcessId})");
        D("after first Logger.Info");

        // Wire up dependency resolution BEFORE any code that needs Mono.Cecil
        // is JITted. The NuGet dependency DLLs (Mono.Cecil, its companions)
        // live in our mods folder next to this assembly, but neither the
        // IsolatedComponentLoadContext nor the Default ALC will find them
        // without help — they don't auto-probe that directory.
        try
        {
            var myCtx = AssemblyLoadContext.GetLoadContext(typeof(LoaderMain).Assembly);
            if (myCtx != null)
            {
                myCtx.Resolving += ResolveSiblingAssembly;
                D("Resolving handler wired on our ALC");
            }
        }
        catch (Exception e) { D($"resolver wire failed: {e.Message}"); }

        try
        {
            ModConfigRegistry.Register(ModId, new SpireLensConfig());
            RuntimeOptionsBridge.Initialize();
            D("config registry initialized");
        }
        catch (Exception e)
        {
            D($"config bootstrap threw: {e.GetType().Name}: {e.Message}");
            Logger.Error($"Config bootstrap threw: {e}");
        }

        try { D("about to LoadCore"); LoadCore(); D("LoadCore returned"); }
        catch (Exception e) { D($"LoadCore threw: {e.GetType().Name}: {e.Message}"); Logger.Error($"LoadCore threw: {e}"); }

        try { D("about to AttachInputListener"); AttachInputListener(); D("AttachInputListener returned"); }
        catch (Exception e) { D($"AttachInputListener threw: {e.GetType().Name}: {e.Message}"); Logger.Error($"AttachInputListener threw: {e}"); }

        D("Initialize exit");
        Logger.Info("Loader.Initialize complete — F5 to reload");
    }

    /// <summary>
    /// Locate Core.dll in our mods directory, copy to a fresh temp path, and
    /// load into a new non-collectible ALC. Old ALC (if any) stays orphaned
    /// in memory until process exit; Shutdown() on the old Core must have
    /// already run to release external references.
    /// </summary>
    public static void LoadCore()
    {
        D("LoadCore: entry");
        if (_currentContext != null)
        {
            Logger.Warn("LoadCore called while a Core is already loaded; call UnloadCore first");
            return;
        }

        D("LoadCore: getting assembly location");
        var loaderDllPath = typeof(LoaderMain).Assembly.Location;
        D($"LoadCore: loader path='{loaderDllPath}'");
        var loaderDir = Path.GetDirectoryName(loaderDllPath);
        if (string.IsNullOrEmpty(loaderDir))
        {
            Logger.Error("Could not determine Loader DLL directory");
            return;
        }

        var corePath = Path.Combine(loaderDir, "SpireLens.Core.dll");
        if (!File.Exists(corePath))
        {
            Logger.Error($"Core DLL not found at {corePath}");
            return;
        }

        // BepInEx-style: copy to a unique temp path so the file in mods/
        // stays unlocked (free for 'dotnet build' to overwrite between
        // reloads) and each reload gets a distinct identity in the debugger.
        int n = Interlocked.Increment(ref _reloadCounter);
        var tempPath = Path.Combine(
            Path.GetTempPath(),
            $"SpireLens.Core.{n:D3}.dll");
        try
        {
            File.Copy(corePath, tempPath, overwrite: true);
        }
        catch (Exception e)
        {
            Logger.Error($"Failed to stage Core DLL to {tempPath}: {e}");
            return;
        }

        // Load into the SAME ALC as our own Loader — which is Godot's mod ALC,
        // not Default. This matches how ModManager loads mods:
        //   AssemblyLoadContext.GetLoadContext(Assembly.GetExecutingAssembly())
        //       .LoadFromAssemblyPath(text2);
        // (MegaCrit.Sts2.Core.Modding.ModManager.cs line 647-650)
        //
        // Godot's .NET integration uses a specific managed ALC, not Default.
        // sts2.dll, GodotSharp, 0Harmony, BaseLib, and this stable Loader
        // all live in that context.
        // Putting Core into Default (what we tried first) or a custom ALC
        // means Core's type references to Godot/sts2/Harmony resolve
        // cross-context, which crashes the native bridge (SIGSEGV).
        var godotContext = AssemblyLoadContext.GetLoadContext(typeof(LoaderMain).Assembly);
        if (godotContext == null)
        {
            Logger.Error("Could not get Godot ALC from our own assembly");
            D("LoadCore: godotContext null");
            return;
        }
        D($"LoadCore: using Godot ALC: {godotContext.Name ?? "(unnamed)"}");

        // LoadFromAssemblyPath dedupes by assembly IDENTITY (name+version), so
        // a second call with the same manifest returns the cached assembly —
        // even if the file bytes differ. Our builds keep "SpireLens.Core,
        // Version=1.0.0.0" each time, so that dedupe means F5 would re-run the
        // SAME code instead of our freshly-rebuilt code.
        //
        // LoadFromStream(byte[]) bypasses the identity cache entirely — each
        // call produces a distinct Assembly object. Trade-off: when two
        // assemblies with the same identity coexist, reflection / type-
        // identity checks can be confused, but that's exactly what happens
        // with hot reload by design.
        // Rewrite the manifest's short name to something unique per load —
        // "SpireLens.Core.{N}" — using Mono.Cecil. Without this,
        // LoadFromStream and LoadFromAssemblyPath both throw
        //   "Assembly with same name is already loaded"
        // because .NET dedupes assemblies within an ALC by short name
        // (not by full identity). This is the BepInEx ScriptEngine trick.
        // The renamed assembly still contains our SpireLens.Core.CoreMain
        // type at the same namespace, so the Loader's reflection lookup
        // continues to work.
        Assembly loadedAssembly;
        try
        {
            var bytes = File.ReadAllBytes(tempPath);
            byte[] renamedBytes;
            using (var inStream = new MemoryStream(bytes))
            {
                var asm = Mono.Cecil.AssemblyDefinition.ReadAssembly(inStream);
                asm.Name.Name = $"SpireLens.Core.{n}";
                // Module name gets persisted too; keep in sync so Cecil doesn't
                // complain on write.
                asm.MainModule.Name = asm.Name.Name + ".dll";
                using var outStream = new MemoryStream();
                asm.Write(outStream);
                renamedBytes = outStream.ToArray();
            }
            D($"LoadCore: renamed manifest to SpireLens.Core.{n}");
            using (var ms = new MemoryStream(renamedBytes))
            {
                loadedAssembly = godotContext.LoadFromStream(ms);
            }
            D($"LoadCore: loaded assembly: {loadedAssembly.FullName}");
        }
        catch (Exception e)
        {
            D($"LoadCore: load threw: {e.GetType().Name}: {e.Message}");
            Logger.Error($"Failed to load Core from {tempPath}: {e}");
            // Don't touch _currentContext/_currentAssembly — leave them null
            // so the next F5 retries cleanly.
            return;
        }

        // Only commit state after a successful load.
        _currentContext = godotContext;
        _currentAssembly = loadedAssembly;
        _currentTempPath = tempPath;

        var coreType = _currentAssembly.GetType("SpireLens.Core.CoreMain");
        if (coreType == null)
        {
            Logger.Error("SpireLens.Core.CoreMain type not found in Core assembly");
            return;
        }

        var initMethod = coreType.GetMethod("Initialize", BindingFlags.Public | BindingFlags.Static);
        if (initMethod == null)
        {
            Logger.Error("CoreMain.Initialize method not found");
            return;
        }

        D("LoadCore: about to Invoke CoreMain.Initialize");
        try
        {
            initMethod.Invoke(null, null);
            D("LoadCore: Invoke returned normally");
            Logger.Info($"Core loaded (load #{n}, temp={Path.GetFileName(tempPath)})");
        }
        catch (TargetInvocationException tie)
        {
            D($"LoadCore: Invoke TIE: {tie.InnerException?.GetType().Name}: {tie.InnerException?.Message}");
            Logger.Error($"Core.Initialize threw: {tie.InnerException}");
        }
        catch (Exception e)
        {
            D($"LoadCore: Invoke threw: {e.GetType().Name}: {e.Message}");
            Logger.Error($"Core.Initialize.Invoke failed: {e}");
        }
    }

    /// <summary>
    /// Call Core.Shutdown() for cleanup, then orphan the context. We do NOT
    /// call Unload() — the ALC is non-collectible and would throw. The
    /// orphaned context (and its temp DLL file) linger until process exit.
    /// </summary>
    public static void UnloadCore()
    {
        if (_currentContext == null || _currentAssembly == null)
        {
            Logger.Warn("UnloadCore called but no Core is loaded");
            return;
        }

        try
        {
            var coreType = _currentAssembly.GetType("SpireLens.Core.CoreMain");
            var shutdownMethod = coreType?.GetMethod("Shutdown", BindingFlags.Public | BindingFlags.Static);
            shutdownMethod?.Invoke(null, null);
        }
        catch (Exception e)
        {
            Logger.Error($"Core.Shutdown threw (continuing reload): {e}");
        }

        // Orphan — don't unload (non-collectible). GC can't reclaim it but
        // nothing else should hold live refs once Shutdown did its job.
        _currentContext = null;
        _currentAssembly = null;
        // _currentTempPath is left dangling — the file is locked until process exit.

        Logger.Info("Core orphaned");
    }

    /// <summary>Unload current Core, then load fresh. Triggered by F5.</summary>
    public static void ReloadCore()
    {
        Logger.Info("--- HOT RELOAD START ---");
        UnloadCore();
        LoadCore();
        Logger.Info("--- HOT RELOAD DONE ---");
        // Core.Initialize is responsible for any on-screen toast/confirmation.
        // Keeping that in Core (not Loader) means toast behavior is itself
        // hot-reloadable.
    }

    /// <summary>Exposed to Core so it can tag its toast with the reload number.</summary>
    public static int ReloadNumber => _reloadCounter;

    /// <summary>
    /// Resolve dependency DLLs (like Mono.Cecil) from our mods folder.
    /// Attached to our ALC's Resolving event early in Initialize so JIT
    /// can find these types when LoadCore is first called.
    /// </summary>
    private static Assembly? ResolveSiblingAssembly(AssemblyLoadContext ctx, AssemblyName name)
    {
        try
        {
            var loaderDir = Path.GetDirectoryName(typeof(LoaderMain).Assembly.Location);
            if (string.IsNullOrEmpty(loaderDir) || name.Name == null) return null;
            var path = Path.Combine(loaderDir, name.Name + ".dll");
            if (File.Exists(path))
            {
                D($"resolver: loading sibling {name.Name}");
                return ctx.LoadFromAssemblyPath(path);
            }
        }
        catch (Exception e) { D($"resolver threw for {name.Name}: {e.Message}"); }
        return null;
    }

    private static void AttachInputListener()
    {
        var tree = Engine.GetMainLoop() as SceneTree;
        if (tree == null)
        {
            Logger.Error("Could not get SceneTree — hot-reload hotkey won't work");
            return;
        }

        _inputNode = new HotReloadInputNode { Name = "SpireLensHotReload" };
        tree.Root.CallDeferred(Node.MethodName.AddChild, _inputNode);
        Logger.Info("Hot-reload input listener attached (F5 to reload)");
    }
}
