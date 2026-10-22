using Perch.Core.Bridge;
using Perch.Core.Protocol;

namespace Perch.Core.State;

public enum ConnectionState
{
    Disconnected,
    Connecting,
    Online,
    Faulted,
}

/// Raised on any change the UI should reflect. The controller mutates state on the
/// caller's thread; the WPF layer marshals these to the dispatcher.
public interface ISessionObserver
{
    void OnConnectionStateChanged();
    void OnCatalogChanged();
    void OnSelectionChanged();
    void OnTranscriptChanged();
    void OnOutboxChanged();
    void OnError(string message);
}

/// A no-op observer, so the controller is usable from tests without a UI.
public sealed class NullSessionObserver : ISessionObserver
{
    public static readonly NullSessionObserver Instance = new();
    public void OnConnectionStateChanged() { }
    public void OnCatalogChanged() { }
    public void OnSelectionChanged() { }
    public void OnTranscriptChanged() { }
    public void OnOutboxChanged() { }
    public void OnError(string message) { }
}

/// Connection configuration validated before any SSH process starts. The local
/// forward port is allocated per connection by the coordinator, not fixed by the user:
/// the user supplies the SSH alias and the *remote* bridge loopback port.
public sealed record ConnectionConfig(
    string Destination,
    int RemotePort,
    int ForwardReadyTimeoutMs = 15000,
    int PollIntervalMs = 1500,
    int IdlePollIntervalMs = 4000)
{
    public void Validate()
    {
        Ssh.SshCommand.ValidateDestination(Destination);
        Ssh.SshCommand.ValidatePort(RemotePort, "远端桥接端口");
    }
}

/// Owns one connection to one remote bridge and the currently selected session.
///
/// Correctness rules this class enforces (all covered by tests against real fixtures):
///   * a connection generation token: a poll that returns after a reconnect or
///     disconnect is discarded, never applied;
///   * a selection generation token: a snapshot for a previously selected session
///     cannot overwrite the newly selected one;
///   * transcript merges by index, so repeated polls never re-append the growing reply;
///   * cancel (abort the live turn) and disconnect (release only this client) are
///     separate operations with separate effects.
public sealed class SessionController
{
    private readonly BridgeClient _client;
    private readonly ISessionObserver _observer;
    private readonly Outbox _outbox = new();

    private long _connectionGeneration;
    private long _selectionGeneration;

    public SessionController(BridgeClient client, ISessionObserver? observer = null)
    {
        _client = client;
        _observer = observer ?? NullSessionObserver.Instance;
    }

    public ConnectionState ConnectionState { get; private set; } = ConnectionState.Disconnected;
    public string? ConnectionError { get; private set; }
    public IReadOnlyList<SessionSummary> Sessions { get; private set; } = Array.Empty<SessionSummary>();
    public string? SelectedId { get; private set; }
    public Transcript? Transcript { get; private set; }
    public BridgeSnapshot? Snapshot { get; private set; }
    public Outbox Outbox => _outbox;

    /// Pending approvals/questions of the selected session. The MVP displays these and
    /// never answers them; answering stays with the terminal until a later release.
    public IReadOnlyList<BridgeInteraction> PendingInteractions =>
        Snapshot?.InteractionsOrEmpty ?? Array.Empty<BridgeInteraction>();

    public bool IsOnline => ConnectionState == ConnectionState.Online;
    public SessionSummary? SelectedSession => SelectedId is { } id ? Sessions.FirstOrDefault(s => s.Id == id) : null;

    /// Marks this controller online at a fixed generation. The SSH/HTTP wiring lives in
    /// the app layer; tests and the connection coordinator call this once the tunnel is
    /// confirmed healthy, then drive PollOnceAsync().
    public void BeginOnlineSession()
    {
        Interlocked.Increment(ref _connectionGeneration);
        ConnectionState = ConnectionState.Online;
        ConnectionError = null;
        _observer.OnConnectionStateChanged();
    }

    /// One catalog + selected-snapshot refresh. Returns false when a newer generation
    /// superseded this call mid-flight, so the caller stops the loop.
    public async Task<bool> PollOnceAsync(CancellationToken cancellationToken)
    {
        var connectionToken = _connectionGeneration;
        var selectionToken = _selectionGeneration;

        await RefreshCatalogAsync(connectionToken, cancellationToken).ConfigureAwait(false);
        if (connectionToken != _connectionGeneration) return false;

        if (SelectedId is { } id)
        {
            var applied = await RefreshSelectedAsync(id, connectionToken, selectionToken, cancellationToken)
                .ConfigureAwait(false);
            if (connectionToken != _connectionGeneration) return false;
            if (applied)
            {
                ReconcileOutbox();
                _observer.OnTranscriptChanged();
            }
        }
        return true;
    }

