import SwiftUI
import WorkbenchCore

struct SessionGroupsSheet: View {
    @Bindable var model: WorkbenchModel
    let item: WorkspaceSession
    @State private var selected = Set<UUID>()
    @State private var newGroupName = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("任务组归属").font(.title2.weight(.semibold))
            Text(item.title).lineLimit(2).foregroundStyle(.secondary)
            if model.workspace.groups.isEmpty {
                Text("还没有任务组。在下方填写名称，保存后会创建并关联此会话。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.workspace.groups) { group in
                            Toggle(group.name, isOn: Binding(get: { selected.contains(group.id) }, set: { value in
                                if value { selected.insert(group.id) } else { selected.remove(group.id) }
                            })).toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.frame(maxHeight: 220)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("新建并关联任务组").font(.headline)
                TextField("任务组名称（可选）", text: $newGroupName)
            }
            Text("可选多个任务组；取消全部选择且不新建，保存后即移出所有任务组。不会共享对话上下文。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    model.setGroups(selected, for: item.reference, newGroupName: newGroupName)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 440)
            .onAppear { selected = Set(model.workspace.groups.filter { $0.sessions.contains(item.reference) }.map(\.id)) }
    }
}
