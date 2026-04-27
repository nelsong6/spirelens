using System;
using System.Linq;
using System.Text;
using Godot;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Models.Cards;
using MegaCrit.Sts2.Core.Nodes.Cards.Holders;

namespace SpireLens.Core.Patches;

/// <summary>
/// Shows our per-card stats tooltip when the user hovers a card in the deck
/// view (or other card-holder surfaces) AND the ViewStats checkbox is on.
///
/// Hook surface matches what SlayTheStats uses:
///   NCardHolder.CreateHoverTips  (postfix) — show on hover
///   NCardHolder.ClearHoverTips   (postfix) — hide on unhover
///
/// Our panel is independent of theirs. If both mods are active, both
/// tooltips appear — side-by-side on screen (or one on each side of the
/// card). No collision because we don't touch their TooltipHelper.
/// </summary>
[HarmonyPatch(typeof(NCardHolder), "CreateHoverTips")]
public static class CardHoverShowPatch
{
    private const int InlineKeywordIconSize = 16;
    private const string ShivMetaNote = "Reflects All Shiv Usage";
    private const string BlockIconPath = "res://images/ui/combat/block.png";
    private const string DrawCardsNextTurnPowerIconPath = "res://images/atlases/power_atlas.sprites/draw_cards_next_turn_power.tres";
    private const string BlockedDrawIconPath = DrawCardsNextTurnPowerIconPath;
    private const string EnergyPotionIconPath = "res://images/atlases/potion_atlas.sprites/energy_potion.tres";
    private const string StarIconPath = "res://images/packed/sprite_fonts/star_icon.png";
    private const string SovereignBladeMetaNote = "Reflects All Sovereign Blade Usage";

    [HarmonyPostfix]
    public static void Postfix(NCardHolder __instance)
    {
        // We DO want to fire on hand cards (combat) per Nelson's call:
        // "which version of a card I'm using" is useful info mid-combat
        // when the same card has multiple instances with different stats.
        // The placement is handled in StatsTooltip: if stacking below the
        // game's hover tips would overflow the viewport (common for hand
        // hovers on cards with multiple keyword tooltips like Coolheaded),
        // we stack above instead.

        RuntimeOptionsProvider.Refresh();
        if (__instance is NHandCardHolder && !RuntimeOptionsProvider.Current.ShowHandTooltips)
            return;

        // Gate on our checkbox state. If it's not even injected yet (no deck
        // view opened this session) or unchecked, do nothing.
        var tickbox = ViewStatsInjectorPatch.LastInjectedTickbox;
        var viewStatsEnabled = tickbox?.IsTicked ?? RuntimeOptionsProvider.Current.ViewStatsToggleEnabled;
        if (!viewStatsEnabled) return;

        try
        {
            var tree = Engine.GetMainLoop() as SceneTree;
            if (tree == null) return;

            var cardModel = __instance.CardModel;
            if (cardModel == null) return;

            // Per-instance display: every deck card gets a stable "#N" number
            // (per Nelson: "all cards should have a bit of an ID attached"),
            // assigned at RunStarted for the starting deck and lazily for
            // any card added mid-run.
            //
            // Upgrade marker strip: the game's Title field includes a trailing
            // "+" (or "++") when the card is upgraded — "Defend" becomes
            // "Defend+" in the game's rendering. Per Nelson's call, we strip
            // that for the tooltip header so the instance name stays stable
            // across upgrade ("Defend #1" is always "Defend #1"). Upgrade
            // state is already shown in the Lineage section below.
            // Gated on CurrentUpgradeLevel > 0 so we don't accidentally
            // strip a legitimate trailing "+" from a card whose base name
            // happens to end that way.
            var rawTitle = cardModel.Title;
            if (cardModel.CurrentUpgradeLevel > 0 && !string.IsNullOrEmpty(rawTitle))
            {
                rawTitle = rawTitle.TrimEnd('+').TrimEnd();
            }
            var title = !string.IsNullOrWhiteSpace(rawTitle) ? rawTitle : cardModel.Id.ToString();
            var instanceNum = RunTracker.GetInstanceNumber(cardModel);
            var displayName = instanceNum > 0 ? $"{title} #{instanceNum}" : title;

            // The hover card is the deck original (DeckVersion is null), so
            // its hash IS the canonical hash. Compare against the play-time
            // log's canonicalHash to verify attribution lands on the right
            // key. If they match → dict lookup must succeed.
            CoreMain.LogDebug($"hover: id={cardModel.Id} rawTitle='{rawTitle}' instance={instanceNum} displayName='{displayName}' hash={cardModel.GetHashCode()} deckVersionNull={cardModel.DeckVersion == null}");

            // Hand hovers stay compact by default. Issue-agent validation and
            // power users can opt into the full breakdown for hand tooltips.
            bool compact = __instance is NHandCardHolder
                && !RuntimeOptionsProvider.Current.UseVerboseHandStats;
            var body = BuildBodyBBCode(cardModel, displayName, compact);
            // Reuse the gold title slot for the hovered card's instance name
            // on every surface. That's the highest-signal identity marker,
            // and it keeps the compact and full tooltips visually aligned.
            StatsTooltip.Show(
                tree,
                __instance,
                displayName,
                "SpireLens",
                body);
        }
        catch (System.Exception e)
        {
            CoreMain.Logger.Error($"CardHoverShow failed: {e.Message}");
        }
    }

