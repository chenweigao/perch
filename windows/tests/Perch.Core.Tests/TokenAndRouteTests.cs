using System.Security;
using System.Text.Json;
using Perch.Core.Bridge;
using Perch.Core.Secrets;

namespace Perch.Core.Tests;

/// The token is a secret. These tests pin the rules: it is loaded from secure input or
/// a restricted-permission file, held only in memory, never logged or serialized, and a
/// world-readable token file is refused rather than read.
public class TokenTests
{
    [Fact]
    public void TokenToStringIsRedacted()
    {
        using var token = BridgeToken.FromString("super-secret-value");
        Assert.Equal("<redacted-bridge-token>", token.ToString());
        Assert.DoesNotContain("super-secret-value", token.ToString());
        // The real value is still available to callers that need it.
        Assert.Equal("super-secret-value", token.Value);
    }

    [Fact]
    public void TokenIsNotSerializedIntoJson()
    {
        using var token = BridgeToken.FromString("super-secret-value");
        // A record/object holding the token must not leak it through the bridge serializer.
        var json = Protocol.BridgeJson.Write(new { note = token.ToString() });
        Assert.DoesNotContain("super-secret-value", json);
    }

    [Fact]
    public void SecureStringTokenYieldsTheValue()
    {
        var secure = new SecureString();
        foreach (var c in "abc-123") secure.AppendChar(c);
        secure.MakeReadOnly();
        using var token = BridgeToken.FromSecureString(secure);
        Assert.Equal("abc-123", token.Value);
    }

    [Fact]
    public void DisposedTokenRefusesToYieldItsValue()
    {
        var token = BridgeToken.FromString("secret");
        token.Dispose();
        Assert.Throws<ObjectDisposedException>(() => token.Value);
    }

    [Fact]
    public void ExtractTokenAcceptsABareValue()
    {
        Assert.Equal("tok_123", TokenFileProvider.ExtractToken("tok_123\n"));
    }

    [Fact]
    public void ExtractTokenAcceptsEndpointJson()
    {
        var json = Fixtures.Raw("endpoint.json");
        Assert.Equal("fixture-token-do-not-use", TokenFileProvider.ExtractToken(json));
    }

    [Fact]
    public void ExtractTokenRejectsJsonWithoutATokenField()
    {
        Assert.Throws<PerchException>(() => TokenFileProvider.ExtractToken("{\"port\":1234}"));
    }

    [Fact]
    public void ExtractTokenRejectsEmptyContent()
    {
        Assert.Throws<PerchException>(() => TokenFileProvider.ExtractToken("   "));
    }

    [Fact]
    public async Task WorldReadableTokenFileIsRefusedWithoutReading()
    {
        var path = WriteTempToken("secret-value");
        try
        {
            var provider = new TokenFileProvider(path, new StubPermissions(TokenFilePermission.Unsafe("S-1-1-0 (Everyone) 有读取权限")),
                readAllText: _ => throw new InvalidOperationException("must not read a world-readable token file"));
            var ex = await Assert.ThrowsAsync<PerchException>(() => provider.GetTokenAsync().AsTask());
            Assert.Contains("权限过宽", ex.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task RestrictedTokenFileIsReadIntoMemory()
    {
        var path = WriteTempToken("  tok-restricted  ");
        try
        {
            var provider = new TokenFileProvider(path, new StubPermissions(TokenFilePermission.Safe("仅当前用户可读")));
            using var token = await provider.GetTokenAsync();
            Assert.Equal("tok-restricted", token.Value);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void TokenFilePathIsValidatedBeforeUse()
    {
        Assert.Throws<PerchException>(() => TokenFileProvider.ValidatePath(""));
        Assert.Throws<PerchException>(() => TokenFileProvider.ValidatePath("has\u0000nul"));
    }

    [Fact]
    public async Task MissingTokenFileIsReported()
    {
        var path = Path.Combine(Path.GetTempPath(), "perch-missing-" + Guid.NewGuid().ToString("N") + ".token");
        var provider = new TokenFileProvider(path, new StubPermissions(TokenFilePermission.Safe("ok")));
        var ex = await Assert.ThrowsAsync<PerchException>(() => provider.GetTokenAsync().AsTask());
        Assert.Contains("不存在", ex.Message);
    }

    private static string WriteTempToken(string content)
    {
        var path = Path.Combine(Path.GetTempPath(), "perch-token-" + Guid.NewGuid().ToString("N") + ".token");
        File.WriteAllText(path, content);
        return path;
    }

    private sealed class StubPermissions : ITokenFilePermissionChecker
    {
        private readonly TokenFilePermission _permission;
        public StubPermissions(TokenFilePermission permission) => _permission = permission;
        public TokenFilePermission Audit(string path) => _permission;
    }
}

/// Route building must percent-encode every user-influenced segment so a session id or
/// request id containing a space, Chinese, or a shell/URL metacharacter cannot break the
/// URL or the remote side.
public class BridgeRouteTests
{
    [Theory]
    [InlineData("ses-1", "/sessions/ses-1")]
    [InlineData("ses 1", "/sessions/ses%201")]
    [InlineData("会话-1", "/sessions/%E4%BC%9A%E8%AF%9D-1")]
    [InlineData("a/b", "/sessions/a%2Fb")]
    [InlineData("a?b&c", "/sessions/a%3Fb%26c")]
    public void SessionRouteEncodesTheId(string id, string expected)
    {
        Assert.Equal(expected, BridgeRoutes.Session(id));
    }

    [Fact]
    public void SnapshotRouteBuildsDeltaQueryInOrder()
    {
        var path = BridgeRoutes.SessionSnapshot("ses-1", revision: 4, start: 0, epoch: "abc");
        Assert.Equal("/sessions/ses-1?revision=4&start=0&epoch=abc", path);
    }

    [Fact]
    public void SnapshotRouteEncodesEpochAndSpaces()
    {
        var path = BridgeRoutes.SessionSnapshot("ses 1", revision: 4, start: 2, epoch: "e p/o?c");
        Assert.Equal("/sessions/ses%201?revision=4&start=2&epoch=e%20p%2Fo%3Fc", path);
    }

    [Fact]
    public void SnapshotRouteBuildsPagedAndDeltaQueries()
    {
        Assert.Equal("/sessions/ses-1?turns=25", BridgeRoutes.SessionSnapshot("ses-1", turns: 25));
        // Parameters are emitted in a fixed order (revision, start, epoch, turns)
        // regardless of argument order, so the path is stable for a given set.
        Assert.Equal("/sessions/ses-1?revision=4&start=0&epoch=abc",
            BridgeRoutes.SessionSnapshot("ses-1", revision: 4, start: 0, epoch: "abc"));
    }

    [Fact]
    public void ActionRouteEncodesBothSegments()
    {
        Assert.Equal("/sessions/ses%201/abort", BridgeRoutes.Action("ses 1", "abort"));
        Assert.Equal("/sessions/%E4%BC%9A%E8%AF%9D-1/prompt", BridgeRoutes.Action("会话-1", "prompt"));
    }

    [Fact]
    public void UrlEncodeNeverUsesPlusForSpace()
    {
        // The bridge's urlparse/unquote expects %20; a '+' would be read as a literal.
        Assert.Equal("a%20b", BridgeRoutes.UrlEncode("a b"));
        Assert.DoesNotContain('+', BridgeRoutes.UrlEncode("a b c"));
    }
}
