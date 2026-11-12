import AppKit
import Combine
import WorkbenchCore

@MainActor
final class RemoteSetupController: ObservableObject {
    enum Step: Int, CaseIterable { case machine, agent, project }
    enum Status: Equatable { case waiting, checking, passed, needsAction, information }
    struct Check: Identifiable {
        struct Action {
            let title: String
            let perform: () -> Void
        }
        let id: String
        var title: String
        var status: Status = .waiting
        var detail = ""
        var needsManualRestart = false
        var action: Action? = nil
    }
    @Published var step = Step.machine
    @Published var destination: String
    @Published var name: String
    @Published var provider: SessionKind
    @Published var enabledAgents: Set<SessionKind>
    @Published var directory = ""
    @Published var modelID = ""
    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var checks: [Check] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var awaitingInstallCheck = false
    @Published private(set) var error: String?
    @Published private(set) var hint = ""
    @Published private(set) var failedCheck: String?
    @Published private(set) var remoteHome = ""
    @Published private(set) var aliases: [String] = []
    @Published private(set) var verifiedDirectory: String?
    var projectVerified: Bool { verifiedDirectory == directory }
    @Published private(set) var folders: [String] = []
    @Published private(set) var browsingDirectory = ""
    let original: SSHHost?
    private let hostID: UUID
    private var task: Task<Void, Never>?
    private var native: NativeAgentConnection?

