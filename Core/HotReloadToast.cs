using Godot;

namespace SpireLens.Core;

/// <summary>
/// Ephemeral on-screen notification for hot-reload events. Spawned by
/// <see cref="LoaderMain.ReloadCore"/> so you get immediate visual
/// confirmation that F5 did something.
///
/// Self-destructs after ~2 seconds. Uses a CanvasLayer at a high z-index
/// so it renders on top of any game UI (combat, menus, screens).
/// </summary>
public partial class HotReloadToast : CanvasLayer
{
    private const float DurationSeconds = 2.0f;

    public static void Show(SceneTree tree, string message)
    {
        if (tree == null) return;

        var layer = new HotReloadToast { Layer = 128 };  // above most game UI
        var label = new Label
        {
            Text = message,
            Position = new Vector2(20, 80),  // top-left-ish, out of the way
            Modulate = new Color(1, 1, 0, 1),  // yellow — legible on most backgrounds
        };
        // Add a drop shadow so it's readable on light backgrounds too.
        label.AddThemeConstantOverride("outline_size", 4);
        label.AddThemeColorOverride("font_outline_color", new Color(0, 0, 0, 1));
        label.AddThemeFontSizeOverride("font_size", 24);

        layer.AddChild(label);
        tree.Root.CallDeferred(Node.MethodName.AddChild, layer);

        // Self-destruct timer. CreateTimer returns a SceneTreeTimer; connecting
        // its Timeout signal to our QueueFree gets us the auto-cleanup.
        var timer = tree.CreateTimer(DurationSeconds);
        timer.Connect(SceneTreeTimer.SignalName.Timeout,
            Callable.From(() => { if (GodotObject.IsInstanceValid(layer)) layer.QueueFree(); }));
    }
}
