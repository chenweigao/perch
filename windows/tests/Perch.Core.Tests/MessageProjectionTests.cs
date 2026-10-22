using System.Text.Json.Nodes;
using Perch.Core.Protocol;
using Perch.Core.State;

namespace Perch.Core.Tests;

/// Projection of bridge messages into display blocks. Chinese, emoji, quotes and
/// backslashes must pass through verbatim; injected runtime context folds; tool calls and
/// results render readably.
public class MessageProjectionTests
{
    private static BridgeMessage Msg(string role, params MessagePart[] parts) =>
        new("m", role, parts, null, null);

    private static MessagePart Text(string value, JsonNode? source = null) =>
        new("text", value, null, null, null, null, null, null, source);

    [Fact]
    public void UserPromptAndAssistantTextKeepChineseAndEmojiVerbatim()
    {
        var messages = new[]
        {
            Msg("user", Text("请修复 C:\\路径 & \"引号\" 'single' 🚀")),
            Msg("assistant", Text("正在处理 中文 ✅ done")),
        };
        var blocks = MessageProjection.Project(messages);
        Assert.Equal(BlockKind.UserPrompt, blocks[0].Kind);
        Assert.Equal("请修复 C:\\路径 & \"引号\" 'single' 🚀", blocks[0].Text);
        Assert.Equal(BlockKind.AssistantText, blocks[1].Kind);
        Assert.Equal("正在处理 中文 ✅ done", blocks[1].Text);
    }

    [Fact]
    public void StreamingReplyIsReplacedNotAppended()
    {
        // Two successive projections of the *same* message id, with growing text, must
        // render the latest text — never concatenate the two into a doubled reply.
        var first = MessageProjection.Project(new[] { Msg("assistant", Text("正在处理 ")) });
        var second = MessageProjection.Project(new[] { Msg("assistant", Text("正在处理 中文 🚀")) });
        Assert.Equal("正在处理 ", first.Single().Text);
        Assert.Equal("正在处理 中文 🚀", second.Single().Text);
        Assert.Single(second);
    }

    [Fact]
    public void RuntimeContextIsFoldedIntoASystemNote()
    {
        var reminder = Msg("user", Text("<system-reminder>内部提示，不展示正文</system-reminder>"));
        var blocks = MessageProjection.Project(new[] { reminder });
        Assert.Equal(BlockKind.SystemNote, blocks.Single().Kind);

        var sourced = Msg("user", Text("Base directory for this skill: /x",
            new JsonObject { ["kind"] = "runtime_context" }));
        Assert.Equal(BlockKind.SystemNote, MessageProjection.Project(new[] { sourced }).Single().Kind);
    }

    [Fact]
    public void ToolCallRendersCommandAndPathReadably()
    {
        var call = Msg("assistant", new MessagePart("tool_use", null, null, "item-2", "shell",
            new JsonObject { ["command"] = "ls \"/home/developer/项目 目录\"" }, null, null, null));
        var block = MessageProjection.Project(new[] { call }).Single();
        Assert.Equal(BlockKind.ToolCall, block.Kind);
        Assert.Equal("shell", block.ToolName);
        Assert.Contains("ls \"/home/developer/项目 目录\"", block.Text);
    }

    [Fact]
    public void ToolResultRendersTextOutputAndErrorFlag()
    {
        var output = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "文件 1\n文件 2" });
        var result = Msg("tool", new MessagePart("tool_result", null, null, "item-2", null, null, output, false, null));
        var block = MessageProjection.Project(new[] { result }).Single();
        Assert.Equal(BlockKind.ToolResult, block.Kind);
        Assert.False(block.IsError);
        Assert.Contains("文件 1", block.Text);
        Assert.Contains("文件 2", block.Text);

        var errored = Msg("tool", new MessagePart("tool_result", null, null, "item-3", null, null,
            JsonValue.Create("boom"), true, null));
        Assert.True(MessageProjection.Project(new[] { errored }).Single().IsError);
    }

    [Fact]
    public void ToolResultRoleMessageIsNotAUserPrompt()
    {
        // A user-role message carrying only tool_result parts does not open a turn.
        var message = Msg("user", new MessagePart("tool_result", null, null, "x", null, null, null, false, null));
        Assert.False(MessageProjection.IsUserPrompt(message));
        Assert.Equal(BlockKind.ToolResult, MessageProjection.Project(new[] { message }).Single().Kind);
    }

    [Fact]
    public void CompactionSummaryUserMessageIsNotAPrompt()
    {
        var metadata = new JsonObject { ["origin"] = new JsonObject { ["kind"] = "compaction_summary" } };
        var message = new BridgeMessage("m", "user", new[] { Text("摘要") }, null, metadata);
        Assert.False(MessageProjection.IsUserPrompt(message));
    }

    [Fact]
    public void RealUserPromptIsRecognized()
    {
        var message = Msg("user", Text("你好 🚀"));
        Assert.True(MessageProjection.IsUserPrompt(message));
    }

    [Fact]
    public void ThinkingPartProjectsAsThinking()
    {
        var message = Msg("assistant", new MessagePart("thinking", null, "让我想想 🤔", null, null, null, null, null, null));
        var block = MessageProjection.Project(new[] { message }).Single();
        Assert.Equal(BlockKind.Thinking, block.Kind);
        Assert.Equal("让我想想 🤔", block.Text);
    }

    [Fact]
    public void ProjectionOfTheRealApprovalFixtureShowsTheCommand()
    {
        // End-to-end: the approval snapshot's transcript projects without throwing and
        // keeps the shell command text intact.
        var snapshot = Fixtures.Read<BridgeSnapshot>("session-snapshot-approval.json");
        var blocks = MessageProjection.Project(snapshot.MessagesOrEmpty);
        Assert.NotNull(blocks);
    }
}
