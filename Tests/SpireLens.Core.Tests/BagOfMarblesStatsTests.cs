using System.Text.Json;
using System.Text.Json.Serialization;
using SpireLens.Core;
using Xunit;

namespace SpireLens.Core.Tests;

/// <summary>
/// Tests for Bag of Marbles relic stat data model, persistence, and schema
/// backwards compatibility. Live RunTracker integration is exercised by the
/// verification phase via live in-run MCP evidence.
/// </summary>
public class BagOfMarblesStatsTests
{
    private const string BagOfMarblesRelicId = "RELIC.BAG_OF_MARBLES";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public void RelicAggregate_DefaultsToZero()
    {
        var agg = new RelicAggregate();
        Assert.Equal(0, agg.EnemiesAffected);
        Assert.Equal(0, agg.VulnerableApplied);
    }

    [Fact]
    public void RelicAggregate_JsonRoundtrip_PreservesFields()
    {
        var agg = new RelicAggregate { EnemiesAffected = 7, VulnerableApplied = 7 };
        var run = new RunData();
        run.RelicAggregates[BagOfMarblesRelicId] = agg;

        var json = JsonSerializer.Serialize(run, SerializerOptions);

        Assert.Contains("relic_aggregates", json);
        Assert.Contains("enemies_affected", json);
        Assert.Contains("vulnerable_applied", json);

        var restored = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);
        Assert.NotNull(restored);
        Assert.True(restored!.RelicAggregates.ContainsKey(BagOfMarblesRelicId));
        var restoredAgg = restored.RelicAggregates[BagOfMarblesRelicId];
        Assert.Equal(7, restoredAgg.EnemiesAffected);
        Assert.Equal(7, restoredAgg.VulnerableApplied);
    }

    [Fact]
    public void RelicAggregate_AccumulatesAcrossCombats()
    {
        var run = new RunData();

        if (!run.RelicAggregates.TryGetValue(BagOfMarblesRelicId, out var agg))
        {
            agg = new RelicAggregate();
            run.RelicAggregates[BagOfMarblesRelicId] = agg;
        }

        agg.EnemiesAffected += 3;
        agg.VulnerableApplied += 3;
        agg.EnemiesAffected += 2;
        agg.VulnerableApplied += 2;

        Assert.Equal(5, run.RelicAggregates[BagOfMarblesRelicId].EnemiesAffected);
        Assert.Equal(5, run.RelicAggregates[BagOfMarblesRelicId].VulnerableApplied);
    }

    [Fact]
    public void RunData_WithoutRelicAggregates_DeserializesEmpty()
    {
        const string json = """
            {
              "schema_version": 14,
              "run_id": "test",
              "started_at": "2026-01-01T00:00:00Z",
              "updated_at": "2026-01-01T00:00:00Z",
              "outcome": "in_progress",
              "aggregates": {},
              "events": [],
              "instance_numbers_by_def": {},
              "def_counters": {}
            }
            """;

        var run = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);

        Assert.NotNull(run);
        Assert.NotNull(run!.RelicAggregates);
        Assert.Empty(run.RelicAggregates);
    }

    [Fact]
    public void RunData_SchemaVersion_IsCurrentVersion()
    {
        var run = new RunData();
        Assert.Equal(RunData.CurrentSchemaVersion, run.SchemaVersion);
        Assert.Equal(16, RunData.CurrentSchemaVersion);
    }
}
