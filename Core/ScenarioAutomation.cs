using System.Text.Json;
using Godot;
using MegaCrit.Sts2.Core.Combat;
using MegaCrit.Sts2.Core.Commands;
using MegaCrit.Sts2.Core.DevConsole;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Entities.Creatures;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.Core.Map;
using MegaCrit.Sts2.Core.Models;
using MegaCrit.Sts2.Core.Nodes;
using MegaCrit.Sts2.Core.Rooms;
using MegaCrit.Sts2.Core.Runs;

namespace CardUtilityStats.Core;

/// <summary>
/// In-game side of the live worker bridge. The GitHub runner can launch STS2
/// and capture artifacts, but scenario intent belongs inside the game where we
/// can use game APIs instead of fragile mouse/keyboard automation.
/// </summary>
public static class ScenarioAutomation
{
    private static ScenarioAutomationNode? _node;

    public static void Initialize()
    {
        var tree = Godot.Engine.GetMainLoop() as SceneTree;
        if (tree == null)
        {
            CoreMain.Logger.Warn("[CUS-live] Scenario automation skipped: no Godot SceneTree.");
            return;
        }

        if (_node != null && GodotObject.IsInstanceValid(_node))
            return;

        _node = new ScenarioAutomationNode();
        tree.Root.CallDeferred(Node.MethodName.AddChild, _node);
        CoreMain.Logger.Info("[CUS-live] Scenario automation node scheduled.");
    }

    public static void Shutdown()
    {
        if (_node != null && GodotObject.IsInstanceValid(_node))
            _node.QueueFree();

        _node = null;
    }
}

public partial class ScenarioAutomationNode : Node
{
    private const string DefaultBridgeRoot = @"D:\automation\card-utility-stats-live-bridge";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private readonly HashSet<string> _completedRequestIds = new(StringComparer.OrdinalIgnoreCase);
    private double _pollSecondsRemaining;
    private bool _isRunning;

    public override void _EnterTree()
    {
        SetProcess(true);
        CoreMain.Logger.Info("[CUS-live] Scenario automation node entered tree.");
    }

    public override void _Ready()
    {
        SetProcess(true);
        CoreMain.Logger.Info("[CUS-live] Scenario automation node ready.");
    }

    public override void _Process(double delta)
    {
        if (_isRunning) return;

        _pollSecondsRemaining -= delta;
        if (_pollSecondsRemaining > 0) return;
        _pollSecondsRemaining = 1.0;

        var active = ResolveActiveRequest();
        if (active == null) return;
        if (_completedRequestIds.Contains(active.RequestId) && File.Exists(active.ResultPath)) return;
        if (!File.Exists(active.RequestPath)) return;
        if (File.Exists(active.ResultPath)) return;

        _isRunning = true;
        _ = RunScenarioAsync(active);
    }

    private async Task RunScenarioAsync(ActiveScenarioRequest active)
    {
        var startedAt = DateTimeOffset.UtcNow;
        var steps = new List<ScenarioStepResult>();
        string scenarioName = "";

        try
        {
            using var requestDoc = JsonDocument.Parse(await File.ReadAllTextAsync(active.RequestPath));
            var root = requestDoc.RootElement;
            scenarioName = GetString(root, "scenario", "name") ?? "";

            if (!TryGetAutomation(root, out var automation))
            {
                WriteResult(active, "skipped", "No driver.automation block was present in the scenario manifest.",
                    scenarioName, startedAt, steps);
                return;
            }

            CoreMain.Logger.Info($"[CUS-live] Starting in-game scenario automation for request {active.RequestId} ({scenarioName}).");
            await WaitForGameAsync();

            if (!automation.TryGetProperty("steps", out var stepElements) || stepElements.ValueKind != JsonValueKind.Array)
                throw new InvalidOperationException("driver.automation.steps must be an array.");

            var index = 0;
            foreach (var step in stepElements.EnumerateArray())
            {
                index++;
                var action = GetString(step, "action") ?? throw new InvalidOperationException($"Step {index} is missing action.");
                var stepStartedAt = DateTimeOffset.UtcNow;
                var details = await ExecuteStepAsync(action, step, root);
                steps.Add(new ScenarioStepResult(index, action, "success", DateTimeOffset.UtcNow - stepStartedAt, details));
                CoreMain.Logger.Info($"[CUS-live] Step {index} succeeded: {action}.");
            }

            WriteResult(active, "success", "In-game scenario automation completed.", scenarioName, startedAt, steps);
            CoreMain.Logger.Info($"[CUS-live] Completed in-game scenario automation for request {active.RequestId}.");
        }
        catch (Exception e)
        {
            CoreMain.Logger.Error($"[CUS-live] Scenario automation failed for request {active.RequestId}: {e}");
            WriteResult(active, "failure", e.Message, scenarioName, startedAt, steps);
        }
        finally
        {
            _completedRequestIds.Add(active.RequestId);
            _isRunning = false;
        }
    }

