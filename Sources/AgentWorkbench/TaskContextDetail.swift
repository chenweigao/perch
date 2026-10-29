import SwiftUI
import WorkbenchCore

/// One task of the task page, shown in place of the list: what it is, how it
/// ran, and its output tail or result. The list's reader keeps it current; a
/// task the latest read no longer lists keeps the state it was last read in.
/// Reading it never selects another conversation.
struct TaskContextDetailView: View {
    let model: WorkbenchModel
    let item: WorkspaceSession
    let route: TaskContextRoute
    let snapshot: TaskContextSnapshot?
    let state: TaskContextState
    let online: Bool
    /// The panel is showing; a hidden panel reads nothing.
    let active: Bool
    let back: () -> Void
    @State private var remembered: KimiTask?
    @State private var outputRefresh = 0

    private var listed: KimiTask? { snapshot?.task(for: route) }

    var body: some View {
        let listed = listed
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("后台任务与子 Agent").lineLimit(1)
                }.contentShape(Rectangle())
            }.buttonStyle(.borderless).foregroundStyle(WorkbenchTheme.quiet)
                .help("返回任务列表").accessibilityLabel("返回任务列表")
                .accessibilityIdentifier("task-context-back")
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            if let task = listed ?? remembered {
                content(task, current: listed != nil)
            } else if snapshot == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("此任务已不在最新列表中。").foregroundStyle(WorkbenchTheme.quiet)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: listed, initial: true) { _, value in
                if let value { remembered = value }
            }
    }

    @ViewBuilder private func content(_ task: KimiTask, current: Bool) -> some View {
        let readsOutput = snapshot?.readsOutput(task) == true
        VStack(alignment: .leading, spacing: 0) {
            summary(task, current: current, readsOutput: readsOutput)
                .padding(.horizontal, 16).padding(.bottom, 14)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if readsOutput || state.outputs[task.id] != nil {
                output(task, following: current && readsOutput)
            } else {
                result(task)
            }
        }
    }

    // MARK: Summary

    private func summary(_ task: KimiTask, current: Bool, readsOutput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TaskStatusSymbol(task: task)
                Text(task.displayTitle)
                    .font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                    .lineLimit(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                Text(verbatim: [task.subagentType ?? task.kindLabel, task.phaseLabel].joined(separator: " · "))
                if current, task.startedDate != nil {
                    Text(verbatim: " · ")
                    KimiTaskClock(task: task)
                }
            }.font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                .padding(.leading, 26)
            if let usage = Self.usage(task) {
                Text(verbatim: usage).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
                    .lineLimit(2).padding(.leading, 26)
            }
            if !current {
                Label("此任务已不在最新列表中，显示最后读取的内容。", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
            }
            if let command = task.command, !command.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: command).font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    }.frame(maxHeight: 120)
                    ReplyCopyButton(text: command, label: "复制命令")
                }.padding(.leading, 10).padding(.vertical, 6).padding(.trailing, 4)
                    .background(WorkbenchTheme.Fill.surface,
                                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
            }
            VStack(alignment: .leading, spacing: 3) {
                if let name = task.model { meta("模型", task.thinkingEffort.map { "\(name) · \($0)" } ?? name) }
                if let index = task.swarmIndex { meta("并行序号", String(index)) }
                if let reason = task.suspendedReason { meta("暂停原因", reason) }
                meta("任务 ID", task.id)
            }.font(.system(size: WorkbenchTheme.Typography.caption))
            actions(task, current: current, readsOutput: readsOutput)
            if let error = state.actionErrors[task.id] {
                Text(error).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Tokens, tool calls and the latest tool, as far as the runtime reports them.
    private static func usage(_ task: KimiTask) -> String? {
        var parts: [String] = []
        if let tokens = task.tokenCount { parts.append(L("已用 \(tokens) Token")) }
        if let calls = task.toolUseCount { parts.append(L("\(calls) 次调用")) }
        if let tool = task.latestActivity, !tool.isEmpty { parts.append(L("最近工具：\(tool)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func meta(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(WorkbenchTheme.quiet).frame(width: 72, alignment: .leading)
            Text(value).foregroundStyle(WorkbenchTheme.quiet).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func actions(_ task: KimiTask, current: Bool, readsOutput: Bool) -> some View {
        let stops = current && snapshot?.stops(task) == true
        if task.transcriptAgentId != nil || stops {
            HStack(spacing: 14) {
                if task.transcriptAgentId != nil {
                    if model.showsConversation(item.reference) {
                        Button("查看过程") {
                            model.openTaskTranscript(task, source: item.reference)
                            CompanionWindowController.shared.showMain()
                        }.help("读取这个子 Agent 自己的轮次、思考与工具调用")
                            .accessibilityIdentifier("task-context-transcript")
                    } else {
                        // Its sheet belongs to the conversation; the panel stays open and locked.
                        Button("打开会话") { model.open(item); CompanionWindowController.shared.showMain() }
                            .help("在主窗口打开这个会话后，可以查看子 Agent 的过程")
                            .disabled(!item.online || item.archived)
                            .accessibilityIdentifier("task-context-open-session")
                    }
                }
                Spacer(minLength: 0)
                if stops {
                    let requested = state.stopRequested.contains(task.id)
                    Button {
                        Task { await state.stop(task, source: route.source) {
                            _ = try await model.taskContextOperation(task, source: route.source, stop: true)
                        } }
                    } label: {
                        if requested { Text("已请求停止") }
                        else if state.working.contains(task.id) { Text("正在停止…") }
                        else { Text("停止任务") }
                    }.disabled(requested || state.working.contains(task.id) || !online)
                        .help(readsOutput ? "停止任务" : "只停止这个子 Agent，主会话继续运行")
                        .accessibilityIdentifier("task-context-stop")
                }
            }.buttonStyle(.borderless).font(.system(size: WorkbenchTheme.Typography.body))
        }
    }

    // MARK: Output and result

    private struct OutputKey: Equatable {
        let route: TaskContextRoute
        let running: Bool
        let reads: Bool
        let refresh: Int
    }

    private func output(_ task: KimiTask, following: Bool) -> some View {
        let value = state.outputs[task.id]
        let failure = state.outputErrors[task.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("输出").fontWeight(.semibold)
                if value?.truncated == true {
                    Text("显示最后 \(KimiTask.outputTailBytes / 1024) KiB").foregroundStyle(WorkbenchTheme.quiet)
                }
                Spacer(minLength: 4)
                if following && task.isRunning {
                    Label("跟随最新", systemImage: "arrow.down.to.line").foregroundStyle(WorkbenchTheme.quiet)
                }
                if following {
                    Button { outputRefresh += 1 } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                    }.buttonStyle(.borderless).disabled(!online)
                        .help("重新读取输出").accessibilityLabel("重新读取输出")
                }
            }.font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
            if let value, !value.text.isEmpty {
                ScrollView {
                    Text(value.text).font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                        .textSelection(.enabled).padding(10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                    // A running process prints toward its latest line.
                    .defaultScrollAnchor(.bottom)
                    .background(WorkbenchTheme.Fill.surface,
                                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
                    .accessibilityIdentifier("task-context-output")
            } else if value != nil {
                Text("暂无输出").foregroundStyle(WorkbenchTheme.quiet)
            } else if failure == nil {
                if following { ProgressView("正在读取输出…").controlSize(.small) }
                else { Text("暂无输出").foregroundStyle(WorkbenchTheme.quiet) }
            }
            if let failure {
                Text(failure).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.orange)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .workbenchHostedTask(id: OutputKey(route: route, running: following && task.isRunning,
                                               reads: active && online && following, refresh: outputRefresh)) {
                guard following, online, active else { return }
                let source = route.source, id = task.id
                await state.followOutput(id, source: source, running: task.isRunning) {
                    try await model.readTaskOutput(id, source: source)
                }
            }
    }

    private func result(_ task: KimiTask) -> some View {
        let text = task.outputPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text(task.isFailed ? "错误" : "结果").fontWeight(.semibold)
                .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(WorkbenchTheme.quiet)
            if text.isEmpty {
                Text(task.isRunning ? "运行结束后在这里显示结果。" : "没有返回结果。").foregroundStyle(WorkbenchTheme.quiet)
            } else {
                ScrollView {
                    Text(text).foregroundStyle(task.isFailed ? Color.red : .primary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }.accessibilityIdentifier("task-context-result")
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The status mark of a task row and its detail page.
struct TaskStatusSymbol: View {
    let task: KimiTask
    var body: some View {
        Image(systemName: Self.name(of: task))
            .foregroundStyle(task.isFailed ? Color.red : .secondary).frame(width: 16)
            .accessibilityHidden(true)
    }
    static func name(of task: KimiTask) -> String {
        if task.isRunning { return "circle.dashed" }
        if task.isFailed { return "exclamationmark.circle" }
        switch task.status {
        case "completed": return "checkmark.circle"
        case "cancelled": return "stop.circle"
        default: return "questionmark.circle"
        }
    }
}
