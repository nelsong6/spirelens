using Godot;

namespace SpireLens.Loader;

/// <summary>
/// Godot Node that lives in the scene tree and watches for F5 keypress.
/// Stays alive for the process lifetime since it belongs to the Loader,
/// not the hot-reloaded Core.
///
/// Using <c>_Input</c> (not _Process polling) so the handler fires exactly
/// once per keypress and respects Godot's input event routing.
/// </summary>
public partial class HotReloadInputNode : Node
{
    public override void _Input(InputEvent evt)
    {
        if (evt is InputEventKey key && key.Pressed && !key.Echo && key.Keycode == Key.F5)
        {
            LoaderMain.Logger.Info("F5 pressed — triggering hot reload");
            LoaderMain.ReloadCore();
        }
    }
}