    private async Task<Dictionary<string, object?>> ExecuteStepAsync(string action, JsonElement step, JsonElement root)
    {
        return Normalize(action) switch
        {
            "STARTRUN" => await StartRunAsync(step, root),
            "WAITFORRUN" => await WaitForRunAsync(step),
            "ENTERCOMBAT" => await EnterCombatAsync(step),
            "WAITFORCOMBAT" => await WaitForCombatAsync(step),
            "GRANTCARD" => await GrantCardAsync(step),
            "PLAYCARD" => await PlayCardAsync(step),
            "CONSOLE" => await ConsoleAsync(step),
            "WAIT" => await WaitAsync(step),
            "WINCOMBAT" => await WinCombatAsync(step),
            _ => throw new InvalidOperationException($"Unsupported scenario automation action '{action}'.")
        };
    }

    private async Task<Dictionary<string, object?>> StartRunAsync(JsonElement step, JsonElement root)
    {
        if (RunManager.Instance.IsInProgress)
        {
            return new Dictionary<string, object?> { ["already_in_progress"] = true };
        }

        var profile =
            GetString(step, "character")
            ?? GetString(root, "scenario", "driver", "profile")
            ?? "silent";
        var character = ResolveCharacter(profile);
        var seed = GetString(step, "seed");
        if (string.IsNullOrWhiteSpace(seed))
            seed = $"CUS{DateTimeOffset.UtcNow:MMddHHmmss}";

        var shouldSave = GetBool(step, "save_run_history") ?? false;
        var ascension = GetInt(step, "ascension") ?? 0;
        var acts = ActModel.GetDefaultList();

        var game = NGame.Instance ?? throw new InvalidOperationException("NGame.Instance is not available.");
        await game.StartNewSingleplayerRun(
            character,
            shouldSave,
            acts,
            new List<ModifierModel>(),
            seed,
            GameMode.Standard,
            ascension,
            null);

        await WaitUntilAsync(() => RunManager.Instance.IsInProgress, 30, "run to start");
        return new Dictionary<string, object?>
        {
            ["character"] = character.Id.ToString(),
            ["seed"] = seed,
            ["save_run_history"] = shouldSave,
            ["ascension"] = ascension
        };
    }

    private async Task<Dictionary<string, object?>> WaitForRunAsync(JsonElement step)
    {
        var timeout = GetDouble(step, "timeout_seconds") ?? 30;
        await WaitUntilAsync(() => RunManager.Instance.IsInProgress, timeout, "run to be in progress");
        return new Dictionary<string, object?> { ["is_in_progress"] = true };
    }