    /// <summary>
    /// Render the BODY portion of the tooltip — the stats block. Title and
    /// brand are set separately on the Label nodes inside StatsTooltip so
    /// they can use proper Kreon font + gold/grey coloring instead of BBCode
    /// inline hacks. This method only produces what goes in the RichTextLabel.
    ///
    /// <paramref name="compact"/> controls density:
    ///   - true (hand hovers): just the high-signal numbers the player
    ///     needs mid-combat — Played/Drawn, Total damage (if attack),
    ///     Energy gained (if any), Block gained (if any), Kills (if any). Skips lineage, energy
    ///     details, averages, percentages.
    ///   - false (deck view, graveyard, draw pile, etc.): full breakdown
    ///     including lineage and all tabled stats.
    /// </summary>
    private static string BuildBodyBBCode(MegaCrit.Sts2.Core.Models.CardModel cardModel, string displayName, bool compact = false)
    {
        var run = RunTracker.Current;
        var sb = new StringBuilder();
        bool isShivMetaCard = RunTracker.IsShivDeckViewCard(cardModel);
        bool isSovereignBladeMetaCard = RunTracker.IsSovereignBladeDeckViewCard(cardModel);
        bool isSupplementalMetaCard = isShivMetaCard || isSovereignBladeMetaCard;

        // The card identity now lives in the gold title slot for both compact
        // and full views, so repeating it again in the body just adds noise.
        // Supplemental meta cards (pooled Shiv / Sovereign Blade)
        // get a red explanatory banner instead of the generic ephemeral
        // "not present in deck" note.
        if (isShivMetaCard)
            sb.Append($"[color=#e04c4c][b]{ShivMetaNote}[/b][/color]\n");
        else if (isSovereignBladeMetaCard)
            sb.Append($"[color=#e04c4c][b]{SovereignBladeMetaNote}[/b][/color]\n");

        // Merges committed run + current pending combat so mid-combat plays
        // show up immediately (don't wait for CombatEnded). If we have no
        // aggregate entry yet for this card (unplayed), treat it as an
        // empty/zero aggregate and render the normal stats layout with
        // zeros. Per Nelson: "no data this run" was an awkward escape
        // hatch — zeros are more informative and structurally consistent.
        var agg = RunTracker.GetEffectiveAggregate(cardModel) ?? new CardAggregate();
        CoreMain.LogDebug($"  lookup: Plays={agg.Plays} Intended={agg.TotalIntended}");

        // Compact mode (hand hovers) — skip lineage and everything tabular,
        // return just the signals a player needs mid-combat.
        if (compact)
        {
            AppendCompactBody(sb, cardModel, agg);
            return sb.ToString();
        }

        // Per-play averages — the actual "utility" signal. Guard against
        // div-by-zero for the unplayed case.
        float avgIntended = agg.Plays > 0 ? (float)agg.TotalIntended / agg.Plays : 0f;
        float avgEffective = agg.Plays > 0 ? (float)agg.TotalEffective / agg.Plays : 0f;
        float overkillPct = agg.TotalIntended > 0 ? 100f * agg.TotalOverkill / agg.TotalIntended : 0f;
        float blockedPct = agg.TotalIntended > 0 ? 100f * agg.TotalBlocked / agg.TotalIntended : 0f;

        // Lineage: when/how the card entered the deck, and any upgrades
        // since. Label/value style matches the stats tables below — no
        // colons, bold numbers, subdued surrounding prose.
        //
        // Special case: cards that aren't in the player's permanent deck
        // (combat-generated Souls, Shivs, short-lived transformed cards,
        // etc.). For those, "Received floor X" is misleading — the card
        // isn't a deck member, it just exists transiently. Render a
        // distinct "Card not present in deck" note instead.
        //
        // FloorAdded: the game sets this to 1 for starter cards (see
        // Player.PopulateStartingDeck). Mid-run adds get current floor.
        // No special "starting deck" text — starters just show "floor 1".
        if (IsCardInDeck(cardModel))
        {
            //   "Received floor 1"                        → starter or floor-1 acquisition
            //   "Received floor 22, came upgraded +1"      → pre-upgraded (shop/event)
            //   "Received floor 22" + "Upgraded floor 22 → +1" → got and upgraded same floor
            string floorStr = agg.FloorAdded.HasValue
                ? $"floor [b]{agg.FloorAdded.Value}[/b]"
                : "unknown floor";
            if (agg.InitialUpgradeLevel > 0)
                sb.Append($"[color=#b5b5b5]Received {floorStr}, came upgraded +[b]{agg.InitialUpgradeLevel}[/b][/color]\n");
            else
                sb.Append($"[color=#b5b5b5]Received {floorStr}[/color]\n");

            foreach (var ue in RunTracker.GetUpgradeEvents(cardModel))
            {
                string ufloor = ue.Floor.HasValue
                    ? $"floor [b]{ue.Floor.Value}[/b]"
                    : "?";
                int level = ue.UpgradeLevel ?? 0;
                sb.Append($"[color=#b5b5b5]Upgraded {ufloor} → +[b]{level}[/b][/color]\n");
            }

            // Removal marker. Shown in the tooltip so users can tell at a
            // glance that this is a removed card even without the visual
            // grouping in the deck view. Floor 0 defaults to "?" text.
            if (agg.Removed)
            {
                string rfloor = agg.RemovedAtFloor.HasValue
                    ? $"floor [b]{agg.RemovedAtFloor.Value}[/b]"
                    : "[b]?[/b]";
                sb.Append($"[color=#b5b5b5]Removed {rfloor}[/color]\n");
            }
        }
        else
        {
            // Distinguish "was removed from deck" from "never entered deck"
            // (combat-generated ephemerals like Souls/Shivs). Removed gets
            // a red bold banner since it's an important run decision to
            // flag at a glance. Supplemental deck-view meta cards already
            // emitted their own explanatory red banner above, so we suppress
            // the generic "not present" line for them. Other ephemerals keep
            // the subdued grey note.
            if (agg.Removed)
                sb.Append("[color=#e04c4c][b]Card Removed[/b][/color]\n");
            else if (!isSupplementalMetaCard)
                sb.Append("[color=#b5b5b5]Card not present in deck[/color]\n");
        }

        // All stat rows use the same 3-col table layout for visual
        // consistency: label | value | (optional percent). Rows without a
        // percentage get an empty 3rd cell so the label and value columns
        // align vertically across every row in the tooltip. Cell padding
        // prevents adjacent cells from crowding against each other (was
        // observed as "Played/Drawn1/1100%" with zero space between).
        bool isUnplayable = cardModel.Type == CardType.Curse
            || (cardModel.Keywords != null && cardModel.Keywords.Contains(CardKeyword.Unplayable));

        if (isUnplayable)
        {
            // For unplayable cards, just show Drawn. Played is always 0.
            Row3(sb, GetDrawStatLabel("drawn"), agg.TimesDrawn.ToString(), "");
        }
        else
        {
            // Playable cards: show Played/Drawn ratio with play rate %.
            float playRate = agg.TimesDrawn > 0 ? 100f * agg.Plays / agg.TimesDrawn : 0f;
            Row3(sb, "Played/Drawn", $"{agg.Plays}/{agg.TimesDrawn}", $"{playRate:F0}%");
        }

        AppendMakeItSoStats(sb, cardModel, agg, compact: false);

        bool hasDedicatedPoison = AppendDedicatedPoisonStats(sb, agg, compact: false);
        AppendAppliedEffects(sb, agg, compact: false, excludePoison: hasDedicatedPoison);
        AppendArtifactBlockedSummary(sb, agg, excludePoison: hasDedicatedPoison);

        // Energy-gain rows — cards like Adrenaline / Concentrate / energy
        // pot-style effects need a direct "what did this card give me?"
        // stat, independent of the existing energy-spent cost tracking.
        if (agg.TotalEnergyGenerated > 0)
        {
            float avgGenerated = agg.Plays > 0 ? (float)agg.TotalEnergyGenerated / agg.Plays : 0f;
            Row3(sb, GetEnergyStatLabel("gained"), agg.TotalEnergyGenerated.ToString(), "");
            Row3(sb, GetEnergyStatLabel("avg gained"), $"{avgGenerated:F1}", "");
        }

        if (agg.TotalStarsGenerated > 0)
        {
            float avgGenerated = agg.Plays > 0 ? (float)agg.TotalStarsGenerated / agg.Plays : 0f;
            Row3(sb, GetStarStatLabel("gained"), agg.TotalStarsGenerated.ToString(), "");
            Row3(sb, GetStarStatLabel("avg gained"), $"{avgGenerated:F1}", "");
        }

        if (agg.TotalForgeGenerated > 0m)
        {
            decimal avgGenerated = agg.Plays > 0 ? agg.TotalForgeGenerated / agg.Plays : 0m;
            Row3(sb, GetForgeStatLabel("gained"), FormatDecimal(agg.TotalForgeGenerated), "");
            Row3(sb, GetForgeStatLabel("avg gained"), FormatDecimal(avgGenerated), "");
        }

        // Energy-spent rows — only rendered when the card's cost is actually
        // variable (see IsEnergyInteresting). Same 3-col layout as every
        // other stat row; percent column stays empty since there's nothing
        // to percentage-ify here.
        if (IsEnergyInteresting(cardModel, agg))
        {
            float avgEnergy = agg.Plays > 0 ? (float)agg.TotalEnergySpent / agg.Plays : 0f;
            Row3(sb, GetEnergyStatLabel("total spent"), agg.TotalEnergySpent.ToString(), "");
            Row3(sb, GetEnergyStatLabel("avg cost"), $"{avgEnergy:F1}", "");
        }

        if (IsStarInteresting(cardModel, agg))
        {
            float avgStars = agg.Plays > 0 ? (float)agg.TotalStarsSpent / agg.Plays : 0f;
            Row3(sb, GetStarStatLabel("total spent"), agg.TotalStarsSpent.ToString(), "");
            Row3(sb, GetStarStatLabel("avg cost"), $"{avgStars:F1}", "");
        }

        // Damage section rules:
        //   - Attack cards: always show the damage block. With zeros for
        //     unplayed or 0-damage attacks (target died / fully blocked
        //     case), with the full breakdown once damage has been dealt.
        //   - Non-attack (Skill/Power/Status/Curse): skip the section
        //     entirely unless we somehow accumulated damage (edge case;
        //     shouldn't happen but respects the data if it does).
        bool isAttack = cardModel.Type == CardType.Attack;
        bool showDamage = isAttack || agg.TotalIntended > 0;
        if (showDamage)
        {
            // Total damage = effective damage = HP actually removed by this
            // card across the whole run. "Effective" over "intended" because
            // that's what players mean by "this card has done X damage" —
            // block and overkill waste don't count.
            // Damage section in the same 3-col layout. Total damage =
            // effective damage = HP actually removed. "Effective" over
            // "intended" because that's what players mean by "X damage".
            // Avg intended intentionally omitted pending issue #15.
            Row3(sb, "Total damage", agg.TotalEffective.ToString(), "");
            Row3(sb, "Avg effective", $"{avgEffective:F1}", "");
            _ = avgIntended;  // still computed above; silence unused warning

            // Clarify 0 damage for attacks that played without dealing any:
            // the game skips DamageReceivedEntry when the target is in the
            // "dead but not yet removed" state, so the play is real but
            // we have no damage event to attribute. Rendered as a subdued
            // own-line annotation rather than inline with Total damage.
            if (isAttack && agg.Plays > 0 && agg.TotalIntended == 0)
                sb.Append("[color=#7a7a85]  (target died / fully blocked)[/color]\n");
            // Overkill and Blocked: whole number + %. Same 3-col row as
            // everything else; here the percent cell is populated.
            Row3(sb, "Overkill", agg.TotalOverkill.ToString(), $"{overkillPct:F0}%");
            Row3(sb, "Blocked", agg.TotalBlocked.ToString(), $"{blockedPct:F0}%");
            if (agg.Kills > 0) Row3(sb, "Kills", agg.Kills.ToString(), "");
        }

        // Block gained — rendered for cards that have actually produced
        // block. Absorbed uses FIFO consumption across the player's block
        // ledger; wasted uses LIFO across whatever survived until clear/
        // expiry, which matches the "later block was redundant overfill"
        // mental model described in issue #6.
        if (agg.TotalBlockGained > 0)
        {
            float avgBlock = agg.Plays > 0 ? (float)agg.TotalBlockGained / agg.Plays : 0f;
            float absorbedPct = 100f * agg.TotalBlockEffective / agg.TotalBlockGained;
            float wastedPct = 100f * agg.TotalBlockWasted / agg.TotalBlockGained;
            RowDual(sb, GetBlockStatLabel("gained"), agg.TotalBlockGained.ToString(), GetBlockStatLabel("avg"), $"{avgBlock:F1}");
            Row3(sb, GetBlockStatLabel("absorbed"), agg.TotalBlockEffective.ToString(), $"{absorbedPct:F0}%");
            Row3(sb, GetBlockStatLabel("wasted"), agg.TotalBlockWasted.ToString(), $"{wastedPct:F0}%");
        }

        // Discarded count — shown only when > 0 because for most cards
        // discarding doesn't happen. When it does (end-of-turn with card
        // still in hand, discard-triggering effects), the number is
        // useful signal — a card you keep discarding without playing is
        // probably dead weight.
        if (agg.TimesDiscarded > 0)
            Row3(sb, "Discarded", agg.TimesDiscarded.ToString(), "");

        // Pile-top placements — signals draw-order manipulation. Only
        // rendered when > 0 to keep noise down on normal cards.
        if (agg.TimesPlacedOnTopFromHand > 0)
            Row3(sb, "Top from hand", agg.TimesPlacedOnTopFromHand.ToString(), "");
        if (agg.TimesPlacedOnTopFromDiscard > 0)
            Row3(sb, "Top from graveyard", agg.TimesPlacedOnTopFromDiscard.ToString(), "");

        // Exhausted other cards — Havoc-style side-effect stat. Only
        // shown for cards that have actually caused an exhaust.
        if (agg.TimesExhaustedOtherCards > 0)
            Row3(sb, "Exhausted others", agg.TimesExhaustedOtherCards.ToString(), "");

        // How often THIS card itself got exhausted. Full-view only; useful
        // for exhaust-tag cards and ephemeral generated cards, but not worth
        // the space in the compact in-hand view.
        if (agg.TimesExhausted > 0)
            Row3(sb, "Exhausted", agg.TimesExhausted.ToString(), "");

        AppendCardDrawStats(sb, agg);

        // HP lost from playing this card — Ironclad self-damage cards.
        // POST-reduction value, so Tungsten Rod / buffer interactions
        // show as reduced HP loss, which is the true cost signal.
        if (agg.TotalHpLost > 0)
            Row3(sb, "HP lost", agg.TotalHpLost.ToString(), "");

        // No footer. Previously we rendered "A4 · DEFECT · this run" here
        // as a mirror of SlayTheStats' filter-context footer — but they need
        // that line because their data aggregates across many runs with
        // configurable filters. Ours is scoped to one run by construction,
        // so the line was repeating back run info the user already knows.
        // Reintroduce a scope marker when/if we add cross-run lifetime stats.
        _ = run;  // silence unused-variable warning; keeps RunTracker reference live for debug.

        return sb.ToString();
    }

