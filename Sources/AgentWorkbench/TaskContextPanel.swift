import AppKit
import Observation
import SwiftUI
import WorkbenchCore

@MainActor @Observable final class TaskContextWindowController: NSObject, NSWindowDelegate {
    var locked: SessionReference?
    var embeddedVisible = false
    private(set) var visible = false
    @ObservationIgnored private(set) var window: NSPanel?
    func show(model: WorkbenchModel) {
        embeddedVisible = false
        if window == nil {
            let panel = TaskContextPanel(contentRect: NSRect(x: 220, y: 180, width: 400, height: 580),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = L("任务面板"); panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.minSize = NSSize(width: 340, height: 360)
            panel.delegate = self
            panel.setFrameAutosaveName("PerchTaskContext")
            panel.contentViewController = NSHostingController(rootView: TaskContextView(model: model, detached: true))
            panel.setFrameUsingName("PerchTaskContext")
            window = panel
        }
        visible = true
        window?.makeKeyAndOrderFront(nil)
    }
    func embed(model: WorkbenchModel) {
        close()
        embeddedVisible = true
        if model.showDashboard || model.draftingNewTask,
           let source = locked ?? model.selectedReference,
           let item = model.allSessions.first(where: { $0.reference == source }) {
            model.open(item)
        }
        CompanionWindowController.shared.showMain()
    }
    func close() { visible = false; window?.close() }
    func windowWillClose(_ notification: Notification) {
        visible = false
        window?.contentViewController = nil
        window = nil
    }
}

private final class TaskContextPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

struct TaskContextButton: View {
    let model: WorkbenchModel
    var body: some View {
        Button {
            if model.taskContextWindow.visible { model.taskContextWindow.embed(model: model) }
            else { model.taskContextWindow.embeddedVisible.toggle() }
        } label: {
            WorkbenchToolbarSymbol(name: "sidebar.right")
                .foregroundStyle(model.taskContextWindow.embeddedVisible ? WorkbenchTheme.accent : .secondary)
                .workbenchControlSurface()
        }.buttonStyle(.plain).help("任务面板").accessibilityLabel("任务面板")
            .accessibilityValue(model.taskContextWindow.embeddedVisible ? "已展开" : "已收起")
    }
}

/// Reserve a side lane only when the full reading column fits. At smaller sizes,
/// a compact entry above the conversation opens the independent panel instead.
/// Padding changes preserve the transcript and composer at one structural identity.
struct TaskContextWorkspace<Content: View>: View {
    let model: WorkbenchModel
    @ViewBuilder let content: Content
    private var shown: Bool {
        model.taskContextWindow.embeddedVisible && !model.showDashboard && !model.draftingNewTask
    }
    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - ReplyStyle.readingWidth - 2 * ReplyStyle.horizontalPadding - 24
            let alongside = available >= 280
            let cardWidth = min(340, available)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, shown && alongside ? cardWidth + 24 : 0)
                .padding(.top, shown && !alongside ? 48 : 0)
                .overlay(alignment: .topTrailing) {
                    if shown && alongside {
                        TaskContextView(model: model, maximumHeight: min(620, max(0, geometry.size.height - 24)),
                                        detach: { model.taskContextWindow.show(model: model) },
                                        close: { model.taskContextWindow.embeddedVisible = false })
                            .frame(width: cardWidth)
                            .contentShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
                            .background(WorkbenchTheme.contentBackground)
                            .clipShape(RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
                            .overlay {
                                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card)
                                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.04), radius: 12, y: 3)
                            .padding(12)
                    } else if shown {
                        HStack(spacing: 12) {
                            Text("任务面板").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button { model.taskContextWindow.show(model: model) } label: {
                                Label("在浮窗中查看", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            Button { model.taskContextWindow.embeddedVisible = false } label: {
                                Image(systemName: "xmark").frame(width: 24, height: 24)
                            }.help("收起任务面板").accessibilityLabel("收起任务面板")
                        }.font(.callout).buttonStyle(.borderless)
                            .frame(maxWidth: ReplyStyle.readingWidth).frame(height: 48)
                            .padding(.horizontal, ReplyStyle.horizontalPadding).frame(maxWidth: .infinity)
                    }
                }
        }
    }
}

