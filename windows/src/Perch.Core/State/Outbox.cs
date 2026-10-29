using Perch.Core.Protocol;

namespace Perch.Core.State;

public enum OutboxState
{
    /// Queued locally, not yet sent.
    Draft,
    /// The initial prompt/steer POST is still in flight; no receipt poll is allowed yet.
    Sending,
    /// Sent; the bridge has the requestId but has not accepted it yet.
    Submitting,
    /// The bridge accepted the prompt/steer.
    Accepted,
    /// The runtime is running the turn this message belongs to.
    Running,
    /// Delivered: the message is visible in the transcript, or a terminal receipt confirms it.
    Delivered,
    /// The bridge refused it; the draft can be restored.
    Failed,
    /// Sent but the outcome is unknown (e.g. a reconnect); do not auto-resend.
    Unknown,
}

/// One message the user sent from this client. The bridge's transcript is the source of
/// truth once a message lands; the outbox tracks delivery *state* so a send that races
/// a reconnect is never silently replayed or duplicated.
public sealed record OutboxEntry(string RequestId, string SessionId, string Text, bool IsSteer)
{
    public OutboxState State { get; set; } = OutboxState.Draft;
    public string? Error { get; set; }
    public string? TurnId { get; set; }
}

/// Per-session outbox. Entries leave the outbox once their text is visible in the
/// transcript, so nothing is shown twice (local echo + bridge echo).
public sealed class Outbox
{
    private readonly Dictionary<string, OutboxEntry> _byRequest = new(StringComparer.Ordinal);
    private readonly List<string> _order = new();

    public IReadOnlyList<OutboxEntry> Entries => _order.Select(id => _byRequest[id]).ToList();

    public OutboxEntry Enqueue(string requestId, string sessionId, string text, bool isSteer)
    {
        if (_byRequest.ContainsKey(requestId))
            throw new PerchException("requestId 重复：" + requestId);
        var entry = new OutboxEntry(requestId, sessionId, text, isSteer);
        _byRequest[requestId] = entry;
        _order.Add(requestId);
        return entry;
    }

    public OutboxEntry? Find(string requestId) => _byRequest.TryGetValue(requestId, out var entry) ? entry : null;

    public void SetState(string requestId, OutboxState state, string? error = null, string? turnId = null)
    {
        var entry = Find(requestId) ?? throw new PerchException("未知的 requestId：" + requestId);
        entry.State = state;
        if (error is not null) entry.Error = error;
        if (turnId is not null) entry.TurnId = turnId;
    }

    /// Drops entries whose text is now visible in the transcript, by requestId. The
    /// bridge echoes a prompt under its requestId, so once that id appears we stop
    /// showing a separate local copy.
    public void ReconcileWithTranscript(IEnumerable<string> visibleMessageIds)
    {
        var visible = new HashSet<string>(visibleMessageIds, StringComparer.Ordinal);
        for (var i = _order.Count - 1; i >= 0; i--)
        {
            var id = _order[i];
            if (!visible.Contains(id)) continue;
            _order.RemoveAt(i);
            _byRequest.Remove(id);
        }
    }

    public void ClearSession(string sessionId)
    {
        for (var i = _order.Count - 1; i >= 0; i--)
        {
            var id = _order[i];
            if (_byRequest[id].SessionId != sessionId) continue;
            _order.RemoveAt(i);
            _byRequest.Remove(id);
        }
    }
}
