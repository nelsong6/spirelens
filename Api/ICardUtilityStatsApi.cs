namespace CardUtilityStats.Api;

public interface ICardUtilityStatsApi
{
    bool IsCoreLoaded { get; }
    int CurrentSchemaVersion { get; }
    string GetRuntimeOptionsJson();
    string? GetCurrentRunJson();
    string? TryGetCardAggregateJson(object? cardModel);
}
