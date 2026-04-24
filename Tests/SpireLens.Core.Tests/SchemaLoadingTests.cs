using SpireLens.Core;
using Xunit;

namespace SpireLens.Core.Tests;

public class SchemaLoadingTests
{
    private static readonly string RepoRoot =
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));

    private static string FixturePath(string fileName) =>
        Path.Combine(RepoRoot, "Fixtures", "RunSchema", fileName);

    [Fact]
    public void HistoricalLoad_AcceptsLegacyV1Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v1-pooled-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(1, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.False(loaded.SupportsResume);
        Assert.False(loaded.HasPerInstanceIdentity);
        Assert.Contains("historical data", loaded.CompatibilityNote!, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("CARD.STRIKE_KIN", loaded.Data.Aggregates.Keys);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV2Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v2-per-instance-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(2, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Contains("resumable", loaded.CompatibilityNote!, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("CARD.STRIKE_KIN#1", loaded.Data.Aggregates.Keys);
        Assert.Equal(1, loaded.Data.DefCounters["CARD.STRIKE_KIN"]);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV3Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v3-per-instance-effects-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(3, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Contains("resumable", loaded.CompatibilityNote!, StringComparison.OrdinalIgnoreCase);
        var agg = loaded.Data.Aggregates["CARD.NECROBINDER_POWER#1"];
        var effect = agg.AppliedEffects["POWER.NECROBINDER_TRIGGER"];
        Assert.Equal("Necrobinder Trigger", effect.DisplayName);
        Assert.Equal(3, effect.TimesApplied);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV4Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v4-per-instance-effects-exhaust-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(4, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        var agg = loaded.Data.Aggregates["CARD.NECROBINDER_POWER#1"];
        Assert.Equal(1, agg.TimesExhausted);
        Assert.Equal(9m, agg.AppliedEffects["POWER.NECROBINDER_TRIGGER"].TotalAmountApplied);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV5Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v5-per-instance-block-ledger-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(5, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        var agg = loaded.Data.Aggregates["CARD.DEFEND_KIN#1"];
        Assert.Equal(6, agg.TotalBlockEffective);
        Assert.Equal(4, agg.TotalBlockWasted);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV6Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v6-per-instance-artifact-block-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(6, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Equal(6, loaded.Data.Aggregates["CARD.DEFEND_KIN#1"].TotalBlockEffective);
        var effect = loaded.Data.Aggregates["CARD.BASH_KIN#1"].AppliedEffects["POWER.WEAK"];
        Assert.Equal(1, effect.TimesBlockedByArtifact);
        Assert.Equal(2m, effect.TotalAmountBlockedByArtifact);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV7Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v7-per-instance-poison-damage-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(7, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        var effect = loaded.Data.Aggregates["CARD.DEADLY_POISON#1"].AppliedEffects["POWER.POISON"];
        Assert.Equal(9m, effect.TotalTriggeredEffectiveDamage);
        Assert.Equal(3m, effect.TotalTriggeredOverkill);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV8Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v8-per-instance-regent-stars-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(8, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Equal(2, loaded.Data.Aggregates["CARD.VENERATE#1"].TotalStarsGenerated);
        Assert.Equal(2, loaded.Data.Aggregates["CARD.STARDUST#1"].TotalStarsSpent);
        Assert.Equal(2, loaded.Data.Events[1].StarsSpent);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV9BlockedDrawFixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v9-per-instance-blocked-draw-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(9, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Contains("resumable", loaded.CompatibilityNote!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(2, loaded.Data.Aggregates["CARD.POMMEL_STRIKE#1"].TimesCardsDrawBlocked);
        Assert.Equal(1, loaded.Data.Aggregates["CARD.POMMEL_STRIKE#1"].TimesCardsDrawn);
        Assert.Equal(0, loaded.Data.Aggregates["CARD.POMMEL_STRIKE#1"].TotalStarsGenerated);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV9ForgeFixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v9-per-instance-forge-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(9, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Contains("resumable", loaded.CompatibilityNote!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(9m, loaded.Data.Aggregates["CARD.REFINE_BLADE#1"].TotalForgeGenerated);
        Assert.Equal(5m, loaded.Data.Events[0].ForgeGained);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV10ForgeFixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v10-per-instance-forge-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(10, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Contains("resumable", loaded.CompatibilityNote!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(9m, loaded.Data.Aggregates["CARD.REFINE_BLADE#1"].TotalForgeGenerated);
        Assert.Equal(0, loaded.Data.Aggregates["CARD.REFINE_BLADE#1"].TimesCardsDrawBlocked);
        Assert.Equal(4m, loaded.Data.Events[2].ForgeGained);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV11Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v11-per-instance-no-draw-blocked-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(11, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        var effect = loaded.Data.Aggregates["CARD.BATTLE_TRANCE#1"].AppliedEffects["POWER.NO_DRAW"];
        Assert.Equal(2, effect.TotalTriggeredCardsDrawBlocked);
        Assert.Equal(2, loaded.Data.Aggregates["CARD.POMMEL_STRIKE#1"].TimesCardsDrawBlocked);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV12Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v12-per-instance-draw-attempt-gap-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(12, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        var blocker = loaded.Data.Aggregates["CARD.BATTLE_TRANCE#1"].AppliedEffects["POWER.NO_DRAW"];
        Assert.Equal(3, blocker.TotalTriggeredCardsDrawBlocked);
        Assert.Equal(3, loaded.Data.Aggregates["CARD.BATTLE_TRANCE#2"].TimesCardsDrawAttempted);
        Assert.Equal(0, loaded.Data.Aggregates["CARD.BATTLE_TRANCE#2"].TimesCardsDrawn);
    }

    [Fact]
    public void HistoricalLoad_AcceptsLegacyResumableV13Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v13-per-instance-blocked-draw-reasons-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(13, loaded!.SourceSchemaVersion);
        Assert.True(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Contains("resumable", loaded.CompatibilityNote!, StringComparison.OrdinalIgnoreCase);
        var blocker = loaded.Data.Aggregates["CARD.BATTLE_TRANCE#1"].AppliedEffects["POWER.NO_DRAW"];
        Assert.Equal(3, blocker.TotalTriggeredCardsDrawBlocked);
        var reason = loaded.Data.Aggregates["CARD.BATTLE_TRANCE#2"].BlockedDrawReasons["effect:POWER.NO_DRAW"];
        Assert.Equal("No Draw", reason.DisplayName);
        Assert.Equal(3, reason.Count);
    }

    [Fact]
    public void HistoricalLoad_AcceptsCurrentV14Fixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v14-per-instance-make-it-so-run.json"));

        Assert.NotNull(loaded);
        Assert.Equal(RunData.CurrentSchemaVersion, loaded!.SourceSchemaVersion);
        Assert.False(loaded.IsLegacy);
        Assert.True(loaded.SupportsResume);
        Assert.True(loaded.HasPerInstanceIdentity);
        Assert.Null(loaded.CompatibilityNote);
        Assert.Equal(9m, loaded.Data.Aggregates["CARD.REFINE_BLADE#1"].TotalForgeGenerated);
        Assert.Equal(2, loaded.Data.Aggregates["CARD.MAKE_IT_SO#1"].TimesSummonedToHand);
        Assert.Equal(4m, loaded.Data.Events[2].ForgeGained);
    }

    [Fact]
    public void HistoricalLoad_RejectsUnknownSchemaFixture()
    {
        var loaded = RunStorage.LoadHistorical(FixturePath("v999-unknown-run.json"));

        Assert.Null(loaded);
    }

    [Fact]
    public void ResumableLoad_RejectsLegacyV1Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v1-pooled-run.json"));

        Assert.Null(resumed);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV2Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v2-per-instance-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(2, resumed!.SchemaVersion);
        Assert.Contains("CARD.ENERGY_SURGE#1", resumed.Aggregates.Keys);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV3Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v3-per-instance-effects-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(3, resumed!.SchemaVersion);
        var effect = resumed.Aggregates["CARD.NECROBINDER_POWER#1"].AppliedEffects["POWER.NECROBINDER_TRIGGER"];
        Assert.Equal(3m, effect.TotalAmountApplied);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV4Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v4-per-instance-effects-exhaust-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(4, resumed!.SchemaVersion);
        Assert.Equal(1, resumed.Aggregates["CARD.NECROBINDER_POWER#1"].TimesExhausted);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV5Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v5-per-instance-block-ledger-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(5, resumed!.SchemaVersion);
        Assert.Equal(6, resumed.Aggregates["CARD.DEFEND_KIN#1"].TotalBlockEffective);
        Assert.Equal(4, resumed.Aggregates["CARD.DEFEND_KIN#1"].TotalBlockWasted);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV6Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v6-per-instance-artifact-block-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(6, resumed!.SchemaVersion);
        Assert.Equal(6, resumed.Aggregates["CARD.DEFEND_KIN#1"].TotalBlockEffective);
        var effect = resumed.Aggregates["CARD.BASH_KIN#1"].AppliedEffects["POWER.WEAK"];
        Assert.Equal(1, effect.TimesBlockedByArtifact);
        Assert.Equal(2m, effect.TotalAmountBlockedByArtifact);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV7Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v7-per-instance-poison-damage-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(7, resumed!.SchemaVersion);
        var effect = resumed.Aggregates["CARD.DEADLY_POISON#1"].AppliedEffects["POWER.POISON"];
        Assert.Equal(9m, effect.TotalTriggeredEffectiveDamage);
        Assert.Equal(3m, effect.TotalTriggeredOverkill);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV8Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v8-per-instance-regent-stars-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(8, resumed!.SchemaVersion);
        Assert.Equal(2, resumed.Aggregates["CARD.VENERATE#1"].TotalStarsGenerated);
        Assert.Equal(2, resumed.Aggregates["CARD.STARDUST#1"].TotalStarsSpent);
        Assert.Equal(1, resumed.Aggregates["CARD.VENERATE#1"].TimesDrawn);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV9BlockedDrawFixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v9-per-instance-blocked-draw-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(9, resumed!.SchemaVersion);
        Assert.Equal(2, resumed.Aggregates["CARD.POMMEL_STRIKE#1"].TimesCardsDrawBlocked);
        Assert.Equal(1, resumed.Aggregates["CARD.POMMEL_STRIKE#1"].TimesCardsDrawn);
        Assert.Equal(0, resumed.Aggregates["CARD.POMMEL_STRIKE#1"].TotalStarsSpent);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV9ForgeFixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v9-per-instance-forge-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(9, resumed!.SchemaVersion);
        Assert.Equal(9m, resumed.Aggregates["CARD.REFINE_BLADE#1"].TotalForgeGenerated);
        Assert.Equal(0, resumed.Aggregates["CARD.REFINE_BLADE#1"].TimesCardsDrawBlocked);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV10ForgeFixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v10-per-instance-forge-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(10, resumed!.SchemaVersion);
        Assert.Equal(9m, resumed.Aggregates["CARD.REFINE_BLADE#1"].TotalForgeGenerated);
        Assert.Equal(0, resumed.Aggregates["CARD.REFINE_BLADE#1"].TimesCardsDrawBlocked);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV11Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v11-per-instance-no-draw-blocked-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(11, resumed!.SchemaVersion);
        var effect = resumed.Aggregates["CARD.BATTLE_TRANCE#1"].AppliedEffects["POWER.NO_DRAW"];
        Assert.Equal(2, effect.TotalTriggeredCardsDrawBlocked);
        Assert.Equal(2, resumed.Aggregates["CARD.POMMEL_STRIKE#1"].TimesCardsDrawBlocked);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV12Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v12-per-instance-draw-attempt-gap-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(12, resumed!.SchemaVersion);
        var blocker = resumed.Aggregates["CARD.BATTLE_TRANCE#1"].AppliedEffects["POWER.NO_DRAW"];
        Assert.Equal(3, blocker.TotalTriggeredCardsDrawBlocked);
        Assert.Equal(3, resumed.Aggregates["CARD.BATTLE_TRANCE#2"].TimesCardsDrawAttempted);
        Assert.Equal(0, resumed.Aggregates["CARD.BATTLE_TRANCE#2"].TimesCardsDrawn);
    }

    [Fact]
    public void ResumableLoad_AcceptsLegacyResumableV13Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v13-per-instance-blocked-draw-reasons-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(13, resumed!.SchemaVersion);
        var blocker = resumed.Aggregates["CARD.BATTLE_TRANCE#1"].AppliedEffects["POWER.NO_DRAW"];
        Assert.Equal(3, blocker.TotalTriggeredCardsDrawBlocked);
        var reason = resumed.Aggregates["CARD.BATTLE_TRANCE#2"].BlockedDrawReasons["effect:POWER.NO_DRAW"];
        Assert.Equal("No Draw", reason.DisplayName);
        Assert.Equal(3, reason.Count);
    }

    [Fact]
    public void ResumableLoad_AcceptsCurrentV14Fixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v14-per-instance-make-it-so-run.json"));

        Assert.NotNull(resumed);
        Assert.Equal(RunData.CurrentSchemaVersion, resumed!.SchemaVersion);
        Assert.Equal(9m, resumed.Aggregates["CARD.REFINE_BLADE#1"].TotalForgeGenerated);
        Assert.Equal(2, resumed.Aggregates["CARD.MAKE_IT_SO#1"].TimesSummonedToHand);
        Assert.Equal(3, resumed.Aggregates["CARD.MAKE_IT_SO#1"].TimesDrawn);
    }

    [Fact]
    public void ResumableLoad_RejectsUnknownSchemaFixture()
    {
        var resumed = RunStorage.LoadResumable(FixturePath("v999-unknown-run.json"));

        Assert.Null(resumed);
    }
}