    /// <summary>
    /// Compact stats body for hand hovers during combat. High-signal
    /// numbers only — the player's deciding what to play, not studying
    /// lifetime performance.
    ///
    /// Shows: Played/Drawn ratio, Total damage (if attack), Energy gained
    /// (if any), Block gained (if any), Kills (if any). Skips: lineage, most energy details, per-play
    /// averages, overkill/blocked percentages. Everything uses the same
    /// 3-col layout as the full view for visual consistency.
    /// </summary>
    private static void AppendCompactBody(StringBuilder sb, MegaCrit.Sts2.Core.Models.CardModel cardModel, CardAggregate agg)
    {
        bool isAttack = cardModel.Type == CardType.Attack;

        bool isUnplayable = cardModel.Type == CardType.Curse
            || (cardModel.Keywords != null && cardModel.Keywords.Contains(CardKeyword.Unplayable));

        if (isUnplayable)
        {
            // For unplayable cards, just show Drawn. Played is always 0.
            Row3(sb, GetDrawStatLabel("drawn"), agg.TimesDrawn.ToString(), "");
        }
        else
        {
            float playRate = agg.TimesDrawn > 0 ? 100f * agg.Plays / agg.TimesDrawn : 0f;
            Row3(sb, "Played/Drawn", $"{agg.Plays}/{agg.TimesDrawn}", $"{playRate:F0}%");
        }

        bool hasDedicatedPoison = AppendDedicatedPoisonStats(sb, agg, compact: true);
        AppendAppliedEffects(sb, agg, compact: true, excludePoison: hasDedicatedPoison);

        if (agg.TotalEnergyGenerated > 0)
            Row3(sb, GetEnergyStatLabel("gained"), agg.TotalEnergyGenerated.ToString(), "");

        if (agg.TotalStarsGenerated > 0)
            Row3(sb, GetStarStatLabel("gained"), agg.TotalStarsGenerated.ToString(), "");

        if (agg.TotalForgeGenerated > 0m)
            Row3(sb, GetForgeStatLabel("gained"), FormatDecimal(agg.TotalForgeGenerated), "");

        AppendMakeItSoStats(sb, cardModel, agg, compact: true);

        bool showDamage = isAttack || agg.TotalIntended > 0;
        if (showDamage)
        {
            Row3(sb, "Total damage", agg.TotalEffective.ToString(), "");
            if (agg.Kills > 0) Row3(sb, "Kills", agg.Kills.ToString(), "");
        }

        if (agg.TotalBlockGained > 0)
            Row3(sb, GetBlockStatLabel("gained"), agg.TotalBlockGained.ToString(), "");

        if (agg.TotalHpLost > 0)
            Row3(sb, "HP lost", agg.TotalHpLost.ToString(), "");
    }

