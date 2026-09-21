import SwiftUI
import WorkbenchCore

struct WorkspaceHome: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        let scoped = model.scopedSessions
        let live = scoped.filter(\.online)
        let offline = scoped.filter { !$0.online }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.selectedGroup?.name ?? L("今天，先处理重要的事。"))
                        .font(.system(size: 26, weight: .semibold))
                    Text(model.selectedGroup?.goal.isEmpty == false ? model.selectedGroup!.goal : L("对话与终端，都围绕你正在推进的事情组织。"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if let group = model.selectedGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("下一步", systemImage: "arrow.turn.down.right").font(.system(size: 12, weight: .semibold))
                        Text(group.nextStep.isEmpty ? L("写下回来后要继续做的第一件事。") : group.nextStep).font(.system(size: 14)).textSelection(.enabled)
                        HStack {
                            Text("关联 \(group.sessions.count) 个会话 · 本地保存").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let item = model.groupResumeSession {
                                Button("继续上次会话") { model.open(item, pinned: true) }.disabled(!item.online)
                            }
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    let missing = group.sessions.filter { ref in !model.allSessions.contains { $0.reference == ref } }
                    ForEach(missing) { ref in
                        Label("关联\(ref.kind.label)尚未出现在当前列表：\(ref.terminalID)", systemImage: "questionmark.folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.workspaceError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
                if !model.pendingRestoration.isEmpty {
                    DisclosureGroup("等待恢复 · \(model.pendingRestoration.count) 个标签") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("连接后恢复原会话；未找到的会话保留，供你确认。").font(.caption).foregroundStyle(.secondary)
                            ForEach(model.pendingRestoration, id: \.session.id) { saved in
                                HStack {
                                    Label(saved.title, systemImage: saved.session.kind.symbol).font(.callout).lineLimit(1)
                                    Spacer()
                                    Button("不再恢复") { model.forgetRestoration(saved) }.font(.caption)
                                }
                            }
                        }.padding(.top, 10)
                    }.padding(18).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 12) {
                    count(.attention, value: live.filter { $0.section == .attention }.count, color: .orange)
                    count(.review, value: live.filter { $0.section == .review }.count, color: .purple)
                    count(.running, value: live.filter { $0.section == .running }.count, color: .blue)
                }
                ForEach([WorkQueueSection.attention, .review, .running], id: \.self) { section in
                    let items = live.filter { $0.section == section }
                    if !items.isEmpty {
                        Text(L(key: section.rawValue)).font(.system(size: 13, weight: .semibold)).padding(.top, 12)
                        // Long result inventories stay collapsed so they don't bury active work.
                        if section == .review {
                            DisclosureGroup("\(items.count) 个结果") { rows(items).padding(.top, 10) }
                        } else { rows(items) }
                    }
                }
                if live.allSatisfy({ $0.section == .other }) {
                    Text("当前已同步的会话中，没有等待处理或运行中的事项。").font(.callout).foregroundStyle(.secondary)
                }
                let others = live.filter { $0.section == .other }
                if !others.isEmpty {
                    DisclosureGroup("已查看、就绪和其他会话 · \(others.count)") { rows(others).padding(.top, 10) }
                }
                if !offline.isEmpty {
                    DisclosureGroup("状态未同步 · \(offline.count)") { rows(offline).padding(.top, 10) }
                }
                if !model.kimi.online || !model.native.online || model.connections.contains(where: { !$0.online }) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !model.native.online { Label("原生对话 · 状态未同步", systemImage: "wifi.slash") }
                        if !model.kimi.online { Label("Kimi · \(model.kimi.state)", systemImage: "wifi.slash") }
                        ForEach(model.connections.filter { !$0.online }) { connection in
                            Label("\(connection.host.name) 终端 · \(connection.state)", systemImage: "wifi.slash")
                        }
                        Text("离线会话不计入上方数量；历史状态保留供参考。")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Text("原生对话的审批与提问来自远端 Agent；终端状态由 Herdr 上报。待查看仅表示本轮有结果，不代表任务已经完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
    }
    private func count(_ section: WorkQueueSection, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L(key: section.rawValue)).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 25, weight: .semibold)).foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }
    private func rows(_ items: [WorkspaceSession]) -> some View {
        ForEach(items) { item in
            HStack(spacing: 0) {
                Button { model.open(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.reference.kind.symbol).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text("\(item.hostName) · \(item.detail) · \(item.directory)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            if model.selectedGroup == nil {
                                let groups = model.workspace.groups.filter { $0.sessions.contains(item.reference) }.map(\.name)
                                if !groups.isEmpty { Text(groups.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(14).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!item.online)
                    .contextMenu { SessionActionsMenu(model: model, item: item) }
                if item.canMarkReviewed && item.online {
                    Button("已查看") { model.markReviewed(item) }.font(.caption).padding(.trailing, 14)
                }
            }.background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 10)).opacity(item.online ? 1 : 0.5)
        }
    }
}

struct WorkItemGroupEditor: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var goal = ""
    @State private var nextStep = ""
    @State private var search = ""
    @State private var sessions = Set<SessionReference>()
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(model.editingGroup == nil ? L("新建任务组") : L("编辑任务组")).font(.title2.weight(.semibold))
            Text("关联原生对话与终端，记下共同目标和下一步。归组不共享对话上下文。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("名称", text: $name, prompt: Text("例如：推理仿真前端优化"))
                TextField("目标", text: $goal, prompt: Text("做到什么程度算完成？"), axis: .vertical).lineLimit(2...3)
                TextField("下一步", text: $nextStep, prompt: Text("回来后先做什么？"), axis: .vertical).lineLimit(2...3)
            }
            TextField("搜索要关联的对话或终端", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.allSessions.filter { search.isEmpty || "\($0.title) \($0.directory) \($0.detail)".localizedCaseInsensitiveContains(search) }) { item in
                        Toggle(isOn: Binding(get: { sessions.contains(item.reference) }, set: { selected in
                            if selected { sessions.insert(item.reference) } else { sessions.remove(item.reference) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(item.title, systemImage: item.reference.kind.symbol).font(.system(size: 12)).lineLimit(1)
                                Text("\(item.hostName) · \(item.detail)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                    ForEach(sessions.filter { ref in !model.allSessions.contains { $0.reference == ref } }.sorted { $0.id < $1.id }) { ref in
                        Toggle("未连接或已结束的\(ref.kind.label)：\(ref.terminalID)", isOn: Binding(get: { sessions.contains(ref) }, set: { selected in
                            if !selected { sessions.remove(ref) }
                        })).toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(4)
            }.frame(height: 250)
            HStack {
                Text("已选 \(sessions.count) 个会话 · 保存在本机").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存任务组") {
                    var group = model.editingGroup ?? WorkItemGroup(name: "", goal: "", nextStep: "", sessions: [])
                    group.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    group.goal = goal; group.nextStep = nextStep; group.sessions = sessions.sorted { $0.id < $1.id }
                    model.saveGroup(group); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 600)
            .onAppear {
                if let group = model.editingGroup {
                    name = group.name; goal = group.goal; nextStep = group.nextStep; sessions = Set(group.sessions)
                }
            }
    }
}
