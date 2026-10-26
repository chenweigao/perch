import SwiftUI
import WorkbenchCore

/// The workspace inspector: the task panel, or the selected session's
/// uncommitted changes read from its working tree.
struct WorkspaceInspector: View {
    let model: WorkbenchModel

    var body: some View {
        let controller = model.taskContextWindow
        VStack(spacing: 0) {
            Picker("面板页面", selection: Binding(get: { controller.page },
                                              set: { controller.showPage($0, model: model) })) {
                Text("任务").tag(WorkspaceInspectorPage.task)
                Text("改动").tag(WorkspaceInspectorPage.changes)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.top, 12)
                .accessibilityIdentifier("inspector.page")
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
            header
            Divider()
            content
        }.font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: key) {
                guard key.reference != nil else { browser.cancel(); return }
                model.syncChangesBrowser()
                browser.loadGitStatus()
            }
            .onChange(of: item?.reference) { _, _ in preferredPath = nil }
            .onChange(of: browser.gitStatus) { _, _ in selectDefaultEntry() }
            .onChange(of: browser.loading) { _, _ in selectDefaultEntry() }
    }

    private var entries: [RemoteGitEntry] {
        if case .changes(_, _, let entries) = browser.gitStatus { return entries }
        return []
    }

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                if let root = browser.gitStatus?.root {
                    Text(URL(fileURLWithPath: root).lastPathComponent)
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(root)
                }
            }
            Spacer(minLength: 4)
            Button { refresh += 1 } label: {
                Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
            }.disabled(item == nil || browser.loading)
                .help("刷新改动").accessibilityLabel("刷新改动")
            Button { model.reviewChangesInFileWindow() } label: {
                Image(systemName: "arrow.up.forward.app").frame(width: 24, height: 24)
            }.disabled(item == nil)
                .help("在文件窗口中审阅").accessibilityLabel("在文件窗口中审阅")
            Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .help("收起面板").accessibilityLabel("收起面板")
        }.font(.system(size: 12)).foregroundStyle(.secondary).buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
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
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        }.padding(.horizontal, 8).padding(.vertical, 6)
                    }.frame(height: CGFloat(min(entries.count, 5)) * 42 + 12)
                    Divider()
                    diffPane
                }
            }
        }
    }

    private func row(_ entry: RemoteGitEntry) -> some View {
        let directory = (entry.path as NSString).deletingLastPathComponent
        return Button {
            preferredPath = entry.path
            browser.loadWorkingChange(entry)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: entry)).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text((entry.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(directory.isEmpty ? entry.label : directory + " · " + entry.label)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(WorkbenchDisclosureButtonStyle(selected: entry.path == browser.gitPath))
            .help(entry.originalPath.map { "\($0) → \(entry.path)" } ?? entry.path)
    }

    private func symbol(for entry: RemoteGitEntry) -> String {
        if entry.untracked || entry.indexStatus == "A" { return "plus.circle" }
        if entry.indexStatus == "D" || entry.worktreeStatus == "D" { return "minus.circle" }
        if entry.originalPath != nil { return "arrow.right.circle" }
        return "pencil.circle"
    }

    @ViewBuilder private var diffPane: some View {
        if browser.loading {
            loadingNotice
        } else if let error = browser.error {
            notice(error, symbol: "exclamationmark.triangle")
        } else {
            switch browser.gitDiff {
            case .text(let diff, let truncated):
                VStack(alignment: .leading, spacing: 0) {
                    if truncated {
                        Label("差异过大，已截断", systemImage: "scissors")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                        Divider()
                    }
                    RemoteSourceText(text: diff, line: nil, diff: true)
                        .id("inspector-diff:\(browser.gitDirectory):\(browser.gitPath ?? ""):\(browser.gitRange.rawValue)")
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
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notice(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// After a status read, show the chosen file again, or the first change.
    private func selectDefaultEntry() {
        guard active, !browser.loading, browser.gitPath == nil, browser.error == nil,
              let entry = entries.first(where: { $0.path == preferredPath }) ?? entries.first else { return }
        browser.loadWorkingChange(entry)
    }
}
