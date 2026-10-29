using System.Globalization;
using System.Text;

namespace Perch.Core.Ssh;

/// Builds the argv for the system OpenSSH client. Everything is a structured
/// argument: no value ever reaches a local shell, and the one remote command is
/// quoted word by word for the remote shell.
///
/// Safety rules this file enforces, mirroring the macOS client:
///   * BatchMode=yes — never prompts for a password, never stores one.
///   * StrictHostKeyChecking=yes — an unknown or changed host key fails the connect.
///   * ExitOnForwardFailure=yes — a refused local bind exits instead of half-connecting.
///   * the local bind is always 127.0.0.1 — the tunnel is never exposed to the LAN.
///   * no ControlMaster, no -tt, no remote command other than the bridge handshake,
///     so this client cannot take over or terminate a remote session.
public static class SshCommand
{
    /// Quoting for one word of a remote POSIX shell command. The MVP sends no remote
    /// command (message text travels as HTTP JSON, never through a shell), but this is
    /// the single place a remote command would be built, and it is tested so a future
    /// caller cannot accidentally interpolate user text into a shell.
    public static string PosixQuote(string value)
    {
        if (value.Length == 0) return "''";
        var needs = false;
        foreach (var c in value)
        {
            if (!IsSafeUnquoted(c)) { needs = true; break; }
        }
        if (!needs) return value;
        var builder = new StringBuilder(value.Length + 2);
        builder.Append('\'');
        foreach (var c in value)
        {
            if (c == '\'') builder.Append("'\"'\"'");
            else builder.Append(c);
        }
        builder.Append('\'');
        return builder.ToString();
    }

    private static bool IsSafeUnquoted(char c) =>
        c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '_' or '/' or '.' or ',' or ':' or '+' or '=' or '@' or '%' or '-';

    /// An SSH config alias or user@host. Ports, identities and jump hosts belong in
    /// ~/.ssh/config, which is what keeps this argument list short and predictable.
    public static void ValidateDestination(string destination)
    {
        if (string.IsNullOrEmpty(destination))
            throw new PerchException("请输入 SSH 配置别名或 user@host；端口和跳板机请配置在 ~/.ssh/config 中。");
        if (destination[0] == '-')
            throw new PerchException("SSH 目标不能以 - 开头，否则会被当成 ssh 的参数。");
        foreach (var c in destination)
        {
            if (char.IsWhiteSpace(c) || c == '\0' || char.IsControl(c))
                throw new PerchException("SSH 目标不能包含空格、换行或控制字符。");
        }
    }

    public static void ValidatePort(int port, string label)
    {
        if (port is < 1 or > 65535)
            throw new PerchException(string.Format(CultureInfo.InvariantCulture, "{0}须为 1–65535，当前为 {1}。", label, port));
    }

    /// ssh arguments for the loopback-only forward. `localPort` is bound to
    /// 127.0.0.1 on this machine and points at the bridge's own loopback port.
    public static IReadOnlyList<string> TunnelArguments(string destination, int localPort, int remotePort)
    {
        ValidateDestination(destination);
        ValidatePort(localPort, "本地转发端口");
        ValidatePort(remotePort, "远端桥接端口");
        return new[]
        {
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-L", ForwardSpec(localPort, remotePort),
            destination,
        };
    }

    /// The forward spec, pinned to loopback on both ends.
    public static string ForwardSpec(int localPort, int remotePort) =>
        string.Format(CultureInfo.InvariantCulture, "127.0.0.1:{0}:127.0.0.1:{1}", localPort, remotePort);

    /// The local base URL the client talks to. Never a remote address.
    public static string LocalBaseUrl(int localPort) =>
        string.Format(CultureInfo.InvariantCulture, "http://127.0.0.1:{0}", localPort);
}

/// Finds the system OpenSSH client for a process that did not inherit an interactive
/// PATH. Returns argv-style candidates; the caller picks the first that exists.
public static class SshLocator
{
    public const string DefaultExecutableName = "ssh.exe";

    public static IReadOnlyList<string> Candidates(string? overridePath, IEnumerable<string> programFilesRoots)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();

        void Add(string? candidate)
        {
            if (string.IsNullOrWhiteSpace(candidate)) return;
            if (seen.Add(candidate)) result.Add(candidate);
        }

        Add(overridePath);
        foreach (var root in programFilesRoots)
            Add(Path.Combine(root, "OpenSSH", DefaultExecutableName));
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            Add(Path.Combine(directory.Trim(), DefaultExecutableName));
        // Last resort: let the OS resolve it.
        Add(DefaultExecutableName);
        return result;
    }

    public static string Resolve(Func<string, bool> exists, string? overridePath, IEnumerable<string> programFilesRoots)
    {
        foreach (var candidate in Candidates(overridePath, programFilesRoots))
            if (exists(candidate)) return candidate;
        throw new PerchException("未找到系统 OpenSSH 客户端。请在 Windows 设置中安装“OpenSSH 客户端”，或在配置里指定 ssh.exe 的路径。");
    }

    public static IReadOnlyList<string> DefaultProgramFilesRoots()
    {
        var roots = new List<string>();
        foreach (var name in new[] { "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432" })
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrWhiteSpace(value)) roots.Add(value);
        }
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrWhiteSpace(systemRoot))
            roots.Add(Path.Combine(systemRoot, "System32"));
        return roots;
    }
}
