import AppKit
import SwiftUI
import WorkbenchCore

/// Read-only remote file viewing for the current session's SSH host. Every read is a
/// fresh BatchMode ssh invocation using the user's existing configuration and
/// host-key checking; nothing is installed, executed or written on the remote.
enum RemotePanelMode: String, CaseIterable, Identifiable {
    case file, git
    var id: String { rawValue }
    var label: String { self == .file ? "文件" : "Git 变更" }
}

@MainActor
final class RemoteFileBrowser: ObservableObject {
    @Published private(set) var host: SSHHost?
    @Published private(set) var cwd = ""
    @Published var input = ""
    @Published private(set) var path = ""
    @Published private(set) var content: RemoteFileContent?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var showLineNumbers = false
    @Published var targetLine: Int?
    @Published var mode: RemotePanelMode = .file
    @Published private(set) var gitStatus: RemoteGitStatus?
    @Published private(set) var gitPath: String?
    @Published private(set) var gitDiff: RemoteGitDiff?
    @Published private(set) var gitDirectory = ""
    @Published private(set) var gitWorktrees: [RemoteGitWorktree] = []
    @Published var gitInput = ""
    @Published var gitStaged = false
    /// Directories the agent recently touched (worktrees included), most recent
    /// first. Both conversation file resolution and the Git tab start from these.
    private var directoryHints: [String] = []
    private var gitSelectionExplicit = false
    private var generation = 0
    private var reader: RemoteReader?
    private var task: Task<Void, Never>?

    var hostName: String { host?.name ?? "未选择主机" }

    /// Switching sessions must never leave another host's path or content on screen.
    func configure(host: SSHHost?, cwd: String, directoryHints: [String] = []) {
        guard self.host?.id != host?.id || self.cwd != cwd else {
            self.directoryHints = directoryHints
            return
        }
        cancel()
        self.host = host
        self.cwd = cwd
        self.directoryHints = directoryHints
        input = ""
        path = ""
        content = nil
        error = nil
        gitStatus = nil
        gitPath = nil
        gitDiff = nil
        gitDirectory = ""
        gitWorktrees = []
        gitInput = cwd
        gitSelectionExplicit = false
        targetLine = nil
    }

    func submit() { open(input) }

