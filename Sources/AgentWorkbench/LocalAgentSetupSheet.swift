import AppKit
import SwiftUI
import WorkbenchCore

struct LocalAgentSetupSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<SessionKind> = Set(LocalAgentDiscovery.supported)
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本机 Agent").font(.title2.weight(.semibold))
            Text("连接本机已安装的 Agent，在你选择的 Mac 项目目录执行。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(LocalAgentDiscovery.agents, id: \.self) { kind in
                HStack(alignment: .top, spacing: 12) {
                    if LocalAgentDiscovery.supported.contains(kind) {
                        Toggle(kind.label, isOn: Binding(get: { selected.contains(kind) }, set: {
                            if $0 { selected.insert(kind) } else { selected.remove(kind) }
                        })).frame(width: 100, alignment: .leading)
                    } else { Text(kind.label).frame(width: 100, alignment: .leading) }
                    VStack(alignment: .leading, spacing: 4) {
                        switch model.localAgents[kind] {
                        case .found(let path, let version):
                            Text(version).font(.callout)
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            if !LocalAgentDiscovery.supported.contains(kind) {
                                Text("已安装，尚未接入本机对话").font(.caption).foregroundStyle(.secondary)
                            }
                        case .unusable(_, let reason):
                            Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(3)
                        case .missing:
                            Text("未找到可执行文件").font(.caption).foregroundStyle(.secondary)
                        case nil:
                            Text(model.probingLocal ? L("正在检测…") : L("尚未检测。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择路径…") { chooseExecutable(kind) }.controlSize(.small)
                        .disabled(model.probingLocal)
                }
            }
            Text("连接会复用或启动本机服务；关闭 Perch 不会停止正在执行的任务。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("重新检测") { model.discoverLocalAgents() }.disabled(model.probingLocal)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("连接并新建任务") {
                    do { try model.connectLocalAgents(LocalAgentDiscovery.supported.filter { selected.contains($0) }); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(model.probingLocal || !selected.contains { model.localAgents[$0]?.executablePath != nil })
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 580)
            .onAppear {
                if let host = model.connections.first(where: { $0.host.isLocal })?.host { selected = Set(host.enabledAgents) }
                model.discoverLocalAgents()
            }
    }
    private func chooseExecutable(_ kind: SessionKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.localAgentPaths[kind.rawValue] = url.path
        model.discoverLocalAgents()
    }
}
