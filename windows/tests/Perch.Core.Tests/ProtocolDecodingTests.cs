using Perch.Core.Bridge;
using Perch.Core.Protocol;
using Perch.Core.State;

namespace Perch.Core.Tests;

/// Decoding the real bridge's JSON, exactly as remote/native-agent-service.py emits it.
/// These fixtures are generated from the bridge code (windows/tools/generate-fixtures.py),
/// so a decoding mismatch here is a real contract break, not a fixture drift.
public class ProtocolDecodingTests
{
    [Fact]
    public void HealthReportsProtocolVersionAndFingerprint()
    {
        var health = Fixtures.Read<BridgeHealth>("health.json");
        Assert.Equal(BridgeProtocol.ServiceVersion, health.Version);
        Assert.False(string.IsNullOrEmpty(health.Implementation));
        Assert.Equal("2026-10-21T09:14:00+08:00", health.StartedAt);
        Assert.Equal(4242, health.Pid);
    }

    [Fact]
    public void ServiceVersionMatchesTheBridgeSource()
    {
        // Guards the constant the same way scripts/check-version.py guards the Swift one.
        // Skipped when the bridge source is not alongside the client (a standalone
        // windows/ checkout or a published package); in the canonical repo layout the
        // file is always present and the equality is asserted.
        var bridgePath = Path.Combine(RepoRoot() ?? string.Empty, "remote", "native-agent-service.py");
        if (!File.Exists(bridgePath)) return;

        var source = File.ReadAllText(bridgePath);
        var match = System.Text.RegularExpressions.Regex.Match(source, @"^SERVICE_VERSION = (\d+)\r?$",
            System.Text.RegularExpressions.RegexOptions.Multiline);
        Assert.True(match.Success, "remote/native-agent-service.py must declare SERVICE_VERSION");
        Assert.Equal(BridgeProtocol.ServiceVersion, int.Parse(match.Groups[1].Value));
    }

    [Fact]
    public void CatalogDecodesSummariesWithChineseTitlesAndEmoji()
    {
        var catalog = Fixtures.Read<SessionCatalog>("sessions.json");
        Assert.Equal(3, catalog.Sessions.Count);

        var busy = catalog.Sessions.Single(s => s.Id == "ses-busy");
        Assert.Equal("重构登录页 \"引号\" & emoji 🚀", busy.Title);
        Assert.Equal("/home/developer/项目 目录", busy.Cwd);
        Assert.True(busy.Busy);
        Assert.Equal("turn-1", busy.TurnId);
        Assert.Equal("running", busy.TurnState);
        Assert.Equal("codex", busy.Provider);
        Assert.True(busy.Steer);
        Assert.Equal("workspace-ask", busy.Permission!.Selected);
        Assert.Contains("read-only", busy.Permission.Options!);

        var approval = catalog.Sessions.Single(s => s.Id == "ses-approval");
        Assert.Equal(1, approval.Pending);
        Assert.True(approval.Busy);

        var idle = catalog.Sessions.Single(s => s.Id == "ses-idle");
        Assert.False(idle.Busy);
        Assert.Equal(3, idle.Completed);
    }

    [Fact]
    public void PagedSnapshotDecodesHistoryWindowAndSnakeCaseParts()
    {
        var snapshot = Fixtures.Read<BridgeSnapshot>("session-snapshot-paged.json");
        Assert.Equal("ses-busy", snapshot.Id);
        Assert.NotNull(snapshot.History);
        Assert.Equal(0, snapshot.History!.Start);
        Assert.Null(snapshot.History.Indices); // a paged read names every position

        var messages = snapshot.MessagesOrEmpty;
        Assert.NotEmpty(messages);
        // The user prompt carries shell metacharacters and Chinese verbatim.
        var user = messages.First(m => m.Role == "user");
        var text = user.Content.Single(p => p.Type == "text").Text!;
        Assert.Contains("C:\\Users\\me\\项目 & 测试 'quoted'", text);
        Assert.Contains("`ls $HOME` && echo \"ok\"", text);

        // The streaming assistant reply arrives as full text at its index, not a delta.
        var assistant = messages.First(m => m.Role == "assistant");
        Assert.Equal("codex:item-1", assistant.Id);
        Assert.Equal("正在处理 中文 🚀", assistant.Content.Single().Text);
    }

