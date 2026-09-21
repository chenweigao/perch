import SwiftUI
import WorkbenchCore

struct AddHostSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var destination = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加机器").font(.title2.weight(.semibold))
            Text("复用 ~/.ssh/config 中的别名、密钥与跳板机设置。首次连接请先在系统终端确认主机指纹。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("SSH 地址", text: $destination, prompt: Text("dev-env 或 user@host"))
                TextField("显示名称", text: $name, prompt: Text("可选"))
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加并连接") {
                    do { try model.addHost(name: name, destination: destination); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(destination.isEmpty)
            }
        }.padding(28).frame(width: 440)
    }
}

struct NewTerminalSheet: View {
    @ObservedObject var connection: HostConnection
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceID = ""
    @State private var cwd = ""
    @State private var label = "终端"
    @State private var error: String?
    @State private var creating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建远端终端").font(.title2.weight(.semibold))
            Text("在 \(connection.host.name) 的 Herdr 中创建持久终端。进入后可运行 Kimi、OMP 或 Qoder CLI。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("工作区", selection: $workspaceID) {
                    ForEach(connection.snapshot?.workspaces ?? []) { workspace in Text(workspace.label).tag(workspace.id) }
                }
                TextField("目录", text: $cwd)
                TextField("名称", text: $label)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button(creating ? L("创建中…") : L("创建终端")) {
                    creating = true
                    Task {
                        do {
                            let pane = try await connection.createTerminal(workspaceID: workspaceID, cwd: cwd, label: label)
                            model.associateWithCurrentGroup(SessionReference(hostID: connection.id, terminalID: pane.id))
                            model.open(pane, on: connection, pinned: true)
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription; creating = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(creating || workspaceID.isEmpty || !cwd.hasPrefix("/"))
            }
        }.padding(28).frame(width: 480)
            .onAppear {
                workspaceID = connection.snapshot?.workspaces.first?.id ?? ""
                cwd = connection.snapshot?.panes.first?.cwd ?? ""
            }
    }
}
