import AppKit
import SwiftUI
import Observation
import WorkbenchCore

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
    private(set) var loading: Bool { get { reads.loading } set { reads.loading = newValue } }
    var error: String? { get { reads.error } set { reads.error = newValue } }
    var showLineNumbers = false
    var targetLine: Int?
    var lineNavigation = 0
    var mode: RemotePanelMode = .file
    let git: RemoteGitBrowser
    private let reads: RemotePanelReadState
    var gitStatus: RemoteGitStatus? { git.gitStatus }
    var gitPath: String? { git.gitPath }
    var gitDiff: RemoteGitDiff? { git.gitDiff }
    var gitDirectory: String { git.gitDirectory }
    var gitWorktrees: [RemoteGitWorktree] { git.gitWorktrees }
    var gitInput: String { get { git.gitInput } set { git.gitInput = newValue } }
    var gitRange: GitReviewRange { get { git.gitRange } set { git.gitRange = newValue } }
    var gitBaseInput: String { get { git.gitBaseInput } set { git.gitBaseInput = newValue } }
    var gitComparison: RemoteGitComparison? { git.gitComparison }
    var gitRefs: [String] { git.gitRefs }
    var reviewProgress: GitReviewProgress { git.reviewProgress }
    var gitStaged: Bool { git.gitStaged }
    var gitWriteError: String? { get { git.gitWriteError } set { git.gitWriteError = newValue } }
    var gitWriting: Bool { git.gitWriting }
    var gitBranches: RemoteGitBranches? { git.gitBranches }
    var gitLog: [RemoteGitCommit]? { git.gitLog }
    var gitCommitMessage: String { get { git.gitCommitMessage } set { git.gitCommitMessage = newValue } }
    var gitCommitSheet: RemoteGitCommit? { get { git.gitCommitSheet } set { git.gitCommitSheet = newValue } }
    var gitCommitDiff: RemoteGitDiff? { git.gitCommitDiff }
    func loadGitStatus() { git.loadGitStatus() }
    func submitGitDirectory() { git.submitGitDirectory() }
    func selectGitWorktree(_ directory: String) { git.selectGitWorktree(directory) }
    func loadWorkingChange(_ entry: RemoteGitEntry) { git.loadWorkingChange(entry) }
    func loadGitDiff(_ entry: RemoteGitEntry) { git.loadGitDiff(entry) }
    func loadGitComparison() { git.loadGitComparison() }
    func changeGitRange(from previous: GitReviewRange) { git.changeGitRange(from: previous) }
    func toggleReviewed() { git.toggleReviewed() }
    func adjacentReview(_ delta: Int) -> RemoteGitEntry? { git.adjacentReview(delta) }
    func rememberReviewOffset() -> ((Double) -> Void)? { git.rememberReviewOffset() }
    func reloadGitDiff() { git.reloadGitDiff() }
    func stageGitEntry(_ entry: RemoteGitEntry) { git.stageGitEntry(entry) }
    func unstageGitEntry(_ entry: RemoteGitEntry) { git.unstageGitEntry(entry) }
    func commitGit() { git.commitGit() }
    func switchGitBranch(_ branch: String) { git.switchGitBranch(branch) }
    func loadGitMetadata() { git.loadGitMetadata() }
    func showGitCommit(_ commit: RemoteGitCommit) { git.showGitCommit(commit) }
    /// Directories the agent recently touched (worktrees included), most recent
    /// first. Both conversation file resolution and the Git tab start from these.
    private var directoryHints: [String] = []

    let documents = FileWorkspaceState()
    let reading = DocumentReadingState()
    private(set) var fileRequest: FileReadRequest? { get { reads.fileRequest } set { reads.fileRequest = newValue } }
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
        let reads = RemotePanelReadState()
        self.reads = reads
        git = RemoteGitBrowser(reads: reads, workingTreeOnly: workingTreeOnly)
    }

    /// Switching sessions must never leave another host's path or content on screen.
    func configure(host: SSHHost?, cwd: String, directoryHints: [String] = []) {
        git.configure(host: host, cwd: cwd, directoryHints: directoryHints)
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

    func cancel() { reads.cancel() }

    func openParent() {
        guard let parent = RemoteFilePath.parent(of: path) else { return }
        open(parent)
    }
}