    /// <summary>
    /// A deck card is "in deck" if its canonical deck reference still
    /// exists in the player's permanent deck list. Combat clones point back
    /// to the deck original via DeckVersion; deck-view cards are already the
    /// canonical object. Removed cards are intentionally NOT in the list.
    ///
    /// If we can't read the deck state (no active run, etc.) we default to
    /// TRUE so we fall back to the normal lineage display. That's the safer
    /// path — mis-reporting a deck card as "not present" is worse than the
    /// reverse.
    /// </summary>
    private static bool IsCardInDeck(MegaCrit.Sts2.Core.Models.CardModel card)
    {
        try
        {
            var player = MegaCrit.Sts2.Core.Runs.RunManager.Instance?.State?.Players.FirstOrDefault();
            if (player?.Deck?.Cards == null) return true;  // unknown → assume deck

            var canonical = card.DeckVersion ?? card;
            foreach (var c in player.Deck.Cards)
            {
                var cCanonical = c.DeckVersion ?? c;
                if (System.Object.ReferenceEquals(cCanonical, canonical)) return true;
            }
            return false;
        }
        catch
        {
            return true;  // error → assume deck
        }
    }

    /// <summary>
    /// Emit a single stat row in the canonical 3-column layout used for
    /// every stat line in the tooltip. <paramref name="pct"/> can be empty
    /// — the cell's still present so the label and value columns align
    /// vertically with rows that DO have a percentage (Overkill, Blocked,
    /// Played/Drawn). The cell padding keeps adjacent columns from
    /// crowding visually (fixes "Played/Drawn1/1100%"-style crowding).
    ///
    /// Column weights: label=4, value=1, percent=1. Label dominates
    /// (~66% of width) so the label text always fits; numeric columns
    /// are narrow since their content is typically 1-5 chars.
    /// Padding: label gets right-padding (12px), value gets right-padding
    /// (12px) so it sits off the percent column, percent gets left-side
    /// padding from value's right-padding and small right-padding (4px).
    /// </summary>
    private static void Row3(StringBuilder sb, string label, string value, string pct)
    {
        sb.Append("[table=3]");
        sb.Append($"[cell expand=4 padding=0,0,12,0][color=#e0e0e0]{label}[/color][/cell]");
        sb.Append($"[cell expand=1 padding=0,0,12,0][right][b]{value}[/b][/right][/cell]");
        sb.Append($"[cell expand=1 padding=0,0,4,0][right][color=#b5b5b5]{pct}[/color][/right][/cell]");
        sb.Append("[/table]\n");
    }

