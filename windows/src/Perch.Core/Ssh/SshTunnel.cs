using System.Diagnostics;
using System.Text;
using Perch.Core.Protocol;

namespace Perch.Core.Ssh;

/// A running ssh.exe child. Implemented over System.Diagnostics.Process on Windows
/// and over a fake in tests, so the tunnel lifecycle runs under `dotnet test`.
public interface ISshProcess : IDisposable
{
    int Id { get; }
    bool HasExited { get; }
    int ExitCode { get; }
    Stream StandardOutput { get; }
    Stream StandardError { get; }
    /// Terminates the local ssh client only. This never signals the remote bridge or
    /// any remote pane; disconnecting releases just this client's own connection.
    void Kill();
    Task WaitForExitAsync(CancellationToken cancellationToken);
}

/// Starts ssh.exe with structured argv. No argument list is ever passed through a
/// local shell, so spaces and Chinese in a path stay literal.
public interface ISshProcessLauncher
{
    ISshProcess Start(string executable, IReadOnlyList<string> arguments);
}

public sealed class DiagnosticsSshProcess : ISshProcess
{
    private readonly Process _process;
    public DiagnosticsSshProcess(Process process) => _process = process;
    public int Id => _process.Id;
    public bool HasExited => _process.HasExited;
    public int ExitCode => _process.ExitCode;
    public Stream StandardOutput => _process.StandardOutput.BaseStream;
    public Stream StandardError => _process.StandardError.BaseStream;

    public void Kill()
    {
        try
        {
            if (!_process.HasExited) _process.Kill(entireProcessTree: false);
        }
        catch (InvalidOperationException) { /* already gone */ }
        catch (System.ComponentModel.Win32Exception) { /* not permitted; the process is leaving anyway */ }
    }

    public Task WaitForExitAsync(CancellationToken cancellationToken) => _process.WaitForExitAsync(cancellationToken);

    public void Dispose() => _process.Dispose();
}

public sealed class DiagnosticsSshLauncher : ISshProcessLauncher
{
    public ISshProcess Start(string executable, IReadOnlyList<string> arguments)
    {
        var info = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true,
            StandardInputEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.Start();
        // An SSH forward must never read a terminal or block on the user; stdin is
        // closed immediately so ssh cannot wait for a password or passphrase prompt.
        process.StandardInput.Close();
        return new DiagnosticsSshProcess(process);
    }
}

/// Manages the loopback-only SSH forward for the lifetime of one connection.
///
/// This client connects to an already-running bridge using a port the user supplies
/// and a token loaded from secure input or a restricted-permission file. It never
/// installs, starts or restarts the remote service, and disconnecting kills only the
/// local ssh process — the remote bridge and any running agent turn keep going.
public sealed class SshTunnel : IAsyncDisposable
{
    private readonly ISshProcessLauncher _launcher;
    private readonly string _sshExecutable;
    private ISshProcess? _tunnelProcess;
    private bool _disposed;

    public SshTunnel(ISshProcessLauncher launcher, string sshExecutable)
    {
        _launcher = launcher;
        _sshExecutable = sshExecutable;
    }

    public bool IsForwardRunning => _tunnelProcess is { HasExited: false };

    /// Starts the loopback forward and waits until it accepts (or ssh exits). The
    /// forward binds 127.0.0.1 on both ends, so nothing on the LAN can reach the bridge.
    public async Task StartForwardAsync(string destination, int localPort, int remotePort,
        int readyTimeoutMs, Func<int, Task<bool>> probe, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_tunnelProcess is not null)
            throw new InvalidOperationException("已有活动的 SSH 转发。");

        var arguments = SshCommand.TunnelArguments(destination, localPort, remotePort);
        var process = _launcher.Start(_sshExecutable, arguments);
        _tunnelProcess = process;

        // Capture stderr for diagnostics while draining both pipes so a chatty ssh
        // cannot deadlock on a full pipe buffer.
        var stderr = new PipeCollector(process.StandardError);
        _ = stderr.RunAsync();
        _ = DrainAsync(process.StandardOutput);

