import Foundation

/// Only connection establishment differs locally; conversation, approval and
/// recovery continue through the same authenticated APIs as remote sessions.
public enum LocalAgentRuntime {
    public static func endpoint(for kind: SessionKind, host: SSHHost) async throws -> Data {
        guard host.isLocal, LocalAgentDiscovery.supported.contains(kind) else {
            throw WorkbenchError(L("此 Agent 尚未接入本机对话"))
        }
        let found = await LocalAgentDiscovery.discover(kind, override: host.localAgentPaths[kind.rawValue])
        guard let binary = found.executablePath else {
            throw WorkbenchError(L("未找到可用的本机 Agent，请重新检测。"))
        }
        guard let resources = Bundle.main.resourceURL else { throw WorkbenchError(L("本机服务组件缺失，请重新构建应用。")) }
        let script = resources.appendingPathComponent("RemoteSetup/remote/local-agent-service.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw WorkbenchError(L("本机服务组件缺失，请重新构建应用。"))
        }
        return try await SetupCommandRunner.run("/usr/bin/python3",
            [script.path, "--agent", kind.rawValue, "--binary", binary, "--port", String(host.kimiPort)],
            timeout: 20, environment: LocalAgentDiscovery.environment)
    }
}