    /// <summary>
    /// Emit a two-stat row for closely-related values that read better side by
    /// side than stacked vertically. Used for compact pairs like
    /// "Block gained" / "Avg block" where both numbers belong to the same
    /// section and neither needs a percentage column.
    /// </summary>
    private static void RowDual(StringBuilder sb, string leftLabel, string leftValue, string rightLabel, string rightValue)
    {
        sb.Append("[table=4]");
        sb.Append($"[cell expand=3 padding=0,0,12,0][color=#e0e0e0]{leftLabel}[/color][/cell]");
        sb.Append($"[cell expand=1 padding=0,0,18,0][right][b]{leftValue}[/b][/right][/cell]");
        sb.Append($"[cell expand=3 padding=0,0,12,0][color=#e0e0e0]{rightLabel}[/color][/cell]");
        sb.Append($"[cell expand=1 padding=0,0,4,0][right][b]{rightValue}[/b][/right][/cell]");
        sb.Append("[/table]\n");
    }

    private static bool AppendDedicatedPoisonStats(StringBuilder sb, CardAggregate agg, bool compact)
    {
        var poison = GetPoisonSummary(agg);
        if (poison == null) return false;

        if (compact)
        {
            if (poison.Value.TimesApplied <= 0 && poison.Value.TotalAmountApplied == 0m)
                return false;

            var extra = poison.Value.TimesApplied > 0
                ? poison.Value.TimesApplied > 1 ? $"{poison.Value.TimesApplied}x" : "1x"
                : "";
            Row3(sb, GetPoisonStatLabel(poison.Value, "applied"), FormatDecimal(poison.Value.TotalAmountApplied), extra);
            return true;
        }

        decimal avgPoison = agg.Plays > 0 ? poison.Value.TotalAmountApplied / agg.Plays : 0m;

        Row3(sb, GetPoisonStatLabel(poison.Value, "total applied"), FormatDecimal(poison.Value.TotalAmountApplied), "");
        Row3(sb, GetPoisonStatLabel(poison.Value, "avg applied"), FormatDecimal(avgPoison), "");
        Row3(sb, GetPoisonStatLabel(poison.Value, "applications"), poison.Value.TimesApplied.ToString(), "");

        if (poison.Value.TotalTriggeredEffectiveDamage > 0m || poison.Value.TotalTriggeredOverkill > 0m)
        {
            decimal avgPoisonDamage = agg.Plays > 0 ? poison.Value.TotalTriggeredEffectiveDamage / agg.Plays : 0m;
            Row3(sb, GetPoisonStatLabel(poison.Value, "damage"), FormatDecimal(poison.Value.TotalTriggeredEffectiveDamage), "");
            Row3(sb, GetPoisonStatLabel(poison.Value, "avg damage"), FormatDecimal(avgPoisonDamage), "");

            if (poison.Value.TotalTriggeredOverkill > 0m)
                Row3(sb, GetPoisonStatLabel(poison.Value, "overkill"), FormatDecimal(poison.Value.TotalTriggeredOverkill), "");
        }

        if (poison.Value.TimesBlockedByArtifact > 0)
        {
            string extra = poison.Value.TimesBlockedByArtifact > 1
                ? $"{poison.Value.TimesBlockedByArtifact}x"
                : "1x";
            Row3(sb, GetPoisonStatLabel(poison.Value, "blocked by Artifact"), FormatDecimal(poison.Value.TotalAmountBlockedByArtifact), extra);
        }

        return true;
    }