    private async Task<Dictionary<string, object?>> EnterCombatAsync(JsonElement step)
    {
        await WaitUntilAsync(() => RunManager.Instance.IsInProgress, 30, "run to be in progress before combat");

        var encounter = ResolveEncounter(GetString(step, "encounter"))?.ToMutable()
            ?? throw new InvalidOperationException("Could not resolve an encounter for enter_combat.");
        encounter.DebugRandomizeRng();

        await RunManager.Instance.EnterRoomDebug(RoomType.Monster, MapPointType.Monster, encounter, true);
        RunManager.Instance.ActionExecutor.Unpause();
        await WaitUntilAsync(() => CombatManager.Instance.IsInProgress, 45, "combat to start");

        return new Dictionary<string, object?> { ["encounter"] = encounter.Id.ToString() };
    }

    private async Task<Dictionary<string, object?>> WaitForCombatAsync(JsonElement step)
    {
        var timeout = GetDouble(step, "timeout_seconds") ?? 45;
        await WaitUntilAsync(() => CombatManager.Instance.IsInProgress, timeout, "combat to be in progress");
        return new Dictionary<string, object?> { ["is_in_progress"] = true };
    }

    private async Task<Dictionary<string, object?>> GrantCardAsync(JsonElement step)
    {
        var cardId = GetString(step, "card") ?? GetString(step, "id")
            ?? throw new InvalidOperationException("grant_card requires card or id.");
        var pile = ResolvePile(GetString(step, "pile") ?? "hand");
        var count = Math.Max(1, GetInt(step, "count") ?? 1);
        var upgradeCount = Math.Max(0, GetInt(step, "upgrades") ?? 0);

        await WaitUntilAsync(() => CombatManager.Instance.IsInProgress, 45, "combat before granting card");
        var state = CombatManager.Instance.DebugOnlyGetState()
            ?? throw new InvalidOperationException("Combat state is not available.");
        var player = GetPlayer(state, step);
        var canonicalCard = ResolveCard(cardId);
        var added = new List<string>();

        for (var i = 0; i < count; i++)
        {
            var card = state.CreateCard(canonicalCard, player);
            for (var upgrade = 0; upgrade < upgradeCount && card.IsUpgradable; upgrade++)
                card.UpgradeInternal();

            await CardPileCmd.AddGeneratedCardToCombat(card, pile, true, CardPilePosition.Top);
            added.Add(card.Id.ToString());
        }

        return new Dictionary<string, object?>
        {
            ["card"] = canonicalCard.Id.ToString(),
            ["pile"] = pile.ToString(),
            ["count"] = count,
            ["added"] = added
        };
    }

    private async Task<Dictionary<string, object?>> PlayCardAsync(JsonElement step)
    {
        var cardId = GetString(step, "card") ?? GetString(step, "id")
            ?? throw new InvalidOperationException("play_card requires card or id.");
        var free = GetBool(step, "free") ?? true;

        await WaitUntilAsync(() => CombatManager.Instance.IsInProgress, 45, "combat before playing card");
        var state = CombatManager.Instance.DebugOnlyGetState()
            ?? throw new InvalidOperationException("Combat state is not available.");
        var player = GetPlayer(state, step);
        await WaitUntilAsync(() => CombatManager.Instance.IsPlayPhase || !CombatManager.Instance.PlayerActionsDisabled,
            45, "player action phase");

        var hand = CardPile.Get(PileType.Hand, player)
            ?? throw new InvalidOperationException("Player hand pile is not available.");
        var card = hand.Cards.FirstOrDefault(c => MatchesModel(c, cardId))
            ?? throw new InvalidOperationException($"Card '{cardId}' was not found in the player's hand.");
        if (free) card.SetToFreeThisTurn();

        var target = ResolveTarget(step, state, player, card);
        if (!card.TryManualPlay(target))
            throw new InvalidOperationException($"Card '{card.Id}' refused manual play against target '{DescribeCreature(target)}'.");

        await WaitForActionQueuesToSettleAsync(GetDouble(step, "settle_timeout_seconds") ?? 30);
        return new Dictionary<string, object?>
        {
            ["card"] = card.Id.ToString(),
            ["target"] = DescribeCreature(target),
            ["free"] = free
        };
    }

