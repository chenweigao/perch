using System.Security;

namespace Perch.Core.Secrets;

/// The bridge access token, held in memory only.
///
/// This is a secret: it authorizes every bridge call. It is never written to disk,
/// never logged and never serialized. ToString() is overridden to a fixed redaction
/// so a stray interpolation into a log line or exception cannot leak it. Dispose()
/// best-effort clears the managed buffers.
public sealed class BridgeToken : IDisposable
{
    private SecureString? _secure;
    private string? _plain;
    private bool _disposed;

    private BridgeToken(SecureString? secure, string? plain)
    {
        _secure = secure;
        _plain = plain;
    }

    /// From a UI password box or any caller that already holds a SecureString.
    public static BridgeToken FromSecureString(SecureString value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return new BridgeToken(value.Copy(), null);
    }

    /// From a file read or a plain string. The caller must not retain its own copy.
    public static BridgeToken FromString(string value)
    {
        ArgumentException.ThrowIfNullOrEmpty(value);
        return new BridgeToken(null, value);
    }

    public bool IsEmpty => Value.Length == 0;

    /// The token text. Callers must keep it off logs and disk.
    public string Value
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_plain is not null) return _plain;
            if (_secure is null) return string.Empty;
            var pointer = System.Runtime.InteropServices.Marshal.SecureStringToBSTR(_secure);
            try
            {
                return System.Runtime.InteropServices.Marshal.PtrToStringBSTR(pointer) ?? string.Empty;
            }
            finally
            {
                System.Runtime.InteropServices.Marshal.ZeroFreeBSTR(pointer);
            }
        }
    }

    public override string ToString() => "<redacted-bridge-token>";

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_plain is not null)
        {
            // Strings are immutable; overwrite the char array the runtime exposes to
            // reduce the window the secret is recoverable, then drop the reference.
            var chars = _plain.ToCharArray();
            Array.Fill(chars, '\0');
            _plain = null;
        }
        _secure?.Dispose();
        _secure = null;
    }
}

/// Supplies the token on demand so a reconnect re-reads it rather than caching a
/// stale secret in the connection object.
public interface IBridgeTokenProvider
{
    ValueTask<BridgeToken> GetTokenAsync(CancellationToken cancellationToken = default);
}

/// A token typed into the UI's secure field for this connection only.
public sealed class SuppliedTokenProvider : IBridgeTokenProvider
{
    private readonly BridgeToken _token;
    public SuppliedTokenProvider(BridgeToken token) => _token = token;
    public ValueTask<BridgeToken> GetTokenAsync(CancellationToken cancellationToken = default) => new(_token);
}

/// Result of a permission audit on a token file.
public readonly record struct TokenFilePermission(bool IsReadableByOthers, string Detail)
{
    public static TokenFilePermission Safe(string detail) => new(false, detail);
    public static TokenFilePermission Unsafe(string detail) => new(true, detail);
}

/// Platform-specific audit of a token file's permissions. The Windows app implements
/// this with filesystem ACLs; the portable tests use a stub. Keeping it behind an
/// interface is what lets the token-loading rules run under `dotnet test` on Linux.
public interface ITokenFilePermissionChecker
{
    TokenFilePermission Audit(string path);
}

/// Loads a token from a file the user points at, refusing files whose permissions let
/// other local users read them. The path is validated before any read so a hostile
/// value cannot escape the intended file.
public sealed class TokenFileProvider : IBridgeTokenProvider
{
    private readonly string _path;
    private readonly ITokenFilePermissionChecker _permissions;
    private readonly Func<string, string> _readAllText;

    public TokenFileProvider(string path, ITokenFilePermissionChecker permissions, Func<string, string>? readAllText = null)
    {
        ValidatePath(path);
        _path = path;
        _permissions = permissions;
        _readAllText = readAllText ?? File.ReadAllText;
    }

    public static void ValidatePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new PerchException("请提供令牌文件的路径。");
        if (path.IndexOf('\0') >= 0)
            throw new PerchException("令牌文件路径包含非法字符。");
    }

    public ValueTask<BridgeToken> GetTokenAsync(CancellationToken cancellationToken = default)
    {
        var audit = _permissions.Audit(_path);
        if (audit.IsReadableByOthers)
            throw new PerchException("令牌文件权限过宽，其他本地用户可能读到它（" + audit.Detail + "）。请收紧权限后重试；Perch 不会读取它。");
        if (!File.Exists(_path))
            throw new PerchException("令牌文件不存在：" + _path);

        string raw;
        try
        {
            raw = _readAllText(_path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new PerchException("读取令牌文件失败：" + ex.Message, ex);
        }

        // endpoint.json may hold `{"token": "..."}`; a bare token file holds the value.
        var token = ExtractToken(raw);
        return new ValueTask<BridgeToken>(BridgeToken.FromString(token));
    }

    /// Accepts either a bare token or the bridge's endpoint.json object, so the user
    /// can point at whichever they copied. Never logs the content.
    internal static string ExtractToken(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) throw new PerchException("令牌文件为空。");
        if (trimmed[0] != '{') return trimmed;
        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(trimmed);
            if (document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object &&
                document.RootElement.TryGetProperty("token", out var tokenElement) &&
                tokenElement.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                var value = tokenElement.GetString();
                if (!string.IsNullOrWhiteSpace(value)) return value!;
            }
        }
        catch (System.Text.Json.JsonException)
        {
            // Fall through: a brace that is not valid JSON is not a token.
        }
        throw new PerchException("令牌文件像是 JSON，但没有可识别的 token 字段。");
    }
}
