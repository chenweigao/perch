import SwiftUI
import WorkbenchCore

struct WorkItemGroupEditor: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    var sessionsOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var goal = ""
    @State private var nextStep = ""
    @State private var search = ""
    @State private var sessions = Set<SessionReference>()
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(sessionsOnly ? L("关联已有会话") : model.editingGroup == nil ? L("新建任务组") : L("编辑任务组"))
                .font(.title2.weight(.medium))
            Text("关联原生对话与终端，记下共同目标和下一步。归组不共享对话上下文。")
                .font(.callout).foregroundStyle(.secondary)
            if !sessionsOnly {
                Form {
                    TextField("名称", text: $name, prompt: Text("例如：推理仿真前端优化"))
                    TextField("目标", text: $goal, prompt: Text("做到什么程度算完成？"), axis: .vertical).lineLimit(2...3)
                    TextField("下一步", text: $nextStep, prompt: Text("回来后先做什么？"), axis: .vertical).lineLimit(2...3)
                }
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