    init(host: SSHHost? = nil, initialProvider: SessionKind? = nil) {
        original = host; hostID = host?.id ?? UUID()
        destination = host?.destination ?? ""; name = host?.name ?? ""
        provider = initialProvider ?? host?.enabledAgents.first ?? .kimi
        enabledAgents = Set(host?.enabledAgents ?? [])
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        if let text = try? String(contentsOf: config, encoding: .utf8) { aliases = RemoteSetup.sshAliases(text) }
    }
    var host: SSHHost {
        var result = SSHHost(id: hostID, name: name.isEmpty ? destination : name, destination: destination,
                             enabledAgents: RemoteSetup.agents.filter { enabledAgents.contains($0) || $0 == provider },
                             kimiPort: original?.kimiPort ?? 58627,
                             kimiTokenPath: original?.kimiTokenPath ?? SSHHost.defaultKimiTokenPath,
                             autoConnectSSH: original?.autoConnectSSH ?? true,
                             autoConnectHerdr: original?.autoConnectHerdr ?? true)
        result.kimiManaged = false
        result.kimiEnvironment = original?.kimiEnvironment ?? [:]
        return result
    }
    var needsBridge: Bool { [.kimi, .omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains(provider) }
    var canContinue: Bool { ready && !busy }
    var canFinish: Bool { projectVerified && ready && !busy }
    var checkAgentTitle: String {
        if awaitingInstallCheck { return L("已安装，重新检查") }
        return ready ? L("重新检查") : L("检查 Agent")
    }
    var launch: TaskLaunchDefaults { TaskLaunchDefaults(hostID: hostID, provider: provider, directory: directory, model: modelID) }
    var installURL: URL {
        switch provider {
        case .kimi: return URL(string: "https://moonshotai.github.io/kimi-code/en/guides/getting-started.html")!
        case .omp: return URL(string: "https://github.com/can1357/oh-my-pi#install")!
        case .qoder: return URL(string: "https://docs.qoder.cn/cli/installation")!
        case .qoderintl: return URL(string: "https://docs.qoder.com/cli/installation")!
        case .dsh: return URL(string: "https://github.com/deepseek-ai/deepseek-harness")!
        case .codex: return URL(string: "https://github.com/openai/codex#installation")!
        case .claude: return URL(string: "https://code.claude.com/docs/en/setup")!
        case .terminal: return URL(string: "https://github.com/herdrdev/herdr")!
        }
    }
    var installCommand: String? {
        switch provider {
        case .kimi: return "npm install -g @moonshot-ai/kimi-code"
        case .omp: return "bun install -g @oh-my-pi/pi-coding-agent@18.1.16"
        case .qoder: return "npm install -g @qodercn-ai/qoderclicn@1.1.58"
        case .qoderintl: return "curl -fsSL https://qoder.com/install | bash"
        case .codex: return "npm install -g @openai/codex"
        case .claude: return "npm install -g @anthropic-ai/claude-code@2.1.302"
        case .dsh, .terminal: return nil
        }
    }
    var loginCommand: String {
        switch provider {
        case .kimi: return "kimi login"
        case .omp: return "omp"
        case .qoder: return "qoderclicn"
        case .qoderintl: return "qodercli"
        case .codex: return "codex login"
        case .claude: return "claude"
        case .dsh: return "" // The user's shell/profile owns DEEPSEEK_API_KEY.
        case .terminal: return "herdr"
        }
    }
    func invalidateAgent() {
        cancel(); ready = false; verifiedDirectory = nil; checks = []; models = []; modelID = ""
        awaitingInstallCheck = false
        error = nil; hint = ""; failedCheck = nil
    }
    func invalidateProject() { error = nil }
    func back() {
        cancel(); error = nil; hint = ""; failedCheck = nil; awaitingInstallCheck = false
        if step == .project { step = .agent; verifiedDirectory = nil }
        else { step = .machine; ready = false; checks = [] }
    }
    func cancel() {
        task?.cancel(); task = nil; disconnectProbes(); busy = false
    }
    private func disconnectProbes() {
        native?.disconnect()
        native = nil
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; hint = ""; failedCheck = nil
        task = Task {
            do { try await action() }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                if step == .machine { hint = RemoteSetup.sshHint(error.localizedDescription) }
                if let index = checks.firstIndex(where: { $0.status == .checking }) {
                    checks[index].status = .needsAction
                    if failedCheck == nil { failedCheck = checks[index].id }
                }
            }
            guard !Task.isCancelled else { return }
            busy = false; task = nil
        }
    }
    private func ssh(_ command: String, timeout: TimeInterval = 30) async throws -> Data {
        try await SetupCommandRunner.run("/usr/bin/ssh", RemoteSetup.sshArguments(destination, command: command), timeout: timeout)
    }
    func verifySSH() {
        run {
            self.destination = self.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            try SSHCommand.validateDestination(self.destination)
            let output = try await self.ssh("printf '%s\\n' \"$HOME\"")
            try Task.checkCancellation()
            let home = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard home.hasPrefix("/"), !home.contains("\n") else {
                throw WorkbenchError(L("SSH 已连接，但未能读取远端主目录。请检查远端 shell 的启动输出。"))
            }
            self.remoteHome = home
            if self.directory.isEmpty { self.directory = home }
            self.step = .agent
        }
    }
    private func mark(_ id: String, _ status: Status, _ detail: String = "") {
        if let index = checks.firstIndex(where: { $0.id == id }) { checks[index].status = status; checks[index].detail = detail }
    }
    private func awaitConnection(seconds: Int = 35, online: () -> Bool, error: () -> String?) async throws {
        for _ in 0..<(seconds * 10) {
            try Task.checkCancellation()
            if online() { return }
            if let error = error() { throw WorkbenchError(error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let error = error() { throw WorkbenchError(error) }
        throw WorkbenchError(L("服务连接超时。检查远端服务是否正在运行，以及 SSH 是否允许端口转发。"))
    }
    func checkAgent() {
        awaitingInstallCheck = false
        run {
            self.ready = false; self.verifiedDirectory = nil; self.disconnectProbes(); self.models = []
            try RemoteSetup.validate(self.host)
            self.checks = [Check(id: "runtime", title: L("运行环境")), Check(id: "service", title: L("服务连接")), Check(id: "models", title: L("模型与登录"))]
            defer { if !Task.isCancelled { self.disconnectProbes() } }
            try await self.checkNative()
            try Task.checkCancellation()
            self.ready = true
        }
    }
    /// The bridge process serving this check. `--ensure` already replaces an idle
    /// service whose source differs, so this row only makes the running one visible;
    /// an agent CLI upgraded mid-session still applies from its next session. While
    /// a staged update waits for running tasks, the row names that transition
    /// instead: the check passes through the compatible old process.
    private func reportBridgeProcess(running: RunningRuntime, transition: BridgeTransition? = nil) {
        checks.removeAll { $0.id == "process" }
        var parts: [String] = []
        if let source = running.version, !source.isEmpty { parts.append(L("桥接源码 \(source)")) }
        if let started = RuntimeVersion.startedLabel(running.startedAt) { parts.append(started) }
        if let transition {
            var detail = L("运行中的服务仍是 v\(transition.serving)，\(transition.activeTasks) 个任务运行中；全部结束后 Perch 自动安全切换，目录与会话不受影响。")
            if !parts.isEmpty { detail += "\n" + parts.joined(separator: " · ") }
            checks.append(Check(id: "process", title: L("桥接更新待生效"), status: .information, detail: detail))
            return
        }
        guard !parts.isEmpty else { return }
        checks.append(Check(id: "process", title: L("运行进程"), status: .information,
                            detail: parts.joined(separator: " · ")))
    }
    /// Compares the installed bridge with the protocol this build speaks, so a stale
    /// or newer remote copy is named here instead of failing later during a task.
    private func checkBridge() async throws -> Int {
        let expected = RemoteSetup.bridgeServiceVersion
        switch RemoteSetup.parseBridgeProbe(try await ssh(RemoteSetup.bridgeProbeCommand)) {
        case .installed(let version) where version == expected:
            return version
        case .installed(let version) where version < expected:
            throw WorkbenchError(L("远端桥接组件是 v\(version)，此 Perch 需要 v\(expected)。请安装 / 更新桥接组件后重新检查。"))
        case .installed(let version):
            throw WorkbenchError(L("远端桥接组件是 v\(version)，比此 Perch 支持的 v\(expected) 更新。请升级 Perch；不要降级远端组件，其他客户端可能正在使用它。"))
        case .missing:
            throw WorkbenchError(L("远端未安装 Perch 桥接组件。请安装桥接组件后重新检查。"))
        case .unreadable, .invalid:
            throw WorkbenchError(L("无法读取远端桥接组件的版本。请重新安装桥接组件后检查。"))
        }
    }
    private func checkNative() async throws {
        mark("runtime", .checking)
        hint = L("远端需要 Python 3；Qoder 与 Claude Code 还需要 Node.js 与 npm。")
        _ = try await ssh(provider == .qoder || provider == .qoderintl || provider == .claude ? "python3 --version && node --version" : "python3 --version")
        try Task.checkCancellation()
        mark("runtime", .passed)
        mark("service", .checking)
        hint = L("安装或更新 Perch 桥接组件后重新检查。空闲的旧服务会自动安全重启；有任务运行时会等待任务结束。")
        let bridge = try await checkBridge()
        try Task.checkCancellation()
        let connection = NativeAgentConnection(setupHost: host); native = connection; connection.connect()
        try await awaitConnection(online: { connection.online }, error: { connection.error })
        let status = try await connection.setupStatus(provider: provider)
        try Task.checkCancellation()
        mark("service", .passed, L("桥接组件 v\(bridge)"))
        reportBridgeProcess(running: connection.runtime, transition: connection.bridgeTransition)
        mark("models", .checking)
        hint = L("在远端安装所选 Agent、完成登录和模型配置，然后重新检查。")
        guard status["installed"] == .bool(true) else {
            mark("models", .waiting); mark("runtime", .needsAction); failedCheck = "runtime"
            throw WorkbenchError(L("未找到可运行的 Agent。安装后请确认 SSH 命令可以读取其版本。"))
        }
        mark("runtime", .passed, status["version"].string ?? "")
        if let message = status["error"].string { throw WorkbenchError(message) }
        switch provider {
        case .kimi:
            let entries = ModelSelectionCatalog.parseOMP(status["models"])
            models = entries.map { ModelOption(id: $0.id, provider: $0.provider, name: $0.name) }
            if !models.isEmpty {
                if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
                mark("models", .passed, L("模型列表已读取；实际模型鉴权将在首条消息时验证。"))
            } else {
                mark("models", .information, L("模型目录将在首次 ACP 会话握手时读取；实际模型鉴权将在首条消息时验证。"))
            }
        case .omp:
            let entries = ModelSelectionCatalog.parseOMP(status["models"])
            models = entries.map { ModelOption(id: $0.provider + "/" + $0.id, provider: $0.provider, name: $0.name) }
            guard !models.isEmpty else { throw WorkbenchError(L("OMP 未返回模型。请在远端配置模型后重试。")) }
            mark("models", .passed, L("模型列表已读取；实际模型鉴权将在首条消息时验证。"))
        case .qoder, .qoderintl:
            guard status["sdkInstalled"] == .bool(true), status["nodeInstalled"] == .bool(true) else {
                mark("service", .needsAction); failedCheck = "service"
                throw WorkbenchError(L("缺少 Qoder SDK 或 Node.js。请安装桥接组件和 Node.js 后重试。"))
            }
            guard status["credentialCheck"].string == "present" else {
                throw WorkbenchError(L("Qoder CLI 尚未登录。请在远端完成登录后重试。"))
            }
            let entries = ModelSelectionCatalog.parseOMP(status["models"])
            models = entries.map { ModelOption(id: $0.id, provider: $0.provider, name: $0.name) }
            guard !models.isEmpty else { throw WorkbenchError(L("Qoder SDK 未返回模型。请检查远端 Qoder 安装与登录。")) }
            if !models.contains(where: { $0.id == modelID }) {
                let defaultID = status["models"].array.first { $0["isDefault"] == .bool(true) }?["id"].string
                modelID = defaultID.flatMap { value in models.first(where: { $0.id == value })?.id }
                    ?? models.first?.id ?? ""
            }
            mark("models", .passed, L("已确认 Qoder 登录并读取 SDK 模型目录；检查未发送任务。"))
        case .claude:
            guard status["sdkInstalled"] == .bool(true), status["nodeInstalled"] == .bool(true) else {
                mark("service", .needsAction); failedCheck = "service"
                throw WorkbenchError(L("缺少 Claude Code SDK 或 Node.js。请安装桥接组件和 Node.js 后重试。"))
            }
            let entries = ModelSelectionCatalog.parseOMP(status["models"])
            models = entries.map { ModelOption(id: $0.id, provider: $0.provider, name: $0.name) }
            guard !models.isEmpty else { throw WorkbenchError(L("Claude Code 未返回模型。请检查远端 Claude Code 安装与登录。")) }
            if !models.contains(where: { $0.id == modelID }) {
                let defaultID = status["models"].array.first { $0["isDefault"] == .bool(true) }?["id"].string
                modelID = defaultID.flatMap { value in models.first(where: { $0.id == value })?.id }
                    ?? models.first?.id ?? ""
            }
            mark("models", .passed, L("已读取 Claude Code 官方模型目录；实际模型鉴权将在首条消息时验证。"))
        case .dsh:
            guard status["credentialCheck"].string == "present" else {
                throw WorkbenchError(L("桥接进程未读取到 DEEPSEEK_API_KEY。请在远端配置服务环境；若桥已运行，等任务结束后重启再检查。"))
            }
            mark("models", .information, L("已检测到远端凭据；模型目录在首次 ACP 会话握手时读取，鉴权在发送时验证。"))
        case .codex:
            let credentials = status["credentialCheck"].string ?? ""
            guard ["present", "provider-managed"].contains(credentials) else {
                throw WorkbenchError(L("Codex CLI 尚未登录。请在远端运行 codex login 后重试。"))
            }
            models = status["models"].array.compactMap { entry in
                guard let id = entry["id"].string else { return nil }
                return ModelOption(id: id, provider: "codex", name: entry["name"].string ?? id)
            }
            guard !models.isEmpty else { throw WorkbenchError(L("Codex app-server 未返回模型。请检查远端 Codex 安装与登录。")) }
            if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
            let detail = credentials == "provider-managed"
                ? L("模型列表已读取；实际模型鉴权将在首条消息时验证。")
                : L("已确认 Codex 登录并读取 app-server 模型目录；检查未发送任务。")
            mark("models", .passed, detail)
        default: break
        }
        hint = ""
    }
    func browse(_ path: String) {
        run {
            guard path.hasPrefix("/") else { throw WorkbenchError(L("请输入远端项目的绝对路径。")) }
            let data = try await self.ssh(RemoteSetup.directoryListCommand(path))
            try Task.checkCancellation()
            self.folders = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
            self.browsingDirectory = path
        }
    }
    func verifyProject() {
        run {
            self.verifiedDirectory = nil
            guard self.directory.hasPrefix("/"), !self.directory.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
                throw WorkbenchError(L("请输入远端项目的绝对路径。"))
            }
            self.hint = L("请输入远端已存在且当前用户可访问的目录。")
            _ = try await self.ssh("test -d " + SSHCommand.quote(self.directory) + " && test -x " + SSHCommand.quote(self.directory))
            try Task.checkCancellation()
            self.verifiedDirectory = self.directory; self.hint = ""
        }
    }
    /// Shared installer: no provider argument updates every component (service,
    /// workers and all SDKs); the settings sheet keeps its per-provider install.
    static func runBridgeInstaller(destination: String, provider: SessionKind? = nil) async throws {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("RemoteSetup"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/install-native-service.sh").path) else {
            throw WorkbenchError(L("此构建缺少安装组件。请使用 scripts/build.sh 打包的 Perch.app。"))
        }
        try SSHCommand.validateDestination(destination)
        var arguments = [root.appendingPathComponent("scripts/install-native-service.sh").path, destination]
        if let provider { arguments.append("--provider=" + provider.rawValue) }
        _ = try await SetupCommandRunner.run("/bin/bash", arguments, timeout: 180)
    }
    func installBridge() {
        run {
            try await Self.runBridgeInstaller(destination: self.destination, provider: self.provider)
            try Task.checkCancellation()
            self.hint = L("组件已安装。请重新检查；Perch 会在旧服务空闲时自动安全重启，且不会中断运行中的任务。")
        }
    }
    func openInstallTerminal() {
        guard let command = installCommand else { return }
        launchTerminal(command: command, awaitingInstall: true)
    }
    func openTerminal(command: String? = nil) {
        launchTerminal(command: command, awaitingInstall: false)
    }
    private func launchTerminal(command: String?, awaitingInstall: Bool) {
        do {
            let shell = try RemoteSetup.terminalCommand(destination: destination, command: command)
            let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            run {
                _ = try await SetupCommandRunner.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\"\nactivate\ndo script \"\(literal)\"\nend tell"])
                try Task.checkCancellation()
                if awaitingInstall {
                    self.awaitingInstallCheck = true
                    self.hint = L("终端安装完成后，返回此处选择“已安装，重新检查”。")
                } else {
                    self.hint = L("在终端完成操作后，返回 Perch 重新检查。")
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
