import SwiftUI
import WorkbenchCore

struct RenameSessionSheet: View {
    let model: WorkbenchModel
    let item: WorkspaceSession
    @State private var title = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名会话").font(.title2.weight(.semibold))
            TextField("会话名称", text: $title).textFieldStyle(.roundedBorder).focused($focused)
            Text("仅修改 Perch 中的显示名称，不更改远端标题。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { model.rename(item, title: title); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420)
            .onAppear { title = item.title; focused = true }
    }
}
