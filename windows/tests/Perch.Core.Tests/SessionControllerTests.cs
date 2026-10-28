using System.Text.Json;
using Perch.Core.Bridge;
using Perch.Core.Protocol;
using Perch.Core.State;
using Perch.Core.Transport;

namespace Perch.Core.Tests;

/// A fixture-backed bridge: serves the real JSON by route and records what was asked.
/// Lets the state machine be driven deterministically without a model, Windows or
/// private credentials.
public sealed class FixtureBridge : IBridgeTransport
{
    private readonly Dictionary<string, string> _routes;
    public List<BridgeRequest> Requests { get; } = new();

    /// Canned replies for prompt/steer/abort, keyed by action; set by tests.
    public RequestReceipt? NextReceipt { get; set; }
    public string? NextError { get; set; }
    public Task? PostGate { get; set; }
    public int AbortCalls { get; private set; }
    public string? LastAbortTurnId { get; private set; }

    public FixtureBridge()
    {
        _routes = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["/health"] = Fixtures.Raw("health.json"),
            ["/sessions"] = Fixtures.Raw("sessions.json"),
        };
    }

    public FixtureBridge WithSnapshot(string sessionPath, string fixture)
    {
        _routes[sessionPath] = Fixtures.Raw(fixture);
        return this;
    }

    public FixtureBridge WithJson(string sessionPath, string body)
    {
        _routes[sessionPath] = body;
        return this;
    }

    public async Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken)
    {
        Requests.Add(request);
        if (request.Method == "POST")
        {
            if (PostGate is not null) await PostGate;
            if (request.PathAndQuery.EndsWith("/abort"))
            {
                AbortCalls++;
                LastAbortTurnId = ExtractTurnId(request.Body);
                if (NextError is not null) throw new BridgeException(NextError) { StatusCode = 400 };
                return "{\"ok\":true}";
            }
            if (NextError is not null) throw new BridgeException(NextError) { StatusCode = 400 };
            var receipt = NextReceipt ?? Fixtures.Read<RequestReceipt>("prompt-receipt.json");
            return BridgeJson.Write(receipt);
        }
        if (_routes.TryGetValue(request.PathAndQuery, out var body))
            return body;
        throw new BridgeException("未知路径：" + request.PathAndQuery) { StatusCode = 400 };
    }

    private static string? ExtractTurnId(object? body)
    {
        if (body is null) return null;
        var json = JsonSerializer.Serialize(body);
        using var document = JsonDocument.Parse(json);
        return document.RootElement.TryGetProperty("turnId", out var value) ? value.GetString() : null;
    }
}

/// Records observer callbacks so tests can assert what the UI would have been told.
public sealed class RecordingObserver : ISessionObserver
{
    public int ConnectionChanges;
    public int CatalogChanges;
    public int SelectionChanges;
    public int TranscriptChanges;
    public List<string> Errors { get; } = new();
    public void OnConnectionStateChanged() => ConnectionChanges++;
    public void OnCatalogChanged() => CatalogChanges++;
    public void OnSelectionChanged() => SelectionChanges++;
    public void OnTranscriptChanged() => TranscriptChanges++;
    public void OnOutboxChanged() { }
    public void OnError(string message) => Errors.Add(message);
}

public class SessionControllerTests
{
    private static SessionController MakeController(IBridgeTransport bridge, RecordingObserver? observer = null)
        => new(new BridgeClient(bridge), observer ?? new RecordingObserver());

    [Fact]
    public async Task FirstPollLoadsCatalogNewestFirst()
    {
        var bridge = new FixtureBridge();
        var observer = new RecordingObserver();
        var controller = MakeController(bridge, observer);
        controller.BeginOnlineSession();

        await controller.PollOnceAsync(default);

        Assert.Equal(3, controller.Sessions.Count);
        // ses-busy has the newest `updated` in the fixtures.
        Assert.Equal("ses-busy", controller.Sessions[0].Id);
        Assert.True(observer.CatalogChanges >= 1);
    }

    [Fact]
    public async Task SelectThenPollLoadsTheTranscript()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        await controller.PollOnceAsync(default);

        controller.Select("ses-busy");
        await controller.PollOnceAsync(default);

