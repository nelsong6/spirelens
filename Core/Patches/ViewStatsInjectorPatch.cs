using System;
using Godot;
using HarmonyLib;
using MegaCrit.Sts2.addons.mega_text;
using MegaCrit.Sts2.Core.Nodes.CommonUi;
using MegaCrit.Sts2.Core.Nodes.Screens;
using MegaCrit.Sts2.Core.Nodes.Screens.InspectScreens;

namespace CardUtilityStats.Core.Patches;

/// <summary>
/// M4 phase 1: inject a sibling "View Stats" tickbox next to the game's
/// existing "View Upgrades" tickbox on the in-run deck view screen.
///
/// Scene structure (discovered by the DeckViewScreenProbePatch on 2026-04-19):
///   DeckViewScreen
///     ViewUpgrades              (MarginContainer, holds the whole block)
///       MarginContainer
///         Upgrades              (NUpgradePreviewTickbox)
///           ViewUpgradesLabel   (MegaLabel — sits INSIDE the tickbox)
///
/// We hook NCardsViewScreen.ConnectSignals (the post-ready wiring method;
/// _Ready throws on derived types), gate on NDeckViewScreen specifically
/// so we don't inject on unrelated card-view surfaces, duplicate the
/// entire ViewUpgrades subtree, rename the clone's inner nodes, change the
/// label text, offset the position, and connect our own toggle handler.
///
/// Phase-1 scope: checkbox renders and logs when toggled. Tooltip/description
/// override is phase 2.
/// </summary>
[HarmonyPatch(typeof(NCardsViewScreen), "ConnectSignals")]
public static class ViewStatsInjectorPatch
{
    // Track the most recently injected tickbox so phase 2 can read its state.
    public static NTickbox? LastInjectedTickbox { get; private set; }

    // Track the cloned container so Shutdown can QueueFree() it on hot-reload.
    // Otherwise the injected checkbox stays on screen after unload, referencing
    // a dead assembly and potentially causing exceptions when clicked.
    private static Node? _injectedClone;

    /// <summary>
    /// Called by CoreMain.Shutdown before unloading. QueueFrees the injected
    /// clone node so it's removed from the scene tree; Godot will clean up
    /// the underlying resources next frame. After this, the user won't see
    /// our checkbox until they reopen the deck view (which triggers the
    /// re-loaded patch on the next ConnectSignals).
    /// </summary>
    public static void TeardownInjectedUI()
    {
        if (_injectedClone != null && Godot.GodotObject.IsInstanceValid(_injectedClone))
        {
            _injectedClone.QueueFree();
            CoreMain.Logger.Info("ViewStatsInjector: cloned container queued for removal");
        }
        _injectedClone = null;
        LastInjectedTickbox = null;
    }

    [HarmonyPostfix]
    public static void Postfix(NCardsViewScreen __instance)
    {
        // Only inject on the in-run deck-view surface for now. Other CardsView
        // subclasses (compendium, card selection dialogs) aren't in scope until
        // we validate semantics per-screen — e.g. Compendium stats would need
        // lifetime aggregation (#2).
        if (__instance is not NDeckViewScreen) return;

        try { Inject(__instance); }
        catch (Exception e) { CoreMain.Logger.Error($"ViewStatsInjector failed: {e}"); }
    }

