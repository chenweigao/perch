using System.IO;
using System.Security;
using System.Windows.Threading;
using Perch.App;
using Perch.Core;
using Perch.Core.Protocol;
using Perch.Core.Secrets;
using Perch.Core.Ssh;
using Perch.Core.State;
using Perch.Core.Transport;

namespace Perch.App.Tests;

// Runs the production ViewModel on a real WPF dispatcher. SSH and HTTP are
// controlled dependencies; these tests do not certify rendered UI or live SSH.
public sealed class MainViewModelTests
{
    [Fact]
    public void UserAndAssistantRowsShowTheirRoleHeaders()
    {
        var user = new MessageRow(new MessageBlock(BlockKind.UserPrompt, "user", "hello"));
        var assistant = new MessageRow(new MessageBlock(BlockKind.AssistantText, "assistant", "reply"));
        Assert.Equal("你", user.Header);
        Assert.Equal("Agent", assistant.Header);
        Assert.Equal(System.Windows.Visibility.Visible, user.HeaderVisibility);
        Assert.Equal(System.Windows.Visibility.Visible, assistant.HeaderVisibility);
    }

    [Fact]
    public Task SnapshotErrorIsShownToTheUser() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        scenario.Bridges[0].SnapshotError = "provider failed";

        await scenario.Coordinators[0].Controller!.PollOnceAsync(default);

