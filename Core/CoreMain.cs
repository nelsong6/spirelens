using System;
using HarmonyLib;
using MegaCrit.Sts2.Core.Logging;
using CardUtilityStats.Core.Patches;

namespace CardUtilityStats.Core;

/// <summary>
/// Hot-reloaded core entry point. Exposes the reload contract the Loader
/// shell invokes via reflection across the ALC boundary:
///
///   public static void Initialize()   — called on first load and each reload
///   public static void Shutdown()     — called before the ALC is unloaded
///
/// Each assembly load generates a unique Harmony ID so <c>UnpatchAll(id)</c>
/// in Shutdown only removes this load's patches (no risk of stomping on other
/// mods' patches). Static fields here live in the collectible ALC, so they
/// vanish along with the assembly on unload.
/// </summary>
public static class CoreMain
{
    public const string ModId = "CardUtilityStats";

    // Unique per-load so reload cycles don't collide in Harmony's global patch registry.
    private static readonly string _harmonyId = $"{ModId}.{Guid.NewGuid():N}";

    // Uses the game's own logger. Tagged with ModId so log lines are greppable.
    public static Logger Logger { get; } = new(ModId, LogType.Generic);

    private static Harmony? _harmony;

    /// <summary>
    /// First-load + hot-reload entry. Sets up Harmony patches and game
    /// event subscriptions. Must be idempotent-safe across reloads:
    /// every resource it allocates must also be reclaimed in <see cref="Shutdown"/>.
    /// </summary>
    public static void Initialize()
    {
        Logger.Info($"Core.Initialize starting (harmony_id={_harmonyId})");

        _harmony = new Harmony(_harmonyId);
        _harmony.PatchAll();

        RunTracker.InitializeHooks();

        Logger.Info("Core.Initialize complete");
    }

    /// <summary>
    /// Called by the Loader before unloading this assembly. Must release
    /// every reference the game or Harmony holds back to this assembly,
    /// else the ALC can't collect and we'll leak assemblies on each reload.
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

        try { RunTracker.TeardownHooks(); }
        catch (Exception e) { Logger.Error($"Shutdown: TeardownHooks failed: {e}"); }

        try { _harmony?.UnpatchAll(_harmonyId); }
        catch (Exception e) { Logger.Error($"Shutdown: UnpatchAll failed: {e}"); }

        _harmony = null;

        Logger.Info("Core.Shutdown complete");
    }
}
