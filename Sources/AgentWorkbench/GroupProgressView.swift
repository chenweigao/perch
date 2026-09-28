import SwiftUI
import WorkbenchCore

struct GroupProgressView: View {
    @Bindable var model: WorkbenchModel
    let group: WorkItemGroup
    @State private var addingOutcome = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("完成标准").font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("阶段", selection: Binding(get: { group.stage }, set: { stage in
                    var updated = group; updated.stage = stage; model.updateGroup(updated)
                })) { ForEach(GroupStage.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) } }
                    .fixedSize()
            }
            if group.criteria.isEmpty {
                Button("添加完成标准") { model.editGroup(group) }.buttonStyle(.link)
            }
            ForEach(group.criteria) { criterion in
                Toggle(criterion.title, isOn: Binding(get: { criterion.completed }, set: { checked in
                    var updated = group
                    if let i = updated.criteria.firstIndex(where: { $0.id == criterion.id }) {
                        updated.criteria[i].completed = checked; model.updateGroup(updated)
                    }
                })).toggleStyle(.checkbox)
            }
            if !group.criteria.isEmpty {
                Text("已核对 \(group.criteria.filter(\.completed).count) / \(group.criteria.count) 项 · 阶段由你确认")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("成果与决策").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("添加成果") { addingOutcome = true }.buttonStyle(.link)
            }
            if group.outcomes.isEmpty {
                Text("固定结论、PR 或报告，并保留来源会话。").foregroundStyle(.secondary)
            }
            ForEach(group.outcomes) { outcome in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(outcome.title).fontWeight(.medium).textSelection(.enabled)
                        Spacer()
                        Menu {
                            Button("移除成果") {
                                var updated = group; updated.outcomes.removeAll { $0.id == outcome.id }; model.updateGroup(updated)
                            }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    if !outcome.detail.isEmpty { Text(outcome.detail).textSelection(.enabled) }
                    if let url = outcome.webURL { Link(outcome.link, destination: url).lineLimit(2) }
                    else if !outcome.link.isEmpty { Text(outcome.link).textSelection(.enabled).foregroundStyle(.secondary) }
                    if let source = outcome.source {
                        if let session = model.allSessions.first(where: { $0.reference == source }) {
                            Button("来源：\(session.title)") { model.open(session) }.buttonStyle(.link).disabled(!session.online || session.archived)
                        } else { Text("来源会话尚未同步").foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 6)
            }
        }.font(.system(size: 12))
            .sheet(isPresented: $addingOutcome) { GroupOutcomeEditor(model: model, group: group) }
    }
}

private struct GroupOutcomeEditor: View {
    @Bindable var model: WorkbenchModel
    let group: WorkItemGroup
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var link = ""
    @State private var source: SessionReference?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加成果与决策").font(.title2)
            TextField("标题", text: $title)
            TextField("结论或说明", text: $detail, axis: .vertical).lineLimit(3...6)
            TextField("链接或文件路径（可选）", text: $link)
            Picker("来源会话", selection: $source) {
                Text("不关联").tag(Optional<SessionReference>.none)
                ForEach(model.allSessions.filter { group.sessions.contains($0.reference) }) { session in
                    Text(session.title).tag(Optional(session.reference))
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    model.addOutcome(GroupOutcome(title: title.trimmingCharacters(in: .whitespacesAndNewlines), detail: detail,
                                                  link: link.trimmingCharacters(in: .whitespacesAndNewlines), source: source), to: group.id)
                    dismiss()
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 540)
    }
}
