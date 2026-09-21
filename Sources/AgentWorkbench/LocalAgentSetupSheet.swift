import SwiftUI
import WorkbenchCore

/// Reports what the local machine actually offers. This sheet deliberately has no
/// "start" action: discovery and the RPC command surface were verified, but a
/// complete local turn was not, and offering to start one would claim otherwise.
struct LocalAgentSetupSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本机 Agent").font(.title2.weight(.semibold))
            Text("本机执行环境与远程 SSH 主机分开：本机工具在你选择的 Mac 目录执行，不通过 ssh localhost。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch model.localOMP {
            case .found(let path, let version):
                VStack(alignment: .leading, spacing: 8) {
                    Label("已找到 omp \(version)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text("已读取版本；此检测没有验证 RPC、工具审批或运行中引导。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unusable(let path, let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Label("找到了可执行文件，但无法使用", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            case .missing(let hint):
                Text(hint).font(.callout).fixedSize(horizontal: false, vertical: true)
            case nil:
                if model.probingLocal { ProgressView("正在查找本机 omp…") }
                else { Text("尚未检测。").font(.callout).foregroundStyle(.secondary) }
            }
            Text("当前检测仅验证可执行文件与版本。本机原生对话、工具审批和运行中引导尚未接通。")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新检测") { model.discoverLocalOMP() }.disabled(model.probingLocal)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(26).frame(width: 520)
            .onAppear { if model.localOMP == nil { model.discoverLocalOMP() } }
    }
}
