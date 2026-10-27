import AppKit
import SwiftUI
import Observation
import WorkbenchCore

/// Read-only remote file viewing for the current session's SSH host. Every read is a
/// fresh BatchMode ssh invocation using the user's existing configuration and
/// host-key checking; nothing is installed, executed or written on the remote.
enum RemotePanelMode: String, CaseIterable, Identifiable {
    case file, git
    var id: String { rawValue }
    var label: LocalizedStringKey { self == .file ? "文件" : "Git 变更" }
}

struct DocumentLibraryActions {
    let pinned: Bool
    let togglePin: () -> Void
}

enum GitReviewRange: String { case unstaged, staged, branch }

struct FileReadRequest: Equatable {
    let id = UUID()
    let command: String
    let destination: String
    let local: Bool
    let path: String
    let limit: Int
    let fromEnd: Bool
    let source: SessionReference?
}

@MainActor @Observable
final class RemoteFileBrowser {
    private(set) var host: SSHHost?
    private(set) var cwd = ""
    var source: SessionReference?
    var input = ""
    private(set) var path = ""
    private(set) var content: RemoteFileContent?
    private(set) var loading = false
    var error: String?
    var showLineNumbers = false
    var targetLine: Int?
    var lineNavigation = 0
    var mode: RemotePanelMode = .file
    private(set) var gitStatus: RemoteGitStatus?
    private(set) var gitPath: String?
    private(set) var gitDiff: RemoteGitDiff?
    private(set) var gitDirectory = ""
    private(set) var gitWorktrees: [RemoteGitWorktree] = []
    var gitInput = ""
    var gitRange: GitReviewRange = .unstaged
    var gitBaseInput = ""
    private(set) var gitComparison: RemoteGitComparison?
    private(set) var gitRefs: [String] = []
    private(set) var reviewProgress = GitReviewProgress()
    var gitStaged: Bool { gitRange == .staged }
    /// Directories the agent recently touched (worktrees included), most recent
    /// first. Both conversation file resolution and the Git tab start from these.
    private var directoryHints: [String] = []
    private var gitSelectionExplicit = false
    private var generation = 0
    @ObservationIgnored private var reader: RemoteReader?
    @ObservationIgnored private var task: Task<Void, Never>?

    let documents = FileWorkspaceState()
    let reading = DocumentReadingState()
    private(set) var fileRequest: FileReadRequest?
    private(set) var completedFileReadID: UUID?
    private(set) var previewData: Data?
    private(set) var readLimit = RemoteFileCommand.readLimit
    private(set) var readingTail = false
    var documentAnchor: String?
    var documentNavigation = 0
    private(set) var modifiedAt: Double?
    var findQuery = ""
    var findIndex = 0
    var previewKind: FilePreviewKind { FilePreviewKind(path: path) }

    var hasLoadedDocument: Bool {
        guard mode == .file, !loading, error == nil, previewKind != .source else { return false }
        switch content { case .text, .binary: return true; default: return false }
    }

    var hostName: String { host?.name ?? L("未选择主机") }

    /// The inspector's changes page reads the working tree only: it neither
    /// reopens the file window's document tabs nor restores its review range,
    /// base or branch metadata.
    let workingTreeOnly: Bool

    init(workingTreeOnly: Bool = false) {
        self.workingTreeOnly = workingTreeOnly
    }

    /// Switching sessions must never leave another host's path or content on screen.
    func configure(host: SSHHost?, cwd: String, directoryHints: [String] = []) {
        guard self.host?.id != host?.id || self.cwd != cwd else {
            self.directoryHints = directoryHints
            return
        }
        cancel()
        self.host = host
        self.cwd = cwd
        documents.activate(host: host?.id, cwd: cwd)
        self.directoryHints = directoryHints
        input = ""
        path = ""
        content = nil
        error = nil
        gitStatus = nil
        gitComparison = nil
        gitBaseInput = ""
        gitRefs = []
        reviewProgress = GitReviewProgress()
        gitRange = .unstaged
        gitPath = nil
        gitDiff = nil
        gitDirectory = ""
        gitWorktrees = []
        gitWriteError = nil
        gitBranches = nil
        gitLog = nil
        gitCommitMessage = ""
        gitCommitSheet = nil
        gitCommitDiff = nil
        gitInput = cwd
        gitSelectionExplicit = false
        targetLine = nil
        previewData = nil
        if !workingTreeOnly, let selected = documents.selected { open(selected) }
    }

    func submit() { open(input) }

    func open(_ requested: String, line: Int? = nil, fromConversation: Bool = false,
              limit: Int? = nil, fromEnd: Bool = false, source: SessionReference? = nil, anchor: String? = nil, inheritSource: Bool = true) {
        guard let host else { error = L("当前会话没有可用的执行环境。"); return }
        do {
            if !host.isLocal { try SSHCommand.validateDestination(host.destination) }
            let resolved = try RemoteFilePath.resolve(requested, cwd: cwd)
            let limit = limit ?? FilePreviewKind(path: requested).initialReadLimit
            let command = fromConversation
                ? try RemoteFileCommand.referenceCommand(path: requested, cwd: cwd, roots: directoryHints, limit: limit)
                : RemoteFileCommand.remoteCommand(path: resolved, limit: limit, fromEnd: fromEnd)
            cancel()
            reading.document = nil; reading.notice = nil
            documentAnchor = anchor; documentNavigation += 1; modifiedAt = nil
            mode = .file; path = resolved; input = resolved; targetLine = fromEnd ? nil : line
            content = nil; previewData = nil; error = nil; loading = true
            readLimit = limit; readingTail = fromEnd; findQuery = ""; findIndex = 0
            fileRequest = FileReadRequest(command: command, destination: host.destination, local: host.isLocal,
                                          path: resolved, limit: limit, fromEnd: fromEnd,
                                          source: source ?? (inheritSource ? (documents.tabs.first(where: { $0.path == resolved })?.source ?? self.source) : nil))
            documents.recordVisit(resolved, source: fileRequest?.source)
        } catch { self.error = error.localizedDescription }
    }

    /// The file panel owns the task, so closing it cancels the process as well as
    /// publication. Identity is checked even if a cancelled transport returns late.
    func loadFile(_ request: FileReadRequest) async {
        let reader = RemoteReader(local: request.local)
        let result = await withTaskCancellationHandler {
            await reader.run(command: request.command, destination: request.destination)
        } onCancel: { reader.terminate() }
        guard !Task.isCancelled, fileRequest?.id == request.id else { return }
        loading = false
        do {
            let data = try result.get()
            let value = try RemoteFileCommand.parse(data, limit: request.limit, fromEnd: request.fromEnd)
            let actual = RemoteFileCommand.resolvedPath(in: data) ?? request.path
            path = actual; input = actual
            documents.resolveVisit(request.path, to: actual)
            if case .matches(let paths) = value, paths.count == 1 {
                documents.resolveVisit(actual, to: paths[0]); open(paths[0], line: targetLine, source: request.source); return
            }
            content = value
            modifiedAt = RemoteFileCommand.modifiedAt(in: data)
            switch value {
            case .text, .binary:
                documents.select(actual, source: request.source)
                if targetLine != nil { documents.setReading(false) }
                else if documentAnchor != nil { documents.setReading(true) }
                if FilePreviewKind(path: actual).isBinary { previewData = RemoteFileCommand.body(in: data) }
                completedFileReadID = request.id
            default: break
            }
        } catch { content = nil; previewData = nil; self.error = error.localizedDescription }
    }