struct TaskContextView: View {
    let model: WorkbenchModel
    var detached = false
    var maximumHeight: CGFloat?
    var detach: (() -> Void)?
    var close: (() -> Void)?
    @State private var headerHeight: CGFloat?
    @State private var contentHeight: CGFloat?
    @State private var footerHeight: CGFloat?
    @State private var state = TaskContextState()
    @State private var allFiles = false
    @State private var allTasks = false
    @State private var completedTools = false
    @State private var outputTask: String?
    @State private var draftSource: WorkspaceSession?
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .system
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    private var reference: SessionReference? {
        model.taskContextWindow.locked ?? (model.showDashboard ? nil : model.selectedReference)
    }
    private var item: WorkspaceSession? { model.allSessions.first { $0.reference == reference } }
    private var active: Bool { !detached || model.taskContextWindow.visible }
    private var current: TaskContextSnapshot? { state.reference == reference ? state.snapshot : nil }
    private struct LoadKey: Equatable {
        let reference: SessionReference?
        let online: Bool
        let refresh: Int
        let language: AppLanguage
    }
    private var key: LoadKey {
        LoadKey(reference: active && reference?.kind != .terminal ? reference : nil,
                online: item?.online == true, refresh: state.refresh, language: language)
    }
    private var fittedHeight: CGFloat? {
        guard let maximumHeight else { return nil }
        guard let headerHeight, let contentHeight else { return maximumHeight }
        return min(maximumHeight, headerHeight + contentHeight + (detached && item != nil ? footerHeight ?? 0 : 0))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = state.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("状态未同步", systemImage: "wifi.exclamationmark")
                            Text(error).font(.caption).textSelection(.enabled)
                            Button("重试") { state.refresh += 1 }.disabled(item?.online != true)
                        }.foregroundStyle(.secondary)
                    }
                    if let current, let item {
                        sections(current, item: item)
                    } else if state.loading {
                        ProgressView("正在读取任务…").frame(maxWidth: .infinity)
                    } else if reference == nil {
                        Text("选择一个会话，查看它的文件、活动和待处理事项。").foregroundStyle(.secondary)
                    } else if item == nil {
                        Text("此任务已不在工作台中，请取消锁定后选择其他会话。").foregroundStyle(.secondary)
                    } else if reference?.kind == .terminal {
                        Text("终端任务请在完整会话中查看。").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            if detached, let item {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Button("打开会话") { model.open(item); openMain() }
                        Spacer()
                        if item.reference.kind != .terminal {
                            Button("补充要求") { draftSource = item }
                                .help("补充到该任务草稿，不自动发送")
                        }
                    }.buttonStyle(.borderless).padding(14)
                }.fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: fittedHeight)
            .background(detached ? Color(nsColor: .windowBackgroundColor) : WorkbenchTheme.contentBackground)
            .environment(\.locale, language.resolvedLocale).preferredColorScheme(appearance.colorScheme)
            .task(id: key) {
                let input = key
                await state.follow(input.reference, online: input.online) {
                    guard let source = input.reference else { throw CancellationError() }
                    return try await model.readTaskContext(source)
                }
            }
            .onChange(of: reference) { _, _ in
                allFiles = false; allTasks = false; completedTools = false; outputTask = nil
            }
            .sheet(item: $draftSource) { source in
                TaskContextDraft(model: model, source: source)
            }
    }
    private var header: some View {
        HStack(spacing: 4) {
            if (detached || model.taskContextWindow.locked != nil), let item {
                Button { model.open(item); openMain() } label: {
                    Text(item.title).lineLimit(1).truncationMode(.tail)
                }.help("打开会话")
            } else {
                Text("任务面板")
            }
            Spacer(minLength: 4)
            if detached {
                Button { model.taskContextWindow.embed(model: model) } label: {
                    Image(systemName: "rectangle.inset.filled").frame(width: 24, height: 24)
                }
                    .help("在正文中显示").accessibilityLabel("在正文中显示")
            }
            Button {
                model.taskContextWindow.locked = model.taskContextWindow.locked == nil ? reference : nil
            } label: {
                Image(systemName: model.taskContextWindow.locked == nil ? "pin" : "pin.fill")
                    .frame(width: 24, height: 24)
            }.disabled(reference == nil)
                .help(model.taskContextWindow.locked == nil ? "锁定此任务" : "跟随当前会话")
                .accessibilityLabel(model.taskContextWindow.locked == nil ? "锁定此任务" : "跟随当前会话")
            if let detach {
                Button(action: detach) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24) }
                    .help("固定为浮窗").accessibilityLabel("固定为浮窗")
            }
            if let close {
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .help("收起任务面板").accessibilityLabel("收起任务面板")
            }
        }.font(.callout).foregroundStyle(.secondary).buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.top, 10)
    }

    @ViewBuilder private func sections(_ value: TaskContextSnapshot, item: WorkspaceSession) -> some View {
        let online = item.online && state.error == nil
        if !value.requests.isEmpty || value.failure != nil {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("需要你处理", count: value.requests.count + (value.failure == nil ? 0 : 1))
                ForEach(value.requests.prefix(3)) { request in
                    Text(request.title).lineLimit(3).font(.callout)
                }
                if let error = value.failure { Text(error).lineLimit(3).foregroundStyle(.orange) }
                Button("查看并处理") { model.inspect(item); openMain() }.disabled(!online)
            }
        }
        if !value.files.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("文档与产物", count: value.files.count)
                ForEach(allFiles ? value.files : Array(value.files.prefix(4))) { file in
                    Button {
                        model.openWorkspaceFile(GroupOutcome(title: file.name, link: file.path, source: item.reference))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(file.written ? "本轮更新" : "相关文件").font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(file.path).disabled(!item.online)
                }
                if value.files.count > 4 { Button(allFiles ? "收起" : "查看全部文件") { allFiles.toggle() }.font(.caption) }
            }
        }
        if !value.tasks.isEmpty || value.taskError != nil {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("后台任务与子 Agent", count: value.tasks.count)
                if let error = value.taskError { Text(error).font(.caption).foregroundStyle(.secondary) }
                let ordered = value.tasks.sorted { $0.isRunning && !$1.isRunning }
                ForEach(allTasks ? ordered : Array(ordered.prefix(4))) { task in
                    taskRow(task, item: item, online: online)
                }
                if value.tasks.count > 4 { Button(allTasks ? "收起" : "查看全部任务") { allTasks.toggle() }.font(.caption) }
            }
        }
        if !value.tools.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("工具活动", count: value.tools.count)
                ForEach(value.tools.filter { $0.staysVisible || $0.status == .failed }) { tool in toolRow(tool) }
                let completed = value.tools.filter { !$0.staysVisible && $0.status != .failed }
                if !completed.isEmpty {
                    DisclosureGroup("已结束的调用 · \(completed.count)", isExpanded: $completedTools) {
                        ForEach(completed.suffix(20).reversed()) { tool in toolRow(tool) }
                        if completed.count > 20 {
                            Text("显示最近 20 次调用，完整记录请打开会话。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if value.files.isEmpty && value.tasks.isEmpty && value.tools.isEmpty &&
            value.requests.isEmpty && value.failure == nil {
            Text(value.busy ? "任务正在进行，文件和工具活动会显示在这里。" : "此任务暂时没有文件或工具活动。")
                .foregroundStyle(.secondary)
        }
    }
    private func sectionTitle(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(count.formatted()).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func toolRow(_ tool: VisibleTool) -> some View {
        DisclosureGroup {
            KimiToolCard(tool: tool)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(ConversationActivity.summary(of: tool)).lineLimit(2)
                Text(ConversationActivity.status(of: tool)).font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout)
    }
    private func taskRow(_ task: KimiTask, item: WorkspaceSession, online: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.description.isEmpty ? task.kindLabel : task.description).font(.callout).lineLimit(2)
            HStack(spacing: 8) {
                Text(task.phaseLabel)
                if let elapsed = task.elapsed(at: Date()) { Text("\(Int(elapsed)) 秒").monospacedDigit() }
            }.font(.caption).foregroundStyle(.secondary)
            if let latest = task.latestActivity { Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            HStack {
                if item.reference.kind == .kimi && task.kind != "subagent" {
                    Button(outputTask == task.id ? "收起输出" : "查看输出") {
                        if outputTask == task.id { outputTask = nil }
                        else {
                            outputTask = task.id
                            Task { await state.perform(task, source: item.reference, stopping: false) {
                                try await model.taskContextOperation(task, source: item.reference, stop: false)
                            } }
                        }
                    }
                } else {
                    Button("查看会话") { model.open(item); openMain() }
                }
                Spacer()
                if task.isRunning && (task.stoppable == true || (item.reference.kind == .kimi && task.kind != "subagent")) {
                    Button(state.stopRequested.contains(task.id) ? "已请求停止" : "停止") {
                        Task { await state.perform(task, source: item.reference, stopping: true) {
                            try await model.taskContextOperation(task, source: item.reference, stop: true)
                        } }
                    }.disabled(state.stopRequested.contains(task.id))
                }
            }.font(.caption).disabled(!online || state.working.contains(task.id))
            if outputTask == task.id {
                ScrollView {
                    Text(state.outputs[task.id] ?? task.outputPreview ?? L("正在读取输出…"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
            if let error = state.actionErrors[task.id] { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func openMain() {
        close?()
        CompanionWindowController.shared.showMain()
    }
}

struct TaskContextDraft: View {
    let model: WorkbenchModel
    let source: WorkspaceSession
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("补充要求").font(.headline)
            Text(source.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            TextField("希望任务如何继续…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...8).focused($focused)
            Text("加入该任务的草稿，由你确认后发送。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("加入草稿并查看") {
                    model.stageArtifactFeedback(text, to: source.reference)
                    model.open(source); CompanionWindowController.shared.showMain(); dismiss()
                }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !model.allSessions.contains { $0.reference == source.reference })
            }
        }.padding(20).frame(width: 340).onAppear { focused = true }
    }
}
