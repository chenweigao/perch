import Foundation
import Observation
import WorkbenchCore

enum GitReviewRange: String { case unstaged, staged, branch }

/// Owns repository selection, review progress and Git operations. Reads share
/// the file panel's cancellation channel; writes retain their own process.
@MainActor @Observable
final class RemoteGitBrowser {
    private var host: SSHHost?
    private var cwd = ""
    private var directoryHints: [String] = []
    private var gitSelectionExplicit = false
    private let reads: RemotePanelReadState
    let workingTreeOnly: Bool
    var loading: Bool { get { reads.loading } set { reads.loading = newValue } }
    var error: String? { get { reads.error } set { reads.error = newValue } }
    private var generation: Int { get { reads.generation } set { reads.generation = newValue } }

    init(reads: RemotePanelReadState, workingTreeOnly: Bool) {
        self.reads = reads
        self.workingTreeOnly = workingTreeOnly
    }

    func configure(host: SSHHost?, cwd: String, directoryHints: [String]) {
        guard self.host?.id != host?.id || self.cwd != cwd else {
            self.directoryHints = directoryHints
            return
        }
        self.host = host
        self.cwd = cwd
        self.directoryHints = directoryHints
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
    }

    func cancel() { reads.cancel() }

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

    /// Writes never show the full-pane spinner; failures stay inline and every
    /// success re-reads status so the lists stay authoritative.
    private func runGitWrite(_ command: String, then: @escaping (RemoteGitBrowser) -> Void = { _ in }) {
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
                     apply: @escaping (RemoteGitBrowser, Data) throws -> Void,
                     failed: @escaping (RemoteGitBrowser) -> Void) {
        reads.run(command, destination: destination, local: host?.isLocal == true, token: token) { [weak self] data in
            guard let self else { return }
            try apply(self, data)
        } failed: { [weak self] in
            guard let self else { return }
            failed(self)
        }
    }
}