    [Fact]
    public void DeltaSnapshotNamesOnlyChangedIndicesAndCarriesBaseRevision()
    {
        var delta = Fixtures.Read<BridgeSnapshot>("session-snapshot-delta.json");
        var window = delta.History!;
        Assert.Equal(new[] { 1 }, window.Indices!.ToArray());
        Assert.Equal(3, window.BaseRevision);
        Assert.Equal(4, delta.Revision);
        // The delta's messages are only the changed positions, in index order.
        Assert.Single(delta.MessagesOrEmpty);
        Assert.Equal("正在处理 中文 🚀 完成 ✅", delta.MessagesOrEmpty[0].Content.Single().Text);
    }

    [Fact]
    public void DeltaAppendCarriesToolUseAndToolResultParts()
    {
        var delta = Fixtures.Read<BridgeSnapshot>("session-snapshot-delta-append.json");
        Assert.Equal(new[] { 2, 3 }, delta.History!.Indices!.ToArray());
        var toolUse = delta.MessagesOrEmpty[0];
        Assert.Equal("assistant", toolUse.Role);
        var part = toolUse.Content.Single();
        Assert.Equal("tool_use", part.Type);
        Assert.Equal("shell", part.ToolName);
        Assert.Equal("item-2", part.ToolCallId);

        var toolResult = delta.MessagesOrEmpty[1];
        Assert.Equal("tool", toolResult.Role);
        var resultPart = toolResult.Content.Single();
        Assert.Equal("tool_result", resultPart.Type);
        Assert.False(resultPart.IsError!.Value);
        // output is an array of text parts; projection renders it back to text.
        var projected = State.MessageProjection.Project(new[] { toolResult });
        Assert.Contains("文件 1", string.Join("\n", projected.Select(b => b.Text)));
    }

    [Fact]
    public void UnchangedSnapshotIsRecognized()
    {
        var response = SnapshotResponse.Parse(Fixtures.Raw("session-snapshot-unchanged.json"));
        Assert.True(response.Unchanged);
        Assert.Null(response.Snapshot);
    }

    [Fact]
    public void ApprovalSnapshotSurfacesInteractionWithoutAnswering()
    {
        var snapshot = Fixtures.Read<BridgeSnapshot>("session-snapshot-approval.json");
        Assert.True(snapshot.Busy);
        var interaction = Assert.Single(snapshot.InteractionsOrEmpty);
        Assert.Equal("codex-request-7", interaction.Id);
        Assert.Equal("shell", interaction.Name);
        Assert.Equal("Codex 请求确认", interaction.Title);
        var input = interaction.Input!.AsObject();
        Assert.Equal("rm -rf /tmp/项目 x", input["command"]!.GetValue<string>());
        Assert.Equal("需要执行命令", input["reason"]!.GetValue<string>());
    }

    [Fact]
    public void PromptReceiptDecodesIdStatusAndRuntimeTurnId()
    {
        var receipt = Fixtures.Read<RequestReceipt>("prompt-receipt.json");
        Assert.Equal("req-send-1", receipt.Id);
        Assert.Equal("accepted", receipt.Status);
        Assert.Equal("turn-1", receipt.RuntimeTurnId);
        Assert.Equal("turn-1", receipt.ActiveTurnId);
        // The prompt text round-trips with every metacharacter and Chinese intact.
        Assert.Equal("shell 元字符 $VAR `whoami` && rm -rf / \"引号\" 'single' 中文 🚀 C:\\路径 空格", receipt.Text);
    }

    [Fact]
    public void ReplayReceiptIsIdenticalSoARetryIsIdempotent()
    {
        var first = Fixtures.Read<RequestReceipt>("prompt-receipt.json");
        var replay = Fixtures.Read<RequestReceipt>("prompt-receipt-replay.json");
        Assert.Equal(first.Id, replay.Id);
        Assert.Equal(first.Status, replay.Status);
        Assert.Equal(first.Digest, replay.Digest);
    }

