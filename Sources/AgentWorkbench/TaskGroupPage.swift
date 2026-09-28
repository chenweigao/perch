import SwiftUI
import WorkbenchCore

/// Goal context augments the shared dashboard; it never renders a second queue.
struct GroupWorkbenchHeader: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        if let group = model.selectedGroup {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("目标与下一步").foregroundStyle(.secondary)
                    Spacer()
                    Button(group.isPinned ? "取消置顶" : "置顶任务组") { model.toggleGroupPin(group) }.buttonStyle(.link)
                    Button("编辑目标") { model.editGroup(group) }.buttonStyle(.link)
                }.font(.system(size: 12))
                if group.goal.isEmpty {
                    Button("写下目标") { model.editGroup(group) }.buttonStyle(.link)
                } else { Text(group.goal).font(.system(size: 14)).textSelection(.enabled) }
                HStack(alignment: .top, spacing: 12) {
                    Text("下一步").foregroundStyle(.secondary)
                    if group.nextStep.isEmpty {
                        Button("记下回来后先做什么") { model.editGroup(group) }.buttonStyle(.link)
                    } else { Text(group.nextStep).textSelection(.enabled) }
                }.font(.system(size: 13))
                HStack(spacing: 14) {
                    if let resume = model.groupResumeSession,
                       model.scopeHost == nil || resume.reference.hostID == model.scopeHost?.id {
                        Button("继续上次会话") { model.open(resume) }.disabled(!resume.online)
                    }
                    Button("新建会话") { model.startNewTask() }
                    Button("关联已有会话") { model.editGroup(group, sessionsOnly: true) }.buttonStyle(.link)
                    Spacer()
                }
                TextField("搜索本组会话", text: $model.search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("workbench.group.search")
                if !model.search.isEmpty {
                    Button("清除搜索") { model.search = "" }.buttonStyle(.link)
                }
            }
        }
    }
}

struct GroupWorkbenchProgress: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        if let group = model.selectedGroup { GroupProgressView(model: model, group: group).id(group.id) }
    }
}

struct GroupWorkbenchHistory: View {
    @ObservedObject var model: WorkbenchModel
    var body: some View {
        if let group = model.selectedGroup {
            let references = Set(group.sessions.filter { model.scopeHost == nil || $0.hostID == model.scopeHost?.id })
            let members = model.allSessions.filter { references.contains($0.reference) }
            let archived = members.filter { $0.archived && $0.matchesSearch(model.search) }
            let missing = references.subtracting(Set(members.map(\.reference))).count
            VStack(alignment: .leading, spacing: 12) {
                if !archived.isEmpty {
                    DisclosureGroup("已归档 · \(archived.count)") {
                        ForEach(archived) { item in
                            HStack {
                                Text(item.title).lineLimit(2)
                                Spacer()
                                Button("恢复") { model.setArchived(item, archived: false) }.disabled(!item.online && item.reference.kind != .terminal)
                            }.padding(.vertical, 8)
                        }
                    }.disclosureGroupStyle(WorkbenchDisclosureStyle(minHeight: 36))
                }
                if missing > 0 {
                    Text("另有 \(missing) 个关联会话尚未同步，可在关联管理中查看。")
                    Button("管理关联") { model.editGroup(group, sessionsOnly: true) }.buttonStyle(.link)
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
