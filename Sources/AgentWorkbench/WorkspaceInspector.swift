import SwiftUI
import WorkbenchCore

/// The workspace inspector: the task panel, or the selected session's
/// uncommitted changes read from its working tree.
struct WorkspaceInspector: View {
    let model: WorkbenchModel

    var body: some View {
        let controller = model.taskContextWindow
        VStack(spacing: 0) {
            switch controller.page {
            case .task:
                TaskContextView(model: model,
                    detach: { controller.show(model: model) },
                    close: { controller.embeddedVisible = false })
            case .changes:
                ChangesInspectorView(model: model, close: { controller.embeddedVisible = false })
            }
        }
    }
}

/// Opens the inspector on its changes page; a second press closes it.
struct ChangesButton: View {
    let model: WorkbenchModel
    var body: some View {
        let open = model.taskContextWindow.isShowing(.changes)
        Button { model.taskContextWindow.togglePage(.changes, model: model) } label: {
            WorkbenchToolbarSymbol(name: "plus.forwardslash.minus")
                .foregroundStyle(open ? WorkbenchTheme.accent : .secondary)
        }.buttonStyle(.plain).help("查看改动").accessibilityLabel("改动")
            .accessibilityValue(open ? "已展开" : "已收起")
    }
}

/// The working tree's uncommitted files above the selected file's diff, which
/// fills the rest of the panel. Reads start when the page is showing and stop
/// when it hides; the full review stays in the file window.
struct ChangesInspectorView: View {
    private static let fileRowHeight: CGFloat = 44
    @UILocalization private var L
    let model: WorkbenchModel
    let close: () -> Void
    @State private var refresh = 0
    /// The file the reader chose; it stays selected across refreshes.
    @State private var preferredPath: String?