    private static PoisonEffectSummary? GetPoisonSummary(CardAggregate agg)
    {
        if (agg.AppliedEffects == null || agg.AppliedEffects.Count == 0) return null;

        int timesApplied = 0;
        decimal totalAmountApplied = 0m;
        int timesBlockedByArtifact = 0;
        decimal totalAmountBlockedByArtifact = 0m;
        decimal totalTriggeredEffectiveDamage = 0m;
        decimal totalTriggeredOverkill = 0m;
        string? iconPath = null;

        foreach (var effect in agg.AppliedEffects.Values)
        {
            if (!IsPoisonEffect(effect)) continue;

            timesApplied += effect.TimesApplied;
            totalAmountApplied += effect.TotalAmountApplied;
            timesBlockedByArtifact += effect.TimesBlockedByArtifact;
            totalAmountBlockedByArtifact += effect.TotalAmountBlockedByArtifact;
            totalTriggeredEffectiveDamage += effect.TotalTriggeredEffectiveDamage;
            totalTriggeredOverkill += effect.TotalTriggeredOverkill;
            if (string.IsNullOrWhiteSpace(iconPath) && !string.IsNullOrWhiteSpace(effect.IconPath))
                iconPath = effect.IconPath;
        }

        if (timesApplied <= 0 &&
            totalAmountApplied == 0m &&
            timesBlockedByArtifact <= 0 &&
            totalAmountBlockedByArtifact == 0m &&
            totalTriggeredEffectiveDamage == 0m &&
            totalTriggeredOverkill == 0m)
            return null;

        return new PoisonEffectSummary(
            timesApplied,
            totalAmountApplied,
            timesBlockedByArtifact,
            totalAmountBlockedByArtifact,
            totalTriggeredEffectiveDamage,
            totalTriggeredOverkill,
            iconPath);
    }

    private static string GetPoisonStatLabel(PoisonEffectSummary poison, string suffix)
    {
        if (!string.IsNullOrWhiteSpace(poison.IconPath))
            return GetInlineIconStatLabel(poison.IconPath, suffix);

        return $"Poison {suffix}";
    }

    private static string GetBlockStatLabel(string suffix)
    {
        return GetInlineIconStatLabel(BlockIconPath, suffix);
    }

    private static string GetDrawStatLabel(string suffix)
    {
        return GetInlineIconStatLabel(DrawCardsNextTurnPowerIconPath, suffix);
    }

    private static string GetEnergyStatLabel(string suffix)
    {
        return GetInlineIconStatLabel(EnergyPotionIconPath, suffix);
    }

    private static string GetStarStatLabel(string suffix)
    {
        return GetInlineIconStatLabel(StarIconPath, suffix);
    }

    private static string GetForgeStatLabel(string suffix)
    {
        return suffix switch
        {
            "avg gained" => "Forge avg",
            _ => $"Forge {suffix}",
        };
    }

    private static void AppendMakeItSoStats(
        StringBuilder sb,
        MegaCrit.Sts2.Core.Models.CardModel cardModel,
        CardAggregate agg,
        bool compact)
    {
        if (cardModel is not MakeItSo) return;

        int? currentCounter = null;
        int threshold = 0;
        if (RunTracker.TryGetMakeItSoSkillCounter(cardModel, out var current, out var currentThreshold))
        {
            currentCounter = current;
            threshold = currentThreshold;
        }

        AppendMakeItSoStats(sb, agg, compact, currentCounter, threshold);
    }

    private static void AppendMakeItSoStats(
        StringBuilder sb,
        CardAggregate agg,
        bool compact,
        int? currentCounter,
        int threshold)
    {
        if (currentCounter.HasValue && threshold > 0)
            Row3(sb, "Skills this turn", $"{currentCounter.Value}/{threshold}", "");

        if (!compact && agg.TimesSummonedToHand > 0)
            Row3(sb, "Times triggered", agg.TimesSummonedToHand.ToString(), "");
    }
    private static string GetInlineIconStatLabel(string iconPath, string suffix)
    {
        var normalizedPath = NormalizeResourcePath(iconPath);
        return $"[img={InlineKeywordIconSize}x{InlineKeywordIconSize}]{normalizedPath}[/img] {suffix}";
    }

    private static string NormalizeResourcePath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return string.Empty;

