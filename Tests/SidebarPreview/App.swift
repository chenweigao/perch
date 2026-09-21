import AppKit
import SwiftUI

@main struct SidebarPreviewApp: App {
    var body: some Scene {
        WindowGroup("侧栏隔离验收") { SidebarPreview().preferredColorScheme(.light) }
            .defaultSize(width: 1100, height: 760)
        Settings { Text("隔离预览设置").padding(40) }
    }
}

private struct SidebarPreview: View {
    @State private var page = SidebarPage.home
    @State private var title = "工作台"
    @State private var showSearch = false
    @State private var query = ""
    @State private var starred: Set<String> = []
    @State private var archived: Set<String> = []
    var body: some View {
        WorkspaceSplitView(newConversation: { title = "新建任务" }) {
            WorkspaceSidebarShell(page: page, attentionCount: 2, environmentSummary: "1 个 SSH",
                                  onNew: { title = "新建任务"; page = .other },
                                  onSearch: { showSearch = true },
                                  onHome: { title = "工作台"; page = .home },
                                  onInbox: { title = "待处理"; page = .inbox },
                                  onArchive: { title = "已归档"; page = .archive }) {
                section("置顶")
                task("打磨原生对话阅读体验", status: "OMP · 运行中", symbol: "circle.dotted")
                section("任务组")
                Button { title = "Perch 开源"; page = .other } label: {
                    Label("Perch 开源", systemImage: "folder").padding(10)
                }.buttonStyle(.plain)
                section("最近会话")
                task("离线会话", status: "连接中断 · 状态未同步", symbol: "wifi.slash")
                ForEach(1...20, id: \.self) { index in
                    task("原生工作台 · 会话 \(index)", status: index == 1 ? "Kimi · 等你处理" : "Kimi · 已完成",
                         symbol: index == 1 ? "exclamationmark.circle" : "checkmark.circle")
                }
                Button("全部会话 →") { title = "全部会话"; page = .other }.buttonStyle(.plain).padding(10)
            } environments: {
                VStack(alignment: .leading, spacing: 16) {
                    Text("环境与 Agent").font(.headline)
                    Label("本机 Agent", systemImage: "desktopcomputer")
                    Label("示例 SSH · 已连接", systemImage: "server.rack")
                    Text("纯虚构数据，不建立连接").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
        } header: {
            Label(title, systemImage: "square.grid.2x2").font(.system(size: 13, weight: .semibold))
        } actions: {
            Image(systemName: "ellipsis")
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2.weight(.semibold))
                Text("验证固定入口、独立滚动、宽度拖动和环境弹层。")
                    .foregroundStyle(.secondary)
                Text("此窗口只使用虚构数据，不加载工作区或连接远端。")
                Spacer()
            }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.sheet(isPresented: $showSearch) {
            VStack(alignment: .leading, spacing: 20) {
                Text("搜索任务").font(.title2)
                TextField("标题、Agent、环境或目录", text: $query).textFieldStyle(.roundedBorder)
                Button("完成") { showSearch = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 480)
        }
    }
    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 7)
    }
    private func task(_ name: String, status: String, symbol: String) -> some View {
        SessionRowChrome(title: name, subtitle: status.contains("等你处理") || status.contains("连接中断") ? status : nil,
                         selected: title == name, starred: starred.contains(name), archived: archived.contains(name),
                         canOpen: !archived.contains(name) && !status.contains("连接中断"), canQuickArchive: !status.contains("运行中") && !status.contains("连接中断"), busy: false,
                         onOpen: { title = name; page = .other },
                         onPin: {
                             if starred.contains(name) { starred.remove(name) } else { starred.insert(name) }
                         }, onArchive: {
                             if archived.contains(name) { archived.remove(name) } else { archived.insert(name) }
                         }) {
            Image(systemName: archived.contains(name) ? "archivebox" : symbol).foregroundStyle(.secondary)
        }.contextMenu {
            Button("重命名…") { title = "重命名预览" }
            Button("分组…") { title = "分组预览" }
            Divider()
            Button("删除会话…", role: .destructive) { title = "删除确认预览 · 不执行真实操作" }
        }
    }
}
