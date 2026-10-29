using Perch.Core.Ssh;

namespace Perch.Core.Tests;

/// The SSH surface is security-critical: host keys strictly checked, batch mode, no
/// password storage, loopback-only forwarding, no takeover. These tests assert the
/// exact argv so a regression cannot quietly relax one of those.
public class SshCommandTests
{
    [Fact]
    public void TunnelArgumentsAreLoopbackOnlyBatchAndStrictHostKey()
    {
        var args = SshCommand.TunnelArguments("dev-box", 51000, 41873);
        Assert.Equal("-N", args[0]);
        Assert.Contains("BatchMode=yes", args);
        Assert.Contains("StrictHostKeyChecking=yes", args);
        Assert.Contains("ExitOnForwardFailure=yes", args);
        Assert.Contains("127.0.0.1:51000:127.0.0.1:41873", args);
        Assert.Equal("dev-box", args[^1]);

        // Must NOT accept unknown hosts, must NOT carry a takeover/control-master flag,
        // must NOT allocate a remote tty, and must NOT run any remote command.
        Assert.DoesNotContain("StrictHostKeyChecking=no", args);
        Assert.DoesNotContain("StrictHostKeyChecking=accept-new", args);
        Assert.DoesNotContain("--takeover", args);
        Assert.DoesNotContain("-M", args);
        Assert.DoesNotContain("-tt", args);
        Assert.DoesNotContain(args, a => a.Contains("ControlMaster"));
        Assert.DoesNotContain(args, a => a.Contains("ControlPersist"));
    }

    [Fact]
    public void ForwardSpecBindsLoopbackOnBothEnds()
    {
        // A bare ":port:localhost:port" or "0.0.0.0" bind would expose the bridge to the
        // LAN; the spec must pin 127.0.0.1 on the local side and the remote side.
        var spec = SshCommand.ForwardSpec(51000, 41873);
        Assert.Equal("127.0.0.1:51000:127.0.0.1:41873", spec);
        Assert.DoesNotContain("0.0.0.0", spec);
        Assert.DoesNotContain("*:", spec);
    }

    [Fact]
    public void LocalBaseUrlIsLoopbackHttp()
    {
        Assert.Equal("http://127.0.0.1:51000", SshCommand.LocalBaseUrl(51000));
    }

    [Theory]
    [InlineData("")]
    [InlineData("-oProxyCommand=evil")]
    [InlineData("host with space")]
    [InlineData("host\ttab")]
    [InlineData("host\nnewline")]
    public void ValidateDestinationRejectsUnsafeValues(string destination)
    {
        Assert.Throws<PerchException>(() => SshCommand.ValidateDestination(destination));
    }

    [Theory]
    [InlineData("dev-box")]
    [InlineData("user@host")]
    [InlineData("user@host.example")]
    public void ValidateDestinationAcceptsAliasesAndUserHost(string destination)
    {
        SshCommand.ValidateDestination(destination); // no throw
    }

    [Fact]
    public void TunnelArgumentsRejectABadDestinationBeforeBuildingArgv()
    {
        // A destination starting with '-' would be parsed as an ssh option; it must be
        // refused so it can never inject a flag.
        Assert.Throws<PerchException>(() => SshCommand.TunnelArguments("-oProxyCommand=x", 51000, 41873));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(65536)]
    public void ValidatePortRejectsOutOfRange(int port)
    {
        Assert.Throws<PerchException>(() => SshCommand.ValidatePort(port, "端口"));
        Assert.Throws<PerchException>(() => SshCommand.TunnelArguments("dev-box", port, 41873));
        Assert.Throws<PerchException>(() => SshCommand.TunnelArguments("dev-box", 51000, port));
    }

    [Theory]
    [InlineData("", "''")]
    [InlineData("plain", "plain")]
    [InlineData("a b", "'a b'")]
    [InlineData("it's", "'it'\"'\"'s'")]
    [InlineData("$HOME", "'$HOME'")]
    [InlineData("a`b", "'a`b'")]
    [InlineData("a&&b", "'a&&b'")]
    [InlineData("中文 路径", "'中文 路径'")]
    [InlineData("*", "'*'")]
    [InlineData("a;rm -rf /", "'a;rm -rf /'")]
    public void PosixQuoteEscapesShellMetacharacters(string input, string expected)
    {
        Assert.Equal(expected, SshCommand.PosixQuote(input));
    }

    [Fact]
    public void PosixQuoteNeutralizesInjectionAttempt()
    {
        // Whatever the user typed must survive as a single literal word.
        var quoted = SshCommand.PosixQuote("foo'; rm -rf / #");
        Assert.Equal("'foo'\"'\"'; rm -rf / #'", quoted);
        Assert.StartsWith("'", quoted);
        Assert.EndsWith("'", quoted);
    }

    [Fact]
    public void SshLocatorFindsSystemOpenSshUnderProgramFiles()
    {
        var roots = new[] { @"C:\Program Files", @"C:\Program Files (x86)" };
        var candidates = SshLocator.Candidates(null, roots);
        // Asserted separator-agnostically because these tests run on Linux CI too, where
        // Path.Combine joins with '/'; the runtime target is Windows.
        Assert.Contains(candidates, c => c.Contains("Program Files") && c.Contains("OpenSSH") && c.EndsWith("ssh.exe"));
        // The explicit override wins and is tried first.
        var withOverride = SshLocator.Candidates(@"D:\tools\ssh.exe", roots);
        Assert.Equal(@"D:\tools\ssh.exe", withOverride[0]);
    }

    [Fact]
    public void SshLocatorResolvePicksTheFirstExistingCandidate()
    {
        var roots = new[] { @"C:\Program Files" };
        var candidates = SshLocator.Candidates(null, roots);
        var programFilesCandidate = candidates.First(c => c.Contains("Program Files") && c.EndsWith("ssh.exe"));
        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { programFilesCandidate };
        var resolved = SshLocator.Resolve(existing.Contains, null, roots);
        Assert.Equal(programFilesCandidate, resolved);
    }

    [Fact]
    public void SshLocatorResolveThrowsWithGuidanceWhenAbsent()
    {
        var ex = Assert.Throws<PerchException>(() => SshLocator.Resolve(_ => false, null, Array.Empty<string>()));
        Assert.Contains("OpenSSH", ex.Message);
    }
}

/// Error classification must point the user at the real cause without ever suggesting
/// Perch accepted an unknown host key or stored a password.
public class SshErrorClassificationTests
{
    [Fact]
    public void UnknownHostKeyIsExplainedNotAccepted()
    {
        var hint = SshTunnel.ClassifySshError(
            "Host key verification failed. The authenticity of host 'x' can't be established.");
        Assert.Contains("主机密钥", hint);
        Assert.Contains("不会自动接受未知主机", hint);
    }

    [Fact]
    public void PermissionDeniedPointsToAgentLogin()
    {
        var hint = SshTunnel.ClassifySshError("Permission denied (publickey).");
        Assert.Contains("免交互登录失败", hint);
        Assert.Contains("不保存密码", hint);
    }

    [Fact]
    public void ForwardingRefusedIsExplained()
    {
        var hint = SshTunnel.ClassifySshError("channel 0: open failed: administratively prohibited: open failed");
        Assert.Contains("AllowTcpForwarding", hint);
    }

    [Fact]
    public void UnrecognizedErrorYieldsNoMisleadingHint()
    {
        Assert.Equal(string.Empty, SshTunnel.ClassifySshError("something odd happened"));
    }
}
