using Perch.Core.Protocol;
using Perch.Core.Secrets;
using Perch.Core.Ssh;
using Perch.Core.State;

namespace Perch.Core.Tests;

/// End-to-end connection coordination with a fake ssh process and a stub bridge, so the
/// whole connect → health-gate → poll → disconnect path runs on Linux without Windows,
/// a network or credentials.
public class ConnectionCoordinatorTests
{
    private sealed class FixedPortAllocator : ILocalPortAllocator
    {
        private readonly int _port;
        public FixedPortAllocator(int port) => _port = port;
        public int Allocate() => _port;
    }

    private static IBridgeTokenProvider Token(string value) =>
        new SuppliedTokenProvider(BridgeToken.FromString(value));

    [Fact]
    public async Task ConnectStartsForwardAndGoesOnline()
    {
        var process = new FakeSshProcess();
        var launcher = new FakeLauncher(_ => process);
        var bridge = new StubBridge(version: BridgeProtocol.ServiceVersion);
        var coordinator = await StartAsync(launcher, bridge, new FixedPortAllocator(51000));

        Assert.Equal(ConnectionState.Online, coordinator.State);
        Assert.True(process.Killed is false);
        Assert.Contains(launcher.Starts, s => s.Arguments.Contains("127.0.0.1:51000:127.0.0.1:41873"));

        await coordinator.DisposeAsync();
        Assert.True(process.Killed); // disconnect killed the local forward
    }

    [Fact]
    public async Task ConnectRejectsAnOlderBridgeVersion()
    {
        var process = new FakeSshProcess();
        var launcher = new FakeLauncher(_ => process);
        var bridge = new StubBridge(version: BridgeProtocol.ServiceVersion - 1);

        var ex = await Assert.ThrowsAsync<TunnelException>(() => StartAsync(launcher, bridge, new FixedPortAllocator(51000)));
        Assert.Contains("需要 v", ex.Message);
        Assert.True(process.Killed); // no partial tunnel left behind
    }

    [Fact]
    public async Task ConnectRejectsANewerBridgeVersion()
    {
        var process = new FakeSshProcess();
        var launcher = new FakeLauncher(_ => process);
        var bridge = new StubBridge(version: BridgeProtocol.ServiceVersion + 1);

        var ex = await Assert.ThrowsAsync<TunnelException>(() => StartAsync(launcher, bridge, new FixedPortAllocator(51000)));
        Assert.Contains("请更新 Perch", ex.Message);
        Assert.True(process.Killed);
    }

    [Fact]
    public async Task ConnectSurfacesUnauthorizedToken()
    {
        var process = new FakeSshProcess();
        var launcher = new FakeLauncher(_ => process);
        var bridge = new StubBridge(version: BridgeProtocol.ServiceVersion, unauthorized: true);

        var ex = await Assert.ThrowsAsync<UnauthorizedException>(() => StartAsync(launcher, bridge, new FixedPortAllocator(51000)));
        Assert.Contains("凭证", ex.Message);
        Assert.True(process.Killed);
    }

    [Fact]
    public async Task DisconnectDoesNotAbortAnyRemoteTurn()
    {
        var process = new FakeSshProcess();
        var launcher = new FakeLauncher(_ => process);
        var bridge = new StubBridge(version: BridgeProtocol.ServiceVersion);
        var coordinator = await StartAsync(launcher, bridge, new FixedPortAllocator(51000));

        await coordinator.DisconnectAsync();

        // Disconnect releases only this client: the local ssh process is killed and no
        // abort/kill was sent to the bridge. The remote turn keeps running.
        Assert.True(process.Killed);
        Assert.Equal(0, bridge.AbortCalls);
        Assert.Equal(ConnectionState.Disconnected, coordinator.State);
    }

    [Fact]
    public async Task DisconnectIsIdempotent()
    {
        var process = new FakeSshProcess();
        var launcher = new FakeLauncher(_ => process);
        var bridge = new StubBridge(version: BridgeProtocol.ServiceVersion);
        var coordinator = await StartAsync(launcher, bridge, new FixedPortAllocator(51000));

        await coordinator.DisconnectAsync();
        await coordinator.DisconnectAsync(); // must not throw
        await coordinator.DisposeAsync();
    }

    private static async Task<ConnectionCoordinator> StartAsync(
        FakeLauncher launcher, StubBridge bridge, ILocalPortAllocator ports)
    {
        var coordinator = new ConnectionCoordinator(launcher, ports, Token("fixture-token"), "ssh.exe",
            (_, _) => bridge);
        await coordinator.ConnectAsync(new ConnectionConfig("dev-box", 41873), NullSessionObserver.Instance,
            _ => Task.FromResult(true), default);
        return coordinator;
    }

    /// A bridge stub serving health + catalog from fixtures, with an optional version or
    /// 401 override. Counts aborts so a test can prove disconnect does not cancel.
    public sealed class StubBridge : Transport.IBridgeTransport
    {
        private readonly int _version;
        private readonly bool _unauthorized;
        public int AbortCalls { get; private set; }

        public StubBridge(int version, bool unauthorized = false)
        {
            _version = version;
            _unauthorized = unauthorized;
        }

        public Task<string> SendAsync(Transport.BridgeRequest request, CancellationToken cancellationToken)
        {
            if (_unauthorized) throw new UnauthorizedException();
            if (request.PathAndQuery == "/health")
            {
                var health = Fixtures.Read<BridgeHealth>("health.json") with { Version = _version };
                return Task.FromResult(BridgeJson.Write(health));
            }
            if (request.PathAndQuery == "/sessions") return Task.FromResult(Fixtures.Raw("sessions.json"));
            if (request.PathAndQuery.EndsWith("/abort")) { AbortCalls++; return Task.FromResult("{\"ok\":true}"); }
            throw new BridgeException("未知路径") { StatusCode = 400 };
        }
    }
}
