using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Perch.Core.Protocol;

/// Wire shapes of remote/native-agent-service.py (bridge protocol v10).
/// Field names are declared explicitly: session/snapshot fields are camelCase while
/// message parts are snake_case, so no global naming policy can cover both.
public static class BridgeProtocol
{
    /// Must equal SERVICE_VERSION in remote/native-agent-service.py.
    public const int ServiceVersion = 10;
}

public sealed record BridgeHealth(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("implementation")] string? Implementation,
    [property: JsonPropertyName("startedAt")] string? StartedAt,
    [property: JsonPropertyName("pid")] long? Pid);

public sealed record PermissionCapability(
    [property: JsonPropertyName("selected")] string? Selected,
    [property: JsonPropertyName("options")] IReadOnlyList<string>? Options,
    [property: JsonPropertyName("scope")] string? Scope);

public sealed record ContextUsage(
    [property: JsonPropertyName("tokens")] long? Tokens,
    [property: JsonPropertyName("limit")] long? Limit,
    [property: JsonPropertyName("reportedAt")] double? ReportedAt);

/// One `GET /sessions` entry (Session.summary()).
public sealed record SessionSummary(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("cwd")] string Cwd,
    [property: JsonPropertyName("busy")] bool Busy,
    [property: JsonPropertyName("archived")] bool Archived,
    [property: JsonPropertyName("updated")] double Updated,
    [property: JsonPropertyName("revision")] long Revision,
    [property: JsonPropertyName("completed")] int Completed,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("pending")] int Pending,
    [property: JsonPropertyName("cancelled")] bool? Cancelled,
    [property: JsonPropertyName("thinking")] string? Thinking,
    [property: JsonPropertyName("context")] ContextUsage? Context,
    [property: JsonPropertyName("permission")] PermissionCapability? Permission,
    [property: JsonPropertyName("turnId")] string? TurnId,
    [property: JsonPropertyName("turnState")] string? TurnState,
    [property: JsonPropertyName("steer")] bool? Steer,
    [property: JsonPropertyName("runningSubagents")] int? RunningSubagents);

public sealed record SessionCatalog(
    [property: JsonPropertyName("sessions")] IReadOnlyList<SessionSummary> Sessions);

/// Absolute message positions belong to one bridge history epoch (Session.snapshot()).
public sealed record HistoryWindow(
    [property: JsonPropertyName("epoch")] string Epoch,
    [property: JsonPropertyName("start")] int Start,
    [property: JsonPropertyName("total")] int Total,
    [property: JsonPropertyName("end")] int End,
    [property: JsonPropertyName("indices")] IReadOnlyList<int>? Indices,
    [property: JsonPropertyName("baseRevision")] long? BaseRevision);

/// One content part. `type` selects which of the payload fields are populated.
public sealed record MessagePart(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("text")] string? Text,
    [property: JsonPropertyName("thinking")] string? Thinking,
    [property: JsonPropertyName("tool_call_id")] string? ToolCallId,
    [property: JsonPropertyName("tool_name")] string? ToolName,
    [property: JsonPropertyName("input")] JsonNode? Input,
    [property: JsonPropertyName("output")] JsonNode? Output,
    [property: JsonPropertyName("is_error")] bool? IsError,
    [property: JsonPropertyName("source")] JsonNode? Source);

public sealed record BridgeMessage(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("content")] IReadOnlyList<MessagePart> Content,
    [property: JsonPropertyName("created_at")] string? CreatedAt,
    [property: JsonPropertyName("metadata")] JsonNode? Metadata);

/// A pending approval or question. The Windows MVP displays these and never answers
/// them, so the payload stays untyped rather than modelling every runtime's shape.
public sealed record BridgeInteraction(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string? Name,
    [property: JsonPropertyName("method")] string? Method,
    [property: JsonPropertyName("title")] string? Title,
    [property: JsonPropertyName("message")] string? Message,
    [property: JsonPropertyName("input")] JsonNode? Input,
    [property: JsonPropertyName("options")] JsonNode? Options,
    [property: JsonPropertyName("subagent")] JsonNode? Subagent);

public sealed record BridgeSnapshot(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("cwd")] string Cwd,
    [property: JsonPropertyName("busy")] bool Busy,
    [property: JsonPropertyName("revision")] long Revision,
    [property: JsonPropertyName("completed")] int Completed,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("messages")] IReadOnlyList<BridgeMessage>? Messages,
    [property: JsonPropertyName("history")] HistoryWindow? History,
    [property: JsonPropertyName("interactions")] IReadOnlyList<BridgeInteraction>? Interactions,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("permission")] PermissionCapability? Permission,
    [property: JsonPropertyName("thinking")] string? Thinking,
    [property: JsonPropertyName("context")] ContextUsage? Context,
    [property: JsonPropertyName("turnId")] string? TurnId,
    [property: JsonPropertyName("turnState")] string? TurnState,
    [property: JsonPropertyName("stopRequested")] bool? StopRequested,
    [property: JsonPropertyName("cancelled")] bool? Cancelled)
{
    /// The transcript this snapshot carries. A delta snapshot holds only the changed
    /// positions, so callers must merge it into the held window before display.
    public IReadOnlyList<BridgeMessage> MessagesOrEmpty => Messages ?? Array.Empty<BridgeMessage>();

    public IReadOnlyList<BridgeInteraction> InteractionsOrEmpty =>
        Interactions ?? Array.Empty<BridgeInteraction>();
}

/// Receipt of a prompt/steer request (Session.prompt()/steer(), or a
/// `/sessions/{id}/requests/{requestId}` read).
public sealed record RequestReceipt(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("error")] string? Error,
    [property: JsonPropertyName("mode")] string? Mode,
    [property: JsonPropertyName("runtimeTurnId")] string? RuntimeTurnId,
    [property: JsonPropertyName("turnId")] string? TurnId,
    [property: JsonPropertyName("text")] string? Text,
    [property: JsonPropertyName("digest")] string? Digest)
{
    public string ActiveTurnId => RuntimeTurnId ?? TurnId ?? Id;
}

public static class BridgeJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        // Chinese text and emoji stay readable on the wire and in diagnostics.
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };

    public static T Read<T>(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, Options)
                   ?? throw new BridgeException("桥接服务返回了空的响应体");
        }
        catch (JsonException ex)
        {
            throw new BridgeException("无法解析桥接服务的响应：" + ex.Message, ex);
        }
    }

    public static string Write(object value) => JsonSerializer.Serialize(value, Options);
}
