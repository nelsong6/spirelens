using System;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using SpireLens.Core;
using SpireLens.Core.Patches;
using Xunit;

namespace SpireLens.Core.Tests;

/// <summary>
/// Tests for Orichalcum relic stat data model, persistence, and schema
/// backwards compatibility. Live RunTracker integration is exercised by the
/// verification phase via live in-run MCP evidence.
/// </summary>
public class OrichalcumStatsTests
{
    private const string OrichalcumRelicId = "RELIC.ORICHALCUM";

    private static readonly MethodInfo BuildOrichalcumBodyMethod =
        typeof(RelicHoverShowPatch).GetMethod("BuildOrichalcumBodyBBCode", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("BuildOrichalcumBodyBBCode not found.");

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public void RelicAggregate_AdditionalBlockGained_DefaultsToZero()
    {
        var agg = new RelicAggregate();
        Assert.Equal(0, agg.AdditionalBlockGained);
    }

    [Fact]
    public void RelicAggregate_AdditionalBlockGained_JsonRoundtrip_PreservesField()
    {
        var agg = new RelicAggregate { AdditionalBlockGained = 24 };
        var run = new RunData();
        run.RelicAggregates[OrichalcumRelicId] = agg;

        var json = JsonSerializer.Serialize(run, SerializerOptions);

        Assert.Contains("relic_aggregates", json);
        Assert.Contains("additional_block_gained", json);

        var restored = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);
        Assert.NotNull(restored);
        Assert.True(restored!.RelicAggregates.ContainsKey(OrichalcumRelicId));
        var restoredAgg = restored.RelicAggregates[OrichalcumRelicId];
        Assert.Equal(24, restoredAgg.AdditionalBlockGained);
    }

    [Fact]
    public void RelicAggregate_AdditionalBlockGained_AccumulatesAcrossTriggers()
    {
        var run = new RunData();

        if (!run.RelicAggregates.TryGetValue(OrichalcumRelicId, out var agg))
        {
            agg = new RelicAggregate();
            run.RelicAggregates[OrichalcumRelicId] = agg;
        }

        agg.AdditionalBlockGained += 6;
        agg.AdditionalBlockGained += 6;
        agg.AdditionalBlockGained += 6;

        Assert.Equal(18, run.RelicAggregates[OrichalcumRelicId].AdditionalBlockGained);
    }

    [Fact]
    public void RelicTooltip_AdditionalBlockGained_ShowsBlockIconAndTotal()
    {
        var agg = new RelicAggregate { AdditionalBlockGained = 12 };

        var body = (string)(BuildOrichalcumBodyMethod.Invoke(null, new object?[] { agg })
            ?? throw new InvalidOperationException("BuildOrichalcumBodyBBCode returned null."));

        Assert.Contains("[img=16x16]res://images/ui/combat/block.png[/img] block gained", body);
        Assert.Contains("[b]12[/b]", body);
    }

    [Fact]
    public void RunData_OlderShapeWithoutAdditionalBlockGained_DeserializesWithZeroDefault()
    {
        const string json = """
            {
              "run_id": "test",
              "started_at": "2026-01-01T00:00:00Z",
              "updated_at": "2026-01-01T00:00:00Z",
              "outcome": "in_progress",
              "aggregates": {},
              "events": [],
              "instance_numbers_by_def": {},
              "def_counters": {},
              "relic_aggregates": {
                "RELIC.ORICHALCUM": {
                  "enemies_affected": 0,
                  "vulnerable_applied": 0,
                  "weak_applied": 0
                }
              }
            }
            """;

        var run = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);

        Assert.NotNull(run);
        Assert.True(run!.RelicAggregates.ContainsKey(OrichalcumRelicId));
        var agg = run.RelicAggregates[OrichalcumRelicId];
        Assert.Equal(0, agg.AdditionalBlockGained);
    }
}
