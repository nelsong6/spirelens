using CardUtilityStats.Core;
using Xunit;

namespace CardUtilityStats.Core.Tests;

public class RunTrackerDamageMathTests
{
    [Fact]
    public void ComputeEnemyDamageTotals_UsesObservedHpLossForEffectiveDamage()
    {
        var totals = RunTracker.ComputeEnemyDamageTotals(
            blockedDamage: 0,
            unblockedDamage: 1,
            overkillDamage: 23);

        Assert.Equal(24, totals.IntendedDamage);
        Assert.Equal(1, totals.EffectiveDamage);
    }

    [Fact]
    public void ComputeEnemyDamageTotals_IncludesBlockedDamageInIntendedDamage()
    {
        var totals = RunTracker.ComputeEnemyDamageTotals(
            blockedDamage: 5,
            unblockedDamage: 7,
            overkillDamage: 0);

        Assert.Equal(12, totals.IntendedDamage);
        Assert.Equal(7, totals.EffectiveDamage);
    }
}
