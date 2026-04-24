using System;
using System.Collections.Generic;

namespace SpireLens.Core;

internal static class CardAggregatePooler
{
    public static bool IsAggregateForDefinition(string aggregateKey, string definitionId)
    {
        return aggregateKey.StartsWith(definitionId, StringComparison.Ordinal)
            && aggregateKey.Length > definitionId.Length
            && aggregateKey[definitionId.Length] == '#';
    }

    public static CardAggregate? PoolByDefinition(
        IEnumerable<KeyValuePair<string, CardAggregate>> aggregates,
        string definitionId)
    {
        CardAggregate? pooled = null;

        foreach (var (aggregateKey, aggregate) in aggregates)
        {
            if (!IsAggregateForDefinition(aggregateKey, definitionId)) continue;
            pooled ??= new CardAggregate();
            MergeInto(pooled, aggregate);
        }

        return pooled;
    }

    public static void MergeInto(CardAggregate target, CardAggregate source)
    {
        target.Plays += source.Plays;
        target.TotalIntended += source.TotalIntended;
        target.TotalBlocked += source.TotalBlocked;
        target.TotalOverkill += source.TotalOverkill;
        target.TotalEffective += source.TotalEffective;
        target.Kills += source.Kills;
        target.TotalEnergySpent += source.TotalEnergySpent;
        target.TotalEnergyGenerated += source.TotalEnergyGenerated;
        target.TotalStarsSpent += source.TotalStarsSpent;
        target.TotalStarsGenerated += source.TotalStarsGenerated;
        target.TotalForgeGenerated += source.TotalForgeGenerated;
        target.TotalBlockGained += source.TotalBlockGained;
        target.TotalBlockEffective += source.TotalBlockEffective;
        target.TotalBlockWasted += source.TotalBlockWasted;
        target.TimesDrawn += source.TimesDrawn;
        target.TimesDiscarded += source.TimesDiscarded;
        target.TimesPlacedOnTopFromHand += source.TimesPlacedOnTopFromHand;
        target.TimesPlacedOnTopFromDiscard += source.TimesPlacedOnTopFromDiscard;
        target.TimesExhaustedOtherCards += source.TimesExhaustedOtherCards;
        target.TimesExhausted += source.TimesExhausted;
        target.TotalHpLost += source.TotalHpLost;
        target.TimesCardsDrawn += source.TimesCardsDrawn;
        target.TimesCardsDrawAttempted += source.TimesCardsDrawAttempted;
        target.TimesCardsDrawBlocked += source.TimesCardsDrawBlocked;
        MergeBlockedDrawReasonsInto(target.BlockedDrawReasons, source.BlockedDrawReasons);
        MergeAppliedEffectsInto(target.AppliedEffects, source.AppliedEffects);
    }

    private static void MergeBlockedDrawReasonsInto(
        Dictionary<string, BlockedDrawReasonAggregate> target,
        Dictionary<string, BlockedDrawReasonAggregate> source)
    {
        foreach (var kv in source)
        {
            if (!target.TryGetValue(kv.Key, out var reason))
            {
                reason = new BlockedDrawReasonAggregate
                {
                    ReasonId = kv.Value.ReasonId,
                    DisplayName = kv.Value.DisplayName,
                };
                target[kv.Key] = reason;
            }

            reason.Count += kv.Value.Count;
            if (string.IsNullOrWhiteSpace(reason.DisplayName) && !string.IsNullOrWhiteSpace(kv.Value.DisplayName))
                reason.DisplayName = kv.Value.DisplayName;
        }
    }

    private static void MergeAppliedEffectsInto(
        Dictionary<string, AppliedEffectAggregate> target,
        Dictionary<string, AppliedEffectAggregate> source)
    {
        foreach (var kv in source)
        {
            if (!target.TryGetValue(kv.Key, out var effect))
            {
                effect = new AppliedEffectAggregate
                {
                    EffectId = kv.Value.EffectId,
                    DisplayName = kv.Value.DisplayName,
                    IconPath = kv.Value.IconPath,
                };
                target[kv.Key] = effect;
            }

            effect.TimesApplied += kv.Value.TimesApplied;
            effect.TotalAmountApplied += kv.Value.TotalAmountApplied;
            effect.TimesBlockedByArtifact += kv.Value.TimesBlockedByArtifact;
            effect.TotalAmountBlockedByArtifact += kv.Value.TotalAmountBlockedByArtifact;
            effect.TotalTriggeredEffectiveDamage += kv.Value.TotalTriggeredEffectiveDamage;
            effect.TotalTriggeredOverkill += kv.Value.TotalTriggeredOverkill;
            effect.TotalTriggeredCardsDrawBlocked += kv.Value.TotalTriggeredCardsDrawBlocked;
            if (string.IsNullOrWhiteSpace(effect.DisplayName) && !string.IsNullOrWhiteSpace(kv.Value.DisplayName))
                effect.DisplayName = kv.Value.DisplayName;
            if (string.IsNullOrWhiteSpace(effect.IconPath) && !string.IsNullOrWhiteSpace(kv.Value.IconPath))
                effect.IconPath = kv.Value.IconPath;
        }
    }
}
