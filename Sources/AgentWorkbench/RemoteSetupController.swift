import AppKit
import Combine
import WorkbenchCore

@MainActor
final class RemoteSetupController: ObservableObject {
    enum Step: Int, CaseIterable { case machine, agent, project }
    enum Status: Equatable { case waiting, checking, passed, needsAction, information }
    struct Check: Identifiable {
        let id: String
        var title: String
        var status: Status = .waiting
        var detail = ""
    }
    @Published var step = Step.machine
    @Published var destination: String
    @Published var name: String
    @Published var provider: SessionKind
    @Published var enabledAgents: Set<SessionKind>
    @Published var port: String
    @Published var tokenPath: String
    @Published var directory = ""
    @Published var modelID = ""
    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var checks: [Check] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
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
    private var kimi: KimiConnection?
    private var native: NativeAgentConnection?
    private var terminal: HostConnection?

    init(host: SSHHost? = nil) {
        original = host; hostID = host?.id ?? UUID()
        destination = host?.destination ?? ""; name = host?.name ?? ""
        provider = host?.enabledAgents.first ?? .kimi
        enabledAgents = Set(host?.enabledAgents ?? [])
        port = String(host?.kimiPort ?? 58627); tokenPath = host?.kimiTokenPath ?? "~/.kimi-code/server.token"
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        if let text = try? String(contentsOf: config, encoding: .utf8) { aliases = RemoteSetup.sshAliases(text) }
    }
    var host: SSHHost {
        SSHHost(id: hostID, name: name.isEmpty ? destination : name, destination: destination,
                enabledAgents: RemoteSetup.agents.filter { enabledAgents.contains($0) || $0 == provider },
                kimiPort: Int(port) ?? 0, kimiTokenPath: tokenPath)
    }
    var needsBridge: Bool { [.omp, .qoder, .dsh, .codex].contains(provider) }
    var canContinue: Bool { ready && !busy }
    var canFinish: Bool { projectVerified && ready && !busy }
    var launch: TaskLaunchDefaults { TaskLaunchDefaults(hostID: hostID, provider: provider, directory: directory, model: modelID) }
    var installURL: URL {
        switch provider {
        case .kimi: return URL(string: "https://moonshotai.github.io/kimi-code/en/guides/getting-started.html")!
        case .omp: return URL(string: "https://github.com/can1357/oh-my-pi#install")!
        case .qoder: return URL(string: "https://docs.qoder.cn/cli/installation")!
        case .dsh: return URL(string: "https://github.com/deepseek-ai/deepseek-harness")!
        case .codex: return URL(string: "https://github.com/openai/codex#installation")!
        case .terminal: return URL(string: "https://github.com/herdrdev/herdr")!
        }
    }
    var installCommand: String? {
        switch provider {
        case .kimi: return "npm install -g @moonshot-ai/kimi-code@2.0.2"
        case .omp: return "bun install -g @oh-my-pi/pi-coding-agent@18.1.16"
        case .qoder: return "npm install -g @qodercn-ai/qoderclicn@1.1.58"
        case .codex: return "npm install -g @openai/codex@0.155.1"
        case .dsh, .terminal: return nil
        }
    }
    var loginCommand: String {
        switch provider {
        case .kimi: return "kimi"
        case .omp: return "omp"
        case .qoder: return "qoderclicn"
        case .codex: return "codex login"
        case .dsh: return "" // The user's shell/profile owns DEEPSEEK_API_KEY.
        case .terminal: return "herdr"
        }
    }
    func invalidateAgent() {
        cancel(); ready = false; verifiedDirectory = nil; checks = []; models = []; modelID = ""
        error = nil; hint = ""; failedCheck = nil
    }
    func invalidateProject() { error = nil }
    func back() {
        cancel(); error = nil; hint = ""; failedCheck = nil
        if step == .project { step = .agent; verifiedDirectory = nil }
        else { step = .machine; ready = false; checks = [] }
    }
    func cancel() {
        task?.cancel(); task = nil; disconnectProbes(); busy = false
    }
    private func disconnectProbes() {
        kimi?.disconnect(); native?.disconnect(); terminal?.disconnect()
        kimi = nil; native = nil; terminal = nil
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
    private func awaitConnection(online: () -> Bool, error: () -> String?) async throws {
        for _ in 0..<350 {
            try Task.checkCancellation()
            if online() { return }
            if let error = error() { throw WorkbenchError(error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkbenchError(L("服务连接超时。检查远端服务是否正在运行，以及 SSH 是否允许端口转发。"))
    }
    func checkAgent() {
        run {
            self.ready = false; self.verifiedDirectory = nil; self.disconnectProbes(); self.models = []
            try RemoteSetup.validate(self.host)
            self.checks = [Check(id: "runtime", title: L("运行环境")), Check(id: "service", title: L("服务连接")), Check(id: "models", title: L("模型与登录"))]
            defer { if !Task.isCancelled { self.disconnectProbes() } }
            if self.provider == .kimi { try await self.checkKimi() }
            else if self.provider == .terminal { try await self.checkTerminal() }
            else { try await self.checkNative() }
            try Task.checkCancellation()
            self.ready = true
        }
    }
    private func checkKimi() async throws {
        mark("runtime", .checking)
        hint = L("安装 Kimi，并确保非交互 SSH 可以运行 kimi --version。")
        let version = try await ssh("command -v kimi >/dev/null && kimi --version")
        try Task.checkCancellation()
        mark("runtime", .passed, String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        mark("service", .checking)
        hint = L("启动 Kimi Web 后重新检查；已有服务请核对高级设置中的端口与令牌路径。")
        let connection = KimiConnection(setupHost: host); kimi = connection; connection.connect()
        try await awaitConnection(online: { connection.online }, error: { connection.error })
        mark("service", .passed, "127.0.0.1:\(host.kimiPort)")
        mark("models", .checking)
        models = ModelCatalog.options(connection.models)
        hint = L("在远端 Kimi 中完成登录并配置模型，然后重新检查。")
        guard !models.isEmpty else { throw WorkbenchError(L("Kimi 服务可用，但没有已配置的模型。")) }
        if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
        mark("models", .passed, L("模型列表已读取；实际模型鉴权将在首条消息时验证。"))
        hint = ""
    }
    private func checkNative() async throws {
        mark("runtime", .checking)
        hint = L("远端需要 Python 3；Qoder 还需要 Node.js 与 npm。")
        _ = try await ssh(provider == .qoder ? "python3 --version && node --version" : "python3 --version")
        try Task.checkCancellation()
        mark("runtime", .passed)
        mark("service", .checking)
        hint = L("安装或更新 Perch 桥接组件后重新检查。空闲的旧服务会自动安全重启；有任务运行时会等待任务结束。")
        _ = try await ssh("test -f ~/.local/share/agent-workbench/native/native-agent-service.py")
        try Task.checkCancellation()
        let connection = NativeAgentConnection(setupHost: host); native = connection; connection.connect()
        try await awaitConnection(online: { connection.online }, error: { connection.error })
        let status = try await connection.setupStatus(provider: provider)
        try Task.checkCancellation()
        mark("service", .passed)
        mark("models", .checking)
        hint = L("在远端安装所选 Agent、完成登录和模型配置，然后重新检查。")
        guard status["installed"] == .bool(true) else {
            mark("models", .waiting); mark("runtime", .needsAction); failedCheck = "runtime"
            throw WorkbenchError(L("未找到可运行的 Agent。安装后请确认 SSH 命令可以读取其版本。"))
        }
        mark("runtime", .passed, status["version"].string ?? "")
        if let message = status["error"].string { throw WorkbenchError(message) }
        switch provider {
        case .omp:
            let entries = ModelSelectionCatalog.parseOMP(status["models"])
            models = entries.map { ModelOption(id: $0.provider + "/" + $0.id, provider: $0.provider, name: $0.name) }
            guard !models.isEmpty else { throw WorkbenchError(L("OMP 未返回模型。请在远端配置模型后重试。")) }
            mark("models", .passed, L("模型列表已读取；实际模型鉴权将在首条消息时验证。"))
        case .qoder:
            guard status["sdkInstalled"] == .bool(true), status["nodeInstalled"] == .bool(true) else {
                mark("service", .needsAction); failedCheck = "service"
                throw WorkbenchError(L("缺少 Qoder SDK 或 Node.js。请安装桥接组件和 Node.js 后重试。"))
            }
            mark("models", .information, L("Qoder 使用远端 CLI 登录与默认模型；SDK 在首条消息时验证登录。"))
        case .dsh:
            guard status["credentialCheck"].string == "present" else {
                throw WorkbenchError(L("桥接进程未读取到 DEEPSEEK_API_KEY。请在远端配置服务环境；若桥已运行，等任务结束后重启再检查。"))
            }
            mark("models", .information, L("已检测到远端凭据；模型目录在首次 ACP 会话握手时读取，鉴权在发送时验证。"))
        case .codex:
            guard status["credentialCheck"].string == "present" else {
                throw WorkbenchError(L("Codex CLI 尚未登录。请在远端运行 codex login 后重试。"))
            }
            models = status["models"].array.compactMap { entry in
                guard let id = entry["id"].string else { return nil }
                return ModelOption(id: id, provider: "codex", name: entry["name"].string ?? id)
            }
            guard !models.isEmpty else { throw WorkbenchError(L("Codex app-server 未返回模型。请检查远端 Codex 安装与登录。")) }
            if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
            mark("models", .passed, L("已确认 Codex 登录并读取 app-server 模型目录；检查未发送任务。"))
        default: break
        }
        hint = ""
    }
    private func checkTerminal() async throws {
        mark("runtime", .checking)
        hint = L("请在远端安装并启动 Herdr，然后重新检查。")
        _ = try await ssh("herdr --version")
        try Task.checkCancellation(); mark("runtime", .passed); mark("service", .checking)
        let connection = HostConnection(host: host); terminal = connection; connection.connect()
        try await awaitConnection(online: { connection.online }, error: { connection.error })
        mark("service", .passed)
        mark("models", .information, L("终端中的 Agent 与模型由你使用的 CLI 管理。")); hint = ""
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
    func startKimi() {
        run {
            try RemoteSetup.validate(self.host)
            _ = try await self.ssh(RemoteSetup.kimiStartCommand(port: self.host.kimiPort))
            try Task.checkCancellation()
            self.hint = L("启动命令已提交。请重新检查连接；启动日志位于远端 ~/.local/state/perch/kimi-web.log。")
        }
    }
    func installBridge() {
        run {
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("RemoteSetup"),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/install-native-service.sh").path) else {
                throw WorkbenchError(L("此构建缺少安装组件。请使用 scripts/build.sh 打包的 Perch.app。"))
            }
            try SSHCommand.validateDestination(self.destination)
            let arguments = [root.appendingPathComponent("scripts/install-native-service.sh").path, self.destination, "--provider=" + self.provider.rawValue]
            _ = try await SetupCommandRunner.run("/bin/bash", arguments, timeout: 180)
            try Task.checkCancellation()
            self.hint = L("组件已安装。请重新检查；Perch 会在旧服务空闲时自动安全重启，且不会中断运行中的任务。")
        }
    }
    func openTerminal(command: String? = nil) {
        do {
            let shell = try RemoteSetup.terminalCommand(destination: destination, command: command)
            let literal = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            run {
                _ = try await SetupCommandRunner.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\"\nactivate\ndo script \"\(literal)\"\nend tell"])
                try Task.checkCancellation()
                self.hint = L("在终端完成操作后，返回 Perch 重新检查。")
            }
        } catch { self.error = error.localizedDescription }
    }
}
