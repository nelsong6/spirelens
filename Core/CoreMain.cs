using System;
using HarmonyLib;
using SpireLens.Core.Patches;
using MegaCrit.Sts2.Core.Logging;

namespace SpireLens.Core;

/// <summary>
/// Hot-reloaded core entry point. Exposes the reload contract the Loader
/// shell invokes via reflection across the ALC boundary:
///
///   public static void Initialize()   — called on first load and each reload
///   public static void Shutdown()     — called before the ALC is orphaned
///
/// Each assembly load generates a unique Harmony ID so <c>UnpatchAll(id)</c>
/// in Shutdown only removes this load's patches (no risk of stomping on other
/// mods' patches).
///
/// Hot-reload model (BepInEx ScriptEngine pattern):
/// On reload, the Loader calls Shutdown(), then orphans the whole assembly
/// (it stays in memory until process exit — maybe 50KB leaked per reload,
/// which is negligible for dev sessions under ~100 reloads). The Shutdown
/// contract is the critical discipline: unless we release every reference
/// the game holds back to us (Harmony patches, event subscriptions, UI
/// nodes), the orphaned assembly will still receive callbacks and behave
/// as "phantom" code alongside the freshly-loaded copy.
///
/// We previously tried collectible AssemblyLoadContext (to actually reclaim
/// memory on unload) but that approach is "fundamentally flawed" per
/// Microsoft's own runtime team: it requires every dependency to be
/// collectible-safe, and Harmony + Godot + Publicizer + loader-side BaseLib
/// are not. See research commit for details.
/// </summary>
public static class CoreMain
{
    public const string ModId = "SpireLens";

    // Unique per-load so reload cycles don't collide in Harmony's global patch registry.
    private static readonly string _harmonyId = $"{ModId}.{Guid.NewGuid():N}";

    // Upgrades to the game's own logger during Initialize(), but remains safe
    // to call from tests / offline tooling before Godot exists.
    public static SafeLogger Logger { get; } = new(ModId, LogType.Generic);

    /// <summary>
    /// Our own debug gate — when true, per-event and per-hook logs write out;
    /// when false, only structural milestones (Initialize/Shutdown/RunStarted/
    /// CombatEnded etc.) do. Toggled by the BaseLib-backed settings UI or the
    /// CUS_DEBUG environment variable. NOT using MegaCrit's GlobalLogLevel
    /// because that's process-wide — flipping it would make every other mod
    /// spam too.
    /// </summary>
    public static bool DebugLogging { get; private set; }

    /// <summary>Gated debug-level log; no-op when DebugLogging is off.</summary>
    public static void LogDebug(string msg)
    {
        if (DebugLogging) Logger.Info(msg);
    }

    private static Harmony? _harmony;

    /// <summary>
    /// First-load + hot-reload entry. Sets up Harmony patches and game
    /// event subscriptions. Must be idempotent-safe across reloads:
    /// every resource it allocates must also be reclaimed in <see cref="Shutdown"/>.
    /// </summary>
    public static void Initialize()
    {
        Logger.ActivateGameLogger();
        RuntimeOptionsProvider.Refresh();

        // Read debug gate from both config and env var. The env var remains a
        // handy one-off override for development sessions without touching the
        // persisted settings UI toggle.
        var envDebug = System.Environment.GetEnvironmentVariable("CUS_DEBUG");
        var envDebugEnabled = !string.IsNullOrEmpty(envDebug)
            && envDebug != "0"
            && !envDebug.Equals("false", StringComparison.OrdinalIgnoreCase);
        DebugLogging = RuntimeOptionsProvider.Current.EnableDebugLogging || envDebugEnabled;

        Logger.Info($"Core.Initialize starting (harmony_id={_harmonyId}, debug={DebugLogging})");

        _harmony = new Harmony(_harmonyId);
        _harmony.PatchAll();

        // Diagnostic: enumerate every Harmony-patched method so we can
        // confirm from the log whether a given hook (especially
        // CombatHistory.Add) actually got installed. Hot-reload cycles
        // have historically had cases where a patch failed silently;
        // the logged list gives us a grep target.
        var patched = Harmony.GetAllPatchedMethods().ToList();
        Logger.Info($"[CUS-diag] Harmony patched methods ({patched.Count} total):");
        foreach (var m in patched)
            Logger.Info($"[CUS-diag]   {m.DeclaringType?.FullName}.{m.Name}");

        RunTracker.InitializeHooks();

        // Resume an active run across hot reload. Our static state (current
        // run ref, instance-number map, per-def counters) lives on this Core
        // assembly and is therefore wiped every reload — but the game's
        // RunManager persists, and we've been writing a JSON snapshot to
        // disk on every save. This looks up that file by the game's own
        // _startTime identifier and rebuilds our in-memory state so stats
        // attribution continues seamlessly instead of "No data this run"
        // appearing after every F5.
        //
        // No-op if we're not mid-run (main menu, between runs) — RunStarted
        // will handle fresh setup when the next run begins.
        RunTracker.TryResumeActiveRun();
        // Re-inject the ViewStats checkbox if the deck view is currently
        // open — Shutdown just freed the injected clone, so without this
        // the user would see the checkbox disappear until they close and
        // reopen the deck view.
        Patches.ViewStatsInjectorPatch.ReinjectIntoActiveDeckView();

        // Visible confirmation on screen so hot reload has immediate feedback.
        // Kept in Core (not Loader) so toast text/style can be tweaked and
        // hot-reloaded without game restart.
        var tree = Godot.Engine.GetMainLoop() as Godot.SceneTree;
        if (tree != null)
        {
            var stamp = DateTime.Now.ToString("HH:mm:ss");
            HotReloadToast.Show(tree, $"✅ Hot reload working! {stamp}");
        }

        Logger.Info("Core.Initialize complete");
    }

    /// <summary>
    /// Called by the Loader before orphaning this assembly. Must release
    /// every reference the game or Harmony holds back to this assembly,
    /// else the orphaned assembly will continue to receive callbacks as a
    /// "phantom" running alongside the fresh copy.
    ///
    /// Cleanup order matters: UI first (user-visible), then event
    /// subscriptions (stop receiving callbacks we can no longer handle),
    /// then Harmony patches (stop intercepting).
    /// </summary>
    public static void Shutdown()
    {
        Logger.Info("Core.Shutdown starting");

        // Strategy: swallow exceptions per step so one failure doesn't skip
        // later cleanup. A half-cleaned state is better than a no-cleaned state.
        try { ViewStatsInjectorPatch.TeardownInjectedUI(); }
        catch (Exception e) { Logger.Error($"Shutdown: UI teardown failed: {e}"); }

        try { StatsTooltip.Destroy(); }
        catch (Exception e) { Logger.Error($"Shutdown: StatsTooltip teardown failed: {e}"); }

        try { RunTracker.TeardownHooks(); }
        catch (Exception e) { Logger.Error($"Shutdown: TeardownHooks failed: {e}"); }

        try { _harmony?.UnpatchAll(_harmonyId); }
        catch (Exception e) { Logger.Error($"Shutdown: UnpatchAll failed: {e}"); }

        _harmony = null;

        Logger.Info("Core.Shutdown complete");
    }
}