    private var browser: RemoteFileBrowser { model.changesBrowser }
    private var item: WorkspaceSession? { model.showDashboard ? nil : model.selectedItem }
    private var active: Bool {
        model.taskContextWindow.isShowing(.changes) && !model.showDashboard && !model.draftingNewTask
    }
    private struct LoadKey: Equatable {
        let reference: SessionReference?
        let directory: String
        let online: Bool
        let refresh: Int
    }
    private var key: LoadKey {
        LoadKey(reference: active ? item?.reference : nil, directory: item?.directory ?? "",
                online: item?.online == true, refresh: refresh)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.inspectorHeightContribution()
            ScrollView {
                content.fixedSize(horizontal: false, vertical: true).inspectorHeightContribution()
            }
        }.font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .workbenchHostedTask(id: key) {
                guard key.reference != nil else { browser.cancel(); return }
                model.syncChangesBrowser()
                browser.loadGitStatus()
            }
            .workbenchHostedTask(id: item?.reference) { preferredPath = nil }
            .workbenchHostedTask(id: browser.gitStatus) { selectDefaultEntry() }
            .workbenchHostedTask(id: browser.loading) { selectDefaultEntry() }
    }

    private var entries: [RemoteGitEntry] {
        if case .changes(_, _, let entries) = browser.gitStatus { return entries }
        return []
    }

    private var header: some View {
        HStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("改动").font(.system(size: 16, weight: .semibold)).foregroundStyle(WorkbenchTheme.ink)
                Text(summary).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.quiet)
            }
            Spacer(minLength: 4)
            Menu {
                Button("刷新改动") { refresh += 1 }.disabled(item == nil || browser.loading)
                Button("在文件窗口中审阅") { model.reviewChangesInFileWindow() }.disabled(item == nil)
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("会话操作")
            Button(action: close) {
                Image(systemName: "xmark").foregroundStyle(.secondary).frame(width: 32, height: 32)
                    .background(Color.primary.opacity(WorkbenchTheme.Fill.surface), in: Circle())
            }
                .help("收起面板").accessibilityLabel("收起面板")
        }.font(.system(size: 12)).buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var summary: String {
        switch browser.gitStatus {
        case .changes(_, _, let entries): return L("\(entries.count) 个文件")
        case .clean: return L("没有未提交的改动")
        case .notARepository, nil: return L("改动")
        }
    }

    @ViewBuilder private var content: some View {
        if item == nil {
            notice(L("选择一个会话，查看它的改动。"), symbol: "plus.forwardslash.minus")
        } else if let error = browser.error, browser.gitStatus == nil {
            VStack(spacing: 10) {
                notice(error, symbol: "exclamationmark.triangle")
                Button("重试") { refresh += 1 }.disabled(browser.loading)
            }.frame(maxWidth: .infinity)
        } else {
            switch browser.gitStatus {
            case nil:
                if browser.loading { loadingNotice } else { notice(L("读取当前项目 Git 工作树的改动。"), symbol: "arrow.triangle.branch") }
            case .notARepository:
                notice(L("所选目录不是可用的 Git 工作树。"), symbol: "questionmark.folder")
            case .clean:
                notice(L("所选工作树干净，没有未提交的改动。"), symbol: "checkmark.circle")
            case .changes(_, _, let entries):
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(entries) { entry in row(entry) }
                        }.padding(.horizontal, 8).padding(.vertical, 8)
                    }.frame(height: CGFloat(min(entries.count, 5)) * Self.fileRowHeight + 16)
                    Divider().padding(.horizontal, 20)
                    diffPane
                }
            }
        }
    }

    private func row(_ entry: RemoteGitEntry) -> some View {
        return Button {
            preferredPath = entry.path
            browser.loadWorkingChange(entry)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: entry)).foregroundStyle(.secondary).frame(width: 16)
                Text((entry.path as NSString).lastPathComponent).font(.system(size: 14))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(entry.untracked ? "?" : String(entry.worktreeStatus == " " ? entry.indexStatus : entry.worktreeStatus))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: Self.fileRowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(WorkbenchDisclosureButtonStyle(selected: entry.path == browser.gitPath))
            .accessibilityValue(entry.label)
            .help((entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path) + "\n" + entry.label)
    }

    private func symbol(for entry: RemoteGitEntry) -> String {
        if entry.untracked || entry.indexStatus == "A" { return "plus.circle" }
        if entry.indexStatus == "D" || entry.worktreeStatus == "D" { return "minus.circle" }
        if entry.originalPath != nil { return "arrow.right.circle" }
        return "doc.text"
    }

    @ViewBuilder private var diffPane: some View {
        if browser.loading {
            loadingNotice
        } else if let error = browser.error {
            notice(error, symbol: "exclamationmark.triangle")
        } else {
            switch browser.gitDiff {
            case .text(let diff, let truncated):
                let body = diff.range(of: "\n@@").map { String(diff[diff.index(after: $0.lowerBound)...]) } ?? diff
                VStack(alignment: .leading, spacing: 0) {
                    Text(browser.gitPath.map { ($0 as NSString).lastPathComponent } ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
                    if truncated {
                        Label("差异过大，已截断", systemImage: "scissors")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                        Divider()
                    }
                    // File metadata is already in the list and title. Keep the
                    // complete original patch available in the full review.
                    RemoteSourceText(text: body, line: nil, diff: true, transparentBackground: true)
                        .frame(height: min(360, max(100, CGFloat(body.split(separator: "\n", omittingEmptySubsequences: false).count) * 20 + 24)))
                        .id("inspector-diff:\(browser.gitDirectory):\(browser.gitPath ?? ""):\(browser.gitRange.rawValue)")
                        .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card, style: .continuous))
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }
            case .binary: notice(L("二进制文件差异，不做预览。"), symbol: "doc.zipper")
            case .empty: notice(L("该文件在当前范围内没有差异。"), symbol: "equal.circle")
            case .untracked: notice(L("未跟踪文件，没有 tracked diff；可在「文件」页查看内容。"), symbol: "plus.circle")
            case .notARepository: notice(L("所选工作树不再是 Git 仓库。"), symbol: "questionmark.folder")
            case nil: notice(L("选择一个文件查看差异。"), symbol: "doc.text.magnifyingglass")
            }
        }
    }

    private var loadingNotice: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在读取…").font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func notice(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity)
    }

    /// After a status read, show the chosen file again, or the first change.
    private func selectDefaultEntry() {
        guard active, !browser.loading, browser.gitPath == nil, browser.error == nil,
              let entry = entries.first(where: { $0.path == preferredPath }) ?? entries.first else { return }
        browser.loadWorkingChange(entry)
    }
}
