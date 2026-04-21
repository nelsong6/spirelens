using CardUtilityStats.Core;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class PoisonLedgerMathTests
{
    [Fact]
    public void AllocateContributions_SplitsAcrossSourcesInSequenceOrder()
    {
        var chunks = new List<PersistentContributionChunk>
        {
            new() { CardInstanceId = "CARD.NOXIOUS_FUMES#1", Amount = 2m, Sequence = 0 },
            new() { CardInstanceId = "CARD.NOXIOUS_FUMES#2", Amount = 3m, Sequence = 1 },
        };

        var (amounts, remainder) = PoisonLedgerMath.AllocateContributions(chunks, 5m);

        Assert.Equal(0m, remainder);
        Assert.Equal(2m, amounts["CARD.NOXIOUS_FUMES#1"]);
        Assert.Equal(3m, amounts["CARD.NOXIOUS_FUMES#2"]);
    }

    [Fact]
    public void PoisonDamageAndDecay_PreserveSourceLedgerAcrossTicks()
    {
        var chunks = new List<PoisonChunk>
        {
            new() { CardInstanceId = "CARD.DEADLY_POISON#1", Remaining = 3m, Sequence = 0 },
            new() { CardInstanceId = "CARD.NOXIOUS_FUMES#1", Remaining = 2m, Sequence = 1 },
        };

        var (firstTick, firstRemainder) = PoisonLedgerMath.AttributeDamage(chunks, 5m);
        var firstDecayRemainder = PoisonLedgerMath.ApplyDecay(chunks, 1m);

        Assert.Equal(0m, firstRemainder);
        Assert.Equal(0m, firstDecayRemainder);
        Assert.Equal(3m, firstTick["CARD.DEADLY_POISON#1"]);
        Assert.Equal(2m, firstTick["CARD.NOXIOUS_FUMES#1"]);
        Assert.Equal(4m, PoisonLedgerMath.TotalRemaining(chunks));
        Assert.Equal(2m, chunks.Single(chunk => chunk.CardInstanceId == "CARD.DEADLY_POISON#1").Remaining);
        Assert.Equal(2m, chunks.Single(chunk => chunk.CardInstanceId == "CARD.NOXIOUS_FUMES#1").Remaining);

        var (secondTick, secondRemainder) = PoisonLedgerMath.AttributeDamage(chunks, 4m);
        var secondDecayRemainder = PoisonLedgerMath.ApplyDecay(chunks, 1m);

        Assert.Equal(0m, secondRemainder);
        Assert.Equal(0m, secondDecayRemainder);
        Assert.Equal(2m, secondTick["CARD.DEADLY_POISON#1"]);
        Assert.Equal(2m, secondTick["CARD.NOXIOUS_FUMES#1"]);
        Assert.Equal(3m, PoisonLedgerMath.TotalRemaining(chunks));
        Assert.Equal(1m, chunks.Single(chunk => chunk.CardInstanceId == "CARD.DEADLY_POISON#1").Remaining);
        Assert.Equal(2m, chunks.Single(chunk => chunk.CardInstanceId == "CARD.NOXIOUS_FUMES#1").Remaining);
    }
}
