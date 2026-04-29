namespace SpireLens.Api;

public interface ISpireLensApi
{
    bool IsCoreLoaded { get; }
    string GetRuntimeOptionsJson();
    string? GetCurrentRunJson();
    string? TryGetCardAggregateJson(object? cardModel);
}
