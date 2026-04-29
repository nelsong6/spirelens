using System.Text.Json;
using System.Text.Json.Serialization;
using SpireLens.Core;
using Xunit;

namespace SpireLens.Core.Tests;

/// <summary>
/// Tests for Pocketwatch relic stat data model and persistence.
/// Live RunTracker integration is exercised by STS2 verification.
/// </summary>
public class PocketwatchStatsTests
{
    private const string PocketwatchRelicId = "RELIC.POCKETWATCH";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public void RelicAggregate_AdditionalCardsDrawn_DefaultsToZero()
    {
        var agg = new RelicAggregate();
        Assert.Equal(0, agg.AdditionalCardsDrawn);
    }

    [Fact]
    public void RelicAggregate_AdditionalCardsDrawn_JsonRoundtrip_PreservesField()
    {
        var agg = new RelicAggregate { AdditionalCardsDrawn = 9 };
        var run = new RunData();
        run.RelicAggregates[PocketwatchRelicId] = agg;

        var json = JsonSerializer.Serialize(run, SerializerOptions);

        Assert.Contains("relic_aggregates", json);
        Assert.Contains("additional_cards_drawn", json);

        var restored = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);
        Assert.NotNull(restored);
        Assert.True(restored!.RelicAggregates.ContainsKey(PocketwatchRelicId));
        Assert.Equal(9, restored.RelicAggregates[PocketwatchRelicId].AdditionalCardsDrawn);
    }

    [Fact]
    public void RelicAggregate_AdditionalCardsDrawn_AccumulatesAcrossTriggers()
    {
        var run = new RunData();

        if (!run.RelicAggregates.TryGetValue(PocketwatchRelicId, out var agg))
        {
            agg = new RelicAggregate();
            run.RelicAggregates[PocketwatchRelicId] = agg;
        }

        agg.AdditionalCardsDrawn += 3;
        agg.AdditionalCardsDrawn += 3;
        agg.AdditionalCardsDrawn += 3;

        Assert.Equal(9, run.RelicAggregates[PocketwatchRelicId].AdditionalCardsDrawn);
    }

    [Fact]
    public void RunData_OlderShapeWithoutAdditionalCardsDrawn_DeserializesWithZeroDefault()
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
                "RELIC.POCKETWATCH": {
                  "enemies_affected": 0,
                  "vulnerable_applied": 0,
                  "weak_applied": 0
                }
              }
            }
            """;

        var run = JsonSerializer.Deserialize<RunData>(json, SerializerOptions);

        Assert.NotNull(run);
        Assert.True(run!.RelicAggregates.ContainsKey(PocketwatchRelicId));
        Assert.Equal(0, run.RelicAggregates[PocketwatchRelicId].AdditionalCardsDrawn);
    }
}