    func open(_ requested: String, line: Int? = nil, fromConversation: Bool = false) {
        targetLine = line
        mode = .file
        guard let host else { error = "当前会话没有可用的执行环境。"; return }
        let resolved: String
        let command: String
        do {
            if !host.isLocal { try SSHCommand.validateDestination(host.destination) }
            if fromConversation {
                command = try RemoteFileCommand.referenceCommand(path: requested, cwd: cwd,
                                                                 roots: directoryHints)
                resolved = (try? RemoteFilePath.resolve(requested, cwd: cwd)) ?? requested
            } else {
                resolved = try RemoteFilePath.resolve(requested, cwd: cwd)
                command = RemoteFileCommand.remoteCommand(path: resolved)
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        cancel()
        generation += 1
        let token = generation
        path = resolved
        input = resolved
        loading = true
        error = nil
        run(command, destination: host.destination, token: token) { browser, data in
            let content = try RemoteFileCommand.parse(data)
            // A multi-root lookup can read outside the session directory; display
            // the path the remote actually read, not the requested guess.
            if let actual = RemoteFileCommand.resolvedPath(in: data) {
                browser.path = actual
                browser.input = actual
            }
            if case .matches(let paths) = content, paths.count == 1 {
                browser.open(paths[0], line: line)
            } else {
                browser.content = content
            }
        } failed: { browser in
            browser.content = nil
        }
    }

    func loadGitStatus() {
        guard host != nil else { error = "当前会话没有可用的执行环境。"; return }
        if !gitDirectory.isEmpty {
            loadGitStatus(directories: [gitDirectory], allowSuggestion: false)
            return
        }
        var candidates = directoryHints
        candidates.append(cwd)
        candidates = candidates.filter { !$0.isEmpty }.reduce(into: []) { values, value in
            if !values.contains(value) { values.append(value) }
        }
        guard !candidates.isEmpty else { error = "当前会话没有工作目录。"; return }
        loadGitStatus(directories: candidates, allowSuggestion: !gitSelectionExplicit)
    }

    func submitGitDirectory() {
        let resolved: String
        do { resolved = try RemoteFilePath.resolve(gitInput, cwd: cwd) }
        catch { self.error = error.localizedDescription; return }
        gitSelectionExplicit = true
        gitDirectory = resolved
        loadGitStatus(directories: [resolved], allowSuggestion: false)
    }

    func selectGitWorktree(_ directory: String) {
        guard gitWorktrees.contains(where: { $0.path == directory && $0.selectable }) else { return }
        gitSelectionExplicit = true
        gitDirectory = directory
        gitInput = directory
        loadGitStatus(directories: [directory], allowSuggestion: false)
    }

    private func loadGitStatus(directories: [String], allowSuggestion: Bool) {
        guard let host else { return }
        cancel()
        generation += 1
        let token = generation
        loading = true
        error = nil
        gitPath = nil
        gitDiff = nil
        run(RemoteGitCommand.statusCommand(directories: directories), destination: host.destination, token: token) { browser, data in
            let status = try RemoteGitCommand.parseStatus(data)
            if allowSuggestion, let suggested = browser.suggestedWorktree(in: status.worktrees),
               suggested.path != status.root {
                browser.gitDirectory = suggested.path
                browser.gitInput = suggested.path
                browser.loadGitStatus(directories: [suggested.path], allowSuggestion: false)
                return
            }
            browser.gitStatus = status
            browser.gitWorktrees = status.worktrees
            if let root = status.root {
                browser.gitDirectory = root
                browser.gitInput = root
            } else {
                browser.gitWorktrees = []
            }
        } failed: { browser in
            browser.gitStatus = nil
        }
    }

    private func suggestedWorktree(in worktrees: [RemoteGitWorktree]) -> RemoteGitWorktree? {
        for hint in directoryHints {
            let path = (hint as NSString).standardizingPath
            let matches = worktrees.filter { worktree in
                guard worktree.selectable else { return false }
                let root = (worktree.path as NSString).standardizingPath
                return path == root || path.hasPrefix(root == "/" ? root : root + "/")
            }
            if let match = matches.max(by: { $0.path.count < $1.path.count }) { return match }
        }
        return nil
    }

    func loadGitDiff(_ entry: RemoteGitEntry) {
        guard let host, let root = gitStatus?.root else { return }
        cancel()
        generation += 1
        let token = generation
        gitPath = entry.path
        loading = true
        error = nil
        // An untracked file has no tracked diff; show its contents instead of
        // presenting an empty diff as if nothing changed.
        guard !entry.untracked else {
            loading = false
            gitDiff = .untracked
            return
        }
        let staged = gitStaged
        run(RemoteGitCommand.diffCommand(directory: root, path: entry.path, staged: staged),
            destination: host.destination, token: token) { browser, data in
            browser.gitDiff = try RemoteGitCommand.parseDiff(data)
        } failed: { browser in
            browser.gitDiff = nil
        }
    }

    /// Switching between staged and unstaged re-reads the same file rather than
    /// leaving the previous range's diff on screen under the new label.
    func reloadGitDiff() {
        guard case .changes(_, _, let entries) = gitStatus, let path = gitPath,
              let entry = entries.first(where: { $0.path == path }) else { return }
        loadGitDiff(entry)
    }

    private func run(_ command: String, destination: String, token: Int,
                     apply: @escaping (RemoteFileBrowser, Data) throws -> Void,
                     failed: @escaping (RemoteFileBrowser) -> Void) {
        let session = RemoteReader(local: host?.isLocal == true)
        reader = session
        task = Task { [weak self] in
            let result = await session.run(command: command, destination: destination)
            guard let self, token == self.generation else { return }
            self.loading = false
            self.reader = nil
            switch result {
            case .success(let data):
                do { try apply(self, data) } catch { failed(self); self.error = error.localizedDescription }
            case .failure(let failure):
                failed(self)
                self.error = failure.localizedDescription
            }
        }
    }

    /// Bumping the generation drops any in-flight response, and terminating the
    /// process stops a slow read instead of leaving it running in the background.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        reader?.terminate()
        reader = nil
        loading = false
    }

    func openParent() {
        guard let parent = RemoteFilePath.parent(of: path) else { return }
        open(parent)
    }
}

/// Owns one ssh process so a pending read can actually be stopped.
private final class RemoteReader: @unchecked Sendable {
    private let local: Bool
    init(local: Bool = false) { self.local = local }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func terminate() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    func run(command: String, destination: String) async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.execute(command: command, destination: destination))
            }
        }
    }

    private func execute(command: String, destination: String) -> Result<Data, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: local ? "/bin/sh" : "/usr/bin/ssh")
        process.arguments = local ? ["-c", command] : RemoteGitCommand.sshArguments(destination: destination, command: command)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); return .failure(WorkbenchError("已取消读取。")) }
        self.process = process
        lock.unlock()
        do { try process.run() } catch { return .failure(error) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        self.process = nil
        lock.unlock()
        if wasCancelled { return .failure(WorkbenchError("已取消读取。")) }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: failure, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(WorkbenchError(message.isEmpty ? "远端连接失败或已断开。" : message))
        }
        return .success(data)
    }
}

