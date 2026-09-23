import SwiftUI
import WorkbenchCore

struct NewTerminalSheet: View {
    @UILocalization private var L
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
            Label {
                Text("在 \(connection.host.name) 的 Herdr 中创建持久终端。进入后可运行 Kimi、OMP、Qoder 或 dsh CLI。")
            } icon: { HostIdentityIcon(hostID: connection.id) }
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
            .onChange(of: connection.snapshot?.workspaces.first?.id) { _, id in
                if workspaceID.isEmpty { workspaceID = id ?? "" }
            }
            .onAppear {
                workspaceID = connection.snapshot?.workspaces.first?.id ?? ""
                cwd = model.launchAfterSetup?.directory ?? connection.snapshot?.panes.first?.cwd ?? ""
                model.launchAfterSetup = nil
            }
    }
}