    private async Task<Dictionary<string, object?>> ConsoleAsync(JsonElement step)
    {
        var command = GetString(step, "command")
            ?? throw new InvalidOperationException("console requires command.");
        var console = new DevConsole(shouldAllowDebugCommands: true);
        var result = console.ProcessCommand(command);
        if (result.task != null)
            await result.task;
        if (!result.success)
            throw new InvalidOperationException($"Console command '{command}' failed: {result.msg}");

        await WaitForActionQueuesToSettleAsync(GetDouble(step, "settle_timeout_seconds") ?? 10);
        return new Dictionary<string, object?> { ["command"] = command, ["message"] = result.msg };
    }

    private async Task<Dictionary<string, object?>> WaitAsync(JsonElement step)
    {
        var seconds = Math.Max(0, GetDouble(step, "seconds") ?? 1);
        await WaitSecondsAsync(seconds);
        return new Dictionary<string, object?> { ["seconds"] = seconds };
    }

    private async Task<Dictionary<string, object?>> WinCombatAsync(JsonElement step)
    {
        var consoleStep = JsonDocument.Parse(@"{""command"":""kill all"",""settle_timeout_seconds"":30}").RootElement;
        try
        {
            await ConsoleAsync(consoleStep);
        }
        finally
        {
            await WaitSecondsAsync(GetDouble(step, "post_wait_seconds") ?? 3);
        }

        return new Dictionary<string, object?> { ["command"] = "kill all" };
    }

    private async Task WaitForGameAsync()
    {
        await WaitUntilAsync(() =>
        {
            try
            {
                return NGame.Instance != null && ModelDb.AllCharacters.Any();
            }
            catch
            {
                return false;
            }
        }, 120, "game services to initialize");
    }

    private async Task WaitForActionQueuesToSettleAsync(double timeoutSeconds)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (!CombatManager.Instance.IsInProgress)
                return;

            var manager = RunManager.Instance;
            if (manager.ActionQueueSet.IsEmpty && !manager.ActionExecutor.IsRunning)
                return;

