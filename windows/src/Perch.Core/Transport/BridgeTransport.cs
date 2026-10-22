using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Perch.Core.Protocol;
using Perch.Core.Secrets;

namespace Perch.Core.Transport;

/// One HTTP request/response against the bridge. Returns the raw body so callers can
/// decode into the route's own type; non-2xx becomes a BridgeException.
public interface IBridgeTransport
{
    Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken);
}

public sealed record BridgeRequest(string Method, string PathAndQuery, object? Body);

/// Talks to the loopback port the SSH tunnel exposes, always with the bearer token
/// from the provider (re-read per request so a reconnect picks up a new token).
public sealed class HttpBridgeTransport : IBridgeTransport, IDisposable
{
    private readonly HttpClient _client;
    private readonly Func<IBridgeTokenProvider?> _tokenProvider;
    private bool _disposed;

    public HttpBridgeTransport(string baseUrl, Func<IBridgeTokenProvider?> tokenProvider, TimeSpan? timeout = null)
    {
        _tokenProvider = tokenProvider;
        var handler = new SocketsHttpHandler
        {
            // The tunnel is loopback-only and short-lived; do not pool across a reconnect.
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
            AllowAutoRedirect = false,
        };
        _client = new HttpClient(handler)
        {
            BaseAddress = new Uri(baseUrl),
            Timeout = timeout ?? TimeSpan.FromSeconds(30),
        };
    }

    public async Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var provider = _tokenProvider() ?? throw new BridgeException("尚未连接到桥接服务。");
        // The provider owns the token's lifetime; read its value without disposing it.
        var token = await provider.GetTokenAsync(cancellationToken).ConfigureAwait(false);

        using var message = new HttpRequestMessage(new HttpMethod(request.Method), request.PathAndQuery);
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Value);
        message.Headers.UserAgent.ParseAdd("PerchWindows/0.1");
        message.Headers.Accept.ParseAdd("application/json");
        if (request.Body is not null)
        {
            var json = BridgeJson.Write(request.Body);
            message.Content = new StringContent(json, Encoding.UTF8, "application/json");
        }

        HttpResponseMessage response;
        try
        {
            response = await _client.SendAsync(message, HttpCompletionOption.ResponseContentRead, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            throw new BridgeException("无法访问远端桥接服务（隧道可能已断开）：" + ex.Message, ex);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            var status = (int)response.StatusCode;
            if (status == 401)
                throw new UnauthorizedException { StatusCode = status };
            if (status is < 200 or >= 300)
                throw new BridgeException(ExtractError(body, status)) { StatusCode = status };
            return body;
        }
    }

    internal static string ExtractError(string body, int status)
    {
        if (!string.IsNullOrWhiteSpace(body))
        {
            try
            {
                using var document = System.Text.Json.JsonDocument.Parse(body);
                if (document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object &&
                    document.RootElement.TryGetProperty("error", out var error) &&
                    error.ValueKind == System.Text.Json.JsonValueKind.String)
                {
                    var text = error.GetString();
                    if (!string.IsNullOrWhiteSpace(text)) return text!;
                }
            }
            catch (System.Text.Json.JsonException) { /* not JSON; fall through to the generic message */ }
        }
        return "HTTP " + status.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _client.Dispose();
    }
}

/// A transport backed by canned responses, for tests. Records every request so tests
/// can assert the exact path, method and body the client sent.
public sealed class FakeBridgeTransport : IBridgeTransport
{
    private readonly Func<BridgeRequest, string> _responder;
    public List<BridgeRequest> Requests { get; } = new();

    public FakeBridgeTransport(Func<BridgeRequest, string> responder) => _responder = responder;

    public Task<string> SendAsync(BridgeRequest request, CancellationToken cancellationToken)
    {
        Requests.Add(request);
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(_responder(request));
    }
}
