import AppKit
import SwiftUI
import WorkbenchCore

@main struct HostLabelPreviewApp: App {
    var body: some Scene {
        WindowGroup("Perch · 机器标识") {
            HostLabelPreview().preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }.defaultSize(width: 860, height: 590)
    }
}

private struct HostLabelPreview: View {
    @State private var selected = 0
    @State private var environment = 0
    @State private var pinned: Set<Int> = []
    private let titles = ["排查远端构建失败，确认依赖和执行环境", "检查后台任务的运行状态",
                          "验证长会话名称截断时机器标识始终可见", "完善会话摘要与通知展示",
                          "检查断线后的会话显示"]
    private let names = ["dev-env", "mini", "本机"]
    private let ids = [UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                       UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                       ExecutionEnvironment.localHostID]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("同一台机器，同一个标识").font(.system(size: 22, weight: .semibold))
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    heading("侧栏会话")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最近会话").font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
                        ForEach(titles.indices, id: \.self) { index in
                            SessionRowChrome(title: titles[index], subtitle: index == 4 ? "离线 · 状态未同步" : nil,
                                hostName: names[index % 3], hostID: ids[index % 3], selected: selected == index,
                                starred: pinned.contains(index), archived: false, canOpen: index != 4,
                                canQuickArchive: index >= 3, busy: false,
                                onOpen: { selected = index; environment = index % 3 },
                                onPin: { if pinned.contains(index) { pinned.remove(index) } else { pinned.insert(index) } },
                                onArchive: {}) {
                                    Image(systemName: index == 4 ? "wifi.slash" : index < 3 ? "circle.dotted" : "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                }.opacity(index == 4 ? 0.65 : 1)
                        }
                    }.padding(6).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    Text("图标 12 pt · 普通行仍为 34 pt").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(width: 350)
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading("设置 · 机器列表")
                        VStack(spacing: 16) {
                            ForEach(names.indices, id: \.self) { index in
                                HStack(spacing: 10) {
                                    HostIdentityIcon(hostID: ids[index]).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(names[index])
                                        Text(index == 2 ? "本机 Agent" : "SSH · \(names[index])").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(index == 1 ? "未连接" : "已连接").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(16).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        heading("创建会话 · 运行环境")
                        Menu {
                            ForEach(names.indices, id: \.self) { index in
                                Button { environment = index } label: {
                                    Label { Text(names[index]) } icon: { HostIdentityIcon.menuImage(for: ids[index]) }
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Label { Text(names[environment]) } icon: { HostIdentityIcon.menuImage(for: ids[environment]) }
                                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.font(.system(size: 12)).padding(.vertical, 6)
                        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("运行环境")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        heading("当前会话顶部")
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("检查会话的机器标识").font(.system(size: 13, weight: .semibold))
                                HStack(spacing: 5) {
                                    Text("Kimi ·")
                                    HostIdentityLabel(hostID: ids[environment], name: names[environment])
                                }.font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("示例数据 · 各处复用同一图标组件 · 连接状态单独显示 · 可点击运行环境查看菜单")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 14, weight: .medium)) }
}
