using Perch.Core.Ssh;

namespace Perch.Core.Tests;

/// A fake ssh.exe child, so the forward lifecycle runs deterministically on any OS
/// without spawning a real process or touching a network.
public sealed class FakeSshProcess : ISshProcess
{
    private readonly MemoryStream _stdout = new();
    private readonly MemoryStream _stderr;
    public bool HasExited { get; private set; }
    public int ExitCode { get; private set; }
    public bool Killed { get; private set; }
    public int Id { get; } = Random.Shared.Next(1000, 9999);
    public Stream StandardOutput => _stdout;
    public Stream StandardError => _stderr;

    public FakeSshProcess(string stderr = "", bool exitImmediately = false, int exitCode = 255)
    {
        _stderr = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(stderr));
        if (exitImmediately) { HasExited = true; ExitCode = exitCode; }
    }

    public void Exit(int code)
    {
        HasExited = true;
        ExitCode = code;
    }

    public void Kill()
    {
        Killed = true;
        HasExited = true;
        ExitCode = 143;
    }

    public Task WaitForExitAsync(CancellationToken cancellationToken) =>
        HasExited ? Task.CompletedTask : Task.Delay(Timeout.Infinite, cancellationToken);

    public void Dispose() { }
}

/// Records the argv it was asked to run and hands back a scripted process.
public sealed class FakeLauncher : ISshProcessLauncher
{
    private readonly Func<IReadOnlyList<string>, ISshProcess> _factory;
    public List<(string Executable, IReadOnlyList<string> Arguments)> Starts { get; } = new();
    public FakeLauncher(Func<IReadOnlyList<string>, ISshProcess> factory) => _factory = factory;
    public ISshProcess Start(string executable, IReadOnlyList<string> arguments)
    {
        Starts.Add((executable, arguments));
        return _factory(arguments);
    }
}

/// The tunnel must start ssh with the exact loopback-only, batch-mode, strict-host-key
/// argv, treat a dead ssh as a failure with a helpful hint, and kill only the local
/// process on disconnect — never signaling the remote side.
public class SshTunnelTests
{
    [Fact]
    public async Task StartForwardLaunchesSshWithTheSafeArgv()
    {
        var process = new FakeSshProcess();
        var launcher = new FakeLauncher(_ => process);
        var tunnel = new SshTunnel(launcher, "ssh.exe");

        await tunnel.StartForwardAsync("dev-box", 51000, 41873, 2000, _ => Task.FromResult(true), default);

        var (executable, args) = Assert.Single(launcher.Starts);
        Assert.Equal("ssh.exe", executable);
        Assert.Contains("BatchMode=yes", args);
        Assert.Contains("StrictHostKeyChecking=yes", args);
        Assert.Contains("ExitOnForwardFailure=yes", args);
        Assert.Contains("127.0.0.1:51000:127.0.0.1:41873", args);
        Assert.Equal("dev-box", args[^1]);
        Assert.True(tunnel.IsForwardRunning);
        await tunnel.DisposeAsync();
    }

    [Fact]
    public async Task StartForwardWaitsUntilTheProbeAccepts()
    {
        var process = new FakeSshProcess();
        var tunnel = new SshTunnel(new FakeLauncher(_ => process), "ssh.exe");
        var attempts = 0;
        // Probe fails twice, then succeeds: the tunnel must poll, not give up early.
        await tunnel.StartForwardAsync("dev-box", 51000, 41873, 2000,
            _ => Task.FromResult(++attempts >= 3), default);
        Assert.True(attempts >= 3);
        Assert.False(process.Killed);
        await tunnel.DisposeAsync();
    }

    [Fact]
    public async Task SshThatExitsImmediatelyIsAFailureWithHostKeyHint()
    {
        var process = new FakeSshProcess(stderr: "Host key verification failed.", exitImmediately: true, exitCode: 255);
        var tunnel = new SshTunnel(new FakeLauncher(_ => process), "ssh.exe");
        var ex = await Assert.ThrowsAsync<TunnelException>(() =>
            tunnel.StartForwardAsync("dev-box", 51000, 41873, 2000, _ => Task.FromResult(false), default));
        Assert.Contains("主机密钥", ex.Message);
        Assert.Contains("不会自动接受未知主机", ex.Message);
    }

    [Fact]
    public async Task SshAuthFailureIsReportedWithoutSuggestingAPassword()
    {
        var process = new FakeSshProcess(stderr: "Permission denied (publickey).", exitImmediately: true, exitCode: 255);
        var tunnel = new SshTunnel(new FakeLauncher(_ => process), "ssh.exe");
        var ex = await Assert.ThrowsAsync<TunnelException>(() =>
            tunnel.StartForwardAsync("dev-box", 51000, 41873, 2000, _ => Task.FromResult(false), default));
        Assert.Contains("免交互登录失败", ex.Message);
        Assert.Contains("不保存密码", ex.Message);
    }

    [Fact]
    public async Task ForwardTimeoutKillsTheLocalProcess()
    {
        var process = new FakeSshProcess();
        var tunnel = new SshTunnel(new FakeLauncher(_ => process), "ssh.exe");
        await Assert.ThrowsAsync<TunnelException>(() =>
            tunnel.StartForwardAsync("dev-box", 51000, 41873, 200, _ => Task.FromResult(false), default));
        Assert.True(process.Killed);
    }

    [Fact]
    public async Task DisposeKillsOnlyTheLocalSshProcess()
    {
        var process = new FakeSshProcess();
        var tunnel = new SshTunnel(new FakeLauncher(_ => process), "ssh.exe");
        await tunnel.StartForwardAsync("dev-box", 51000, 41873, 2000, _ => Task.FromResult(true), default);
        Assert.False(process.Killed);

        await tunnel.DisposeAsync();

        // Disconnect releases this client's connection: the local ssh forward is killed.
        // Nothing here signals the remote bridge or agent.
        Assert.True(process.Killed);
        Assert.False(tunnel.IsForwardRunning);
    }

    [Fact]
    public async Task SecondForwardWhileOneIsLiveIsRejected()
    {
        var process = new FakeSshProcess();
        var tunnel = new SshTunnel(new FakeLauncher(_ => process), "ssh.exe");
        await tunnel.StartForwardAsync("dev-box", 51000, 41873, 2000, _ => Task.FromResult(true), default);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            tunnel.StartForwardAsync("dev-box", 51001, 41873, 2000, _ => Task.FromResult(true), default));
        await tunnel.DisposeAsync();
    }

    [Fact]
    public async Task CancellationStopsTheForwardWait()
    {
        var process = new FakeSshProcess();
        var tunnel = new SshTunnel(new FakeLauncher(_ => process), "ssh.exe");
        using var cts = new CancellationTokenSource();
        cts.CancelAfter(100);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            tunnel.StartForwardAsync("dev-box", 51000, 41873, 5000, _ => Task.FromResult(false), cts.Token));
        await tunnel.DisposeAsync();
    }
}
