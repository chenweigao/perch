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
    @State private var scrolled = false
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
            header.fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                .overlay(alignment: .bottom) { Divider().opacity(scrolled && detail == nil ? 1 : 0) }
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
                    VStack(alignment: .leading, spacing: 22) {
                        if let error = state.error { syncError(error) }
                        if let current, let item {
                            sections(current, item: item)
                        } else if state.loading {
                            ProgressView("正在读取任务…").frame(maxWidth: .infinity)
                        } else if reference == nil {
                            emptyState("sidebar.right", "选择一个会话，查看它的文件、活动和待处理事项。")
                        } else if item == nil {
                            emptyState("questionmark.folder", "此任务已不在工作台中，请取消锁定后选择其他会话。")
                        } else if reference?.kind == .terminal {
                            emptyState("terminal", "终端任务请在完整会话中查看。")
                        } else if state.error == nil {
                            emptyState("tray", "暂无任务活动")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, next in
                    scrolled = next
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
    /// "1 个运行中 · 76 次调用": what the lane holds, without opening a section.
    private var summary: String? {
        guard let current else { return nil }
        let running = current.tasks.filter(\.isRunning).count
        var parts: [String] = []
        if running > 0 { parts.append(L("\(running) 个运行中")) }
        if !current.tools.isEmpty { parts.append(L("\(current.tools.count) 次调用")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var header: some View {
        HStack(spacing: 2) {
            // Detached, the panel is the only place naming its task; embedded, the
            // toolbar already does, so the lane leads with its own title.
            VStack(alignment: .leading, spacing: 1) {
                if detached, let item {
                    Button { model.open(item); openMain() } label: {
                        Text(item.title).font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    }.buttonStyle(.plain).help("打开会话")
                } else {
                    Text("任务面板").font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                if let summary {
                    Text(verbatim: summary).font(.system(size: WorkbenchTheme.Typography.caption))
                        .monospacedDigit().foregroundStyle(WorkbenchTheme.quiet).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if detached {
                Button { model.taskContextWindow.embed(model: model) } label: {
                    Image(systemName: "rectangle.inset.filled")
                }
                    .help("在正文中显示").accessibilityLabel("在正文中显示")
            }
            let pinned = model.taskContextWindow.locked != nil
            Button {
                model.taskContextWindow.locked = pinned ? nil : reference
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
            }.buttonStyle(TaskContextIconStyle(selected: pinned)).disabled(reference == nil)
                .help(pinned ? "跟随当前会话" : "锁定此任务")
                .accessibilityLabel(pinned ? "跟随当前会话" : "锁定此任务")
            if let detach {
                Button(action: detach) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("固定为浮窗").accessibilityLabel("固定为浮窗")
            }
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .help("收起任务面板").accessibilityLabel("收起任务面板")
            }
        }.font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary)
            .buttonStyle(TaskContextIconStyle())
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    @ViewBuilder private func sections(_ value: TaskContextSnapshot, item: WorkspaceSession) -> some View {
        let online = item.online && state.error == nil
        if !value.requests.isEmpty || value.failure != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("需要你处理", icon: "bubble.left", count: value.requests.count + (value.failure == nil ? 0 : 1))
                ForEach(value.requests.prefix(3)) { request in
                    Button { model.inspect(item); openMain() } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bubble.left").foregroundStyle(Color.orange).frame(width: 16).padding(.top, 2)
                            Text(verbatim: request.title).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }.buttonStyle(TaskContextRowStyle(tinted: true)).disabled(!online)
                        .help("查看并处理")
                }
                if let error = value.failure {
                    Button { model.inspect(item); openMain() } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle").frame(width: 16).padding(.top, 2)
                            Text(verbatim: error).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }.foregroundStyle(Color.red).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }.buttonStyle(TaskContextRowStyle(tinted: true)).disabled(!online).help("查看并处理")
                }
            }
        }
        if !value.files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("文档与产物", icon: "doc.text", count: value.files.count)
                ForEach(allFiles ? value.files : Array(value.files.prefix(4))) { file in
                    let missing = model.isWorkspaceFileMissing(hostID: item.reference.hostID, path: file.path)
                    Button {
                        model.openWorkspaceFile(GroupOutcome(title: file.name, link: file.path, source: item.reference))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: TaskContextFileIcon.name(file.name)).foregroundStyle(WorkbenchTheme.quiet).frame(width: 16)
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(missing ? WorkbenchTheme.quiet : .primary)
                            Spacer(minLength: 4)
                            if missing {
                                Text("已删除").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                            } else if file.written {
                                Text("本轮更新").font(.system(size: WorkbenchTheme.Typography.caption))
                                    .foregroundStyle(WorkbenchTheme.quiet).padding(.horizontal, 6).frame(minHeight: 18)
                                    .background(WorkbenchTheme.Fill.surface, in: Capsule())
                            }
                        }.frame(minHeight: 36).contentShape(Rectangle())
                    }.buttonStyle(TaskContextRowStyle())
                        .help(missing ? "\(file.path)（文件已不在会话主机上）" : file.path)
                        .disabled(!item.online || missing)
                }
                if value.files.count > 4 {
                    Button { withAnimation(.snappy(duration: 0.18)) { allFiles.toggle() } } label: {
                        HStack(spacing: 10) {
                            Text(allFiles ? "收起" : "查看全部文件").foregroundStyle(WorkbenchTheme.quiet)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                                .foregroundStyle(WorkbenchTheme.quiet).rotationEffect(.degrees(allFiles ? 90 : 0))
                                .accessibilityHidden(true)
                        }.frame(minHeight: 30).contentShape(Rectangle())
                    }.buttonStyle(TaskContextRowStyle())
                }
            }
        }
        if !value.tasks.isEmpty || value.taskError != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("后台任务与子 Agent", icon: "square.stack.3d.up", count: value.tasks.count)
                if let error = value.taskError { Text(error).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet) }
                let tasks = TaskContextTasks(value.tasks)
                ForEach(tasks.current) { task in
                    taskRow(task, item: item)
                }
                if !tasks.finished.isEmpty {
                    TaskContextDisclosure(title: "已结束的任务 · \(tasks.finished.count)", expanded: $completedTasks) {
                        ForEach(tasks.finished) { task in taskRow(task, item: item) }
                    }
                }
            }
        }
        if !value.tools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("工具活动", icon: "wrench.and.screwdriver", count: value.tools.count)
                ForEach(value.tools.filter { $0.staysVisible }) { tool in toolRow(tool) }
                let completed = value.tools.filter { !$0.staysVisible }
                if !completed.isEmpty {
                    TaskContextDisclosure(title: "已结束的调用 · \(completed.count)", expanded: $completedTools) {
                        ForEach(completed.suffix(20).reversed()) { tool in toolRow(tool) }
                        if completed.count > 20 {
                            Text("显示最近 20 次调用，完整记录请打开会话。").font(.system(size: WorkbenchTheme.Typography.caption))
                                .foregroundStyle(WorkbenchTheme.quiet).padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
        if value.files.isEmpty && value.tasks.isEmpty && value.tools.isEmpty &&
            value.requests.isEmpty && value.failure == nil {
            emptyState(value.busy ? "hourglass" : "tray",
                       value.busy ? "任务正在进行，文件和工具活动会显示在这里。" : "此任务暂时没有文件或工具活动。")
        }
    }
    private func emptyState(_ icon: String, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(WorkbenchTheme.quiet)
                .accessibilityHidden(true)
            Text(text).multilineTextAlignment(.center).foregroundStyle(WorkbenchTheme.quiet)
        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 12)
    }
    private func sectionTitle(_ title: LocalizedStringKey, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(WorkbenchTheme.quiet).frame(width: 16).accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(count.formatted()).font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                .monospacedDigit().foregroundStyle(WorkbenchTheme.quiet)
                .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 18)
                .background(WorkbenchTheme.Fill.surface, in: Capsule())
            Spacer(minLength: 0)
        }.padding(.bottom, 4).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
    private func toolRow(_ tool: VisibleTool) -> some View { TaskContextToolRow(tool: tool) }
    /// The whole row opens the task in place of the list.
    private func taskRow(_ task: KimiTask, item: WorkspaceSession) -> some View {
        let (title, endpoint) = TaskContextTitle.split(task.displayTitle)
        // Full commands belong to the in-place detail; the list stays a summary.
        let line = task.command == nil ? task.contextDetailLine : nil
        return Button {
            model.taskContextWindow.detail = TaskContextRoute(source: item.reference, taskID: task.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                TaskStatusSymbol(task: task).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).lineLimit(2).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(task.phaseLabel)
                        KimiTaskClock(task: task)
                        if let endpoint {
                            Text(verbatim: endpoint).font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
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
            .accessibilityLabel(Text(verbatim: [title, task.phaseLabel, endpoint, line].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint(Text("查看详情"))
            .accessibilityIdentifier("task-context-row-" + task.id)
    }
    private func syncError(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("状态未同步", systemImage: "wifi.exclamationmark").foregroundStyle(Color.orange)
            Text(error).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                .textSelection(.enabled)
            Button("重试") { state.refresh += 1 }.disabled(item?.online != true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(WorkbenchTheme.Fill.surface, in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
    }
    private func openMain() {
        close?()
        CompanionWindowController.shared.showMain()
    }
}

/// Splits a trailing `host:port` off a task title so the endpoint can read as
/// code on the metadata line instead of running into the sentence.
enum TaskContextTitle {
    static func split(_ title: String) -> (title: String, endpoint: String?) {
        guard let space = title.lastIndex(where: { $0 == " " }) else { return (title, nil) }
        let tail = title[title.index(after: space)...]
        guard let colon = tail.lastIndex(of: ":"), tail.index(after: colon) < tail.endIndex,
              tail[tail.index(after: colon)...].allSatisfy(\.isNumber),
              tail[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_[]".contains($0)) }),
              tail[..<colon].contains(where: { $0 == "." || $0.isLetter }) else { return (title, nil) }
        let head = title[..<space].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? (title, nil) : (head, String(tail))
    }
}

/// Header glyph buttons: a 26pt target with a hover wash, filled while selected.
private struct TaskContextIconStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { Glyph(configuration: configuration, selected: selected) }
    private struct Glyph: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label.frame(width: 26, height: 26)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .background(configuration.isPressed ? WorkbenchTheme.Fill.pressed
                            : selected ? WorkbenchTheme.Fill.selected
                            : hovered ? WorkbenchTheme.Fill.hover : Color.clear,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip + 3))
                .contentShape(Rectangle()).onHover { hovered = $0 }
        }
    }
}

/// A collapsible group whose whole row toggles and whose chevron sits at the
/// trailing edge, like the task rows it groups.
private struct TaskContextDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var expanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Text(title).foregroundStyle(WorkbenchTheme.quiet)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                        .foregroundStyle(WorkbenchTheme.quiet).rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }.frame(minHeight: 30).contentShape(Rectangle())
            }.buttonStyle(TaskContextRowStyle()).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { content }
        }
    }
}