    private static void Inject(NCardsViewScreen screen)
    {
        var viewUpgradesContainer = screen.GetNodeOrNull("ViewUpgrades");
        if (viewUpgradesContainer == null)
        {
            CoreMain.Logger.Warn("ViewStatsInjector: ViewUpgrades container not found — scene structure may have changed.");
            return;
        }

        // Default Duplicate() copies structure + scripts. Runtime-connected signals
        // (made via .Connect() in ConnectSignals) are per-instance and NOT copied,
        // so our clone starts with no inherited toggle handlers — good.
        var clone = (Node)viewUpgradesContainer.Duplicate();
        clone.Name = "ViewStats";

        // Rename the inner tickbox so GetNode lookups don't collide with the original %Upgrades.
        var innerTickbox = FindChildOfType<NUpgradePreviewTickbox>(clone);
        if (innerTickbox != null)
        {
            innerTickbox.Name = "Stats";
            // Connect our toggle handler. Use the Toggled signal defined on NTickbox.
            innerTickbox.Connect(NTickbox.SignalName.Toggled, Callable.From<NTickbox>(OnStatsToggled));
            LastInjectedTickbox = innerTickbox;
        }
        else
        {
            CoreMain.Logger.Warn("ViewStatsInjector: inner tickbox not found in clone");
        }

        // Update the label text. MegaLabel.SetTextAutoSize takes a raw string.
        var label = FindChildOfType<MegaLabel>(clone);
        if (label != null)
        {
            label.Name = "ViewStatsLabel";
            label.SetTextAutoSize("View Stats");  // TODO(i18n): pull from localization once we have keys
        }
        else
        {
            CoreMain.Logger.Warn("ViewStatsInjector: label not found in clone");
        }

        // Insert into the same parent as the original (the DeckViewScreen).
        var parent = viewUpgradesContainer.GetParent();
        parent.AddChild(clone);

        // Track for Shutdown (hot-reload cleanup).
        _injectedClone = clone;

        // Rewire the clone's visuals to point at its OWN subtree.
        //
        // NTickbox.ConnectSignals uses %TickboxVisuals unique-name lookup,
        // which scopes to the scene root. After duplication there are two
        // nodes marked %TickboxVisuals under DeckViewScreen — the clone's
        // lookup resolves to the original's, so clicking the clone toggles
        // the original's visuals (or neither, depending on resolution order).
        //
        // Publicizer gives us access to the private _tickedImage /
        // _notTickedImage / _imageContainer fields on NTickbox; we reassign
        // them to the clone's own nodes via relative paths.
        if (innerTickbox != null)
        {
            var cloneVisuals = innerTickbox.GetNodeOrNull<Control>("TickboxVisuals");
            if (cloneVisuals != null)
            {
                innerTickbox._imageContainer = cloneVisuals;
                innerTickbox._tickedImage = cloneVisuals.GetNodeOrNull<Control>("Ticked");
                innerTickbox._notTickedImage = cloneVisuals.GetNodeOrNull<Control>("NotTicked");

                // Initial render: force the clone to show unticked state explicitly.
                if (innerTickbox._tickedImage != null) innerTickbox._tickedImage.Visible = false;
                if (innerTickbox._notTickedImage != null) innerTickbox._notTickedImage.Visible = true;
                innerTickbox.IsTicked = false;
            }
            else
            {
                CoreMain.Logger.Warn("ViewStatsInjector: clone's TickboxVisuals not found — cannot rewire");
            }
        }

        // Offset position — put it above the original ViewUpgrades.
        // MarginContainer is a Control, so Position is set relative to the
        // original. Empirical offset; may need adjustment once we see it.
        if (clone is Control control && viewUpgradesContainer is Control origControl)
        {
            control.Position = origControl.Position + new Vector2(0, -60);
        }

        CoreMain.Logger.Info($"ViewStatsInjector: injected — tickbox={innerTickbox != null} label={label != null}");
    }

    private static void OnStatsToggled(NTickbox tickbox)
    {
        // Phase 1: just log. Phase 2 will flip a display-mode flag and trigger
        // a card-text refresh so tooltips show our attribution stats.
        CoreMain.Logger.Info($"ViewStats toggled: IsTicked={tickbox.IsTicked}");
    }

    /// <summary>
    /// Depth-first search for a child of the given type anywhere in the node's
    /// subtree. Same helper pattern STS2MCP uses for its settings injection.
    /// </summary>
    private static T? FindChildOfType<T>(Node parent) where T : class
    {
        foreach (var child in parent.GetChildren())
        {
            if (child is T typed) return typed;
            if (child is Node childNode)
            {
                var found = FindChildOfType<T>(childNode);
                if (found != null) return found;
            }
        }
        return null;
    }
}