        Assert.NotNull(controller.Transcript);
        Assert.Equal("ses-busy", controller.Transcript!.SessionId);
        Assert.Equal(2, controller.Transcript.Messages.Count);
        // The first read of a selection is paged, establishing the window.
        Assert.Contains(bridge.Requests, r => r.PathAndQuery == "/sessions/ses-busy?turns=25");
    }

    [Fact]
    public async Task SecondPollUsesADeltaPinnedToRevisionAndEpoch()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json")
            .WithSnapshot("/sessions/ses-busy?revision=3&start=0&epoch=" + Epoch(), "session-snapshot-delta.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-busy");
        await controller.PollOnceAsync(default); // paged read, revision 3
        await controller.PollOnceAsync(default); // delta read

        Assert.Equal(2, controller.Transcript!.Messages.Count);
        Assert.Equal("正在处理 中文 🚀 完成 ✅", controller.Transcript.Messages[1].Content.Single().Text);
        Assert.Contains(bridge.Requests, r => r.PathAndQuery.StartsWith("/sessions/ses-busy?revision=3&start=0&epoch="));
    }

    [Fact]
    public async Task SwitchingSessionDiscardsTheOldTranscriptAndSelectionGeneration()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json")
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();

        controller.Select("ses-busy");
        await controller.PollOnceAsync(default);
        Assert.Equal("ses-busy", controller.Transcript!.SessionId);

        controller.Select("ses-idle");
        // Immediately after switching, the old transcript is cleared so nothing from
        // ses-busy can be shown for ses-idle.
        Assert.Null(controller.Transcript);
        await controller.PollOnceAsync(default);
        Assert.Equal("ses-idle", controller.Transcript!.SessionId);
        Assert.DoesNotContain(controller.Transcript.Messages, m => m.Id == "codex:item-1");
    }

    [Fact]
    public async Task StaleResponseForOldSelectionDoesNotOverwriteNewSelection()
    {
        // A snapshot read for ses-busy is in flight when the user switches to ses-idle.
        // The generation guard must drop the late ses-busy response so it cannot land
        // on top of the newly selected session's transcript.
        var releaseBusy = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var bridge = new BlockingBridge(releaseBusy.Task)
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json")
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();

        controller.Select("ses-busy");
        var inFlight = controller.PollOnceAsync(default); // blocks on the ses-busy read

        controller.Select("ses-idle");        // user switches while the read is in flight
        Assert.Null(controller.Transcript);   // old transcript cleared immediately

        releaseBusy.SetResult();              // now let the stale ses-busy response land
        await inFlight;

        // The stale response was dropped: nothing from ses-busy is shown.
        Assert.True(controller.Transcript is null || controller.Transcript.SessionId != "ses-busy");

        await controller.PollOnceAsync(default); // read the newly selected session
        Assert.Equal("ses-idle", controller.Transcript!.SessionId);
        Assert.DoesNotContain(controller.Transcript.Messages, m => m.Id == "codex:item-1");
    }

    [Fact]
    public async Task SelectionAndSnapshotPublicationAreSerialized()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json")
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        for (var iteration = 0; iteration < 50; iteration++)
        {
            var controller = MakeController(bridge);
            controller.BeginOnlineSession();
            controller.Select("ses-busy");

            var polling = controller.PollOnceAsync(default);
            var selecting = Task.Run(() => controller.Select("ses-idle"));
            await Task.WhenAll(polling, selecting);

            Assert.Equal("ses-idle", controller.SelectedId);
            Assert.True(controller.Transcript is null || controller.Transcript.SessionId == "ses-idle");
        }
    }

    [Fact]
    public async Task LateResponseAfterDisconnectIsIgnored()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var bridge = new BlockingBridge(release.Task)
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-busy");

        var inFlight = controller.PollOnceAsync(default);
        controller.MarkOffline();   // disconnect while the read is in flight
        release.SetResult();
        var applied = await inFlight;

        Assert.False(applied);      // superseded generation: the poll reports "not applied"
        Assert.Null(controller.Transcript);
    }

    [Fact]
    public async Task SendWhenIdlePostsPromptWithRequestIdAndText()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-idle");
        await controller.PollOnceAsync(default);

        var text = "shell 元字符 $VAR `whoami` && rm -rf / \"引号\" 'single' 中文 🚀 C:\\路径 空格";
        var requestId = await controller.SendAsync(text, default);

        var prompt = bridge.Requests.Single(r => r.Method == "POST" && r.PathAndQuery.EndsWith("/prompt"));
        Assert.Equal("/sessions/ses-idle/prompt", prompt.PathAndQuery);
        // The text rides as a JSON body, never interpolated into any shell. Assert the
        // exact round trip: Chinese, emoji (encoded as a valid JSON surrogate escape),
        // quotes, backslashes and shell metacharacters all survive to the wire and back.
        var serialized = BridgeJson.Write(prompt.Body!);
        using var document = JsonDocument.Parse(serialized);
        var sentText = document.RootElement.GetProperty("text").GetString();
        Assert.Equal(text, sentText);
        Assert.Equal(requestId, document.RootElement.GetProperty("requestId").GetString());
        Assert.Equal(OutboxState.Accepted, controller.Outbox.Find(requestId)!.State);
    }

    [Fact]
    public async Task UnknownReceiptIsSurfacedAsARecoverableSendFailure()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        bridge.NextReceipt = Fixtures.Read<RequestReceipt>("prompt-receipt.json") with
        {
            Status = "unknown", Error = "runtime unavailable",
        };
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-idle");
        await controller.PollOnceAsync(default);

        var ex = await Assert.ThrowsAsync<PerchException>(() => controller.SendAsync("keep draft", default));

        Assert.Equal("runtime unavailable", ex.Message);
        var entry = Assert.Single(controller.Outbox.Entries);
        Assert.Equal(OutboxState.Unknown, entry.State);
        Assert.Equal("runtime unavailable", entry.Error);
    }

    [Fact]
    public async Task InitialPostDoesNotPollReceiptBeforeItSettles()
    {
        var postGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        bridge.PostGate = postGate.Task;
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-idle");
        await controller.PollOnceAsync(default);

        var sending = controller.SendAsync("initial post", default);
        await controller.PollOnceAsync(default);

        var entry = Assert.Single(controller.Outbox.Entries);
        Assert.Equal(OutboxState.Sending, entry.State);
        Assert.DoesNotContain(bridge.Requests, request => request.PathAndQuery.Contains("/requests/"));
        Assert.False(sending.IsCompleted);
        postGate.SetResult();
        var requestId = await sending;
        Assert.Equal(OutboxState.Accepted, controller.Outbox.Find(requestId)!.State);
    }

    [Fact]
    public async Task PollRefreshesPendingReceiptAndSurfacesFailure()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        bridge.NextReceipt = Fixtures.Read<RequestReceipt>("prompt-receipt.json") with { Status = "submitted" };
        var observer = new RecordingObserver();
        var controller = MakeController(bridge, observer);
        controller.BeginOnlineSession();
        controller.Select("ses-idle");
        await controller.PollOnceAsync(default);
        var requestId = await controller.SendAsync("pending steer", default);
        var failed = Fixtures.Read<RequestReceipt>("prompt-receipt.json") with
        {
            Id = requestId, Status = "failed", Error = "steer rejected",
        };
        bridge.WithJson($"/sessions/ses-idle/requests/{requestId}", BridgeJson.Write(failed));

        await controller.PollOnceAsync(default);

        var entry = controller.Outbox.Find(requestId)!;
        Assert.Equal(OutboxState.Failed, entry.State);
        Assert.Equal("steer rejected", entry.Error);
        Assert.Equal("steer rejected", observer.Errors.Single());
        Assert.Contains(bridge.Requests, request =>
            request.Method == "GET" && request.PathAndQuery == $"/sessions/ses-idle/requests/{requestId}");
    }

    [Fact]
    public async Task SendWhenBusyPostsSteerNotPrompt()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-busy");
        await controller.PollOnceAsync(default);
        Assert.True(controller.Snapshot!.Busy);

        await controller.SendAsync("加一句中文 🚀", default);

        Assert.Contains(bridge.Requests, r => r.Method == "POST" && r.PathAndQuery.EndsWith("/steer"));
        Assert.DoesNotContain(bridge.Requests, r => r.Method == "POST" && r.PathAndQuery.EndsWith("/prompt"));
    }

    [Fact]
    public async Task BusySessionWithoutSteerCapabilityFallsBackToPrompt()
    {
        // The bridge only accepts steer for providers that declare it (summary().steer).
        // A busy session that does not must be sent a prompt, not a steer the bridge
        // would reject.
        var bridge = new StubSteerBridge(steer: false);
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-x");
        await controller.PollOnceAsync(default);

        await controller.SendAsync("你好", default);

        Assert.Contains(bridge.Requests, r => r.Method == "POST" && r.PathAndQuery.EndsWith("/prompt"));
        Assert.DoesNotContain(bridge.Requests, r => r.Method == "POST" && r.PathAndQuery.EndsWith("/steer"));
    }

    [Fact]
    public async Task CancelPostsAbortWithTheLiveTurnId()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-busy");
        await controller.PollOnceAsync(default);

        await controller.CancelTurnAsync(default);

        Assert.Equal(1, bridge.AbortCalls);
        Assert.Equal("turn-1", bridge.LastAbortTurnId);
        Assert.Contains(bridge.Requests, r => r.Method == "POST" && r.PathAndQuery == "/sessions/ses-busy/abort");
    }

    [Fact]
    public async Task CancelWithNoLiveTurnIsRefused()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-idle?turns=25", "session-snapshot-idle.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-idle");
        await controller.PollOnceAsync(default);

        await Assert.ThrowsAsync<PerchException>(() => controller.CancelTurnAsync(default));
        Assert.Equal(0, bridge.AbortCalls);
    }

    [Fact]
    public async Task CancelSurfacesBridgeRejectionWithoutRetrying()
    {
        var bridge = new FixtureBridge { NextError = "轮次已变化，请重新同步" }
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json");
        var observer = new RecordingObserver();
        var controller = MakeController(bridge, observer);
        controller.BeginOnlineSession();
        controller.Select("ses-busy");
        await controller.PollOnceAsync(default);

        await Assert.ThrowsAsync<BridgeException>(() => controller.CancelTurnAsync(default));
        Assert.Equal(1, bridge.AbortCalls); // one attempt, no retry
        Assert.Contains("轮次已变化", observer.Errors.Single());
    }

    [Fact]
    public async Task PendingApprovalIsSurfacedAndNeverAutoAnswered()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-approval?turns=25", "session-snapshot-approval.json");
        var controller = MakeController(bridge);
        controller.BeginOnlineSession();
        controller.Select("ses-approval");
        await controller.PollOnceAsync(default);

        var pending = Assert.Single(controller.PendingInteractions);
        Assert.Equal("codex-request-7", pending.Id);
        // The client only reads: it never POSTs an answer for the interaction.
        Assert.DoesNotContain(bridge.Requests, r => r.PathAndQuery.EndsWith("/answer"));
    }

    [Fact]
    public async Task DisconnectMarksOfflineAndDoesNotAbortTheRemoteTurn()
    {
        var bridge = new FixtureBridge()
            .WithSnapshot("/sessions/ses-busy?turns=25", "session-snapshot-paged.json");
        var observer = new RecordingObserver();
        var controller = MakeController(bridge, observer);
        controller.BeginOnlineSession();
        controller.Select("ses-busy");
        await controller.PollOnceAsync(default);

        controller.MarkOffline();

        Assert.Equal(ConnectionState.Disconnected, controller.ConnectionState);
        // Disconnect is separate from cancel: no abort was sent, the remote turn lives on.
        Assert.Equal(0, bridge.AbortCalls);
    }

    [Fact]
    public async Task SendWhileOfflineIsRefused()
    {
        var controller = MakeController(new FixtureBridge());
        // Never came online.
        await Assert.ThrowsAsync<PerchException>(() => controller.SendAsync("hi", default));
    }

    [Fact]
    public async Task SelectionThatDisappearsFromCatalogIsCleared()
    {
        // The catalog no longer contains the selected session (deleted on the host):
        // the selection and its transcript must be cleared, not left pointing at a ghost.
        var bridge = new EmptyCatalogBridge();
        var controller = new SessionController(new BridgeClient(bridge));
        controller.BeginOnlineSession();
        controller.Select("ses-busy");

        await controller.PollOnceAsync(default);

        Assert.Null(controller.SelectedId);
        Assert.Null(controller.Transcript);
        Assert.Null(controller.Snapshot);
    }

    [Fact]
    public async Task ConnectionConfigRejectsBadDestinationOrPort()
    {
        await Task.CompletedTask;
        Assert.Throws<PerchException>(() => new ConnectionConfig("-x", 1000).Validate());
        Assert.Throws<PerchException>(() => new ConnectionConfig("dev", 0).Validate());
        Assert.Throws<PerchException>(() => new ConnectionConfig("dev", 70000).Validate());
        new ConnectionConfig("dev", 41873).Validate(); // ok
    }

    private static string Epoch()
    {
        var snapshot = Fixtures.Read<BridgeSnapshot>("session-snapshot-paged.json");
        return snapshot.History!.Epoch;
    }

    /// A bridge whose catalog is empty, to test the selection-vanished path.
    private sealed class EmptyCatalogBridge : IBridgeTransport
    {
        public Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken)
        {
            if (request.PathAndQuery == "/sessions") return Task.FromResult("{\"sessions\":[]}");
            throw new BridgeException("未知路径") { StatusCode = 400 };
        }
    }

    /// A bridge serving one busy session whose `steer` capability is set by the test, so
    /// the send path can be exercised for a provider that does not accept steer.
    private sealed class StubSteerBridge : IBridgeTransport
    {
        private readonly bool _steer;
        public List<BridgeRequest> Requests { get; } = new();
        public StubSteerBridge(bool steer) => _steer = steer;

        public Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            switch (request.PathAndQuery)
            {
                case "/sessions":
                    return Task.FromResult("{\"sessions\":[{\"id\":\"ses-x\",\"provider\":\"codex\"," +
                        "\"title\":\"x\",\"cwd\":\"/tmp\",\"busy\":true,\"archived\":false,\"updated\":1," +
                        "\"revision\":0,\"completed\":0,\"model\":\"m\",\"error\":null,\"pending\":0," +
                        "\"turnId\":\"turn-1\",\"turnState\":\"running\",\"steer\":" +
                        (_steer ? "true" : "false") + "}]}");
                case "/sessions/ses-x?turns=25":
                    return Task.FromResult("{\"id\":\"ses-x\",\"provider\":\"codex\",\"title\":\"x\"," +
                        "\"cwd\":\"/tmp\",\"busy\":true,\"revision\":1,\"completed\":0,\"model\":\"m\"," +
                        "\"messages\":[],\"interactions\":[],\"error\":null,\"turnId\":\"turn-1\"," +
                        "\"turnState\":\"running\"}");
                default:
                    if (request.Method == "POST")
                        return Task.FromResult("{\"id\":\"r\",\"status\":\"accepted\"}");
                    throw new BridgeException("未知路径：" + request.PathAndQuery) { StatusCode = 400 };
            }
        }
    }
}

/// Wraps a FixtureBridge and holds every per-session snapshot GET until a gate opens, so
/// a test can switch selection (or disconnect) while a read is genuinely in flight and
/// assert the generation guard drops the late response.
public sealed class BlockingBridge : IBridgeTransport
{
    private readonly FixtureBridge _inner = new();
    private readonly Task _gate;

    public BlockingBridge(Task gate) => _gate = gate;

    public BlockingBridge WithSnapshot(string sessionPath, string fixture)
    {
        _inner.WithSnapshot(sessionPath, fixture);
        return this;
    }

    public List<BridgeRequest> Requests => _inner.Requests;

    public async Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken)
    {
        // Block only the selected-session snapshot read; the catalog read proceeds so the
        // poll reaches the point where the in-flight snapshot is outstanding.
        var isSessionSnapshot = request.Method == "GET" && request.PathAndQuery.StartsWith("/sessions/", StringComparison.Ordinal);
        if (isSessionSnapshot) await _gate.ConfigureAwait(false);
        return await _inner.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }
}