    private async Task RefreshCatalogAsync(long connectionToken, CancellationToken cancellationToken)
    {
        var sessions = await _client.SessionsAsync(cancellationToken).ConfigureAwait(false);
        if (connectionToken != _connectionGeneration) return;
        // Newest first, matching the sidebar the macOS client shows.
        var ordered = sessions.OrderByDescending(s => s.Updated).ThenBy(s => s.Id, StringComparer.Ordinal).ToList();
        var changed = !SequenceEqual(ordered, Sessions);
        Sessions = ordered;
        // A selection that vanished (deleted remotely) is cleared rather than left stale.
        if (SelectedId is { } id && ordered.All(s => s.Id != id))
        {
            SelectedId = null;
            Transcript = null;
            Snapshot = null;
            Interlocked.Increment(ref _selectionGeneration);
            _observer.OnSelectionChanged();
        }
        if (changed) _observer.OnCatalogChanged();
    }

    private static bool SequenceEqual(IReadOnlyList<SessionSummary> a, IReadOnlyList<SessionSummary> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
            if (a[i].Id != b[i].Id || a[i].Revision != b[i].Revision || a[i].Busy != b[i].Busy ||
                a[i].Pending != b[i].Pending || a[i].Updated != b[i].Updated || a[i].Error != b[i].Error)
                return false;
        return true;
    }

    private async Task<bool> RefreshSelectedAsync(string id, long connectionToken, long selectionToken,
        CancellationToken cancellationToken)
    {
        // A first read of a selection is paged, establishing the history window. Later
        // reads are deltas pinned to that window and the revision we hold.
        SnapshotQuery query = Transcript is { Epoch: { } epoch } && Snapshot?.Id == id
            ? SnapshotQuery.Delta((int)Transcript.Revision, Transcript.Start, epoch)
            : SnapshotQuery.FirstPage();

        var response = await _client.SnapshotAsync(id, query, cancellationToken).ConfigureAwait(false);
        if (connectionToken != _connectionGeneration || selectionToken != _selectionGeneration || id != SelectedId)
            return false;

        if (response.Unchanged) return false;

        var snapshot = response.Snapshot!;
        if (snapshot.Id != id) return false;
        Snapshot = snapshot;

        if (Transcript is null || Transcript.SessionId != id)
        {
            Transcript = Transcript.FromFull(snapshot);
            return true;
        }
        if (Transcript.TryApplyDelta(snapshot, out var needsFullRead)) return true;
        if (!needsFullRead)
        {
            Transcript = Transcript.FromFull(snapshot);
            return true;
        }
        // The window moved or the epoch changed while the delta was in flight: re-read
        // the first page and replace, so no position is duplicated or dropped.
        var full = await _client.SnapshotAsync(id, SnapshotQuery.FirstPage(), cancellationToken).ConfigureAwait(false);
        if (connectionToken != _connectionGeneration || selectionToken != _selectionGeneration || id != SelectedId)
            return false;
        if (full.Unchanged || full.Snapshot is null) return false;
        Snapshot = full.Snapshot;
        Transcript = Transcript.FromFull(full.Snapshot);
        return true;
    }

    /// Selects a session. Clears the previous transcript and bumps the selection
    /// generation so an in-flight poll for the old session is discarded.
    public void Select(string? id)
    {
        if (SelectedId == id) return;
        Interlocked.Increment(ref _selectionGeneration);
        SelectedId = id;
        Transcript = null;
        Snapshot = null;
        _observer.OnSelectionChanged();
    }

    /// Sends a message to the selected session: a prompt when idle, a steer when a turn
    /// is running (Codex supports running guidance). Returns the request id.
    public async Task<string> SendAsync(string text, CancellationToken cancellationToken)
    {
        if (!IsOnline) throw new PerchException("尚未连接到桥接服务。");
        var id = SelectedId ?? throw new PerchException("请先选择一个会话。");
        if (string.IsNullOrWhiteSpace(text)) throw new PerchException("消息不能为空。");

        var session = SelectedSession;
        // Steer only when a turn is live AND the session declares running guidance
        // (summary().steer — true for codex/omp). Otherwise send as a prompt; the bridge
        // refuses a prompt into a busy turn, and that refusal surfaces to the user.
        var busy = session?.Busy == true || Snapshot?.Busy == true;
        var useSteer = busy && session?.Steer == true;
        var requestId = NewRequestId();
        var entry = _outbox.Enqueue(requestId, id, text, useSteer);
        entry.State = OutboxState.Submitting;
        _observer.OnOutboxChanged();

        var connectionToken = _connectionGeneration;
        var selectionToken = _selectionGeneration;
        RequestReceipt receipt;
        try
        {
            receipt = useSteer
                ? await _client.SteerAsync(id, requestId, text, cancellationToken).ConfigureAwait(false)
                : await _client.PromptAsync(id, requestId, text, cancellationToken).ConfigureAwait(false);
        }
        catch (BridgeException ex)
        {
            if (connectionToken == _connectionGeneration && selectionToken == _selectionGeneration)
            {
                _outbox.SetState(requestId, OutboxState.Failed, ex.Message);
                _observer.OnOutboxChanged();
            }
            throw;
        }

        if (connectionToken != _connectionGeneration || selectionToken != _selectionGeneration)
            return requestId; // superseded; the outbox entry stays and settles on reconnect

        ApplyReceipt(entry, receipt);
        _observer.OnOutboxChanged();
        return requestId;
    }

