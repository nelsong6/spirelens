using System.Collections.Generic;

namespace CardUtilityStats.Core;

internal sealed class PoisonChunk
{
    public string CardInstanceId { get; init; } = "";
    public decimal Remaining { get; set; }
    public int Sequence { get; init; }
}

internal sealed class PersistentContributionChunk
{
    public string CardInstanceId { get; init; } = "";
    public decimal Amount { get; set; }
    public int Sequence { get; init; }
}

internal static class PoisonLedgerMath
{
    public static (Dictionary<string, decimal> Amounts, decimal UnattributedAmount) AllocateContributions(
        IReadOnlyList<PersistentContributionChunk> chunks,
        decimal amount)
    {
        var allocations = new Dictionary<string, decimal>();
        if (chunks.Count == 0 || amount <= 0m) return (allocations, amount);

        decimal remaining = amount;
        foreach (var chunk in chunks.OrderBy(c => c.Sequence))
        {
            if (remaining <= 0m) break;
            if (chunk.Amount <= 0m) continue;

            decimal portion = Math.Min(chunk.Amount, remaining);
            if (portion <= 0m) continue;

            if (allocations.TryGetValue(chunk.CardInstanceId, out var existing))
                allocations[chunk.CardInstanceId] = existing + portion;
            else
                allocations[chunk.CardInstanceId] = portion;

            remaining -= portion;
        }

        return (allocations, remaining);
    }

    public static (Dictionary<string, decimal> Amounts, decimal UnattributedAmount) AttributeDamage(
        IReadOnlyList<PoisonChunk> chunks,
        decimal damage)
    {
        var allocations = new Dictionary<string, decimal>();
        if (chunks.Count == 0 || damage <= 0m) return (allocations, damage);

        decimal remaining = damage;
        foreach (var chunk in chunks.OrderBy(c => c.Sequence))
        {
            if (remaining <= 0m) break;
            if (chunk.Remaining <= 0m) continue;

            decimal portion = Math.Min(chunk.Remaining, remaining);
            if (portion <= 0m) continue;

            if (allocations.TryGetValue(chunk.CardInstanceId, out var existing))
                allocations[chunk.CardInstanceId] = existing + portion;
            else
                allocations[chunk.CardInstanceId] = portion;

            remaining -= portion;
        }

        return (allocations, remaining);
    }

    public static decimal ApplyDecay(List<PoisonChunk> chunks, decimal decayAmount)
    {
        if (chunks.Count == 0 || decayAmount <= 0m) return decayAmount;

        decimal remainingToDecay = decayAmount;
        foreach (var chunk in chunks.OrderBy(c => c.Sequence))
        {
            if (remainingToDecay <= 0m) break;
            if (chunk.Remaining <= 0m) continue;

            decimal consumed = Math.Min(chunk.Remaining, remainingToDecay);
            chunk.Remaining -= consumed;
            remainingToDecay -= consumed;
        }

        chunks.RemoveAll(chunk => chunk.Remaining <= 0m);
        return remainingToDecay;
    }

    public static decimal TotalRemaining(IReadOnlyList<PoisonChunk> chunks)
    {
        decimal total = 0m;
        foreach (var chunk in chunks)
        {
            if (chunk.Remaining > 0m)
                total += chunk.Remaining;
        }

        return total;
    }
}
