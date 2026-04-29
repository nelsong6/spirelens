using System.Text.Json;
using System.Text.Json.Serialization;
using SpireLens.Core;
using Xunit;

namespace SpireLens.Core.Tests;

/// <summary>
/// Tests for Red Mask relic stat data model and persistence.
/// Live RunTracker integration is exercised by STS2 verification.
/// </summary>
public class RedMaskStatsTests
{
    private const string RedMaskRelicId = "RELIC.RED_MASK";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public void RelicAggregate_WeakApplied_DefaultsToZero()
    {
        var agg = new RelicAggregate();
        Assert.Equal(0, agg.EnemiesAffected);
        Assert.Equal(0, agg.WeakApplied);
    }

    [Fact]
    public void RelicAggregate_WeakApplied_JsonRoundtrip_PreservesFields()
    {
        var agg = new RelicAggregate { EnemiesAffected = 4, WeakApplied = 4 };
        var run = new RunData();
        run.RelicAggregates[RedMaskRelicId] = agg;

        var json = JsonSerializer.Serialize(run, SerializerOptions);

        Assert.Contains("relic_aggregates", json);
        Assert.Contains("enemies_affected", json);
        Assert.Contains("weak_applied", json);

        var restored = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);
        Assert.NotNull(restored);
        Assert.True(restored!.RelicAggregates.ContainsKey(RedMaskRelicId));
        var restoredAgg = restored.RelicAggregates[RedMaskRelicId];
        Assert.Equal(4, restoredAgg.EnemiesAffected);
        Assert.Equal(4, restoredAgg.WeakApplied);
    }

    [Fact]
    public void RelicAggregate_WeakApplied_AccumulatesAcrossCombats()
    {
        var run = new RunData();

        if (!run.RelicAggregates.TryGetValue(RedMaskRelicId, out var agg))
        {
            agg = new RelicAggregate();
            run.RelicAggregates[RedMaskRelicId] = agg;
        }

        agg.EnemiesAffected += 2;
        agg.WeakApplied += 2;
        agg.EnemiesAffected += 1;
        agg.WeakApplied += 1;

        Assert.Equal(3, run.RelicAggregates[RedMaskRelicId].EnemiesAffected);
        Assert.Equal(3, run.RelicAggregates[RedMaskRelicId].WeakApplied);
        Assert.Equal(0, run.RelicAggregates[RedMaskRelicId].VulnerableApplied);
    }

    [Fact]
    public void RunData_FromOlderShapeWithoutWeakApplied_DeserializesWithZeroDefault()
    {
        const string json = """
            {
              "schema_version": 15,
              "run_id": "test",
              "started_at": "2026-01-01T00:00:00Z",
              "updated_at": "2026-01-01T00:00:00Z",
              "outcome": "in_progress",
              "aggregates": {},
              "events": [],
              "instance_numbers_by_def": {},
              "def_counters": {},
              "relic_aggregates": {
                "RELIC.RED_MASK": {
                  "enemies_affected": 4,
                  "vulnerable_applied": 0
                }
              }
            }
            """;

        var run = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);

        Assert.NotNull(run);
        Assert.True(run!.RelicAggregates.ContainsKey(RedMaskRelicId));
        var agg = run.RelicAggregates[RedMaskRelicId];
        Assert.Equal(4, agg.EnemiesAffected);
        Assert.Equal(0, agg.WeakApplied);
    }
}
