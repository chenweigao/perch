using Perch.Core.Bridge;
using Perch.Core.Protocol;
using Perch.Core.Secrets;
using Perch.Core.Ssh;
using Perch.Core.State;
using Perch.Core.Transport;

namespace Perch.Core;

/// Allocates a free loopback port for the tunnel's local bind.
public interface ILocalPortAllocator
{
    int Allocate();
}

/// Orchestrates one end-to-end connection: SSH handshake → verify bridge health →
/// start the loopback forward → build the transport → hand a live SessionController to
/// the caller and run its poll loop.
///
/// Disconnect releases only this client: it stops the poll loop, closes the transport
/// and kills the local ssh forward. It never signals the remote bridge or agent, so a
/// running turn keeps going on the host (the same contract the macOS client honors).
public sealed class ConnectionCoordinator : IAsyncDisposable
{
    private readonly ISshProcessLauncher _launcher;
    private readonly ILocalPortAllocator _ports;
    private readonly IBridgeTokenProvider _tokenProvider;
    private readonly string _sshExecutable;
    private readonly Func<string, IBridgeTokenProvider, IBridgeTransport> _transportFactory;

    private SshTunnel? _tunnel;
    private IBridgeTransport? _transport;
    private SessionController? _controller;
    private CancellationTokenSource? _loopCancellation;
    private Task? _loop;
    private bool _disposed;

    public ConnectionCoordinator(
        ISshProcessLauncher launcher,
        ILocalPortAllocator ports,
        IBridgeTokenProvider tokenProvider,
        string sshExecutable,
        Func<string, IBridgeTokenProvider, IBridgeTransport>? transportFactory = null)
    {
        _launcher = launcher;
        _ports = ports;
        _tokenProvider = tokenProvider;
        _sshExecutable = sshExecutable;
        // Defaults to the real loopback HTTP transport; tests inject a stub.
        _transportFactory = transportFactory ??
            ((baseUrl, provider) => new HttpBridgeTransport(baseUrl, () => provider));
    }

    public SessionController? Controller => _controller;
    public ConnectionState State => _controller?.ConnectionState ?? ConnectionState.Disconnected;

    /// Connects to an already-running remote bridge and verifies it speaks the protocol
    /// version this build expects. The user supplies the destination and the bridge's
    /// loopback port; the token comes from the injected provider. `probe` reports
    /// whether the local forward is accepting; tests pass a stub, the app passes a real
    /// TCP connect. Throws on any failure, leaving no partial tunnel.
    ///
    /// This never installs or starts the remote service — connecting to a bridge that
    /// is not already running surfaces as a forward/health failure for the user.
    public async Task<SessionController> ConnectAsync(
        ConnectionConfig config,
        ISessionObserver observer,
        Func<int, Task<bool>> probe,
        CancellationToken cancellationToken)
    {
        config.Validate();
        await DisconnectAsync().ConfigureAwait(false);

        var tunnel = new SshTunnel(_launcher, _sshExecutable);
        _tunnel = tunnel;
        try
        {
            var localPort = _ports.Allocate();
            await tunnel.StartForwardAsync(config.Destination, localPort, config.RemotePort,
                config.ForwardReadyTimeoutMs, probe, cancellationToken).ConfigureAwait(false);

            var transport = _transportFactory(SshCommand.LocalBaseUrl(localPort), _tokenProvider);
            _transport = transport;

            var client = new BridgeClient(transport);
            var health = await client.HealthAsync(cancellationToken).ConfigureAwait(false);
            if (health.Version != BridgeProtocol.ServiceVersion)
                throw new TunnelException(health.Version < BridgeProtocol.ServiceVersion
                    ? $"远端桥接服务是 v{health.Version}，此客户端需要 v{BridgeProtocol.ServiceVersion}。请更新远端桥接组件。"
                    : $"远端桥接服务是 v{health.Version}，比此客户端预期的 v{BridgeProtocol.ServiceVersion} 新。请更新 Perch。");

            var controller = new SessionController(client, observer)
            {
                PollIntervalMs = config.PollIntervalMs,
                IdlePollIntervalMs = config.IdlePollIntervalMs,
            };
            controller.BeginOnlineSession();
            _controller = controller;

            _loopCancellation = new CancellationTokenSource();
            _loop = controller.RunPollLoopAsync(_loopCancellation.Token);
            return controller;
        }
        catch
        {
            await DisconnectAsync().ConfigureAwait(false);
            throw;
        }
    }

    /// Releases this client's connection. Idempotent and safe to call when never
    /// connected. Never touches the remote side.
    public async Task DisconnectAsync()
    {
        if (_loopCancellation is not null)
        {
            _loopCancellation.Cancel();
            var loop = _loop;
            _loop = null;
            if (loop is not null)
            {
                try { await loop.ConfigureAwait(false); } catch { /* stopping */ }
            }
            _loopCancellation.Dispose();
            _loopCancellation = null;
        }
        _controller?.MarkOffline();
        _controller = null;
        // The real transport is disposable (it owns an HttpClient); a test stub may not be.
        (_transport as IDisposable)?.Dispose();
        _transport = null;
        if (_tunnel is not null)
        {
            await _tunnel.DisposeAsync().ConfigureAwait(false);
            _tunnel = null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await DisconnectAsync().ConfigureAwait(false);
    }
}

/// Allocates a free loopback port by binding and immediately releasing an ephemeral
/// socket. ssh re-binds it for the forward; a brief race is acceptable for an MVP and
/// matches the macOS client's approach.
public sealed class EphemeralLoopbackPortAllocator : ILocalPortAllocator
{
    public int Allocate()
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