    [Fact]
    public void NotFoundReceiptDecodes()
    {
        var receipt = Fixtures.Read<RequestReceipt>("request-receipt-notfound.json");
        Assert.Equal("notFound", receipt.Status);
        Assert.Equal("req-missing", receipt.Id);
    }

    [Fact]
    public void PromptTextReachesCodexAsStructuredInputNotAShellString()
    {
        // End-to-end shell-safety proof: the bridge handed Codex the prompt as a typed
        // `input` text item. No shell, no interpolation, metacharacters intact.
        var turnStart = Fixtures.ReadNode("prompt-turn-start-params.json").AsObject();
        Assert.Equal("native-thread-1", turnStart["threadId"]!.GetValue<string>());
        var input = turnStart["input"]!.AsArray();
        var single = Assert.Single(input);
        var textItem = Assert.IsType<System.Text.Json.Nodes.JsonObject>(single);
        Assert.Equal("text", textItem["type"]!.GetValue<string>());
        var text = textItem["text"]!.GetValue<string>();
        Assert.Equal("shell 元字符 $VAR `whoami` && rm -rf / \"引号\" 'single' 中文 🚀 C:\\路径 空格", text);
        // The requestId travels as clientUserMessageId, binding the receipt to the turn.
        Assert.Equal("req-send-1", turnStart["clientUserMessageId"]!.GetValue<string>());
    }

    [Fact]
    public void EndpointJsonCarriesTheLoopbackPortAndToken()
    {
        // The token-file provider may be pointed at an endpoint.json; it must expose a
        // loopback port and the secret. Asserted as raw JSON because that is how it is read.
        var endpoint = Fixtures.ReadNode("endpoint.json").AsObject();
        Assert.Equal(41873, endpoint["port"]!.GetValue<int>());
        Assert.Equal("fixture-token-do-not-use", endpoint["token"]!.GetValue<string>());
    }

    [Fact]
    public void UnpagedSnapshotHasNoHistoryWindow()
    {
        // A snapshot read without paging carries the whole transcript and no window; the
        // client must treat that as the full history rather than a delta.
        var snapshot = Fixtures.Read<BridgeSnapshot>("session-snapshot-full.json");
        Assert.Null(snapshot.History);
        Assert.Equal("ses-busy", snapshot.Id);
        Assert.Equal(2, snapshot.MessagesOrEmpty.Count);
    }

    [Fact]
    public void DeltaAtTheHeldRevisionAnswersUnchanged()
    {
        // A delta query whose revision already matches answers {"unchanged":true}: the poll
        // must not rebuild the transcript. This is what keeps idle polling cheap.
        var response = SnapshotResponse.Parse(Fixtures.Raw("session-snapshot-delta-unchanged.json"));
        Assert.True(response.Unchanged);
        Assert.Null(response.Snapshot);
    }

    [Fact]
    public void StaleEpochErrorEnvelopeIsDecodable()
    {
        var (status, body) = Fixtures.ReadError("error-stale-epoch.json");
        Assert.Equal(400, status);
        Assert.Equal("History changed; reopen the conversation",
            Perch.Core.Transport.HttpBridgeTransport.ExtractError(body, status));
    }

    [Fact]
    public void ErrorEnvelopeCarriesTheBridgeMessage()
    {
        var (status, body) = Fixtures.ReadError("error-bad-request.json");
        Assert.Equal(400, status);
        var message = Perch.Core.Transport.HttpBridgeTransport.ExtractError(body, status);
        Assert.Equal("轮次已变化，请重新同步", message);
    }

    [Fact]
    public void UnauthorizedEnvelopeIsStatus401()
    {
        var (status, body) = Fixtures.ReadError("error-unauthorized.json");
        Assert.Equal(401, status);
        Assert.Equal("Unauthorized", Perch.Core.Transport.HttpBridgeTransport.ExtractError(body, status));
    }

    /// Walks up from the test binaries to the repo root (the directory holding
    /// remote/native-agent-service.py). Returns null when the client is checked out or
    /// published without the bridge alongside it.
    private static string? RepoRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "remote", "native-agent-service.py")))
            directory = directory.Parent;
        return directory?.FullName;
    }
}
