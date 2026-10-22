using System.Globalization;
using System.Text;
using Perch.Core.Protocol;
using Perch.Core.Transport;

namespace Perch.Core.Bridge;

/// The routes of remote/native-agent-service.py this client uses. Every path segment
/// that carries a user-influenced value (session id) is percent-encoded so a space, a
/// Chinese character or a shell/URL metacharacter cannot break the URL or the remote
/// side. Only the six MVP capabilities are wired: health, catalog, snapshot, prompt,
/// steer and abort — no models/setup/requests routes this client does not call.
public static class BridgeRoutes
{
    public const string Health = "/health";
    public const string Sessions = "/sessions";

    public static string Session(string id) => "/sessions/" + UrlEncode(id);

    /// A snapshot read. `revision` asks for a delta, `start`/`epoch` pin the history
    /// window, `turns` pages it.
    public static string SessionSnapshot(string id, int? revision = null, int? start = null,
        string? epoch = null, int? turns = null)
    {
        var query = new List<string>();
        if (revision is not null) query.Add("revision=" + revision.Value.ToString(CultureInfo.InvariantCulture));
        if (start is not null) query.Add("start=" + start.Value.ToString(CultureInfo.InvariantCulture));
        if (!string.IsNullOrEmpty(epoch)) query.Add("epoch=" + UrlEncode(epoch));
        if (turns is not null) query.Add("turns=" + turns.Value.ToString(CultureInfo.InvariantCulture));
        var path = Session(id);
        return query.Count == 0 ? path : path + "?" + string.Join('&', query);
    }

    public static string Action(string id, string action) =>
        "/sessions/" + UrlEncode(id) + "/" + UrlEncode(action);

    /// Percent-encode everything that is not unreserved, matching what the bridge's
    /// urlparse/unquote expects. Spaces become %20, not '+'.
    public static string UrlEncode(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            var c = (char)b;
            if (c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_' or '.' or '~')
                builder.Append(c);
            else
                builder.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return builder.ToString();
    }
}

/// Typed calls over the transport. This is the only place that knows the bridge's
/// HTTP surface; the state machine above it deals in decoded records.
public sealed class BridgeClient
{
    private readonly IBridgeTransport _transport;
    public BridgeClient(IBridgeTransport transport) => _transport = transport;

    public async Task<BridgeHealth> HealthAsync(CancellationToken cancellationToken = default)
    {
        var body = await _transport.SendAsync(new BridgeRequest("GET", BridgeRoutes.Health, null), cancellationToken)
            .ConfigureAwait(false);
        return BridgeJson.Read<BridgeHealth>(body);
    }

    public async Task<IReadOnlyList<SessionSummary>> SessionsAsync(CancellationToken cancellationToken = default)
    {
        var body = await _transport.SendAsync(new BridgeRequest("GET", BridgeRoutes.Sessions, null), cancellationToken)
            .ConfigureAwait(false);
        return BridgeJson.Read<SessionCatalog>(body).Sessions;
    }

    public async Task<SnapshotResponse> SnapshotAsync(string id, SnapshotQuery query, CancellationToken cancellationToken = default)
    {
        var path = BridgeRoutes.SessionSnapshot(id, query.Revision, query.Start, query.Epoch, query.Turns);
        var body = await _transport.SendAsync(new BridgeRequest("GET", path, null), cancellationToken).ConfigureAwait(false);
        return SnapshotResponse.Parse(body);
    }

    public async Task<RequestReceipt> PromptAsync(string id, string requestId, string text, CancellationToken cancellationToken = default)
        => await PostReceiptAsync(id, "prompt", new { requestId, text }, cancellationToken).ConfigureAwait(false);

    public async Task<RequestReceipt> SteerAsync(string id, string requestId, string text, CancellationToken cancellationToken = default)
        => await PostReceiptAsync(id, "steer", new { requestId, text }, cancellationToken).ConfigureAwait(false);

    /// Cancels the current turn only. `turnId` must match the live turn or the bridge
    /// refuses with "轮次已变化"; this is distinct from disconnecting.
    public async Task AbortAsync(string id, string turnId, CancellationToken cancellationToken = default)
    {
        var body = await _transport.SendAsync(
            new BridgeRequest("POST", BridgeRoutes.Action(id, "abort"), new { turnId }), cancellationToken)
            .ConfigureAwait(false);
        BridgeJson.Read<OkResult>(body);
    }

    private async Task<RequestReceipt> PostReceiptAsync(string id, string action, object body, CancellationToken cancellationToken)
    {
        var json = await _transport.SendAsync(new BridgeRequest("POST", BridgeRoutes.Action(id, action), body), cancellationToken)
            .ConfigureAwait(false);
        return BridgeJson.Read<RequestReceipt>(json);
    }

    private sealed record OkResult();
}

/// The snapshot query for one poll. Mirrors the macOS client's suffix logic.
public sealed record SnapshotQuery(int? Revision = null, int? Start = null, string? Epoch = null, int? Turns = null)
{
    /// First read of a selection: a paged snapshot that establishes the window.
    public static SnapshotQuery FirstPage(int turns = 25) => new(Turns: turns);

    /// Delta read pinned to the window the client already holds.
    public static SnapshotQuery Delta(int revision, int start, string epoch) => new(Revision: revision, Start: start, Epoch: epoch);
}


/// A snapshot response is either `{"unchanged":true}` or a full/delta snapshot.
public sealed record SnapshotResponse(bool Unchanged, BridgeSnapshot? Snapshot)
{
    public static SnapshotResponse Parse(string body)
    {
        if (SnapshotUnchanged.IsUnchanged(body)) return new SnapshotResponse(true, null);
        return new SnapshotResponse(false, BridgeJson.Read<BridgeSnapshot>(body));
    }

    private static class SnapshotUnchanged
    {
        public static bool IsUnchanged(string body)
        {
            try
            {
                using var document = System.Text.Json.JsonDocument.Parse(body);
                return document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object &&
                       document.RootElement.TryGetProperty("unchanged", out var flag) &&
                       flag.ValueKind == System.Text.Json.JsonValueKind.True;
            }
            catch (System.Text.Json.JsonException)
            {
                return false;
            }
        }
    }
}