            await WaitSecondsAsync(0.25);
        }

        throw new TimeoutException("Timed out waiting for action queues to settle.");
    }

    private async Task WaitUntilAsync(Func<bool> predicate, double timeoutSeconds, string description)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(timeoutSeconds);
        Exception? lastException = null;

        while (DateTimeOffset.UtcNow < deadline)
        {
            try
            {
                if (predicate()) return;
            }
            catch (Exception e)
            {
                lastException = e;
            }

            await WaitSecondsAsync(0.25);
        }

        if (lastException != null)
            throw new TimeoutException($"Timed out waiting for {description}. Last error: {lastException.Message}", lastException);

        throw new TimeoutException($"Timed out waiting for {description}.");
    }

    private async Task WaitSecondsAsync(double seconds)
    {
        if (seconds <= 0) return;
        var tree = GetTree();
        if (tree != null)
            await ToSignal(tree.CreateTimer(seconds), SceneTreeTimer.SignalName.Timeout);
        else
            await Task.Delay(TimeSpan.FromSeconds(seconds));
    }

    private static CharacterModel ResolveCharacter(string raw)
    {
        var model = ResolveModel(ModelDb.AllCharacters, raw);
        if (model != null) return model;

        throw new InvalidOperationException($"Could not resolve character '{raw}'.");
    }

    private static EncounterModel? ResolveEncounter(string? raw)
    {
        if (!string.IsNullOrWhiteSpace(raw))
        {
            var explicitMatch = ResolveModel(ModelDb.AllEncounters, raw);
            if (explicitMatch != null) return explicitMatch;
        }

        return ModelDb.AllEncounters.FirstOrDefault(e => e.IsWeak)
            ?? ModelDb.AllEncounters.FirstOrDefault(e => e.RoomType == RoomType.Monster)
            ?? ModelDb.AllEncounters.FirstOrDefault();
    }

    private static CardModel ResolveCard(string raw)
    {
        var model = ResolveModel(ModelDb.AllCards, raw);
        if (model != null) return model;

        throw new InvalidOperationException($"Could not resolve card '{raw}'.");
    }

    private static T? ResolveModel<T>(IEnumerable<T> models, string raw)
        where T : AbstractModel
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;

        if (raw.Contains('.'))
        {
            try
            {
                var parsed = ModelId.Deserialize(raw);
                var byId = ModelDb.GetByIdOrNull<T>(parsed);
                if (byId != null) return byId;
            }
            catch
            {
                var parts = raw.Split('.', 2);
                if (parts.Length == 2)
                {
                    try
                    {
                        var byId = ModelDb.GetByIdOrNull<T>(new ModelId(parts[0], parts[1].ToUpperInvariant()));
                        if (byId != null) return byId;
                    }
                    catch { }
                }
            }
        }

        var normalized = Normalize(raw);
        return models.FirstOrDefault(model => MatchesModel(model, normalized));
    }

    private static bool MatchesModel(AbstractModel model, string rawOrNormalized)
    {
        var normalized = rawOrNormalized.Any(char.IsLower) || rawOrNormalized.Any(ch => !char.IsLetterOrDigit(ch))
            ? Normalize(rawOrNormalized)
            : rawOrNormalized;
        return Normalize(model.Id.ToString()) == normalized
            || Normalize(model.Id.Entry) == normalized
            || Normalize(model.GetType().Name) == normalized;
    }

    private static PileType ResolvePile(string raw)
    {
        return Normalize(raw) switch
        {
            "DRAW" => PileType.Draw,
            "HAND" => PileType.Hand,
            "DISCARD" => PileType.Discard,
            "EXHAUST" => PileType.Exhaust,
            "PLAY" => PileType.Play,
            "DECK" => PileType.Deck,
            _ => throw new InvalidOperationException($"Unsupported card pile '{raw}'.")
        };
    }

    private static Player GetPlayer(CombatState state, JsonElement step)
    {
        var index = GetInt(step, "player_index") ?? 0;
        if (index < 0 || index >= state.Players.Count)
            throw new InvalidOperationException($"player_index {index} is outside the combat player list.");

        return state.Players[index];
    }

    private static Creature? ResolveTarget(JsonElement step, CombatState state, Player player, CardModel card)
    {
        var target = Normalize(GetString(step, "target") ?? "");
        if (target is "" or "AUTO")
        {
            return card.TargetType switch
            {
                TargetType.Self or TargetType.AnyPlayer or TargetType.AnyAlly => player.Creature,
                TargetType.AnyEnemy or TargetType.RandomEnemy => state.HittableEnemies.FirstOrDefault()
                    ?? state.Enemies.FirstOrDefault(),
                _ => null
            };
        }

        return target switch
        {
            "NONE" => null,
            "SELF" or "PLAYER" => player.Creature,
            "FIRSTENEMY" or "ENEMY" => state.HittableEnemies.FirstOrDefault() ?? state.Enemies.FirstOrDefault(),
            _ when int.TryParse(target, out var index) && index >= 0 && index < state.Creatures.Count => state.Creatures[index],
            _ => throw new InvalidOperationException($"Unsupported target '{target}'.")
        };
    }

    private static string DescribeCreature(Creature? creature)
    {
        if (creature == null) return "none";
        try
        {
            if (creature.IsPlayer) return $"player:{creature.Player?.Character?.Id}";
            return $"enemy:{creature.Monster?.Id}";
        }
        catch
        {
            return "unknown";
        }
    }

    private static bool TryGetAutomation(JsonElement root, out JsonElement automation)
    {
        automation = default;
        return root.TryGetProperty("scenario", out var scenario)
            && scenario.TryGetProperty("driver", out var driver)
            && driver.TryGetProperty("automation", out automation)
            && automation.ValueKind == JsonValueKind.Object
            && (GetBool(automation, "enabled") ?? true);
    }

    private static ActiveScenarioRequest? ResolveActiveRequest()
    {
        var pointerPath = GetActivePointerPath();
        if (File.Exists(pointerPath))
        {
            try
            {
                using var pointerDoc = JsonDocument.Parse(File.ReadAllText(pointerPath));
                var root = pointerDoc.RootElement;
                var requestPath = GetString(root, "request_path");
                var resultPath = GetString(root, "result_path");
                var requestId = GetString(root, "request_id") ?? Path.GetFileName(Path.GetDirectoryName(requestPath ?? ""));

                if (!string.IsNullOrWhiteSpace(requestPath) && !string.IsNullOrWhiteSpace(resultPath)
                    && !string.IsNullOrWhiteSpace(requestId))
                    return new ActiveScenarioRequest(requestId, requestPath, resultPath);
            }
            catch (Exception e)
            {
                CoreMain.LogDebug($"[CUS-live] Failed to read active scenario pointer: {e.Message}");
            }
        }

        var envRequestPath = System.Environment.GetEnvironmentVariable("CARD_UTILITY_STATS_SCENARIO_REQUEST_PATH");
        var envResultPath = System.Environment.GetEnvironmentVariable("CARD_UTILITY_STATS_SCENARIO_AUTOMATION_RESULT_PATH");
        if (string.IsNullOrWhiteSpace(envRequestPath) || string.IsNullOrWhiteSpace(envResultPath))
            return null;

        return new ActiveScenarioRequest(
            Path.GetFileName(Path.GetDirectoryName(envRequestPath)) ?? "env-request",
            envRequestPath,
            envResultPath);
    }

    private static string GetActivePointerPath()
    {
        var bridgeRoot = System.Environment.GetEnvironmentVariable("CARD_UTILITY_STATS_LIVE_BRIDGE_DIR");
        if (string.IsNullOrWhiteSpace(bridgeRoot))
            bridgeRoot = DefaultBridgeRoot;

        return Path.Combine(bridgeRoot, "active-request.json");
    }

    private static void WriteResult(
        ActiveScenarioRequest active,
        string status,
        string message,
        string scenarioName,
        DateTimeOffset startedAt,
        IReadOnlyList<ScenarioStepResult> steps)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(active.ResultPath)!);

        var payload = new Dictionary<string, object?>
        {
            ["request_id"] = active.RequestId,
            ["scenario_name"] = scenarioName,
            ["status"] = status,
            ["mode"] = "in-game-automation",
            ["message"] = message,
            ["started_at"] = startedAt.ToString("o"),
            ["completed_at"] = DateTimeOffset.UtcNow.ToString("o"),
            ["steps"] = steps.Select(step => new Dictionary<string, object?>
            {
                ["index"] = step.Index,
                ["action"] = step.Action,
                ["status"] = step.Status,
                ["duration_ms"] = (int)step.Duration.TotalMilliseconds,
                ["details"] = step.Details
            }).ToList()
        };

        var tmpPath = active.ResultPath + ".tmp";
        File.WriteAllText(tmpPath, JsonSerializer.Serialize(payload, JsonOptions));
        File.Move(tmpPath, active.ResultPath, overwrite: true);
    }

    private static string? GetString(JsonElement element, params string[] path)
    {
        var current = element;
        foreach (var part in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(part, out current))
                return null;
        }

        return current.ValueKind == JsonValueKind.String ? current.GetString() : current.ToString();
    }

    private static int? GetInt(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result)) return result;
        return int.TryParse(value.ToString(), out result) ? result : null;
    }

    private static double? GetDouble(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var result)) return result;
        return double.TryParse(value.ToString(), out result) ? result : null;
    }

    private static bool? GetBool(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.String when bool.TryParse(value.GetString(), out var parsed) => parsed,
            _ => null
        };
    }

    private static string Normalize(string value)
    {
        return new string(value.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
    }
}

internal sealed record ActiveScenarioRequest(string RequestId, string RequestPath, string ResultPath);

internal sealed record ScenarioStepResult(
    int Index,
    string Action,
    string Status,
    TimeSpan Duration,
    Dictionary<string, object?> Details);