    private void ApplyReceipt(OutboxEntry entry, RequestReceipt receipt)
    {
        entry.TurnId = receipt.ActiveTurnId;
        entry.State = receipt.Status switch
        {
            "submitting" or "submitted" => OutboxState.Submitting,
            "accepted" => OutboxState.Accepted,
            "running" => OutboxState.Running,
            "consumed" => OutboxState.Delivered,
            "completed" or "stopped" => OutboxState.Delivered,
            "failed" => OutboxState.Failed,
            "notFound" => OutboxState.Failed,
            _ => OutboxState.Unknown,
        };
        if (entry.State is OutboxState.Failed or OutboxState.Unknown)
            entry.Error = receipt.Error ?? (entry.State == OutboxState.Failed ? "运行时拒绝消息" : "结果未知，请同步后核对，勿重复提交");
    }

    private void ReconcileOutbox()
    {
        var transcript = Transcript;
        if (transcript is null) return;
        var visible = transcript.Messages.Select(m => m.Id);
        _outbox.ReconcileWithTranscript(visible);
        // A settled turn also settles any in-flight sends for it.
        foreach (var entry in _outbox.Entries)
        {
            if (entry.SessionId != SelectedId) continue;
            if (entry.State is OutboxState.Delivered or OutboxState.Failed) continue;
            if (Snapshot is { Busy: false } && entry.TurnId is not null && Snapshot.TurnId == entry.TurnId)
                entry.State = OutboxState.Delivered;
        }
    }

    /// Cancels the current turn only. Distinct from disconnect: the bridge and the
    /// remote agent keep running; this asks the runtime to interrupt the live turn.
    public async Task CancelTurnAsync(CancellationToken cancellationToken)
    {
        if (!IsOnline) throw new PerchException("尚未连接到桥接服务。");
        var id = SelectedId ?? throw new PerchException("请先选择一个会话。");
        var turnId = Snapshot?.TurnId ?? SelectedSession?.TurnId;
        if (string.IsNullOrEmpty(turnId))
            throw new PerchException("当前没有进行中的回合可取消。");
        try
        {
            await _client.AbortAsync(id, turnId, cancellationToken).ConfigureAwait(false);
        }
        catch (BridgeException ex)
        {
            // "轮次已变化" means the turn already moved on; surface it, do not retry.
            _observer.OnError(ex.Message);
            throw;
        }
    }

    /// Releases only this client: stops the poll loop and clears local state. It does
    /// NOT touch the remote bridge, the SSH tunnel process, or any running agent turn —
    /// those are handled by the connection coordinator that owns the tunnel.
    public void MarkOffline(string? error = null)
    {
        Interlocked.Increment(ref _connectionGeneration);
        ConnectionState = error is null ? ConnectionState.Disconnected : ConnectionState.Faulted;
        ConnectionError = error;
        _observer.OnConnectionStateChanged();
    }

    /// Drives PollOnceAsync on a timer until cancelled or the connection generation
    /// changes. A transient error reports and backs off; it does not tear down state.
    public async Task RunPollLoopAsync(CancellationToken cancellationToken)
    {
        var connectionToken = _connectionGeneration;
        while (!cancellationToken.IsCancellationRequested && connectionToken == _connectionGeneration)
        {
            // True unless a poll reports this generation was superseded, which stops
            // the loop. A transient error leaves it true so we back off and retry.
            var shouldContinue = true;
            try
            {
                shouldContinue = await PollOnceAsync(cancellationToken).ConfigureAwait(false);
                if (ConnectionState == ConnectionState.Faulted && ConnectionError is not null)
                {
                    ConnectionState = ConnectionState.Online;
                    ConnectionError = null;
                    _observer.OnConnectionStateChanged();
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (UnauthorizedException ex)
            {
                // The token was rejected; retrying cannot help. Stop and report.
                if (connectionToken != _connectionGeneration) return;
                MarkOffline(ex.Message);
                return;
            }
            catch (Exception ex) when (ex is BridgeException or PerchException)
            {
                if (connectionToken != _connectionGeneration) return;
                ConnectionState = ConnectionState.Faulted;
                ConnectionError = ex.Message;
                _observer.OnConnectionStateChanged();
                _observer.OnError(ex.Message);
            }

            if (!shouldContinue || connectionToken != _connectionGeneration) return;

            var interval = NeedsFastTick() ? PollIntervalMs : IdlePollIntervalMs;
            try
            {
                await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// The poll cadence knobs, set by the coordinator from the connection config.
    public int PollIntervalMs { get; set; } = 1500;
    public int IdlePollIntervalMs { get; set; } = 4000;

    private bool NeedsFastTick()
    {
        if (Sessions.Any(s => s.Busy)) return true;
        if (Snapshot?.Busy == true) return true;
        if (PendingInteractions.Count > 0) return true;
        return _outbox.Entries.Any(e => e.State is OutboxState.Submitting or OutboxState.Accepted or OutboxState.Running or OutboxState.Unknown);
    }

    private static string NewRequestId() => "req-" + Guid.NewGuid().ToString("N");
}
