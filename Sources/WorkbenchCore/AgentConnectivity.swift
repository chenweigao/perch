import Foundation

/// Where an agent actually runs. Local is its own case rather than `ssh localhost`,
/// so working directories, discovery and permissions stay honest about the machine.
public enum ExecutionEnvironment: Equatable, Sendable {
    case local
    case ssh(SSHHost)

    /// A stable synthetic host id for the Mac. SessionReference already keys on
    /// hostID, so this keeps a local session from colliding with a remote one that
    /// happens to share a path and session name.
    public static let localHostID = UUID(uuidString: "00000000-0000-4000-8000-00000000104C")!

    public var hostID: UUID {
        switch self {
        case .local: return Self.localHostID
        case .ssh(let host): return host.id
        }
    }
    public var name: String {
        switch self {
        case .local: return "本机"
        case .ssh(let host): return host.name
        }
    }
    public var isLocal: Bool { self == .local }
}

public enum DiscoveryState: Equatable, Sendable {
    case found(path: String, version: String)
    case missing(hint: String)
    case unusable(path: String, reason: String)

    public var executablePath: String? {
        if case .found(let path, _) = self { return path }
        return nil
    }
}

/// Finds the agent binary for a GUI process. An app launched from Finder does not
/// inherit the interactive shell's PATH, so the search is an explicit list of
/// absolute paths plus whatever PATH does contain — never a shell command built by
/// string concatenation.
public enum LocalAgentDiscovery {
    public static let ompSearchPaths = [
        "/opt/homebrew/bin/omp", "/usr/local/bin/omp", "/opt/local/bin/omp",
        "/run/current-system/sw/bin/omp",
    ]

    public static func candidates(named executable: String, defaults: [String],
                                  path: String?, home: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ candidate: String) {
            guard !candidate.isEmpty, candidate.hasPrefix("/"), seen.insert(candidate).inserted else { return }
            result.append(candidate)
        }
        defaults.forEach(add)
        add(home + "/.local/bin/" + executable)
        add(home + "/.bun/bin/" + executable)
        for directory in (path ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            add(String(directory) + "/" + executable)
        }
        return result
    }

    /// Parses `omp/17.1.4` or `omp v17.1.4`. Anything unrecognised stays unknown so
    /// capabilities are not inferred from a version we cannot read.
    public static func parseOMPVersion(_ output: String) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { return nil }
        return String(text[match])
    }

    public static var missingOMPHint: String {
        L("未找到本机 omp。请在设置中指定可执行文件路径，或参考 oh-my-pi 安装说明后重试。Perch 不会自动安装或修改你的 shell 配置。")
    }
}

/// Launch arguments for a local OMP session. Returned as argv, never as a shell
/// string, and always with an isolated session directory plus explicit approvals.
public struct LocalOMPLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String

    public init(executable: String, workingDirectory: String, sessionDirectory: String,
                model: String? = nil, resume: String? = nil) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        var args = ["--mode", "rpc-ui", "--cwd", workingDirectory,
                    "--approval-mode", "always-ask", "--no-title",
                    "--session-dir", sessionDirectory]
        if let resume, !resume.isEmpty { args += ["--resume", resume] }
        if let model, !model.isEmpty { args += ["--model", model] }
        arguments = args
    }
    public var usesExplicitApproval: Bool {
        zip(arguments, arguments.dropFirst()).contains { $0 == "--approval-mode" && $1 == "always-ask" }
    }
}

public struct AgentEndpoint: Equatable, Sendable, Identifiable {
    public let environment: ExecutionEnvironment
    public let kind: SessionKind
    public let capabilities: AgentCapabilities
    public let runtimeVersion: String?
    /// What was actually exercised against this runtime, for the UI to show instead
    /// of a blanket "supported".
    public let verificationNote: String
    public var id: String { "\(environment.hostID):\(kind.rawValue)" }

    public init(environment: ExecutionEnvironment, kind: SessionKind, capabilities: AgentCapabilities,
                runtimeVersion: String? = nil, verificationNote: String) {
        self.environment = environment; self.kind = kind; self.capabilities = capabilities
        self.runtimeVersion = runtimeVersion; self.verificationNote = verificationNote
    }

    public var canStartNativeConversation: Bool { capabilities.nativeConversation }

    /// Capabilities for a local OMP whose RPC surface was probed at the given
    /// version. Commands are granted only when the probe answered them; an
    /// unreadable version grants nothing.
    public static func localOMP(version: String?, probe: OMPCommandProbe) -> AgentEndpoint {
        guard let version else {
            return AgentEndpoint(environment: .local, kind: .omp, capabilities: .unknown,
                                 verificationNote: L("未能读取 omp 版本，能力未知"))
        }
        let capabilities = AgentCapabilities(
            nativeConversation: probe.prompt,
            stop: probe.abort,
            steer: probe.steer ? .commandPresentEffectUnverified : .unsupported,
            queueWhileBusy: probe.followUp,
            resume: probe.sessionFile)
        return AgentEndpoint(environment: .local, kind: .omp, capabilities: capabilities,
                             runtimeVersion: version,
                             verificationNote: "omp \(version)：RPC 命令存在性已实测，运行中注入与审批未实机验证")
    }
}

/// Which RPC commands the installed runtime actually answered. `steer`/`follow_up`
/// being present is a statement about the command, not about its effect on a turn.
public struct OMPCommandProbe: Equatable, Sendable {
    public let prompt: Bool
    public let abort: Bool
    public let steer: Bool
    public let followUp: Bool
    public let sessionFile: Bool

    public init(prompt: Bool = false, abort: Bool = false, steer: Bool = false,
                followUp: Bool = false, sessionFile: Bool = false) {
        self.prompt = prompt; self.abort = abort; self.steer = steer
        self.followUp = followUp; self.sessionFile = sessionFile
    }

    /// An `Unknown command:` error means the verb does not exist; any other error
    /// means it exists but was called with the wrong arguments.
    public static func commandExists(errorMessage: String?) -> Bool {
        guard let errorMessage else { return true }
        return !errorMessage.hasPrefix("Unknown command:")
    }
}