    func closeFile(_ path: String) {
        let wasSelected = self.path == path
        let next = documents.close(path)
        guard wasSelected else { return }
        if let next { open(next) }
        else { cancel(); content = nil; previewData = nil; self.path = ""; input = "" }
    }

    func navigateDocument(_ target: String) {
        reading.notice = nil
        switch DocumentLink.resolve(target, relativeTo: path) {
        case .file(let next, let anchor):
            if next == path {
                documentAnchor = anchor ?? ""; documentNavigation += 1; documents.setReading(true)
            } else { open(next, source: documents.current?.source ?? source, anchor: anchor) }
        case .web(let url): NSWorkspace.shared.open(url)
        case .blocked: reading.notice = L("无法打开此文档链接。")
        }
    }
    func navigateHistory(_ delta: Int) {
        if let visit = documents.historyEntry(delta) {
            documents.restoreVisit(visit)
            open(visit.path, source: visit.source, inheritSource: false)
        }
    }

    func selectAdjacentFile(_ delta: Int) {
        let tabs = documents.tabs
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.path == path } ?? 0
        open(tabs[(index + delta + tabs.count) % tabs.count].path)
    }

    func loadGitStatus() {
        guard host != nil else { error = L("当前会话没有可用的执行环境。"); return }
        if !gitDirectory.isEmpty {
            loadGitStatus(directories: [gitDirectory], allowSuggestion: false)
            return
        }
        var candidates = directoryHints
        candidates.append(cwd)
        candidates = candidates.filter { !$0.isEmpty }.reduce(into: []) { values, value in
            if !values.contains(value) { values.append(value) }
        }
        guard !candidates.isEmpty else { error = L("当前会话没有工作目录。"); return }
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
        gitComparison = nil
        gitBranches = nil
        gitLog = nil
        gitCommitSheet = nil
        gitCommitDiff = nil
        gitWriteError = nil
        run(RemoteGitCommand.statusCommand(directories: directories), destination: host.destination, token: token) { browser, data in
            let status = try RemoteGitCommand.parseStatus(data)
            if allowSuggestion, let suggested = browser.suggestedWorktree(in: status.worktrees),
               suggested.path != status.root {
                browser.gitDirectory = suggested.path
                browser.gitInput = suggested.path
                browser.loadGitStatus(directories: [suggested.path], allowSuggestion: false)
                return
            }
            let previousRoot = browser.gitStatus?.root
            browser.gitStatus = status
            browser.gitWorktrees = status.worktrees
            if let root = status.root {
                browser.gitDirectory = root
                browser.gitInput = root
                if previousRoot != root && !browser.workingTreeOnly {
                    browser.gitRefs = []
                    browser.gitBaseInput = UserDefaults.standard.string(forKey: browser.preferenceKey(root: root)) ?? ""
                    if let range = UserDefaults.standard.string(forKey: browser.preferenceKey(root: root) + ".range").flatMap(GitReviewRange.init(rawValue:)) {
                        browser.gitRange = range
                    }
                }
            } else {
                browser.gitWorktrees = []
            }
            if status.root != nil && !browser.workingTreeOnly { browser.loadGitMetadata() }
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

    /// A working-tree entry reads from the range that holds its change: the
    /// worktree while it has unstaged edits, the index once only staged ones remain.
    /// The range is not saved as a review preference.
    func loadWorkingChange(_ entry: RemoteGitEntry) {
        gitRange = entry.hasStaged && !entry.hasUnstaged ? .staged : .unstaged
        loadGitDiff(entry)
    }

    func loadGitDiff(_ entry: RemoteGitEntry) {
        guard let host, let root = gitStatus?.root else { return }
        if gitRange == .branch {
            guard let comparison = gitComparison, comparison.entries.contains(entry) else { return }
            cancel()
            reviewProgress.lastPath = entry.path
            saveReviewProgress()
            gitPath = entry.path; gitDiff = nil; loading = true; error = nil
            run(RemoteGitCommand.comparisonDiffCommand(comparison: comparison, entry: entry),
                destination: host.destination, token: generation) { browser, data in
                browser.gitDiff = try RemoteGitCommand.parseDiff(data)
            } failed: { browser in browser.gitDiff = nil }
            return
        }
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

    func loadGitComparison() {
        guard let host, let root = gitStatus?.root else { return }
        cancel()
        gitComparison = nil; gitPath = nil; gitDiff = nil; error = nil
        let base = gitBaseInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        loading = true
        run(RemoteGitCommand.comparisonCommand(directory: root, base: base),
            destination: host.destination, token: generation) { browser, data in
            let comparison = try RemoteGitCommand.parseComparison(data)
            browser.gitComparison = comparison
            let key = browser.preferenceKey(root: root, base: base)
            browser.reviewProgress = UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode(GitReviewProgress.self, from: $0) } ?? GitReviewProgress()
            browser.reviewProgress.reconcile(comparison.versions)
            browser.saveReviewProgress()
            UserDefaults.standard.set(base, forKey: browser.preferenceKey(root: root))
            if let path = browser.reviewProgress.lastPath, let entry = comparison.entries.first(where: { $0.path == path }) {
                browser.loadGitDiff(entry)
            }
        } failed: { browser in browser.gitComparison = nil }
    }

    func changeGitRange(from previous: GitReviewRange) {
        if let root = gitStatus?.root { UserDefaults.standard.set(gitRange.rawValue, forKey: preferenceKey(root: root) + ".range") }
        if gitRange == .branch { loadGitRefs() }
        else if previous == .branch { loadGitStatus() }
        else { reloadGitDiff() }
    }

    private func loadGitRefs() {
        guard let host, let root = gitStatus?.root else { return }
        cancel(); loading = true
        run(RemoteGitCommand.reviewRefsCommand(directory: root), destination: host.destination, token: generation) { browser, data in
            browser.gitRefs = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            browser.loadGitComparison()
        } failed: { browser in browser.gitRefs = []; browser.gitComparison = nil; browser.gitDiff = nil }
    }

    private func preferenceKey(root: String, base: String? = nil) -> String {
        let components = [host?.id.uuidString ?? "", root] + (base.map { [$0] } ?? [])
        return "files.review." + (try! JSONEncoder().encode(components)).base64EncodedString()
    }

    private func saveReviewProgress() {
        guard let comparison = gitComparison else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(reviewProgress),
            forKey: preferenceKey(root: comparison.root, base: comparison.baseRef))
    }

    func toggleReviewed() {
        guard gitRange == .branch, !loading, error == nil, gitDiff != nil, let path = gitPath else { return }
        reviewProgress.toggleReviewed(path)
        saveReviewProgress()
    }

    func adjacentReview(_ delta: Int) -> RemoteGitEntry? {
        guard let entries = gitComparison?.entries, let path = gitPath,
              let index = entries.firstIndex(where: { $0.path == path }), entries.indices.contains(index + delta) else { return nil }
        return entries[index + delta]
    }

    /// Capture the scope before the view unmounts, so a delayed callback cannot
    /// save another worktree's offset or restore an offset for changed content.
    func rememberReviewOffset() -> ((Double) -> Void)? {
        guard gitRange == .branch, let comparison = gitComparison, let path = gitPath,
              let version = comparison.versions[path] else { return nil }
        let key = preferenceKey(root: comparison.root, base: comparison.baseRef)
        return { [weak self] offset in
            guard var progress = UserDefaults.standard.data(forKey: key)
                .flatMap({ try? JSONDecoder().decode(GitReviewProgress.self, from: $0) }),
                  progress.versions[path] == version else { return }
            progress.offsets[path] = offset
            UserDefaults.standard.set(try? JSONEncoder().encode(progress), forKey: key)
            if let self, let current = self.gitComparison,
               self.preferenceKey(root: current.root, base: current.baseRef) == key {
                self.reviewProgress.offsets[path] = offset
            }
        }
    }

    /// Switching between staged and unstaged re-reads the same file rather than
    /// leaving the previous range's diff on screen under the new label.
    func reloadGitDiff() {
        guard case .changes(_, _, let entries) = gitStatus, let path = gitPath,
              let entry = entries.first(where: { $0.path == path }) else { return }
        loadGitDiff(entry)
    }

    // MARK: - Write actions and history

    var gitWriteError: String?
    private struct GitTarget: Hashable { let hostID: UUID; let directory: String }
    private var pendingWrites: Set<GitTarget> = []
    private var gitTarget: GitTarget? {
        host.map {
            let directory = $0.isLocal && !gitDirectory.isEmpty
                ? URL(fileURLWithPath: gitDirectory).resolvingSymlinksInPath().path : gitDirectory
            return GitTarget(hostID: $0.id, directory: directory)
        }
    }
    var gitWriting: Bool { gitTarget.map { pendingWrites.contains($0) } ?? false }
    private(set) var gitBranches: RemoteGitBranches?
    private(set) var gitLog: [RemoteGitCommit]?
    var gitCommitMessage = ""
    var gitCommitSheet: RemoteGitCommit?
    private(set) var gitCommitDiff: RemoteGitDiff?

    /// Writes never show the full-pane spinner; failures stay inline and every
    /// success re-reads status so the lists stay authoritative.
    private func runGitWrite(_ command: String, then: @escaping (RemoteFileBrowser) -> Void = { _ in }) {
        guard let host, let target = gitTarget, !target.directory.isEmpty, !loading,
              pendingWrites.insert(target).inserted else { return }
        gitWriteError = nil
        // A user-started write owns its transport until completion. Page reads
        // and navigation may cancel each other, never this remote operation.
        let writer = RemoteReader(local: host.isLocal)
        let destination = host.destination
        Task {
            let result = await writer.run(command: command, destination: destination)
            pendingWrites.remove(target)
            guard gitTarget == target else { return }
            do {
                let data = try result.get()
                switch try RemoteGitCommand.parseWrite(data) {
                case .ok:
                    then(self)
                    loadGitStatus()
                case .notARepository:
                    gitWriteError = L("所选目录不是可用的 Git 工作树。")
                case .failed(let message): gitWriteError = message
                }
            } catch { gitWriteError = error.localizedDescription }
        }
    }

    func stageGitEntry(_ entry: RemoteGitEntry) {
        runGitWrite(RemoteGitCommand.stageCommand(directory: gitDirectory, path: entry.path, originalPath: entry.originalPath))
    }
    func unstageGitEntry(_ entry: RemoteGitEntry) {
        runGitWrite(RemoteGitCommand.unstageCommand(directory: gitDirectory, path: entry.path, originalPath: entry.originalPath))
    }
    func commitGit() {
        let message = gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        runGitWrite(RemoteGitCommand.commitCommand(directory: gitDirectory, message: message)) { browser in
            browser.gitCommitMessage = ""
        }
    }
    func switchGitBranch(_ branch: String) {
        guard branch != gitBranches?.current else { return }
        runGitWrite(RemoteGitCommand.switchCommand(directory: gitDirectory, branch: branch)) { browser in
            // Comparison pins belong to the old branch.
            browser.gitRefs = []
            browser.gitComparison = nil
            browser.gitBaseInput = ""
        }
    }

    /// Branches and recent commits chain after a status read so the
    /// single-reader transport never interleaves responses. A stale nil retries
    /// on the next status load.
    func loadGitMetadata() {
        guard let host, !gitDirectory.isEmpty else { return }
        let destination = host.destination
        run(RemoteGitCommand.branchesCommand(directory: gitDirectory), destination: destination, token: generation) { browser, data in
            browser.gitBranches = try RemoteGitCommand.parseBranches(data)
            browser.run(RemoteGitCommand.logCommand(directory: browser.gitDirectory), destination: destination, token: browser.generation) { inner, logData in
                inner.gitLog = try RemoteGitCommand.parseLog(logData)
                if inner.gitRange == .branch { inner.loadGitRefs() }
            } failed: { inner in
                inner.gitLog = nil
                if inner.gitRange == .branch { inner.loadGitRefs() }
            }
        } failed: { browser in browser.gitBranches = nil }
    }

    func showGitCommit(_ commit: RemoteGitCommit) {
        guard let host else { return }
        cancel()
        gitCommitSheet = commit
        gitCommitDiff = nil
        run(RemoteGitCommand.showCommand(directory: gitDirectory, commit: commit.hash),
            destination: host.destination, token: generation) { browser, data in
            guard browser.gitCommitSheet?.id == commit.id else { return }
            browser.gitCommitDiff = try RemoteGitCommand.parseDiff(data)
        } failed: { browser in browser.gitCommitDiff = nil }
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
        fileRequest = nil
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
final class RemoteReader: @unchecked Sendable {
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
        if cancelled { lock.unlock(); return .failure(WorkbenchError(L("已取消读取。"))) }
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
        if wasCancelled { return .failure(WorkbenchError(L("已取消读取。"))) }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: failure, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(WorkbenchError(message.isEmpty ? L("远端连接失败或已断开。") : message))
        }
        return .success(data)
    }
}

