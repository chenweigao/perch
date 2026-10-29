import AppKit
import Observation
import SwiftUI
import WorkbenchCore

enum WorkspaceInspectorPage: String, Hashable { case task, changes, files }

@MainActor @Observable final class TaskContextWindowController: NSObject, NSWindowDelegate {
    var locked: SessionReference?
    var embeddedVisible = false
    /// The inspector's page. Not persisted: a launch starts on the task panel.
    var page: WorkspaceInspectorPage = .task
    /// The task the task page shows in place of its list. It survives docking,
    /// detaching and page switches, and closes when the panel follows another
    /// session. Not persisted.
    var detail: TaskContextRoute?
    private(set) var visible = false
    func isShowing(_ page: WorkspaceInspectorPage) -> Bool { embeddedVisible && self.page == page }
    /// Only one task-panel presentation reads at a time, so showing the task page
    /// returns a detached panel to the inspector; the changes page lives only here.
    func showPage(_ page: WorkspaceInspectorPage, model: WorkbenchModel) {
        self.page = page
        if page == .task && visible { embed(model: model) } else { embeddedVisible = true }
    }
    /// A toolbar button closes its own page and switches over from the other one.
    func togglePage(_ page: WorkspaceInspectorPage, model: WorkbenchModel) {
        if isShowing(page) { embeddedVisible = false } else { showPage(page, model: model) }
    }
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

/// Shares the toolbar's grouped glass capsule; it draws no surface of its own.
struct TaskContextButton: View {
    let model: WorkbenchModel
    var body: some View {
        let open = model.taskContextWindow.isShowing(.task)
        Button { model.taskContextWindow.togglePage(.task, model: model) } label: {
            WorkbenchToolbarSymbol(name: "checklist")
                .foregroundStyle(open ? WorkbenchTheme.accent : .secondary)
        }.buttonStyle(WorkbenchToolbarButtonStyle(selected: open)).help("任务面板").accessibilityLabel("任务面板")
            .accessibilityValue(open ? "已展开" : "已收起")
    }
}

struct TaskContextView: View {
    let model: WorkbenchModel
    var detached = false
    var detach: (() -> Void)?
    var close: (() -> Void)?
    @State private var state = TaskContextState()
    @State private var allFiles = false
    @State private var completedTasks = false
    @State private var completedTools = false
    @State private var draftSource: WorkspaceSession?
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .system
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    private var reference: SessionReference? {
        model.taskContextWindow.locked ?? (model.showDashboard ? nil : model.selectedReference)
    }
    private var item: WorkspaceSession? { model.allSessions.first { $0.reference == reference } }
    private var active: Bool {
        if detached { return model.taskContextWindow.visible }
        return model.taskContextWindow.isShowing(.task) && !model.showDashboard && !model.draftingNewTask
    }
    private var current: TaskContextSnapshot? { state.reference == reference ? state.snapshot : nil }
    /// The task shown in place of the list, while it belongs to this panel's session.
    private var detail: TaskContextRoute? {
        guard let route = model.taskContextWindow.detail, route.source == reference else { return nil }
        return route
    }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
            if let detail, let item {
                if let error = state.error {
                    syncError(error).padding(.horizontal, 16).padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TaskContextDetailView(model: model, item: item, route: detail, snapshot: current, state: state,
                                      online: item.online && state.error == nil, active: active,
                                      back: { model.taskContextWindow.detail = nil })
                    .id(detail)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let error = state.error { syncError(error) }
                        if let current, let item {
                            sections(current, item: item)
                        } else if state.loading {
                            ProgressView("正在读取任务…").frame(maxWidth: .infinity)
                        } else if reference == nil {
                            Text("选择一个会话，查看它的文件、活动和待处理事项。").foregroundStyle(WorkbenchTheme.quiet)
                        } else if item == nil {
                            Text("此任务已不在工作台中，请取消锁定后选择其他会话。").foregroundStyle(WorkbenchTheme.quiet)
                        } else if reference?.kind == .terminal {
                            Text("终端任务请在完整会话中查看。").foregroundStyle(WorkbenchTheme.quiet)
                        } else if state.error == nil {
                            Text("暂无任务活动").foregroundStyle(WorkbenchTheme.quiet)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
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
            }
        }.font(.system(size: WorkbenchTheme.Typography.body)).frame(maxWidth: .infinity, maxHeight: .infinity)
            // Embedded in the integrated lane, the workspace owns the surface;
            // detached needs the window's own opaque background.
            .background(detached ? Color(nsColor: .windowBackgroundColor) : Color.clear)
            #if PERCH_ACCEPTANCE
            .background(NativeTaskContextProbe(reference: state.reference, loading: state.loading,
                                               ready: current != nil))
            #endif
            .environment(\.locale, language.resolvedLocale).preferredColorScheme(appearance.colorScheme)
            // A panel that follows the selection leaves a task of the previous
            // session; a locked one keeps it.
            .onChange(of: reference, initial: true) { _, next in
                if let next, let route = model.taskContextWindow.detail, route.source != next {
                    model.taskContextWindow.detail = nil
                }
            }
            .workbenchHostedTask(id: key) {
                let input = key
                if state.reference != input.reference {
                    allFiles = false; completedTasks = false; completedTools = false
                }
                await state.follow(input.reference, online: input.online) {
                    guard let source = input.reference else { throw CancellationError() }
                    return try await model.readTaskContext(source)
                }
            }
            .sheet(item: $draftSource) { source in
                TaskContextDraft(model: model, source: source)
            }
    }
    private var header: some View {
        HStack(spacing: 4) {
            if let item {
                Button { model.open(item); openMain() } label: {
                    Text(item.title).font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                }.help("打开会话")
            } else {
                Text("任务面板").font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold)).foregroundStyle(.primary)
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
        }.font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary).buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.top, 10)
    }

    @ViewBuilder private func sections(_ value: TaskContextSnapshot, item: WorkspaceSession) -> some View {
        let online = item.online && state.error == nil
        if !value.requests.isEmpty || value.failure != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("需要你处理", count: value.requests.count + (value.failure == nil ? 0 : 1))
                ForEach(value.requests.prefix(3)) { request in
                    Button { model.inspect(item); openMain() } label: {
                        Label(request.title, systemImage: "bubble.left")
                            .lineLimit(3).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }.buttonStyle(TaskContextRowStyle()).disabled(!online)
                        .help("查看并处理")
                }
                if let error = value.failure {
                    Button { model.inspect(item); openMain() } label: {
                        Label(error, systemImage: "exclamationmark.circle")
                            .lineLimit(3).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }.buttonStyle(TaskContextRowStyle()).disabled(!online).help("查看并处理")
                }
            }
        }
        if !value.files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("文档与产物", count: value.files.count)
                ForEach(allFiles ? value.files : Array(value.files.prefix(4))) { file in
                    Button {
                        model.openWorkspaceFile(GroupOutcome(title: file.name, link: file.path, source: item.reference))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(WorkbenchTheme.quiet)
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if file.written { Text("本轮更新").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet) }
                        }.frame(minHeight: 36).contentShape(Rectangle())
                    }.buttonStyle(TaskContextRowStyle()).help(file.path).disabled(!item.online)
                }
                if value.files.count > 4 { Button(allFiles ? "收起" : "查看全部文件") { allFiles.toggle() }.font(.system(size: WorkbenchTheme.Typography.body)) }
            }
        }
        if !value.tasks.isEmpty || value.taskError != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("后台任务与子 Agent", count: value.tasks.count)
                if let error = value.taskError { Text(error).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet) }
                let tasks = TaskContextTasks(value.tasks)
                ForEach(tasks.current) { task in
                    taskRow(task, item: item)
                }
                if !tasks.finished.isEmpty {
                    DisclosureGroup("已结束的任务 · \(tasks.finished.count)", isExpanded: $completedTasks) {
                        ForEach(tasks.finished) { task in taskRow(task, item: item) }
                    }.font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(WorkbenchTheme.quiet)
                        .accessibilityIdentifier("task-context-finished")
                }
            }
        }
        if !value.tools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("工具活动", count: value.tools.count)
                ForEach(value.tools.filter { $0.staysVisible }) { tool in toolRow(tool) }
                let completed = value.tools.filter { !$0.staysVisible }
                if !completed.isEmpty {
                    DisclosureGroup("已结束的调用 · \(completed.count)", isExpanded: $completedTools) {
                        ForEach(completed.suffix(20).reversed()) { tool in toolRow(tool) }
                        if completed.count > 20 {
                            Text("显示最近 20 次调用，完整记录请打开会话。").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                        }
                    }.font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(WorkbenchTheme.quiet)
                }
            }
        }
        if value.files.isEmpty && value.tasks.isEmpty && value.tools.isEmpty &&
            value.requests.isEmpty && value.failure == nil {
            Text(value.busy ? "任务正在进行，文件和工具活动会显示在这里。" : "此任务暂时没有文件或工具活动。")
                .foregroundStyle(WorkbenchTheme.quiet)
        }
    }
    private func sectionTitle(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
            Spacer()
            Text(count.formatted()).font(.system(size: WorkbenchTheme.Typography.caption)).monospacedDigit().foregroundStyle(WorkbenchTheme.quiet)
        }.padding(.bottom, 4)
    }
    private func toolRow(_ tool: VisibleTool) -> some View {
        DisclosureGroup {
            KimiToolCard(tool: tool)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: tool.status == .failed ? "exclamationmark.circle" : tool.staysVisible ? "circle.dashed" : "checkmark.circle")
                    .foregroundStyle(tool.staysVisible && tool.status != .running ? Color.orange : WorkbenchTheme.quiet).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ToolPresentation.compactTarget(tool)).lineLimit(2).foregroundStyle(.primary)
                    Text(ConversationActivity.status(of: tool)).font(.system(size: WorkbenchTheme.Typography.caption))
                        .foregroundStyle(tool.staysVisible && tool.status != .running ? Color.orange : WorkbenchTheme.quiet)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 4)
        }.font(.system(size: WorkbenchTheme.Typography.body))
    }
    /// The whole row opens the task in place of the list.
    private func taskRow(_ task: KimiTask, item: WorkspaceSession) -> some View {
        let title = task.displayTitle
        // Full commands belong to the in-place detail; the list stays a summary.
        let line = task.command == nil ? task.contextDetailLine : nil
        return Button {
            model.taskContextWindow.detail = TaskContextRoute(source: item.reference, taskID: task.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                TaskStatusSymbol(task: task).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(2).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(task.phaseLabel)
                        KimiTaskClock(task: task)
                    }.font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                    if let line {
                        Text(verbatim: line).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                    .foregroundStyle(WorkbenchTheme.quiet).padding(.top, 3).accessibilityHidden(true)
            }.padding(.vertical, 6).frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(TaskContextRowStyle()).help("查看详情")
            .accessibilityLabel(Text(verbatim: [title, task.phaseLabel, line].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint(Text("查看详情"))
            .accessibilityIdentifier("task-context-row-" + task.id)
    }
    private func syncError(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("状态未同步", systemImage: "wifi.exclamationmark")
            Text(error).font(.system(size: WorkbenchTheme.Typography.caption)).textSelection(.enabled)
            Button("重试") { state.refresh += 1 }.disabled(item?.online != true)
        }.foregroundStyle(WorkbenchTheme.quiet)
    }
    private func openMain() {
        close?()
        CompanionWindowController.shared.showMain()
    }
}

private struct TaskContextRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }
    private struct Row: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.padding(.horizontal, 4)
                .background(.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.04 : 0),
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row))
                .contentShape(Rectangle()).onHover { hovered = $0 }
        }
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
            Text("补充要求").font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
            Text(source.title).font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(WorkbenchTheme.quiet).lineLimit(2)
            TextField("希望任务如何继续…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...8).focused($focused)
            Text("加入该任务的草稿，由你确认后发送。").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
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