        Assert.Equal("provider failed", view.ErrorText);
    });

    [Theory]
    [InlineData("next draft 中文")]
    [InlineData("original")]
    public Task AcceptedSendPreservesEditsMadeWhileWaiting(string replacement) => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        view.Composer = "original";
        var sending = view.SendAsync();
        await scenario.Bridges[0].SendEntered.Task;

        // Editing away and back to the same text is still a new draft.
        view.Composer = "edited";
        view.Composer = replacement;
        scenario.Bridges[0].SendResult.SetResult(Receipt);
        await sending;

        Assert.Equal(replacement, view.Composer);
        Assert.False(view.IsSending);
    });

    [Fact]
    public Task AcceptedSendClearsTheUnchangedDraft() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        view.Composer = "original";
        var sending = view.SendAsync();
        await scenario.Bridges[0].SendEntered.Task;
        scenario.Bridges[0].SendResult.SetResult(Receipt);
        await sending;
        Assert.Equal(string.Empty, view.Composer);
    });

    [Fact]
    public Task UnknownReceiptPreservesTheDraftAndSurfacesTheError() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        view.Composer = "original";
        var sending = view.SendAsync();
        await scenario.Bridges[0].SendEntered.Task;
        scenario.Bridges[0].SendResult.SetResult("""{"id":"fixture-request","status":"unknown","error":"runtime unavailable"}""");
        await sending;
        Assert.Equal("original", view.Composer);
        Assert.Equal("runtime unavailable", view.ErrorText);
    });

    [Fact]
    public Task RejectedSendPreservesTheDraft() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        view.Composer = "original";
        var sending = view.SendAsync();
        await scenario.Bridges[0].SendEntered.Task;
        scenario.Bridges[0].SendResult.SetException(new BridgeException("fixture rejection"));
        await sending;
        Assert.Equal("original", view.Composer);
        Assert.Equal("fixture rejection", view.ErrorText);
    });

    [Fact]
    public Task LateSendCannotClearAnotherSessionsComposer() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        view.Composer = "original";
        var sending = view.SendAsync();
        await scenario.Bridges[0].SendEntered.Task;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-approval");
        scenario.Bridges[0].SendResult.SetResult(Receipt);
        await sending;
        Assert.Equal("original", view.Composer);
    });

    [Fact]
    public Task DisconnectKeepsANewDraftAndDoesNotAbortTheRemoteTurn() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        view.Composer = "original";
        var sending = view.SendAsync();
        await scenario.Bridges[0].SendEntered.Task;
        await view.DisconnectAsync();
        view.Composer = "next draft";
        scenario.Bridges[0].SendResult.SetResult(Receipt);
        await sending;
        Assert.Equal("next draft", view.Composer);
        Assert.True(scenario.Processes[0].Killed);
        Assert.Equal(0, scenario.Bridges[0].AbortCalls);
    });

    [Fact]
    public Task FaultReconnectWaitsForOldPollingAndSshCleanup() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var oldBridge = scenario.Bridges[0];
        oldBridge.HoldNextCatalog = true;
        await oldBridge.CatalogEntered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        scenario.Coordinators[0].Controller!.MarkOffline("fixture fault");
        Assert.False(scenario.View.IsOnline);

        var reconnect = scenario.ConnectAsync();
        try
        {
            await oldBridge.CancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.False(reconnect.IsCompleted);
            Assert.Single(scenario.Processes);
        }
        finally
        {
            oldBridge.FinishCancellation.TrySetResult();
        }
        await reconnect;

        Assert.True(oldBridge.Disposed);
        Assert.True(scenario.Processes[0].Killed);
        Assert.False(scenario.Processes[1].Killed);
        Assert.True(scenario.View.IsOnline);
        Assert.Equal(0, oldBridge.AbortCalls);
        await scenario.View.DisconnectAsync();
        Assert.True(scenario.Processes.All(p => p.Killed));
        Assert.True(scenario.Bridges.All(b => b.Disposed));
    });

    [Fact]
    public Task CatalogRefreshRestoresSelectionWithABindingNotification() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        view.SelectedSession = view.Sessions.Single(s => s.Id == "ses-idle");
        var notifications = 0;
        view.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(view.SelectedSession)) notifications++;
        };
        view.Sessions.CollectionChanged += (_, args) =>
        {
            if (args.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Reset)
                view.SelectedSession = null;
        };

        view.OnCatalogChanged();

        Assert.Equal("ses-idle", view.SelectedSession?.Id);
        Assert.True(notifications > 0);
        Assert.True(view.Sessions.Single(s => s.Id == "ses-idle").IsSelected);
    });

    [Fact]
    public Task SecureTokenRemainsAvailableForRetryAfterDisconnect() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario();
        await scenario.ConnectAsync();
        var view = scenario.View;
        await view.DisconnectAsync();

        await view.ConnectAsync();

        Assert.True(view.IsOnline);
        Assert.Equal(2, scenario.Bridges.Count);
    });

    [Fact]
    public Task DisconnectCancelsAnInProgressConnection() => OnDispatcher(async () =>
    {
        await using var scenario = new Scenario(probeReady: false);
        var connecting = scenario.ConnectAsync();
        await scenario.ProcessStarted.Task;
        await scenario.View.DisconnectAsync();
        await connecting;
        Assert.False(scenario.View.IsOnline);
        Assert.False(scenario.View.IsConnecting);
        Assert.True(scenario.Processes[0].Killed);
    });

    private const string Receipt = """{"id":"fixture-request","status":"accepted","runtimeTurnId":"turn-1"}""";

    private static async Task OnDispatcher(Func<Task> body)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                try { await body(); done.TrySetResult(); }
                catch (Exception ex) { done.TrySetException(ex); }
                finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await done.Task.WaitAsync(TimeSpan.FromSeconds(30));
    }

    private sealed class Scenario : IAsyncDisposable
    {
        public MainViewModel View { get; }
        public List<TestBridge> Bridges { get; } = new();
        public List<TestProcess> Processes { get; } = new();
        public List<ConnectionCoordinator> Coordinators { get; } = new();
        public TaskCompletionSource ProcessStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Scenario(bool probeReady = true)
        {
            View = new MainViewModel(Dispatcher.CurrentDispatcher, provider =>
            {
                // Replacement cannot allocate resources until its predecessor has
                // disposed both the transport and the local process.
                if (Processes.Count > 0)
                {
                    Assert.True(Processes[^1].Killed);
                    Assert.True(Bridges[^1].Disposed);
                }
                var process = new TestProcess();
                var bridge = new TestBridge();
                Processes.Add(process);
                Bridges.Add(bridge);
                var coordinator = new ConnectionCoordinator(new TestLauncher(process, ProcessStarted),
                    new FixedPort(), provider, "ssh.exe", (_, _) => bridge);
                Coordinators.Add(coordinator);
                return coordinator;
            }, new NoFileAccess(), _ => Task.FromResult(probeReady))
            {
                Destination = "fixture-host",
                RemotePort = "41873",
                UseSecureInput = true,
            };
        }

        public Task ConnectAsync()
        {
            var token = new SecureString();
            foreach (var character in "fixture-token") token.AppendChar(character);
            View.SecureToken = token;
            return View.ConnectAsync();
        }

        public async ValueTask DisposeAsync()
        {
            foreach (var bridge in Bridges) bridge.FinishCancellation.TrySetResult();
            await View.DisconnectAsync();
            foreach (var coordinator in Coordinators) await coordinator.DisposeAsync();
        }
    }

    private sealed class TestBridge : IBridgeTransport, IDisposable
    {
        public bool HoldNextCatalog { get; set; }
        public bool Disposed { get; private set; }
        public int AbortCalls { get; private set; }
        public string? SnapshotError { get; set; }
        public TaskCompletionSource SendEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<string> SendResult { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource CatalogEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource CancellationObserved { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource FinishCancellation { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken)
        {
            if (request.PathAndQuery == "/health") return Fixture("health.json");
            if (request.PathAndQuery == "/sessions")
            {
                if (HoldNextCatalog)
                {
                    CatalogEntered.TrySetResult();
                    try { await Task.Delay(Timeout.Infinite, cancellationToken); }
                    catch (OperationCanceledException)
                    {
                        CancellationObserved.TrySetResult();
                        await FinishCancellation.Task;
                        throw;
                    }
                }
                return Fixture("sessions.json");
            }
            if (request.PathAndQuery.EndsWith("/prompt"))
            {
                SendEntered.TrySetResult();
                return await SendResult.Task.WaitAsync(cancellationToken);
            }
            if (request.PathAndQuery.EndsWith("/abort"))
            {
                AbortCalls++;
                return """{"ok":true}""";
            }
            if (SnapshotError is not null)
            {
                var snapshot = System.Text.Json.Nodes.JsonNode.Parse(Fixture("session-snapshot-idle.json"))!;
                snapshot["error"] = SnapshotError;
                return snapshot.ToJsonString();
            }
            return Fixture("session-snapshot-idle.json");
        }

        public void Dispose() => Disposed = true;
        private static string Fixture(string name) =>
            File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", name));
    }

    private sealed class FixedPort : ILocalPortAllocator
    {
        public int Allocate() => 51000; // The injected launcher never binds a socket.
    }

    private sealed class NoFileAccess : ITokenFilePermissionChecker
    {
        public TokenFilePermission Audit(string path) => throw new InvalidOperationException("No file token in this test.");
    }

    private sealed class TestLauncher(TestProcess process, TaskCompletionSource started) : ISshProcessLauncher
    {
        public ISshProcess Start(string executable, IReadOnlyList<string> arguments)
        {
            started.TrySetResult();
            return process;
        }
    }

    private sealed class TestProcess : ISshProcess
    {
        public bool Killed { get; private set; }
        public int Id => 42;
        public bool HasExited => Killed;
        public int ExitCode => 0;
        public Stream StandardOutput { get; } = new MemoryStream();
        public Stream StandardError { get; } = new MemoryStream();
        public void Kill() => Killed = true;
        public Task WaitForExitAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        public void Dispose() { }
    }
}
