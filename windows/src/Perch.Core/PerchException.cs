namespace Perch.Core;

/// A failure the user can act on. Messages are shown as-is in the UI.
public class PerchException : Exception
{
    public PerchException(string message) : base(message) { }
    public PerchException(string message, Exception inner) : base(message, inner) { }
}

/// The bridge answered with an HTTP error, or its response could not be parsed.
public class BridgeException : PerchException
{
    public BridgeException(string message) : base(message) { }
    public BridgeException(string message, Exception inner) : base(message, inner) { }
    public int? StatusCode { get; init; }
}

/// The token was rejected: the tunnel is up but this client is not authorized.
public sealed class UnauthorizedException : BridgeException
{
    public UnauthorizedException()
        : base("访问凭证无效或已过期，请重新连接。") => StatusCode = 401;
}

/// The connection loop stopped on its own; the caller reconnects or reports.
public sealed class TunnelException : PerchException
{
    public TunnelException(string message) : base(message) { }
    public TunnelException(string message, Exception inner) : base(message, inner) { }
    public int? ExitCode { get; init; }
}
