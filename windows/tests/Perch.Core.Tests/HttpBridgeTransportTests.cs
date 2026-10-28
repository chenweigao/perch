using System.Net;
using System.Net.Sockets;
using Perch.Core.Secrets;
using Perch.Core.Transport;

namespace Perch.Core.Tests;

public class HttpBridgeTransportTests
{
    [Fact]
    public async Task HttpTimeoutBecomesARecoverableBridgeFailure()
    {
        var portProbe = new TcpListener(IPAddress.Loopback, 0);
        portProbe.Start();
        var port = ((IPEndPoint)portProbe.LocalEndpoint).Port;
        portProbe.Stop();

        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        try
        {
            using var token = BridgeToken.FromString("fixture-token");
            using var transport = new HttpBridgeTransport($"http://127.0.0.1:{port}/",
                () => new SuppliedTokenProvider(token), TimeSpan.FromSeconds(1));
            var request = listener.GetContextAsync();
            var send = transport.SendAsync(new BridgeRequest("GET", "/health", null), default);
            var context = await request.WaitAsync(TimeSpan.FromSeconds(5));

            var ex = await Assert.ThrowsAsync<BridgeException>(() => send);

            Assert.Contains("超时", ex.Message);
            context.Response.Abort();
        }
        finally
        {
            listener.Stop();
        }
    }
}
