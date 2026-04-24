using System;
using Godot;
using MegaCrit.Sts2.Core.Nodes;
using MegaCrit.Sts2.Core.Nodes.HoverTips;

namespace SpireLens.Core;

/// <summary>
/// Our hover tooltip panel, positioned below the game's built-in card-text
/// tooltip AND styled to match it (same hover_tip.png StyleBoxTexture, same
/// Kreon fonts, same color palette). Closely mirrors SlayTheStats'
/// TooltipHelper so the two panels look like siblings instead of alien
/// elements crashing the party.
///
/// Visual recipe — all taken directly from SlayTheStats' TooltipHelper.cs:
///   - Background: StyleBoxTexture with res://images/ui/hover_tip.png
///     (game's own panel art), 55/91/43/32 patch margins
///   - Shadow: NinePatchRect behind the panel, same texture, 8px offset,
///     25% black modulate, ZIndex 99 (panel is 100)
///   - SelfModulate (0.6, 0.68, 0.88, 1.0) — the blue tint that gives the
///     whole panel its cool-toned look
///   - Fonts: Kreon bold for the title, Kreon regular for the brand/body,
///     loaded from res://themes/kreon_*_glyph_space_one.tres
///   - Colors: gold title (0.918, 0.745, 0.318), cream body
///     (1.0, 0.9647, 0.8863), grey brand (0.408×3), shadow at 25% alpha
///   - Font sizes: 22 title, 14 brand, 20 body; line separation -2
///
/// Layout:
///   PanelContainer (our root)
///     VBoxContainer (separation 2)
///       HeaderRow (Control, 28px tall)
///         TitleLabel (top-left)      — e.g. "Card Utility"
///         BrandLabel (top-right)      — e.g. "SpireLens"
///       StatsLabel (RichTextLabel, BBCode) — the data block
///
/// Positioning: per-frame via SceneTree.ProcessFrame, stacking below
/// either SlayTheStats' panel (if loaded) or the game's NHoverTipSet
/// textHoverTipContainer (the HUD slot where "Deal 6 damage" appears).
/// </summary>
public static class StatsTooltip
{
    private const float PanelWidth = 348f;
    private const float InnerWidth = 326f;
    private const float HeaderHeight = 28f;
    private const float StackGap = 8f;
    private const float ViewportPad = 8f;
    private const float ShadowOffset = 8f;

    // Colors lifted from TooltipHelper.FontSettings defaults.
    private static readonly Color TitleColor = new(0.918f, 0.745f, 0.318f, 1f);
    private static readonly Color TextColor = new(1f, 0.9647f, 0.8863f, 1f);
    private static readonly Color BrandColor = new(0.408f, 0.408f, 0.408f, 1f);
    private static readonly Color ShadowColor = new(0f, 0f, 0f, 0.251f);
    private static readonly Color PanelTint = new(0.6f, 0.68f, 0.88f, 1f);

    private static PanelContainer? _panel;
    private static NinePatchRect? _shadow;
    private static Control? _headerRow;
    private static Label? _titleLabel;
    private static Label? _brandLabel;
    private static RichTextLabel? _statsLabel;
    private static SceneTree? _tree;
    private static Action? _frameHandler;

    // Fonts loaded from the game. Cached so we don't hit ResourceLoader
    // every hover. Nullable because load can fail in edge cases (missing
    // asset, early init, etc.) — we fall back to Godot defaults then.
    private static Font? _fontRegular;
    private static Font? _fontBold;
    private static Texture2D? _panelTexture;
    private static bool _resourcesLoaded;

    private static void LoadResourcesOnce()
    {
        if (_resourcesLoaded) return;
        _resourcesLoaded = true;

        try { _fontRegular = ResourceLoader.Load<Font>("res://themes/kreon_regular_glyph_space_one.tres"); }
        catch (Exception e) { CoreMain.LogDebug($"Kreon regular load failed: {e.Message}"); }

        try { _fontBold = ResourceLoader.Load<Font>("res://themes/kreon_bold_glyph_space_one.tres"); }
        catch (Exception e) { CoreMain.LogDebug($"Kreon bold load failed: {e.Message}"); }

        try { _panelTexture = ResourceLoader.Load<Texture2D>("res://images/ui/hover_tip.png"); }
        catch (Exception e) { CoreMain.LogDebug($"hover_tip.png load failed: {e.Message}"); }
    }