/// Monospaced diff with added/removed lines tinted. Colour is supplementary: the
/// original +/- markers stay in the text so the diff is readable without it.
private struct DiffText: View {
    let diff: String
    init(_ diff: String) { self.diff = diff }
    var body: some View {
        SelectableReplyText(attributed: Self.attributed(diff))
    }
    static func attributed(_ diff: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let colour: NSColor
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                colour = .secondaryLabelColor
            } else if line.hasPrefix("@@") {
                colour = WorkbenchTheme.diffHunk
            } else if line.hasPrefix("+") {
                colour = WorkbenchTheme.diffAdded
            } else if line.hasPrefix("-") {
                colour = WorkbenchTheme.diffRemoved
            } else {
                colour = ReplyStyle.nativeInk
            }
            result.append(NSAttributedString(string: String(line) + "\n", attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}

struct RemoteFilePanel: View {
    @ObservedObject var browser: RemoteFileBrowser
    var fullWidth = false
    var onToggleWidth: (() -> Void)? = nil
    var onAddContext: ((String) -> Void)? = nil
    let onClose: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var feedbackContext: ReviewContext?
    @State private var feedback = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("文件").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if let onToggleWidth {
                    Button(action: onToggleWidth) {
                        Image(systemName: fullWidth ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(fullWidth ? L("恢复并排布局") : L("全宽审阅"))
                }
                Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭文件面板")
            }.padding(.horizontal, 14).frame(height: WorkbenchChrome.headerHeight)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("\(browser.hostName)\(browser.cwd.isEmpty ? "" : " · \(browser.cwd)")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("在当前执行环境中只读查看文件。")
                Picker("", selection: $browser.mode) {
                    ForEach(RemotePanelMode.allCases) { mode in Text(mode.label).tag(mode) }
                }.pickerStyle(.segmented).labelsHidden()
                    .onChange(of: browser.mode) { _, mode in
                        if mode == .git, browser.gitStatus == nil { browser.loadGitStatus() }
                    }
                if browser.mode == .file {
                    HStack(spacing: 7) {
                        TextField("文件路径，可用绝对路径或相对当前目录", text: $browser.input)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit { browser.submit() }
                        if browser.loading {
                            Button("取消") { browser.cancel() }.controlSize(.small)
                        } else {
                            Button("打开") { browser.submit() }.controlSize(.small)
                                .disabled(browser.input.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if !browser.path.isEmpty {
                        HStack(spacing: 7) {
                            Button { browser.openParent() } label: { Image(systemName: "arrow.up").font(.system(size: 10)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("上一级目录")
                                .disabled(RemoteFilePath.parent(of: browser.path) == nil)
                            Text(browser.path).font(.system(size: 11, design: .monospaced))
                                .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        TextField("Git 仓库或 worktree 目录", text: $browser.gitInput)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .onSubmit { browser.submitGitDirectory() }
                        if browser.loading {
                            Button("取消") { browser.cancel() }.controlSize(.small)
                        } else {
                            let changed = browser.gitInput != browser.gitDirectory
                            Button(changed ? "载入" : "刷新") {
                                if changed { browser.submitGitDirectory() } else { browser.loadGitStatus() }
                            }.controlSize(.small)
                                .disabled(browser.gitInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if !browser.gitWorktrees.isEmpty {
                        HStack(spacing: 7) {
                            Text("工作树").font(.system(size: 11)).foregroundStyle(.secondary)
                            Picker("工作树", selection: Binding(
                                get: { browser.gitDirectory },
                                set: { browser.selectGitWorktree($0) }
                            )) {
                                ForEach(browser.gitWorktrees) { worktree in
                                    Text(worktreeLabel(worktree)).tag(worktree.path).disabled(!worktree.selectable)
                                }
                            }.pickerStyle(.menu).labelsHidden().help(browser.gitDirectory)
                        }
                    }
                    HStack(spacing: 7) {
                        Picker("", selection: $browser.gitStaged) {
                            Text("未暂存").tag(false)
                            Text("已暂存").tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                            .onChange(of: browser.gitStaged) { _, _ in browser.reloadGitDiff() }
                    }
                    Text("只读：仅执行 worktree list、status 与 diff，不做任何写操作。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if onAddContext != nil {
                HStack(spacing: 12) {
                    Button("引用文件") { if let context = context(selection: NSRange(location: 0, length: 0)) { onAddContext?(context.prompt()) } }
                        .disabled(!hasContext || browser.loading || browser.error != nil)
                    Button("反馈选中代码…") {
                        feedback = ""; feedbackContext = context(selection: selection)
                    }.disabled(selection.length == 0 || browser.loading || browser.error != nil)
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.background(WorkbenchTheme.contentBackground)
            .onChange(of: browser.loading) { _, loading in if loading { selection = NSRange(location: 0, length: 0) } }
            .onChange(of: browser.mode) { _, _ in selection = NSRange(location: 0, length: 0) }
            .sheet(item: $feedbackContext) { context in
                VStack(alignment: .leading, spacing: 12) {
                    Text("代码反馈").font(.headline)
                    Group {
                        Text(context.reference).font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView { Text(context.excerpt).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                    }
                    TextField("希望如何修改？", text: $feedback, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                    Text("加入当前任务草稿，检查后再发送。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("取消") { feedbackContext = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("加入草稿") {
                            onAddContext?(context.prompt(feedback: feedback))
                            feedbackContext = nil
                        }.disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(20).frame(width: 520)
            }
    }

    @ViewBuilder private var content: some View {
        if browser.mode == .git { gitContent } else { fileContent }
    }

    @ViewBuilder private var gitContent: some View {
        if let error = browser.error {
            notice(error, symbol: "exclamationmark.triangle", tint: .orange)
        } else if browser.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取…").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch browser.gitStatus {
            case .notARepository:
                notice("所选目录不是可用的 Git 工作树。", symbol: "questionmark.folder", tint: .secondary)
            case .clean:
                notice("所选工作树干净，没有未提交的改动。", symbol: "checkmark.circle", tint: .secondary)
            case .changes(_, _, let entries):
                VSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(entries) { entry in
                                Button { browser.loadGitDiff(entry) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path)
                                            .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        Text(entry.label).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
                                        .background(entry.path == browser.gitPath ? Color.primary.opacity(0.05) : .clear)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 8)
                    }.frame(minHeight: 80, idealHeight: min(220, Double(entries.count) * 42 + 16), maxHeight: 220)
                    diffPane
                }
            case nil:
                notice("读取当前项目 Git 工作树的改动。", symbol: "arrow.triangle.branch", tint: .secondary)
            }
        }
    }

    @ViewBuilder private var diffPane: some View {
        switch browser.gitDiff {
        case .text(let diff, let truncated):
            VStack(alignment: .leading, spacing: 0) {
                if truncated {
                    Label("差异过大，已截断", systemImage: "scissors")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    Divider()
                }
                RemoteSourceText(text: diff, line: nil, diff: true, onSelection: { selection = $0 })
                    .id("diff:\(browser.gitDirectory):\(browser.gitPath ?? ""):\(browser.gitStaged)")
            }
        case .binary: notice("二进制文件差异，不做预览。", symbol: "doc.zipper", tint: .secondary)
        case .empty: notice("该文件在当前范围内没有差异。", symbol: "equal.circle", tint: .secondary)
        case .untracked: notice("未跟踪文件，没有 tracked diff；可在「文件」页查看内容。", symbol: "plus.circle", tint: .secondary)
        case .notARepository: notice("所选工作树不再是 Git 仓库。", symbol: "questionmark.folder", tint: .secondary)
        case nil: notice("选择一个文件查看差异。", symbol: "doc.text.magnifyingglass", tint: .secondary)
        }
    }

    @ViewBuilder private var fileContent: some View {
        if let error = browser.error {
            notice(error, symbol: "exclamationmark.triangle", tint: .orange)
        } else if browser.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取…").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch browser.content {
            case .matches(let paths):
                VStack(alignment: .leading, spacing: 8) {
                    Text("找到多个同名文件，请选择：")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 14)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(paths, id: \.self) { path in
                                Button { browser.open(path, line: browser.targetLine) } label: {
                                    Text(path).font(.system(size: 12, design: .monospaced))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.vertical, 8)
            case .directory(let entries):
                if entries.isEmpty { notice("空目录。", symbol: "folder", tint: .secondary) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(entries) { entry in
                                Button { browser.open(RemoteFilePath.child(browser.path, entry.name)) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                                        Text(entry.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }.padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 8)
                    }
                }
            case .text(let text, let truncated, let size):
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(byteLabel(size)).font(.system(size: 11)).foregroundStyle(.secondary)
                        if let line = browser.targetLine {
                            Text(line <= text.split(separator: "\n", omittingEmptySubsequences: false).count ? "Line \(line)" : "Line \(line) is outside the loaded content")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if truncated {
                            Label("已截断，仅显示前 1 MiB", systemImage: "scissors")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                        Toggle("行号", isOn: $browser.showLineNumbers).toggleStyle(.checkbox).font(.system(size: 11))
                    }.padding(.horizontal, 14).padding(.vertical, 7)
                    Divider()
                    RemoteSourceText(text: text, line: browser.targetLine, numbered: browser.showLineNumbers, onSelection: { selection = $0 }).id(browser.path)

                }
            case .binary(let size):
                notice("这是二进制文件（\(byteLabel(size))），不做预览。", symbol: "doc.zipper", tint: .secondary)
            case .denied:
                notice("没有读取权限。", symbol: "lock", tint: .orange)
            case .missing:
                notice("路径不存在。", symbol: "questionmark.folder", tint: .orange)
            case nil:
                notice("输入文件路径后打开。只读查看，不修改文件。", symbol: "doc.text", tint: .secondary)
            }
        }
    }

    private func worktreeLabel(_ worktree: RemoteGitWorktree) -> String {
        let directory = (worktree.path as NSString).lastPathComponent
        let revision = worktree.branchName ?? (worktree.detached ? "detached \(worktree.head.prefix(8))" : "无分支")
        var states: [String] = []
        if worktree.current { states.append("当前") }
        if worktree.locked { states.append("已锁定") }
        if worktree.prunable { states.append("不可用") }
        if worktree.bare { states.append("bare") }
        let suffix = states.isEmpty ? "" : " · " + states.joined(separator: " · ")
        return "\(revision) · \(directory)\(suffix)"
    }

    private var hasContext: Bool {
        if browser.mode == .git { if case .text = browser.gitDiff { return true }; return false }
        if case .text = browser.content { return true }; return false
    }
    private var contextPath: String? {
        if browser.mode == .git {
            guard let path = browser.gitPath else { return nil }
            return (browser.gitDirectory as NSString).appendingPathComponent(path)
        }
        guard case .text = browser.content else { return nil }
        return browser.path
    }
    private func context(selection: NSRange) -> ReviewContext? {
        guard let path = contextPath else { return nil }
        if browser.mode == .git {
            guard case .text(let diff, _) = browser.gitDiff else { return nil }
            return ReviewContext(path: path, text: diff, selection: selection, diff: true,
                scope: "\(browser.hostName) · \(browser.gitStaged ? "staged" : "unstaged")")
        }
        guard case .text(let text, let truncated, _) = browser.content else { return nil }
        return ReviewContext(path: path, text: text, selection: selection,
            scope: "\(browser.hostName) · \(truncated ? "loaded file prefix" : "file")")
    }
    private func byteLabel(_ size: Int) -> String {
        size < 1024 ? "\(size) 字节" : size < 1_048_576
            ? String(format: "%.1f KiB", Double(size) / 1024)
            : String(format: "%.1f MiB", Double(size) / 1_048_576)
    }
    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RemoteSourceText: NSViewRepresentable {
    let text: String
    let line: Int?
    var diff = false
    var numbered = false
    var onSelection: ((NSRange) -> Void)? = nil
    final class Coordinator: NSObject, NSTextViewDelegate {
        var rendered = ""
        var source = ""
        var line: Int?
        var onSelection: ((NSRange) -> Void)?
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = ReviewContext.sourceSelection(in: source, rendered: rendered, selection: view.selectedRange())
            let callback = onSelection
            DispatchQueue.main.async { callback?(range) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true
        view.identifier = NSUserInterfaceItemIdentifier("PerchReviewSource")
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.onSelection = onSelection
        let rendered = numbered ? text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { "\($0.offset + 1) │ \($0.element)" }.joined(separator: "\n") : text
        guard context.coordinator.rendered != rendered || context.coordinator.line != line else { return }
        context.coordinator.rendered = rendered; context.coordinator.source = text; context.coordinator.line = line
        if diff { view.textStorage?.setAttributedString(DiffText.attributed(text)) }
        else { view.string = rendered }
        view.sizeToFit()
        guard let line, let range = RemoteFileContent.lineRange(in: rendered, line: line) else {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
            return
        }
        view.setSelectedRange(range)
        DispatchQueue.main.async {
            guard context.coordinator.rendered == rendered, context.coordinator.line == line else { return }
            view.scrollRangeToVisible(range)
        }
    }
}