private struct TaskContextToolRow: View {
    let tool: VisibleTool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Failures read red; calls whose outcome is still unknown read orange. A
    /// result that merely lacks its call record is informational, so it stays quiet.
    private enum Tone { case quiet, attention, failure }
    private var tone: Tone {
        switch tool.status {
        case .failed: return .failure
        case .missingResult, .disconnected, .awaitingApproval: return .attention
        case .running, .succeeded, .returned: return .quiet
        }
    }
    private var symbol: String {
        switch tool.status {
        case .failed: return "exclamationmark.circle"
        case .running: return "circle.dashed"
        case .missingResult, .disconnected, .awaitingApproval: return "questionmark.circle"
        case .succeeded: return "checkmark.circle"
        case .returned: return tool.hasCall ? "checkmark.circle" : "questionmark.circle"
        }
    }
    private var ink: Color {
        switch tone {
        case .quiet: return WorkbenchTheme.quiet
        case .attention: return Color.orange
        case .failure: return Color.red
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(ink).frame(width: 16).padding(.top, 2)
                        .symbolEffect(.pulse, options: .repeating, isActive: tool.status == .running && !reduceMotion)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: ToolPresentation.compactTarget(tool)).lineLimit(2)
                            .foregroundStyle(tool.hasCall ? Color.primary : WorkbenchTheme.quiet)
                        Text(verbatim: ConversationActivity.status(of: tool))
                            .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(ink)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                        .foregroundStyle(WorkbenchTheme.quiet).rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, 3).accessibilityHidden(true)
                }.padding(.vertical, 6).frame(minHeight: 36).contentShape(Rectangle())
            }.buttonStyle(TaskContextRowStyle()).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { KimiToolCard(tool: tool).padding(.leading, 30).padding(.bottom, 4) }
        }
    }
}

struct TaskContextRowStyle: ButtonStyle {
    /// Rows that ask for the reader's attention rest on a faint surface.
    var tinted = false
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, tinted: tinted)
    }
    private struct Row: View {
        let configuration: Configuration
        let tinted: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label.padding(.horizontal, 4)
                .background(configuration.isPressed ? WorkbenchTheme.Fill.pressed
                            : hovered ? WorkbenchTheme.Fill.hover
                            : tinted ? WorkbenchTheme.Fill.surface : Color.clear,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row))
                .contentShape(Rectangle()).onHover { hovered = $0 }
        }
    }
}

/// A glyph that hints at the artifact's kind from its extension.
enum TaskContextFileIcon {
    static func name(_ file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "swift", "py", "ts", "tsx", "js", "jsx", "go", "rs", "c", "cc", "cpp", "h", "java", "sh", "vue":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "plist": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": return "photo"
        case "csv", "tsv", "xlsx": return "tablecells"
        case "pdf": return "doc.richtext"
        case "html", "htm": return "globe"
        default: return "doc.text"
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