    private static StyleBox BuildPanelStyle()
    {
        // Prefer the game's textured panel; fall back to flat if texture's unavailable.
        if (_panelTexture != null)
        {
            return new StyleBoxTexture
            {
                Texture = _panelTexture,
                TextureMarginLeft = 55f,
                TextureMarginRight = 91f,
                TextureMarginTop = 43f,
                TextureMarginBottom = 32f,
                ContentMarginLeft = 22f,
                ContentMarginRight = 0f,
                ContentMarginTop = 16f,
                ContentMarginBottom = 12f,
            };
        }
        return new StyleBoxFlat
        {
            BgColor = new Color(0.11f, 0.07f, 0.06f, 0.94f),
            ContentMarginLeft = 12f,
            ContentMarginRight = 12f,
            ContentMarginTop = 10f,
            ContentMarginBottom = 10f,
            CornerRadiusTopLeft = 4,
            CornerRadiusTopRight = 4,
            CornerRadiusBottomLeft = 4,
            CornerRadiusBottomRight = 4,
        };
    }

    private static void EnsureBuilt(SceneTree tree)
    {
        if (_panel != null && GodotObject.IsInstanceValid(_panel)) return;

        LoadResourcesOnce();
        _tree = tree;

        // --- Shadow first (renders behind the panel). ---------------------
        if (_panelTexture != null)
        {
            _shadow = new NinePatchRect
            {
                Name = "SpireLensTooltipShadow",
                Texture = _panelTexture,
                PatchMarginLeft = 55,
                PatchMarginRight = 91,
                PatchMarginTop = 43,
                PatchMarginBottom = 32,
                Modulate = ShadowColor,
                ZIndex = 99,
                Visible = false,
                MouseFilter = Control.MouseFilterEnum.Ignore,
            };
            tree.Root.AddChild(_shadow);
        }

        // --- Panel container ---------------------------------------------
        _panel = new PanelContainer
        {
            Name = "SpireLensTooltip",
            CustomMinimumSize = new Vector2(PanelWidth, 0),
            ZIndex = 100,
            SelfModulate = PanelTint,
            MouseFilter = Control.MouseFilterEnum.Ignore,
            Visible = false,
        };
        _panel.AddThemeStyleboxOverride("panel", BuildPanelStyle());

        // --- Inner VBox ---------------------------------------------------
        var vbox = new VBoxContainer
        {
            Name = "VBoxContainer",
            MouseFilter = Control.MouseFilterEnum.Ignore,
            CustomMinimumSize = new Vector2(InnerWidth, 0),
        };
        vbox.AddThemeConstantOverride("separation", 2);
        _panel.AddChild(vbox);

        // --- Header row: title (left) + brand (right) --------------------
        _headerRow = new Control
        {
            Name = "HeaderRow",
            CustomMinimumSize = new Vector2(0, HeaderHeight),
            SizeFlagsHorizontal = Control.SizeFlags.Fill | Control.SizeFlags.Expand,
            MouseFilter = Control.MouseFilterEnum.Ignore,
        };
        vbox.AddChild(_headerRow);

        _titleLabel = new Label
        {
            Name = "TitleLabel",
            Text = "Card Utility",
            MouseFilter = Control.MouseFilterEnum.Ignore,
            AnchorLeft = 0f, AnchorTop = 0f, AnchorRight = 0f, AnchorBottom = 0f,
            OffsetLeft = 0f, OffsetTop = 0f,
            VerticalAlignment = VerticalAlignment.Top,
        };
        ApplyTitleStyle(_titleLabel);
        _headerRow.AddChild(_titleLabel);

        _brandLabel = new Label
        {
            Name = "BrandLabel",
            Text = "SpireLens",
            MouseFilter = Control.MouseFilterEnum.Ignore,
            AnchorLeft = 1f, AnchorRight = 1f, AnchorTop = 0f, AnchorBottom = 0f,
            // GrowDirection.Begin = grow leftward from the right anchor.
            GrowHorizontal = Control.GrowDirection.Begin,
            OffsetRight = -12f,
            OffsetTop = 0f,
            VerticalAlignment = VerticalAlignment.Top,
        };
        ApplyBrandStyle(_brandLabel);
        _headerRow.AddChild(_brandLabel);

        // --- Stats body ---------------------------------------------------
        _statsLabel = new RichTextLabel
        {
            Name = "StatsLabel",
            BbcodeEnabled = true,
            FitContent = true,
            AutowrapMode = TextServer.AutowrapMode.WordSmart,
            ScrollActive = false,
            SelectionEnabled = false,
            ShortcutKeysEnabled = false,
            MouseFilter = Control.MouseFilterEnum.Ignore,
            CustomMinimumSize = new Vector2(InnerWidth - 22f, 0),
        };
        ApplyStatsStyle(_statsLabel);
        vbox.AddChild(_statsLabel);

        tree.Root.AddChild(_panel);

        // --- Per-frame reposition ----------------------------------------
        _frameHandler = OnProcessFrame;
        tree.ProcessFrame += _frameHandler;
    }

