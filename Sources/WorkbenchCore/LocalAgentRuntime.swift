import Foundation

/// Only connection establishment differs locally; conversation, approval and
/// recovery continue through the same authenticated bridge APIs as remote sessions.
public enum LocalAgentRuntime {
    public static func endpoint(host: SSHHost) async throws -> Data {
        guard host.isLocal else {
            throw WorkbenchError(L("此 Agent 尚未接入本机对话"))
        }
        let targets = LocalAgentDiscovery.supported.filter { host.enabledAgents.contains($0) }
        var binaries: [SessionKind: String] = [:]
        for kind in targets {
            let found = await LocalAgentDiscovery.discover(kind, override: host.localAgentPaths[kind.rawValue])
            if let binary = found.executablePath {
                binaries[kind] = binary
            }
        }
        guard !binaries.isEmpty else {
            throw WorkbenchError(L("未找到可用的本机 Agent，请重新检测。"))
        }
        guard let resources = Bundle.main.resourceURL else { throw WorkbenchError(L("本机服务组件缺失，请重新构建应用。")) }
        let script = resources.appendingPathComponent("RemoteSetup/remote/local-agent-service.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw WorkbenchError(L("本机服务组件缺失，请重新构建应用。"))
        }
        var arguments = [script.path]
        if let kimi = binaries[.kimi] { arguments += ["--kimi-binary", kimi] }
        if let codex = binaries[.codex] { arguments += ["--codex-binary", codex] }
        return try await SetupCommandRunner.run("/usr/bin/python3", arguments,
            timeout: 20, environment: LocalAgentDiscovery.environment)
    }

    public static func endpoint(for kind: SessionKind, host: SSHHost, forceRestart: Bool = false) async throws -> Data {
        guard host.isLocal, LocalAgentDiscovery.supported.contains(kind) else {
            throw WorkbenchError(L("此 Agent 尚未接入本机对话"))
        }
        var scoped = host
        if !scoped.enabledAgents.contains(kind) { scoped.enabledAgents = [kind] }
        return try await endpoint(host: scoped)
    }
}
