using BaseLib.Config;

namespace CardUtilityStats.Config;

public sealed class CardUtilityStatsConfig : SimpleModConfig
{
    [ConfigSection("Deck View")]
    public static bool ViewStatsToggleEnabled { get; set; }

    public static bool ShowRemovedCardsInDeckView { get; set; } = true;

    [ConfigSection("Tooltips")]
    public static bool ShowHandTooltips { get; set; } = true;

    [ConfigSection("Diagnostics")]
    public static bool EnableDebugLogging { get; set; }

    [ConfigHideInUI]
    public static bool LegacyPrefsMigrated { get; set; }
}