    private static void ApplyTitleStyle(Label title)
    {
        title.AddThemeColorOverride("font_color", TitleColor);
        if (_fontBold != null) title.AddThemeFontOverride("font", _fontBold);
        title.AddThemeFontSizeOverride("font_size", 22);
        title.AddThemeColorOverride("font_shadow_color", ShadowColor);
        title.AddThemeConstantOverride("shadow_offset_x", 3);
        title.AddThemeConstantOverride("shadow_offset_y", 2);
    }

    private static void ApplyBrandStyle(Label brand)
    {
        brand.AddThemeColorOverride("font_color", BrandColor);
        if (_fontRegular != null) brand.AddThemeFontOverride("font", _fontRegular);
        brand.AddThemeFontSizeOverride("font_size", 14);
        brand.AddThemeColorOverride("font_shadow_color", ShadowColor);
        brand.AddThemeConstantOverride("shadow_offset_x", 3);
        brand.AddThemeConstantOverride("shadow_offset_y", 2);
    }

    private static void ApplyStatsStyle(RichTextLabel stats)
    {
        stats.AddThemeColorOverride("default_color", TextColor);
        if (_fontRegular != null) stats.AddThemeFontOverride("normal_font", _fontRegular);
        if (_fontBold != null)
        {
            stats.AddThemeFontOverride("bold_font", _fontBold);
            stats.AddThemeFontSizeOverride("bold_font_size", 20);
        }
        stats.AddThemeFontSizeOverride("normal_font_size", 20);
        stats.AddThemeColorOverride("font_shadow_color", ShadowColor);
        stats.AddThemeConstantOverride("shadow_offset_x", 3);
        stats.AddThemeConstantOverride("shadow_offset_y", 2);
        stats.AddThemeConstantOverride("line_separation", -2);
    }

    /// <summary>
    /// Show the tooltip with a separate title, brand (right-side subtext),
    /// and body. Separating these lets the header use crisp label text
    /// styling instead of BBCode inline inside a RichTextLabel.
    /// </summary>
    public static void Show(
        SceneTree tree,
        Control anchor,
        string titleText,
        string brandText,
        string bodyBBCode,
        bool showHeader = true)
    {
        EnsureBuilt(tree);
        if (_panel == null || _headerRow == null || _statsLabel == null || _titleLabel == null || _brandLabel == null) return;

        _headerRow.Visible = showHeader;
        _headerRow.CustomMinimumSize = new Vector2(0, showHeader ? HeaderHeight : 0f);
        _titleLabel.Text = titleText;
        _titleLabel.Visible = showHeader && !string.IsNullOrWhiteSpace(titleText);
        _brandLabel.Text = brandText;
        _brandLabel.Visible = showHeader && !string.IsNullOrWhiteSpace(brandText);
        _statsLabel.Text = bodyBBCode;
        _panel.Visible = true;
        if (_shadow != null && GodotObject.IsInstanceValid(_shadow)) _shadow.Visible = true;

        _panel.CallDeferred(Control.MethodName.ResetSize);
    }

    public static void Hide()
    {
        if (_panel != null && GodotObject.IsInstanceValid(_panel)) _panel.Visible = false;
        if (_shadow != null && GodotObject.IsInstanceValid(_shadow)) _shadow.Visible = false;
    }

    public static void Destroy()
    {
        if (_tree != null && _frameHandler != null)
        {
            try { _tree.ProcessFrame -= _frameHandler; }
            catch { }
        }
        _frameHandler = null;
        _tree = null;

        if (_shadow != null && GodotObject.IsInstanceValid(_shadow)) _shadow.QueueFree();
        if (_panel != null && GodotObject.IsInstanceValid(_panel)) _panel.QueueFree();
        _shadow = null;
        _panel = null;
        _headerRow = null;
        _titleLabel = null;
        _brandLabel = null;
        _statsLabel = null;
    }

