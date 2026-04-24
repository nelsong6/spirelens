using System;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using CardUtilityStats.Loader;

namespace CardUtilityStats.Api;

public static class CardUtilityStatsApiRegistry
{
    public static ICardUtilityStatsApi Api { get; } = new ReflectionBackedCardUtilityStatsApi();

    public static bool IsCoreLoaded => Api.IsCoreLoaded;
    public static int CurrentSchemaVersion => Api.CurrentSchemaVersion;
    public static string GetRuntimeOptionsJson() => Api.GetRuntimeOptionsJson();
    public static string? GetCurrentRunJson() => Api.GetCurrentRunJson();
    public static string? TryGetCardAggregateJson(object? cardModel) => Api.TryGetCardAggregateJson(cardModel);

    private sealed class ReflectionBackedCardUtilityStatsApi : ICardUtilityStatsApi
    {
        private static readonly JsonSerializerOptions JsonOptions = new();

        public bool IsCoreLoaded => ResolveLatestCoreType("CardUtilityStats.Core.RunTracker") != null;

        public int CurrentSchemaVersion
        {
            get
            {
                var field = ResolveLatestCoreType("CardUtilityStats.Core.RunData")
                    ?.GetField("CurrentSchemaVersion", BindingFlags.Public | BindingFlags.Static);
                var value = field?.GetValue(null);
                return value is int schemaVersion ? schemaVersion : 0;
            }
        }

        public string GetRuntimeOptionsJson()
        {
            return RuntimeOptionsBridge.GetCurrentOptionsJson();
        }

        public string? GetCurrentRunJson()
        {
            var currentRun = ResolveLatestCoreType("CardUtilityStats.Core.RunTracker")
                ?.GetProperty("Current", BindingFlags.Public | BindingFlags.Static)
                ?.GetValue(null);
            return Serialize(currentRun);
        }

        public string? TryGetCardAggregateJson(object? cardModel)
        {
            if (cardModel == null) return null;

            var method = ResolveLatestCoreType("CardUtilityStats.Core.RunTracker")
                ?.GetMethod("GetEffectiveAggregate", BindingFlags.Public | BindingFlags.Static);
            if (method == null) return null;

            var parameters = method.GetParameters();
            if (parameters.Length != 1 || !parameters[0].ParameterType.IsInstanceOfType(cardModel))
                return null;

            var aggregate = method.Invoke(null, new[] { cardModel });
            return Serialize(aggregate);
        }

        private static Type? ResolveLatestCoreType(string typeName)
        {
            return AppDomain.CurrentDomain.GetAssemblies()
                .Select(assembly => new { Assembly = assembly, Type = assembly.GetType(typeName, throwOnError: false) })
                .Where(entry => entry.Type != null)
                .OrderByDescending(entry => GetCoreGeneration(entry.Assembly))
                .Select(entry => entry.Type)
                .FirstOrDefault();
        }

        private static int GetCoreGeneration(Assembly assembly)
        {
            const string prefix = "CardUtilityStats.Core.";
            var name = assembly.GetName().Name ?? string.Empty;
            if (name.StartsWith(prefix, StringComparison.Ordinal) &&
                int.TryParse(name.Substring(prefix.Length), out var generation))
                return generation;

            return 0;
        }

        private static string? Serialize(object? value)
        {
            if (value == null) return null;
            return JsonSerializer.Serialize(value, value.GetType(), JsonOptions);
        }
    }
}