/// Monospaced diff with added/removed lines tinted. Colour is supplementary: the
/// original +/- markers stay in the text so the diff is readable without it. Size
/// and line spacing are the reply code style's, as for files in the same panel.
private struct DiffText: View {
    let diff: String
    init(_ diff: String) { self.diff = diff }
    var body: some View {
        SelectableReplyText(attributed: Self.attributed(diff))
    }
    static func attributed(_ diff: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = ReplyStyle.codeLineSpacing
        let font = NSFont.monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular)
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
    @UILocalization private var L
    @Bindable var browser: RemoteFileBrowser
    var showsCloseButton = true
    var onAddContext: ((String) -> Void)? = nil
    var onShowDraft: (() -> Void)? = nil
    var contextDestination: String? = nil
    var documentLibrary: DocumentLibraryActions? = nil
    /// Set where the panel is a sheet of its own. The side panel leaves Escape to
    /// its window, so its close button has no shortcut.
    var closeShortcut: KeyboardShortcut? = nil
    let onClose: () -> Void
    @State private var showLocation = false
    @State private var showDetails = false
    @State private var showFind = false
    @State private var showLine = false
    @State private var lineInput = ""
    @FocusState private var locationFocused: Bool
    @FocusState private var lineFocused: Bool
    @State private var selection = NSRange(location: 0, length: 0)
    private struct FeedbackDraft: Identifiable {
        let id = UUID()
        let context: ReviewContext
        let destination: String?
        let append: (String) -> Void
        let showDraft: (() -> Void)?
    }
    @State private var feedbackContext: FeedbackDraft?
    @State private var feedback = ""
    @State private var contextAdded = false
    @State private var showAddedDraft: (() -> Void)?
    /// A branch switch rewrites the remote worktree under any agent working there.
    @State private var pendingBranch: String?
    private var pendingBranchName: String { pendingBranch ?? "" }
    private var isDocumentReading: Bool {
        browser.mode == .file && browser.previewKind == .markdown && browser.documents.current?.reading == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if browser.mode == .file, !browser.documents.tabs.isEmpty,
               !isDocumentReading || browser.documents.tabs.count > 1 {
                FileTabStrip(browser: browser)
                Divider()
            }
            HStack(spacing: 6) {
                if !isDocumentReading {
                    Picker("", selection: $browser.mode) {
                        ForEach(RemotePanelMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }.pickerStyle(.menu).labelsHidden().frame(width: 74)
                        .onChange(of: browser.mode) { _, mode in
                            if mode == .git, browser.gitStatus == nil { browser.loadGitStatus() }
                        }
                }
                if browser.mode == .file {
                    Button { browser.navigateHistory(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.documents.canGoBack).help("返回上一个文档").accessibilityLabel("返回上一个文档")
                    Button { browser.navigateHistory(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.documents.canGoForward).help("前往下一个文档").accessibilityLabel("前往下一个文档")
                    if !isDocumentReading { FileDisplayMode(browser: browser) }
                    if isDocumentReading && browser.documents.tabs.count == 1 {
                        Image(systemName: "doc.text").foregroundStyle(.secondary).padding(.leading, 4)
                        Text((browser.path as NSString).lastPathComponent)
                            .font(.system(size: 13)).lineLimit(1).truncationMode(.middle).help(browser.path)
                    }
                }
                Spacer(minLength: 0)
                if browser.mode == .file {
                    if isDocumentReading { DocumentReaderControls(state: browser.reading) }
                    if !isDocumentReading {
                        Button { showLocation.toggle() } label: { Image(systemName: "folder") }
                            .help("打开文件…").accessibilityLabel("打开文件…")
                    }
                    Button { showFind.toggle() } label: { Image(systemName: "magnifyingglass") }
                        .help("在已读取内容中查找").accessibilityLabel("在已读取内容中查找")
                        .disabled(!hasContext)
                    if !isDocumentReading {
                        Button { showDetails.toggle() } label: { Image(systemName: "info.circle") }
                        .help("文件详情").accessibilityLabel("文件详情")
                    }
                }
                if browser.mode == .file || onAddContext != nil { fileActions }
                if showsCloseButton {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .help("关闭文件面板").accessibilityLabel("关闭文件面板")
                        .keyboardShortcut(closeShortcut)
                }
            }.buttonStyle(.borderless).controlSize(.small)
                .padding(.horizontal, 12).frame(height: isDocumentReading ? 48 : 38)
                .popover(isPresented: $showLocation) { locationEditor }
                .popover(isPresented: $showDetails) { fileDetails }
                .popover(isPresented: $showLine) { lineEditor }
            Divider()
            if browser.mode == .git {
                VStack(alignment: .leading, spacing: 9) {
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
                        Picker("", selection: $browser.gitRange) {
                            Text("未暂存").tag(GitReviewRange.unstaged)
                            Text("已暂存").tag(GitReviewRange.staged)
                            Text("分支改动").tag(GitReviewRange.branch)
                        }.pickerStyle(.segmented).labelsHidden()
                            .onChange(of: browser.gitRange) { previous, _ in browser.changeGitRange(from: previous) }
                        if let branches = browser.gitBranches {
                            Menu {
                                ForEach(branches.names, id: \.self) { name in
                                    Button { pendingBranch = name } label: {
                                        HStack {
                                            Text(name)
                                            if name == branches.current { Image(systemName: "checkmark") }
                                        }
                                    }.disabled(name == branches.current)
                                }
                            } label: {
                                Label(branches.current ?? L("游离 HEAD"), systemImage: "arrow.triangle.branch")
                                    .font(.system(size: 12))
                            }.menuStyle(.borderlessButton).fixedSize()
                                .help("切换分支，直接作用于远端工作区")
                                .disabled(browser.gitWriting)
                                .alert(L("切换到分支“\(pendingBranchName)”？"), isPresented: Binding(
                                    get: { pendingBranch != nil },
                                    set: { if !$0 { pendingBranch = nil } }
                                )) {
                                    Button(L("取消"), role: .cancel) { pendingBranch = nil }
                                    // Capture the branch: dismissal may clear the state before the action runs.
                                    if let branch = pendingBranch {
                                        Button(L("切换分支")) {
                                            pendingBranch = nil
                                            browser.switchGitBranch(branch)
                                        }
                                    }
                                } message: {
                                    Text(L("将在 \(browser.gitDirectory) 执行 git switch，直接改动远端工作区的文件。正在此目录工作的 Agent 会读到切换后的代码。"))
                                }
                        }
                        if browser.gitWriting { ProgressView().controlSize(.mini) }
                    }
                    if let writeError = browser.gitWriteError {
                        Text(writeError).font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .changes(_, _, let entries) = browser.gitStatus,
                       entries.contains(where: { $0.hasStaged }) {
                        HStack(spacing: 7) {
                            TextField("提交信息", text: $browser.gitCommitMessage)
                                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                                .disabled(browser.gitWriting)
                                .onSubmit { browser.commitGit() }
                            Button("提交") { browser.commitGit() }.controlSize(.small)
                                .disabled(browser.gitWriting
                                          || browser.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    if let log = browser.gitLog, !log.isEmpty {
                        DisclosureGroup("最近提交（\(log.count)）") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(log) { commit in
                                    Button { browser.showGitCommit(commit) } label: {
                                        HStack(spacing: 7) {
                                            Text(commit.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                            Text(commit.subject).font(.system(size: 11)).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Text(commit.relativeDate).font(.system(size: 11)).foregroundStyle(.tertiary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 2).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.top, 4)
                        }.font(.system(size: 11))
                    }
                    if browser.gitRange == .branch {
                        HStack(spacing: 7) {
                            if !browser.gitRefs.isEmpty {
                                Menu {
                                    ForEach(browser.gitRefs, id: \.self) { ref in
                                        Button(ref.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "")) {
                                            browser.gitBaseInput = ref; browser.loadGitComparison()
                                        }
                                    }
                                } label: { Image(systemName: "arrow.triangle.branch") }
                                    // Natural size: a 28 pt target would make the target-branch row taller.
                                    .help("选择已有分支").accessibilityLabel("选择已有分支")
                            }
                            TextField("目标分支或提交，如 origin/main", text: $browser.gitBaseInput)
                                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                                .onSubmit { browser.loadGitComparison() }
                            Button("比较") { browser.loadGitComparison() }.controlSize(.small)
                                .disabled(browser.loading || browser.gitStatus?.root == nil || browser.gitBaseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let comparison = browser.gitComparison {
                            Text("\(comparison.entries.count) 个文件 · 已读 \(browser.reviewProgress.reviewed.count) 个")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            DisclosureGroup("比较版本") {
                                Text("\(comparison.baseRef)\n\(comparison.mergeBase) → \(comparison.headCommit)")
                                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.font(.system(size: 11))
                        }
                        Text("比较共同祖先到当前提交的改动，不含未提交内容；引用使用仓库现有数据，不自动 fetch。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("暂存、提交与切换分支会直接修改远端工作区；差异与比较仍为只读。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
            }
            if contextAdded {
                HStack {
                    Label("已加入会话草稿", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    if let showAddedDraft { Button("查看草稿", action: showAddedDraft) }
                }.font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 6)
            }
            if browser.mode == .file, showFind, hasContext { FileFindBar(browser: browser, isPresented: $showFind) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.background(WorkbenchTheme.contentBackground)
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchFindInFile"))) { _ in
                if browser.mode == .file && hasContext { showFind = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchOpenFileLocation"))) { notice in
                if notice.object as? RemoteFileBrowser === browser { browser.mode = .file; showLocation = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchGoToFileLine"))) { notice in
                if notice.object as? RemoteFileBrowser === browser && hasContext && browser.mode == .file {
                    lineInput = browser.targetLine.map(String.init) ?? ""; showLine = true
                }
            }
            .task(id: browser.fileRequest?.id) {
                if let request = browser.fileRequest { await browser.loadFile(request) }
            }
            .onChange(of: browser.loading) { _, loading in if loading { selection = NSRange(location: 0, length: 0) } }
            .onChange(of: browser.mode) { _, _ in selection = NSRange(location: 0, length: 0) }
            .sheet(item: $browser.gitCommitSheet) { commit in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(commit.hash) · \(commit.subject)").font(.headline).lineLimit(1)
                        Spacer()
                        Button("关闭") { browser.gitCommitSheet = nil }.keyboardShortcut(.cancelAction)
                    }
                    Text("\(commit.author) · \(commit.relativeDate)").font(.subheadline).foregroundStyle(.secondary)
                    switch browser.gitCommitDiff {
                    case .text(let diff, let truncated):
                        if truncated {
                            Label("差异过大，已截断", systemImage: "scissors")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        RemoteSourceText(text: diff, line: nil, diff: true)
                    case .some(.binary): Text("二进制文件差异，不做预览。").foregroundStyle(.secondary)
                    case .some(.empty): Text("该提交没有差异正文。").foregroundStyle(.secondary)
                    case .some(.untracked), .some(.notARepository): EmptyView()
                    case nil: ProgressView().controlSize(.small)
                    }
                }.padding(WorkbenchTheme.Dialog.padding).frame(width: 640, height: 520)
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchFindDocument"))) { note in
                if note.object as? RemoteFileBrowser === browser { showFind = true }
            }
            .sheet(item: $feedbackContext) { draft in
                let context = draft.context
                VStack(alignment: .leading, spacing: 12) {
                    Text("代码反馈").font(.headline)
                    Group {
                        Text(context.reference).font(.subheadline).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView { Text(context.excerpt).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                    }
                    TextField("希望如何修改？", text: $feedback, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                    if let destination = draft.destination { Text("引用到：\(destination)").font(.subheadline).foregroundStyle(.secondary) }
                    Text("加入会话草稿，检查后再发送。").font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("取消") { feedbackContext = nil }.keyboardShortcut(.cancelAction)
                        Button("加入草稿") {
                            draft.append(context.prompt(feedback: feedback)); showAddedDraft = draft.showDraft; contextAdded = true
                            feedbackContext = nil
                        }.keyboardShortcut(.defaultAction)
                            .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(WorkbenchTheme.Dialog.padding).frame(width: 520)
            }
    }

    private var locationEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(browser.hostName) · \(browser.cwd)").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("文件路径，可用绝对路径或相对当前目录", text: $browser.input)
                .textFieldStyle(.roundedBorder).focused($locationFocused).onSubmit { browser.submit(); showLocation = false }
            HStack {
                Button("上一级目录") { browser.openParent(); showLocation = false }
                    .disabled(RemoteFilePath.parent(of: browser.path) == nil)
                Spacer()
                Button("打开") { browser.submit(); showLocation = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(browser.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(16).frame(width: 420).defaultFocus($locationFocused, true)
    }

    private var lineEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("跳转到行", text: $lineInput).textFieldStyle(.roundedBorder).focused($lineFocused)
                .onSubmit(jumpToLine)
            Text("仅定位已读取内容中的行号").font(.subheadline).foregroundStyle(.secondary)
            Button("跳转", action: jumpToLine).keyboardShortcut(.defaultAction).disabled(validLine == nil)
        }.padding(16).frame(width: 260).defaultFocus($lineFocused, true)
    }
    private var validLine: Int? {
        guard let line = Int(lineInput), line > 0, case .text(let text, _, _) = browser.content,
              line <= RemoteSourceStyle.lineCount(text) else { return nil }
        return line
    }
    private func jumpToLine() {
        guard let line = validLine else { return }
        browser.documents.setReading(false); browser.findQuery = ""; browser.targetLine = line; browser.lineNavigation += 1; showLine = false
    }

    private var fileDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((browser.path as NSString).lastPathComponent).font(.headline)
            Text(browser.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Text("\(browser.hostName) · \(browser.cwd)").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            if case .text(let text, _, let size) = browser.content {
                Text(byteLabel(size)).font(.subheadline)
                if let line = browser.targetLine {
                    Text(line <= RemoteSourceStyle.lineCount(text) ? L("Line \(line)") : L("Line \(line) is outside the loaded content"))
                        .font(.subheadline)
                }
            } else if case .binary(let size) = browser.content { Text(byteLabel(size)).font(.subheadline) }
        }.padding(16).frame(width: 360, alignment: .leading)
    }

    private var fileActions: some View {
        Menu {
            if browser.mode == .file {
                if isDocumentReading {
                    Button("打开文件…") { showLocation = true }
                    Button("文件详情") { showDetails = true }
                    Button("源码") { browser.documents.setReading(false) }
                    Button("Git 变更") {
                        browser.mode = .git
                        if browser.gitStatus == nil { browser.loadGitStatus() }
                    }
                    Divider()
                }
                if let library = documentLibrary, !browser.path.isEmpty, browser.previewKind != .source {
                    Button(library.pinned ? "取消固定文档" : "固定到项目文档") { library.togglePin() }
                }
                if browser.loading { Button("取消") { browser.cancel() } }
                else { Button("刷新") { browser.open(browser.path, limit: browser.readLimit, fromEnd: browser.readingTail) }.disabled(browser.path.isEmpty) }
                Button("跳转到行…") { lineInput = browser.targetLine.map(String.init) ?? ""; showLine = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!hasContext)
                Button("上一个文件标签页") { browser.selectAdjacentFile(-1) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(browser.documents.tabs.count < 2)
                Button("下一个文件标签页") { browser.selectAdjacentFile(1) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(browser.documents.tabs.count < 2)
                Toggle("行号", isOn: $browser.showLineNumbers)
                if case .text(_, let truncated, _) = browser.content {
                    if truncated && !browser.readingTail && browser.readLimit < 4 * 1_048_576 {
                        Button("读取更多") { browser.open(browser.path, limit: browser.readLimit + 1_048_576) }
                    }
                    if truncated || browser.readingTail {
                        Button(browser.readingTail ? "查看开头" : "查看尾部") {
                            browser.documents.setReading(false); browser.open(browser.path, fromEnd: !browser.readingTail)
                        }
                    }
                }
            }
            if onAddContext != nil {
                Divider()
                if let contextDestination { Text("引用到：\(contextDestination)") }
                Button("引用文件") {
                    if let context = context(selection: NSRange(location: 0, length: 0)) { onAddContext?(context.prompt()); showAddedDraft = onShowDraft; contextAdded = true }
                }.disabled(!hasContext || browser.loading || browser.error != nil)
                Button("反馈选中代码…") {
                    guard let context = context(selection: selection), let onAddContext else { return }
                    feedback = ""
                    feedbackContext = FeedbackDraft(context: context, destination: contextDestination, append: onAddContext, showDraft: onShowDraft)
                }
                    .disabled(selection.length == 0 || browser.loading || browser.error != nil)
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().help("文件操作").accessibilityLabel("文件操作")
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
        } else if browser.gitRange == .branch, browser.gitStatus?.root != nil {
            if let comparison = browser.gitComparison {
                if comparison.entries.isEmpty { notice(L("当前提交相对目标分支没有新增改动。"), symbol: "checkmark.circle", tint: .secondary) }
                else { gitChanges(comparison.entries) }
            } else { notice(L("输入目标分支或提交后开始审阅。"), symbol: "arrow.triangle.branch", tint: .secondary) }
        } else {
            switch browser.gitStatus {
            case .notARepository:
                notice(L("所选目录不是可用的 Git 工作树。"), symbol: "questionmark.folder", tint: .secondary)
            case .clean:
                notice(L("所选工作树干净，没有未提交的改动。"), symbol: "checkmark.circle", tint: .secondary)
            case .changes(_, _, let entries):
                gitChanges(entries)
            case nil:
                notice(L("读取当前项目 Git 工作树的改动。"), symbol: "arrow.triangle.branch", tint: .secondary)
            }
        }
    }

    private func gitChanges(_ entries: [RemoteGitEntry]) -> some View {
        VStack(spacing: 0) {
            if browser.gitRange == .branch {
                HStack(spacing: 8) {
                    Button("上一个文件") { if let entry = browser.adjacentReview(-1) { browser.loadGitDiff(entry) } }
                        .disabled(browser.adjacentReview(-1) == nil)
                    Button("下一个文件") { if let entry = browser.adjacentReview(1) { browser.loadGitDiff(entry) } }
                        .disabled(browser.adjacentReview(1) == nil)
                    Spacer(minLength: 0)
                    Button(browser.reviewProgress.isReviewed(browser.gitPath ?? "") ? L("标为未读") : L("标为已读")) { browser.toggleReviewed() }
                        .disabled(browser.gitDiff == nil)
                }.font(.system(size: 11)).padding(10)
            }
        VSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { entry in
                        HStack(spacing: 6) {
                            Button { browser.loadGitDiff(entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path)
                                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    HStack(spacing: 6) {
                                        Text(browser.gitRange == .branch ? L(key: entry.changeLabel) : entry.label)
                                        if browser.gitRange == .branch {
                                            if browser.reviewProgress.isReviewed(entry.path) { Label("已读", systemImage: "checkmark.circle.fill") }
                                            else if browser.reviewProgress.changed.contains(entry.path) { Text("有新改动").foregroundStyle(.orange) }
                                        }
                                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if browser.gitRange == .unstaged, entry.hasUnstaged || entry.untracked {
                                Button("暂存") { browser.stageGitEntry(entry) }
                                    .controlSize(.mini).disabled(browser.gitWriting)
                            } else if browser.gitRange == .staged, entry.hasStaged {
                                Button("取消暂存") { browser.unstageGitEntry(entry) }
                                    .controlSize(.mini).disabled(browser.gitWriting)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(entry.path == browser.gitPath ? Color.primary.opacity(WorkbenchTheme.Fill.selected) : .clear)
                    }
                }.padding(.vertical, 8)
            }.frame(minHeight: 80, idealHeight: max(80, min(220, Double(entries.count) * 42 + 16)), maxHeight: max(80, min(220, Double(entries.count) * 42 + 16)))
            diffPane.frame(minHeight: 120)
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
                RemoteSourceText(text: diff, line: nil, diff: true, onSelection: { selection = $0 },
                    initialOffset: browser.gitRange == .branch ? browser.reviewProgress.offsets[browser.gitPath ?? ""] : nil,
                    onSaveOffset: browser.rememberReviewOffset())
                    .id("diff:\(browser.gitDirectory):\(browser.gitPath ?? ""):\(browser.gitRange.rawValue)")
            }
        case .binary: notice(L("二进制文件差异，不做预览。"), symbol: "doc.zipper", tint: .secondary)
        case .empty: notice(L("该文件在当前范围内没有差异。"), symbol: "equal.circle", tint: .secondary)
        case .untracked: notice(L("未跟踪文件，没有 tracked diff；可在「文件」页查看内容。"), symbol: "plus.circle", tint: .secondary)
        case .notARepository: notice(L("所选工作树不再是 Git 仓库。"), symbol: "questionmark.folder", tint: .secondary)
        case nil: notice(L("选择一个文件查看差异。"), symbol: "doc.text.magnifyingglass", tint: .secondary)
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
                if entries.isEmpty { notice(L("空目录。"), symbol: "folder", tint: .secondary) }
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
                    if truncated {
                        Label(browser.readingTail ? "正在查看文件尾部" : "仅显示已读取部分", systemImage: "scissors")
                            .font(.subheadline).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 5)
                    }
                    if browser.previewKind.isBinary {
                        binaryPreview(size: size)
                    } else if browser.documents.current?.reading == true && browser.previewKind == .markdown && !browser.readingTail {
                        DocumentReader(browser: browser, text: text, path: browser.path, onAddContext: onAddContext,
                                       destination: contextDestination, onShowDraft: onShowDraft,
                                       onSaveOffset: browser.documents.offsetRecorder()).id(browser.path)
                    } else if browser.documents.current?.reading == true && browser.previewKind != .source && !browser.readingTail {
                        FileContentPreview(kind: browser.previewKind, text: text, data: nil,
                                           revision: browser.fileRequest?.id, path: browser.path,
                                           initialOffset: browser.documents.current?.offset,
                                           onSaveOffset: browser.documents.offsetRecorder()).id(browser.path)
                    } else {
                        RemoteSourceText(text: text, line: browser.targetLine, numbered: browser.showLineNumbers,
                            onSelection: { selection = $0 }, initialOffset: browser.documents.current?.offset,
                            onSaveOffset: browser.documents.offsetRecorder(),
                            findQuery: browser.findQuery, findIndex: browser.findIndex, sourcePath: browser.path, lineNavigation: browser.lineNavigation).id(browser.path + (browser.readingTail ? ":tail" : ":head"))
                    }

                }
            case .binary(let size):
                binaryPreview(size: size)
            case .denied:
                notice(L("没有读取权限。"), symbol: "lock", tint: .orange)
            case .missing:
                notice(L("路径不存在。"), symbol: "questionmark.folder", tint: .orange)
            case nil:
                VStack(spacing: 12) {
                    ContentUnavailableView("打开文件阅读", systemImage: "doc.text")
                    Button("打开文件…") { showLocation = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func binaryPreview(size: Int) -> some View {
        if browser.previewKind.isBinary, let data = browser.previewData, size <= data.count {
            FileContentPreview(kind: browser.previewKind, text: "", data: data,
                               revision: browser.fileRequest?.id, path: browser.path)
        } else {
            notice(L("文件无法预览或超过 16 MiB 预览上限。"), symbol: "doc.zipper", tint: .secondary)
        }
    }

    private func worktreeLabel(_ worktree: RemoteGitWorktree) -> String {
        let directory = (worktree.path as NSString).lastPathComponent
        let head = String(worktree.head.prefix(8))
        let revision = worktree.branchName ?? (worktree.detached ? L("detached \(head)") : L("无分支"))
        var states: [String] = []
        if worktree.current { states.append(L("当前")) }
        if worktree.locked { states.append(L("已锁定")) }
        if worktree.prunable { states.append(L("不可用")) }
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
                scope: "\(browser.hostName) · \(browser.gitComparison?.scope ?? browser.gitRange.rawValue)")
        }
        guard case .text(let text, let truncated, _) = browser.content else { return nil }
        return ReviewContext(path: path, text: text, selection: selection,
            scope: "\(browser.hostName) · \(truncated ? "loaded file prefix" : "file")")
    }
    private func byteLabel(_ size: Int) -> String {
        size < 1024 ? L("\(size) 字节") : size < 1_048_576
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

/// File and diff text in the reply code style. The text view holds exactly the
/// source, so selection, copy, quotes and feedback all read source offsets. Line
/// numbers are a separate, unselectable column in the scroll view's vertical ruler:
/// the scroll view tiles it beside the clip view, so it scrolls vertically with the
/// code but never sideways, and no frame of ours follows the scroll position.
struct RemoteSourceText: NSViewRepresentable {
    let text: String
    let line: Int?
    var diff = false
    var numbered = false
    /// Embedded inspectors inherit their card's surface; full readers keep the
    /// native text background by default.
    var transparentBackground = false
    var onSelection: ((NSRange) -> Void)? = nil
    var initialOffset: Double? = nil
    var onSaveOffset: ((Double) -> Void)? = nil
    var findQuery = ""
    var findIndex = 0
    var sourcePath = ""
    var lineNavigation = 0
    /// Diffs carry their own line numbers in hunk headers.
    private var showsGutter: Bool { numbered && !diff }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSaveOffset: ((Double) -> Void)?
        var highlighting: CodeHighlightController?
        var search: FileSearchController?
        var text: String?
        var diff = false
        var sourcePath = ""
        var findQuery = ""
        var findIndex = 0
        var line: Int?
        var lineNavigation = 0
        var onSelection: ((NSRange) -> Void)?
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            let callback = onSelection
            DispatchQueue.main.async { callback?(range) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.search?.cancel(); coordinator.highlighting?.reset()
        let save = coordinator.onSaveOffset, offset = Double(scroll.contentView.bounds.origin.y)
        DispatchQueue.main.async { save?(offset) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SourceScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = !transparentBackground
        // TextKit 1 from the start: sizing below and the gutter read its layout.
        let view = NSTextView(usingTextLayoutManager: false); view.isEditable = false; view.isSelectable = true
        view.drawsBackground = !transparentBackground
        view.identifier = NSUserInterfaceItemIdentifier("PerchReviewSource")
        view.delegate = context.coordinator
        let highlighting = CodeHighlightController(view: view)
        context.coordinator.highlighting = highlighting
        context.coordinator.search = FileSearchController(view: view, highlighting: highlighting)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.layoutManager?.backgroundLayoutEnabled = false
        // The vertical ruler is the gutter; the text view must not claim it.
        view.usesRuler = false
        view.textContainer?.lineFragmentPadding = 0
        // TextKit estimates the document extent and lays out only requested ranges.
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        scroll.verticalRulerView = RemoteSourceGutter(scrollView: scroll, source: view)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        scroll.drawsBackground = !transparentBackground
        view.drawsBackground = !transparentBackground
        let coordinator = context.coordinator
        coordinator.onSelection = onSelection
        coordinator.onSaveOffset = onSaveOffset
        let textChanged = coordinator.text != text || coordinator.diff != diff
        let languageChanged = coordinator.sourcePath != sourcePath
        let gutterChanged = scroll.rulersVisible != showsGutter
        let findChanged = coordinator.findQuery != findQuery || coordinator.findIndex != findIndex
        guard textChanged || languageChanged || gutterChanged || coordinator.line != line || coordinator.lineNavigation != lineNavigation || findChanged else { return }
        if textChanged {
            coordinator.text = text; coordinator.diff = diff
            view.textStorage?.setAttributedString(diff ? DiffText.attributed(text) : RemoteSourceStyle.code(text))
        }
        if textChanged || languageChanged {
            coordinator.sourcePath = sourcePath
            coordinator.highlighting?.update(source: text, language: diff ? "" : CodeLanguage.file(sourcePath))
        }
        if textChanged || gutterChanged {
            // Numbers are built once per text, and only while shown.
            if showsGutter { (scroll.verticalRulerView as? RemoteSourceGutter)?.showNumbers(for: text) }
            scroll.rulersVisible = showsGutter
            // Beside the gutter its trailing padding is the gap before the code.
            view.textContainerInset = NSSize(width: showsGutter ? 0 : RemoteSourceMetrics.inset, height: RemoteSourceMetrics.inset)
            scroll.tile()
        }
        coordinator.findQuery = findQuery; coordinator.findIndex = findIndex
        coordinator.search?.update(text: text, query: findQuery, index: findIndex)
        // Showing or hiding the numbers keeps the reader's place and selection.
        guard textChanged || coordinator.line != line || coordinator.lineNavigation != lineNavigation else { return }
        coordinator.line = line; coordinator.lineNavigation = lineNavigation
        guard let line, let range = RemoteFileContent.lineRange(in: text, line: line) else {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            if let initialOffset {
                // A new SwiftUI host has no viewport yet. Restore after native
                // sizing, just as line navigation below waits for attachment.
                DispatchQueue.main.async {
                    guard coordinator.text == text, coordinator.line == line, coordinator.lineNavigation == lineNavigation else { return }
                    scroll.layoutSubtreeIfNeeded()
                    let offset = min(max(0, initialOffset), max(0, view.frame.height - scroll.contentSize.height))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else { view.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
            return
        }
        view.setSelectedRange(range)
        DispatchQueue.main.async {
            guard coordinator.text == text, coordinator.line == line, coordinator.lineNavigation == lineNavigation else { return }
            view.scrollRangeToVisible(range)
        }
    }
}

/// File panel code geometry; the gutter takes the reply code card's paddings.
private enum RemoteSourceMetrics {
    /// Around the code, and before it while the gutter is hidden.
    static let inset: CGFloat = 14
}

/// The reply code and gutter styles with one fixed line height. A line set in a
/// fallback font (CJK, emoji) is otherwise taller than its number, and the two
/// columns drift apart down the file.
@MainActor private enum RemoteSourceStyle {
    static let lineHeight: CGFloat = {
        guard let font = ReplyTextAttributes.code(" ").attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return 0 }
        return NSLayoutManager().defaultLineHeight(for: font)
    }()
    static func code(_ text: String) -> NSAttributedString { fixed(ReplyTextAttributes.code(text)) }
    /// Clipped, never wrapped: the column is exactly as wide as the widest number.
    static func gutter(_ lines: Int) -> NSAttributedString { fixed(ReplyTextAttributes.codeGutter(lines), clipping: true) }
    /// Lines as TextKit and `RemoteFileContent.lineRange` break them: LF, CR, CRLF,
    /// U+2028. A final terminator ends the last line instead of starting one, as in
    /// `CodeLineNumbers`, which cannot count files: CRLF is one Swift `Character`.
    static func lineCount(_ text: String) -> Int {
        let source = text as NSString
        var count = 0, location = 0
        while location < source.length {
            location = NSMaxRange(source.lineRange(for: NSRange(location: location, length: 0)))
            count += 1
        }
        return max(1, count)
    }
    private static func fixed(_ attributed: NSAttributedString, clipping: Bool = false) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let base = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        guard let style = base?.mutableCopy() as? NSMutableParagraphStyle else { return attributed }
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        if clipping { style.lineBreakMode = .byClipping }
        let result = NSMutableAttributedString(attributedString: attributed)
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// Numbers follow the source's actual visible fragments. Independent estimated
/// document heights would drift when TextKit lays out noncontiguous ranges.
final class RemoteSourceGutter: NSRulerView {
    private weak var codeView: NSTextView?
    private var numberedText: String?
    private var lineStarts = [0]
    private var attributes: [NSAttributedString.Key: Any] = [:]

    init(scrollView: NSScrollView, source: NSTextView) {
        codeView = source
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        reservedThicknessForMarkers = 0; reservedThicknessForAccessoryView = 0
        clipsToBounds = true; setAccessibilityElement(false)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    func showNumbers(for text: String) {
        guard numberedText != text else { return }
        numberedText = text; lineStarts = []
        let source = text as NSString
        var offset = 0
        while offset < source.length {
            lineStarts.append(offset)
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
        }
        if lineStarts.isEmpty { lineStarts = [0] }
        attributes = RemoteSourceStyle.gutter(1).attributes(at: 0, effectiveRange: nil)
        let widest = NSAttributedString(string: String(lineStarts.count), attributes: attributes)
        ruleThickness = ReplyStyle.Code.gutterLeading + ceil(widest.size().width) + ReplyStyle.Code.gutterTrailing
        needsDisplay = true
    }
    func lineNumber(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }
    override func draw(_ dirtyRect: NSRect) {
        let area = dirtyRect.intersection(bounds)
        (codeView?.backgroundColor ?? .textBackgroundColor).setFill(); area.fill()
        guard let codeView, let layout = codeView.layoutManager, let container = codeView.textContainer else { return }
        let origin = convert(codeView.textContainerOrigin, from: codeView)
        let rows = NSRect(x: 0, y: area.minY - origin.y, width: max(1, codeView.visibleRect.width), height: area.height)
        let glyphs = layout.glyphRange(forBoundingRect: rows, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            let line = self.lineNumber(at: layout.characterIndexForGlyph(at: range.location))
            let number = NSAttributedString(string: String(line), attributes: self.attributes)
            number.draw(at: NSPoint(x: self.ruleThickness - ReplyStyle.Code.gutterTrailing - number.size().width,
                                    y: origin.y + rect.minY))
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    @objc private func clipDidScroll(_ notification: Notification) { needsDisplay = true }
}

private final class SourceScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let view = documentView as? NSTextView else { return }
        if view.minSize != contentSize { view.minSize = contentSize }
    }
}