    private static void OnProcessFrame()
    {
        if (_panel == null || !GodotObject.IsInstanceValid(_panel)) return;
        if (!_panel.Visible) return;
        if (_tree == null) return;

        try
        {
            var viewport = _tree.Root.GetViewport().GetVisibleRect();

            // Anchor choice: stack below SlayTheStats' panel if visible, else
            // below the game's textHoverTipContainer. We capture both the
            // TOP and BOTTOM Y of the anchor so we can flip to above-anchor
            // placement if below would overflow the viewport (common in
            // hand hovers on cards with many keyword tooltips — Coolheaded
            // shows Channel + Frost which fills most of the vertical space).
            float anchorX = 0f, anchorTopY = 0f, anchorBottomY = 0f;
            bool anchorFound = false;

            var sts = FindNodeByName(_tree.Root, "SlayTheStatsTooltip") as Control;
            if (sts != null && GodotObject.IsInstanceValid(sts) && sts.Visible && sts.Size.Y > 0)
            {
                anchorX = sts.GlobalPosition.X;
                anchorTopY = sts.GlobalPosition.Y;
                anchorBottomY = anchorTopY + sts.Size.Y;
                anchorFound = true;
            }
            else
            {
                var tipSet = FindHoverTipSet();
                if (tipSet != null && GodotObject.IsInstanceValid(tipSet))
                {
                    var textContainer = tipSet._textHoverTipContainer;
                    if (textContainer != null && GodotObject.IsInstanceValid(textContainer))
                    {
                        anchorX = textContainer.GlobalPosition.X;
                        anchorTopY = textContainer.GlobalPosition.Y;
                        anchorBottomY = anchorTopY + textContainer.Size.Y;
                        anchorFound = true;
                    }
                }
            }

            var panelSize = _panel.Size;

            float x, y;
            if (anchorFound)
            {
                x = anchorX;

                // Prefer below. If below doesn't fit, flip to above. If
                // above also doesn't fit (tiny viewport or gigantic panel),
                // keep below and let the final clamp sort it out.
                float belowY = anchorBottomY + StackGap;
                float aboveY = anchorTopY - panelSize.Y - StackGap;
                bool belowOverflows = belowY + panelSize.Y > viewport.End.Y - ViewportPad;
                bool aboveFits = aboveY >= ViewportPad;

                y = (belowOverflows && aboveFits) ? aboveY : belowY;
            }
            else
            {
                x = viewport.End.X - panelSize.X - 20f;
                y = viewport.Position.Y + 80f;
            }

            x = Math.Clamp(x, ViewportPad, Math.Max(ViewportPad, viewport.End.X - panelSize.X - ViewportPad));
            // Final clamp: never render off-screen. Shift up if we'd bottom
            // out, and cap to top-padding if we'd go above the viewport.
            float bottomOverflow = y + panelSize.Y - (viewport.End.Y - ViewportPad);
            if (bottomOverflow > 0) y -= bottomOverflow;
            if (y < ViewportPad) y = ViewportPad;

            _panel.Position = new Vector2(x, y);

            // Track shadow under the panel, offset by (8,8) per SlayTheStats.
            if (_shadow != null && GodotObject.IsInstanceValid(_shadow))
            {
                _shadow.Position = _panel.Position + new Vector2(ShadowOffset, ShadowOffset);
                _shadow.Size = _panel.Size;
            }
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"StatsTooltip.OnProcessFrame failed: {e.Message}");
        }
    }

    private static NHoverTipSet? FindHoverTipSet()
    {
        var container = NGame.Instance?.HoverTipsContainer;
        if (container == null) return null;
        int count = container.GetChildCount();
        for (int i = count - 1; i >= 0; i--)
        {
            var child = container.GetChild(i);
            if (child is NHoverTipSet tipSet && GodotObject.IsInstanceValid(tipSet))
                return tipSet;
        }
        return null;
    }

    private static Node? FindNodeByName(Node root, string name)
    {
        if (root == null) return null;
        if (root.Name == name) return root;
        int count = root.GetChildCount();
        for (int i = 0; i < count; i++)
        {
            var found = FindNodeByName(root.GetChild(i), name);
            if (found != null) return found;
        }
        return null;
    }
}
