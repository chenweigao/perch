using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Perch.Core.Protocol;

namespace Perch.Core.State;

/// A display row derived from one bridge message part. The UI binds to these so it
/// never has to know the wire part shapes. Text is passed through verbatim: Chinese,
/// emoji, quotes and backslashes stay exactly as the model produced them.
public enum BlockKind
{
    UserPrompt,
    AssistantText,
    Thinking,
    ToolCall,
    ToolResult,
    SystemNote,
}

public sealed record MessageBlock(
    BlockKind Kind,
    string MessageId,
    string Text,
    string? ToolName = null,
    bool IsError = false)
{
    public string Display => Text;
}

/// Projects bridge messages into display blocks.
public static class MessageProjection
{
    public static IReadOnlyList<MessageBlock> Project(IEnumerable<BridgeMessage> messages)
    {
        var blocks = new List<MessageBlock>();
        foreach (var message in messages)
        {
            var isUser = message.Role == "user" && IsUserPrompt(message);
            var isToolResultRole = message.Role == "tool";
            foreach (var part in message.Content)
            {
                var block = ProjectPart(message.Id, message.Role, part, isUser, isToolResultRole);
                if (block is not null) blocks.Add(block);
            }
        }
        return blocks;
    }

    private static MessageBlock? ProjectPart(string messageId, string role, MessagePart part, bool isUser, bool isToolResultRole)
    {
        switch (part.Type)
        {
            case "text":
                var text = part.Text ?? string.Empty;
                if (IsRuntimeContext(part, text))
                    return new MessageBlock(BlockKind.SystemNote, messageId, SummarizeContext(text));
                return new MessageBlock(isUser ? BlockKind.UserPrompt : BlockKind.AssistantText, messageId, text);
            case "thinking":
                return new MessageBlock(BlockKind.Thinking, messageId, part.Thinking ?? string.Empty);
            case "tool_use":
                return new MessageBlock(BlockKind.ToolCall, messageId, RenderToolInput(part.Input), part.ToolName);
            case "tool_result":
                return new MessageBlock(BlockKind.ToolResult, messageId, RenderOutput(part.Output),
                    part.ToolName, part.IsError == true);
            default:
                return new MessageBlock(BlockKind.SystemNote, messageId, "[" + part.Type + "]");
        }
    }

    /// Mirrors the bridge's is_user_prompt(): a user-role message that is only tool
    /// results or injected context does not open a turn.
    public static bool IsUserPrompt(BridgeMessage message)
    {
        if (message.Role != "user") return false;
        if (IsCompactionSummary(message.Metadata)) return false;
        return !message.Content.All(p => p.Type == "tool_result" || IsRuntimeContext(p, p.Text ?? string.Empty));
    }

    private static bool IsCompactionSummary(JsonNode? metadata)
    {
        if (metadata is not JsonObject obj) return false;
        if (obj["origin"] is not JsonObject origin) return false;
        return origin["kind"]?.GetValue<string>() == "compaction_summary";
    }

    private static bool IsRuntimeContext(MessagePart part, string text)
    {
        if (part.Type != "text") return false;
        if (part.Source is JsonObject source && source["kind"]?.GetValue<string>() == "runtime_context") return true;
        var trimmed = text.TrimStart();
        return trimmed.StartsWith("<system-reminder>", StringComparison.Ordinal)
               || trimmed.StartsWith("<system>", StringComparison.Ordinal)
               || trimmed.StartsWith("<notification ", StringComparison.Ordinal)
               || trimmed.StartsWith("<skill-loaded ", StringComparison.Ordinal)
               || trimmed.StartsWith("Base directory for this skill: ", StringComparison.Ordinal);
    }

    private static string SummarizeContext(string text)
    {
        var firstLine = text.Split('\n', 2)[0].Trim();
        return firstLine.Length > 120 ? firstLine[..120] + "…" : firstLine;
    }

    private static string RenderToolInput(JsonNode? input)
    {
        if (input is null) return string.Empty;
        if (input is JsonObject obj)
        {
            // Show the most useful scalar fields first (command, path, query), then any
            // remainder. Keeps a shell command readable without dumping raw JSON.
            var parts = new List<string>();
            foreach (var key in new[] { "command", "path", "query", "file", "pattern" })
            {
                if (obj[key] is JsonValue value && TryGetScalar(value, out var text))
                    parts.Add(key + ": " + text);
            }
            foreach (var (key, value) in obj)
            {
                if (parts.Any(p => p.StartsWith(key + ": ", StringComparison.Ordinal))) continue;
                parts.Add(key + ": " + RenderNode(value));
            }
            return string.Join("\n", parts);
        }
        return RenderNode(input);
    }

    private static string RenderOutput(JsonNode? output)
    {
        if (output is null) return string.Empty;
        if (output is JsonArray array)
        {
            var builder = new StringBuilder();
            foreach (var item in array)
            {
                if (item is JsonObject obj && obj["type"]?.GetValue<string>() == "text" &&
                    obj["text"] is JsonValue textValue && TryGetScalar(textValue, out var text))
                {
                    if (builder.Length > 0) builder.Append('\n');
                    builder.Append(text);
                }
                else
                {
                    if (builder.Length > 0) builder.Append('\n');
                    builder.Append(RenderNode(item));
                }
            }
            return builder.ToString();
        }
        if (output is JsonValue scalar && TryGetScalar(scalar, out var scalarText)) return scalarText;
        return RenderNode(output);
    }

    private static bool TryGetScalar(JsonValue value, out string text)
    {
        if (value.TryGetValue<string>(out var s)) { text = s; return true; }
        if (value.TryGetValue<bool>(out var b)) { text = b ? "true" : "false"; return true; }
        if (value.TryGetValue<long>(out var l)) { text = l.ToString(System.Globalization.CultureInfo.InvariantCulture); return true; }
        if (value.TryGetValue<double>(out var d)) { text = d.ToString(System.Globalization.CultureInfo.InvariantCulture); return true; }
        text = value.ToJsonString();
        return true;
    }

    private static string RenderNode(JsonNode? node) => node?.ToJsonString(BridgeJson.Options) ?? string.Empty;
}