        var deadline = Environment.TickCount64 + readyTimeoutMs;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (process.HasExited)
            {
                var detail = await stderr.TextAsync().ConfigureAwait(false);
                var exitCode = process.ExitCode;
                KillTunnel();
                throw new TunnelException(DescribeForwardFailure(exitCode, detail));
            }
            if (await probe(localPort).ConfigureAwait(false)) return;
            if (Environment.TickCount64 > deadline)
            {
                KillTunnel();
                throw new TunnelException("等待 SSH 转发就绪超时。");
            }
            await Task.Delay(50, cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task DrainAsync(Stream stream)
    {
        try
        {
            var buffer = new byte[4096];
            while (await stream.ReadAsync(buffer).ConfigureAwait(false) > 0) { /* discard */ }
        }
        catch { /* the tunnel is closing */ }
    }

    private static string DescribeForwardFailure(int exitCode, string stderr)
    {
        var hint = ClassifySshError(stderr);
        var message = string.IsNullOrWhiteSpace(stderr)
            ? "SSH 转发建立失败（ssh 退出码 " + exitCode + "）。"
            : "SSH 转发建立失败（ssh 退出码 " + exitCode + "）：" + FirstLines(stderr);
        return string.IsNullOrEmpty(hint) ? message : message + " " + hint;
    }

    internal static string ClassifySshError(string message)
    {
        var lower = message.ToLowerInvariant();
        if (lower.Contains("host key") || lower.Contains("host identification") || lower.Contains("known_hosts"))
            return "主机密钥校验未通过：请在终端确认指纹；若指纹已改变，先核实服务器身份，再更新 SSH 配置。Perch 不会自动接受未知主机。";
        if (lower.Contains("permission denied") || lower.Contains("authentication") || lower.Contains("publickey"))
            return "免交互登录失败：请在终端完成登录并把密钥加入 SSH agent。Perch 不保存密码。";
        if (lower.Contains("resolve hostname") || lower.Contains("name or service not known") || lower.Contains("nodename"))
            return "无法解析主机名：请检查 SSH 别名或 user@host；端口、用户名与跳板机可配置在 ~/.ssh/config。";
        if (lower.Contains("administratively prohibited") || lower.Contains("forwarding"))
            return "远端拒绝了本地转发：请确认 SSH 服务端允许 TCP 转发（AllowTcpForwarding）。";
        if (lower.Contains("connection timed out") || lower.Contains("connection refused"))
            return "网络不可达：请检查网络、VPN 与 SSH 配置。";
        return string.Empty;
    }

    private static string FirstLines(string message, int maxLines = 4)
    {
        var lines = message.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        return string.Join(' ', lines.Take(maxLines).Select(l => l.Trim())).Trim();
    }

    /// Releases only this client's connection: the local ssh forward process. The
    /// remote bridge and any running agent turn are untouched.
    public void KillTunnel()
    {
        var process = _tunnelProcess;
        _tunnelProcess = null;
        if (process is null) return;
        process.Kill();
        process.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        KillTunnel();
        await Task.CompletedTask;
    }

    /// Reads a stream to a bounded string in the background, so error text is available
    /// when ssh exits early without ever blocking the forward on a full pipe.
    private sealed class PipeCollector
    {
        private readonly Stream _stream;
        private readonly StringBuilder _builder = new();
        private readonly Task _task;

        public PipeCollector(Stream stream)
        {
            _stream = stream;
            _task = Task.Run(CollectAsync);
        }

        private async Task CollectAsync()
        {
            var buffer = new byte[4096];
            try
            {
                int read;
                while ((read = await _stream.ReadAsync(buffer).ConfigureAwait(false)) > 0)
                {
                    lock (_builder)
                    {
                        if (_builder.Length < 16384)
                            _builder.Append(Encoding.UTF8.GetString(buffer, 0, read));
                    }
                }
            }
            catch { /* the tunnel is closing */ }
        }

        public Task RunAsync() => _task;

        public async Task<string> TextAsync()
        {
            try { await _task.ConfigureAwait(false); } catch { /* best effort */ }
            lock (_builder) return _builder.ToString();
        }
    }
}
