import AppKit
import SwiftUI
import Observation
import WorkbenchCore

enum RemotePanelMode: String, CaseIterable, Identifiable {
    case file, git
    var id: String { rawValue }
    var label: LocalizedStringKey { self == .file ? "文件" : "Git 变更" }
}

struct DocumentLibraryActions {
    let pinned: Bool
    let togglePin: () -> Void
}

struct RemoteFilePanel: View {
    static let directoryRowHeight: CGFloat = 32
    @UILocalization private var L
    @Bindable var browser: RemoteFileBrowser
    var showsCloseButton = true
    /// The floating inspector supplies its own directory/navigation chrome.
    var compact = false
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
    private var isDocumentReading: Bool {
        browser.mode == .file && browser.previewKind == .markdown && browser.documents.current?.reading == true
    }
    @ViewBuilder var body: some View {
        if compact {
            fileContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .popover(isPresented: $showLocation) { locationEditor }
                .workbenchHostedTask(id: browser.fileRequest?.id) {
                    if let request = browser.fileRequest { await browser.loadFile(request) }
                }
        } else { fullPanel }
    }
    private var fullPanel: some View {
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
                            .font(.system(size: WorkbenchTheme.Typography.body)).lineLimit(1).truncationMode(.middle).help(browser.path)
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
                RemoteGitControls(browser: browser.git, pendingBranch: $pendingBranch)
            }
            if contextAdded {
                HStack {
                    Label("已加入会话草稿", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    if let showAddedDraft { Button("查看草稿", action: showAddedDraft) }
                }.font(.system(size: WorkbenchTheme.Typography.caption)).padding(.horizontal, 14).padding(.vertical, 6)
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
                    Text("\(commit.author) · \(commit.relativeDate)").font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary)
                    switch browser.gitCommitDiff {
                    case .text(let diff, let truncated):
                        if truncated {
                            Label("差异过大，已截断", systemImage: "scissors")
                                .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.orange)
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
                        Text(context.reference).font(.system(size: WorkbenchTheme.Typography.secondary)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView { Text(context.excerpt).font(.system(size: WorkbenchTheme.Typography.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                    }
                    TextField("希望如何修改？", text: $feedback, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                    if let destination = draft.destination { Text("引用到：\(destination)").font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary) }
                    Text("加入会话草稿，检查后再发送。").font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary)
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
            Text("\(browser.hostName) · \(browser.cwd)").font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary).textSelection(.enabled)
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
            Text("仅定位已读取内容中的行号").font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary)
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
            Text(browser.path).font(.system(size: WorkbenchTheme.Typography.body, design: .monospaced)).textSelection(.enabled)
            Text("\(browser.hostName) · \(browser.cwd)").font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary).textSelection(.enabled)
            if case .text(let text, _, let size) = browser.content {
                Text(byteLabel(size)).font(.system(size: WorkbenchTheme.Typography.secondary))
                if let line = browser.targetLine {
                    Text(line <= RemoteSourceStyle.lineCount(text) ? L("Line \(line)") : L("Line \(line) is outside the loaded content"))
                        .font(.system(size: WorkbenchTheme.Typography.secondary))
                }
            } else if case .binary(let size) = browser.content { Text(byteLabel(size)).font(.system(size: WorkbenchTheme.Typography.secondary)) }
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
        if browser.mode == .git { RemoteGitContent(browser: browser.git, selection: $selection) } else { fileContent }
    }

    @ViewBuilder private var fileContent: some View {
        if let error = browser.error {
            notice(error, symbol: "exclamationmark.triangle", tint: .orange)
        } else if browser.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取…").font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch browser.content {
            case .matches(let paths):
                VStack(alignment: .leading, spacing: 8) {
                    Text("找到多个同名文件，请选择：")
                        .font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary).padding(.horizontal, 14)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(paths, id: \.self) { path in
                                Button { browser.open(path, line: browser.targetLine) } label: {
                                    Text(path).font(.system(size: WorkbenchTheme.Typography.body, design: .monospaced))
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
                                            .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary).frame(width: 14)
                                        Text(entry.name).font(.system(size: WorkbenchTheme.Typography.body)).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }.padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: Self.directoryRowHeight).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 8)
                    }
                }
            case .text(let text, let truncated, let size):
                VStack(alignment: .leading, spacing: 0) {
                    if truncated {
                        Label(browser.readingTail ? "正在查看文件尾部" : "仅显示已读取部分", systemImage: "scissors")
                            .font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 5)
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
            Text(text).font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
