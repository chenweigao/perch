import AppKit
import SwiftUI
import Observation
import WorkbenchCore

struct RemoteGitControls: View {
    @UILocalization private var L
    @Bindable var browser: RemoteGitBrowser
    @Binding var pendingBranch: String?
    private var pendingBranchName: String { pendingBranch ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                TextField("Git 仓库或 worktree 目录", text: $browser.gitInput)
                    .textFieldStyle(.roundedBorder).font(.system(size: WorkbenchTheme.Typography.body))
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
                    Text("工作树").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
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
                            .font(.system(size: WorkbenchTheme.Typography.body))
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
                Text(writeError).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .changes(_, _, let entries) = browser.gitStatus,
               entries.contains(where: { $0.hasStaged }) {
                HStack(spacing: 7) {
                    TextField("提交信息", text: $browser.gitCommitMessage)
                        .textFieldStyle(.roundedBorder).font(.system(size: WorkbenchTheme.Typography.body))
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
                                    Text(commit.hash).font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(commit.subject).font(.system(size: WorkbenchTheme.Typography.caption)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(commit.relativeDate).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.tertiary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 4)
                }.font(.system(size: WorkbenchTheme.Typography.caption))
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
                        .textFieldStyle(.roundedBorder).font(.system(size: WorkbenchTheme.Typography.body))
                        .onSubmit { browser.loadGitComparison() }
                    Button("比较") { browser.loadGitComparison() }.controlSize(.small)
                        .disabled(browser.loading || browser.gitStatus?.root == nil || browser.gitBaseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let comparison = browser.gitComparison {
                    Text("\(comparison.entries.count) 个文件 · 已读 \(browser.reviewProgress.reviewed.count) 个")
                        .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
                    DisclosureGroup("比较版本") {
                        Text("\(comparison.baseRef)\n\(comparison.mergeBase) → \(comparison.headCommit)")
                            .font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.system(size: WorkbenchTheme.Typography.caption))
                }
                Text("比较共同祖先到当前提交的改动，不含未提交内容；引用使用仓库现有数据，不自动 fetch。")
                    .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("暂存、提交与切换分支会直接修改远端工作区；差异与比较仍为只读。")
                    .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        Divider()
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

}

struct RemoteGitContent: View {
    @UILocalization private var L
    @Bindable var browser: RemoteGitBrowser
    @Binding var selection: NSRange

    @ViewBuilder var body: some View {
        if let error = browser.error {
            notice(error, symbol: "exclamationmark.triangle", tint: .orange)
        } else if browser.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取…").font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary)
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
                }.font(.system(size: WorkbenchTheme.Typography.caption)).padding(10)
            }
        VSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { entry in
                        HStack(spacing: 6) {
                            Button { browser.loadGitDiff(entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path)
                                        .font(.system(size: WorkbenchTheme.Typography.body)).lineLimit(1).truncationMode(.middle)
                                    HStack(spacing: 6) {
                                        Text(browser.gitRange == .branch ? L(key: entry.changeLabel) : entry.label)
                                        if browser.gitRange == .branch {
                                            if browser.reviewProgress.isReviewed(entry.path) { Label("已读", systemImage: "checkmark.circle.fill") }
                                            else if browser.reviewProgress.changed.contains(entry.path) { Text("有新改动").foregroundStyle(.orange) }
                                        }
                                    }.font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
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
                        .background(entry.path == browser.gitPath ? WorkbenchTheme.Fill.selected : .clear)
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
                        .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.orange)
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

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(tint)
            Text(text).font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