        return path.StartsWith("res://", StringComparison.Ordinal)
            ? path
            : $"res://{path.TrimStart('/')}";
    }

    private static void AppendAppliedEffects(StringBuilder sb, CardAggregate agg, bool compact, bool excludePoison)
    {
        if (agg.AppliedEffects == null || agg.AppliedEffects.Count == 0) return;
        bool hasArtifactBlockedSummary = GetArtifactBlockedTotals(agg, excludePoison).Times > 0;
        var visibleEffects = agg.AppliedEffects.Values
            .Where(effect => ShouldShowAppliedEffectRow(effect, hasArtifactBlockedSummary, excludePoison))
            .OrderByDescending(e => e.TimesApplied)
            .ThenBy(e => e.DisplayName)
            .ToList();

        if (visibleEffects.Count == 0) return;

        if (!compact)
            sb.Append("[color=#b5b5b5]Effects applied[/color]\n");

        int shown = 0;
        foreach (var effect in visibleEffects)
        {
            if (compact && shown >= 2) break;

            var label = GetAppliedEffectLabel(effect);
            var value = FormatDecimal(effect.TotalAmountApplied);
            var extra = effect.TimesApplied > 1 ? $"{effect.TimesApplied}x" : "1x";
            Row3(sb, label, value, extra);

            if (!compact && effect.TotalTriggeredCardsDrawBlocked > 0)
                Row3(sb, GetAppliedEffectBlockedDrawLabel(effect), effect.TotalTriggeredCardsDrawBlocked.ToString(), "");

            shown++;
        }
    }

    private static void AppendArtifactBlockedSummary(StringBuilder sb, CardAggregate agg, bool excludePoison)
    {
        var (times, amount) = GetArtifactBlockedTotals(agg, excludePoison);
        if (times <= 0) return;

        var label = GetArtifactStrippedLabel(agg, excludePoison);
        var value = times.ToString();
        var extra = amount != times ? $"{FormatDecimal(amount)} amt" : "";
        Row3(sb, label, value, extra);
    }

    private static (int Times, decimal Amount) GetArtifactBlockedTotals(CardAggregate agg, bool excludePoison)
    {
        if (agg.AppliedEffects == null || agg.AppliedEffects.Count == 0)
            return (0, 0m);

        int times = 0;
        decimal amount = 0m;
        foreach (var effect in agg.AppliedEffects.Values)
        {
            if (excludePoison && IsPoisonEffect(effect)) continue;
            times += effect.TimesBlockedByArtifact;
            amount += effect.TotalAmountBlockedByArtifact;
        }

        return (times, amount);
    }

    private static bool ShouldShowAppliedEffectRow(AppliedEffectAggregate effect, bool hasArtifactBlockedSummary, bool excludePoison)
    {
        if (excludePoison && IsPoisonEffect(effect))
            return false;

        if (effect.TotalAmountApplied == 0m && effect.TimesBlockedByArtifact > 0)
            return false;

        if (hasArtifactBlockedSummary && IsArtifactEffect(effect) && effect.TotalAmountApplied < 0m)
            return false;

        return true;
    }

    private static string GetArtifactStrippedLabel(CardAggregate agg, bool excludePoison)
    {
        if (agg.AppliedEffects != null)
        {
            foreach (var effect in agg.AppliedEffects.Values)
            {
                if (excludePoison && IsPoisonEffect(effect)) continue;
                if (!IsArtifactEffect(effect) || string.IsNullOrWhiteSpace(effect.IconPath)) continue;
                return $"[img={InlineKeywordIconSize}x{InlineKeywordIconSize}]{effect.IconPath}[/img] stripped";
            }
        }

        return "Artifact stripped";
    }

    private static bool IsArtifactEffect(AppliedEffectAggregate effect)
    {
        if (!string.IsNullOrWhiteSpace(effect.EffectId) &&
            effect.EffectId.Contains("ARTIFACT_POWER", StringComparison.OrdinalIgnoreCase))
            return true;

        return string.Equals(effect.DisplayName, "Artifact", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsPoisonEffect(AppliedEffectAggregate effect)
    {
        if (!string.IsNullOrWhiteSpace(effect.EffectId) &&
            effect.EffectId.Contains("POISON", StringComparison.OrdinalIgnoreCase))
            return true;

        return string.Equals(effect.DisplayName, "Poison", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetAppliedEffectLabel(AppliedEffectAggregate effect)
    {
        var label = string.IsNullOrWhiteSpace(effect.DisplayName) ? effect.EffectId : effect.DisplayName;
        if (!string.IsNullOrWhiteSpace(effect.IconPath))
            return GetInlineIconStatLabel(effect.IconPath, label);
        if (IsEnergyEffect(effect))
            return GetEnergyEffectLabel(label);
        if (IsStarEffect(effect))
            return GetStarEffectLabel(label);
        if (IsNoxiousFumesEffect(effect))
            return GetIconBackedEffectLabel(label, effect.IconPath);

        return label;
    }

    private static string GetAppliedEffectBlockedDrawLabel(AppliedEffectAggregate effect)
    {
        return GetBlockedDrawStatLabel("cards blocked");
    }

    private static string GetBlockedDrawStatLabel(string suffix)
    {
        return GetInlineIconStatLabel(BlockedDrawIconPath, suffix);
    }

    private static void AppendCardDrawStats(StringBuilder sb, CardAggregate agg)
    {
        int attempted = agg.TimesCardsDrawAttempted;
        if (attempted <= 0)
            attempted = agg.TimesCardsDrawn + agg.TimesCardsDrawBlocked;

        if (attempted > agg.TimesCardsDrawn)
        {
            Row3(sb, GetDrawStatLabel("drawn / tried"), $"{agg.TimesCardsDrawn}/{attempted}", "");
            AppendBlockedDrawReasonRows(sb, agg, attempted - agg.TimesCardsDrawn);
            return;
        }

        if (agg.TimesCardsDrawn > 0)
            Row3(sb, GetDrawStatLabel("cards drawn"), agg.TimesCardsDrawn.ToString(), "");
    }

    private static void AppendBlockedDrawReasonRows(StringBuilder sb, CardAggregate agg, int blockedGap)
    {
        if (blockedGap <= 0) return;

        int categorized = 0;
        foreach (var reason in agg.BlockedDrawReasons.Values
                     .OrderByDescending(r => r.Count)
                     .ThenBy(r => r.DisplayName))
        {
            if (reason.Count <= 0) continue;
            Row3(sb, GetBlockedDrawReasonLabel(reason.DisplayName), reason.Count.ToString(), "");
            categorized += reason.Count;
        }

        int uncategorized = Math.Max(0, blockedGap - categorized);
        if (uncategorized > 0)
            Row3(sb, GetBlockedDrawReasonLabel("other"), uncategorized.ToString(), "");
    }

    private static string GetBlockedDrawReasonLabel(string reasonDisplayName)
    {
        return GetBlockedDrawStatLabel($"blocked by {reasonDisplayName}");
    }

    private static bool IsEnergyEffect(AppliedEffectAggregate effect)
    {
        if (!string.IsNullOrWhiteSpace(effect.EffectId) &&
            effect.EffectId.Contains("ENERGY", StringComparison.OrdinalIgnoreCase))
            return true;

        return !string.IsNullOrWhiteSpace(effect.DisplayName) &&
               effect.DisplayName.Contains("Energy", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetEnergyEffectLabel(string label)
    {
        const string energyPrefix = "Energy ";
        if (label.StartsWith(energyPrefix, StringComparison.OrdinalIgnoreCase))
        {
            var suffix = label.Substring(energyPrefix.Length).Trim();
            if (!string.IsNullOrWhiteSpace(suffix))
                return GetInlineIconStatLabel(EnergyPotionIconPath, suffix);
        }

        return GetInlineIconStatLabel(EnergyPotionIconPath, label);
    }

    private static bool IsStarEffect(AppliedEffectAggregate effect)
    {
        if (!string.IsNullOrWhiteSpace(effect.EffectId) &&
            effect.EffectId.Contains("STAR", StringComparison.OrdinalIgnoreCase))
            return true;

        return !string.IsNullOrWhiteSpace(effect.DisplayName) &&
               effect.DisplayName.StartsWith("Star", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetStarEffectLabel(string label)
    {
        const string pluralPrefix = "Stars ";
        const string singularPrefix = "Star ";

        if (label.StartsWith(pluralPrefix, StringComparison.OrdinalIgnoreCase))
        {
            var suffix = label.Substring(pluralPrefix.Length).Trim();
            if (!string.IsNullOrWhiteSpace(suffix))
                return GetInlineIconStatLabel(StarIconPath, suffix);
        }

        if (label.StartsWith(singularPrefix, StringComparison.OrdinalIgnoreCase))
        {
            var suffix = label.Substring(singularPrefix.Length).Trim();
            if (!string.IsNullOrWhiteSpace(suffix))
                return GetInlineIconStatLabel(StarIconPath, suffix);
        }

        return GetInlineIconStatLabel(StarIconPath, label);
    }

    private static bool IsNoxiousFumesEffect(AppliedEffectAggregate effect)
    {
        if (!string.IsNullOrWhiteSpace(effect.EffectId) &&
            effect.EffectId.Contains("NOXIOUS_FUMES", StringComparison.OrdinalIgnoreCase))
            return true;

        return string.Equals(effect.DisplayName, "Noxious Fumes", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetIconBackedEffectLabel(string label, string? iconPath)
    {
        if (string.IsNullOrWhiteSpace(iconPath))
            return label;

        return GetInlineIconStatLabel(iconPath, label);
    }

    private static string FormatDecimal(decimal value)
    {
        return decimal.Truncate(value) == value
            ? value.ToString("0")
            : value.ToString("0.##");
    }

    /// <summary>
    /// Whether the energy-spent stats are worth showing. Rule (per Nelson):
    /// show only when empirical variance exists between the actual energy
    /// paid across all plays and what you'd expect if every play cost the
    /// listed amount. If the rows aren't there, the user can safely assume
    /// 1 play = 1 listed cost and not think about it.
    ///
    /// This single rule subsumes every specific trigger we previously
    /// enumerated (Snecko, Master Planner, Sly, Corruption, upgrade cost
    /// change, X-cost, ...): they ALL manifest as a TotalEnergySpent that
    /// doesn't equal listed-cost × plays. If any of those mechanics is
    /// active and the card's been played, variance will show up and the
    /// rows will appear.
    ///
    /// Consequence: unplayed cards don't show energy stats even under a
    /// cost-variance relic. Acceptable — play the card once and it starts
    /// showing. Simpler than maintaining an enumeration of triggers the
    /// game's balance team might add to in a future patch.
    /// </summary>
    private static bool IsEnergyInteresting(
        MegaCrit.Sts2.Core.Models.CardModel card, CardAggregate agg)
    {
        try
        {
            if (agg.Plays <= 0) return false;
            int expectedPerPlay = card.EnergyCost.GetWithModifiers(CostModifiers.None);
            if (expectedPerPlay < 0) return true;  // X-cost / negative sentinel — show if played
            return agg.TotalEnergySpent != expectedPerPlay * agg.Plays;
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"IsEnergyInteresting failed: {e.Message}");
            return false;
        }
    }

    private static bool IsStarInteresting(
        MegaCrit.Sts2.Core.Models.CardModel card, CardAggregate agg)
    {
        try
        {
            if (agg.Plays <= 0 || agg.TotalStarsSpent <= 0) return false;
            if (card.HasStarCostX) return true;

            int expectedPerPlay = Math.Max(0, card.GetStarCostWithModifiers());
            return agg.TotalStarsSpent != expectedPerPlay * agg.Plays;
        }
        catch (Exception e)
        {
            CoreMain.LogDebug($"IsStarInteresting failed: {e.Message}");
            return false;
        }
    }
}

internal readonly record struct PoisonEffectSummary(
    int TimesApplied,
    decimal TotalAmountApplied,
    int TimesBlockedByArtifact,
    decimal TotalAmountBlockedByArtifact,
    decimal TotalTriggeredEffectiveDamage,
    decimal TotalTriggeredOverkill,
    string? IconPath);

[HarmonyPatch(typeof(NCardHolder), "ClearHoverTips")]
public static class CardHoverHidePatch
{
    [HarmonyPostfix]
    public static void Postfix()
    {
        try { StatsTooltip.Hide(); }
        catch (System.Exception e) { CoreMain.Logger.Error($"CardHoverHide failed: {e.Message}"); }
    }
}
