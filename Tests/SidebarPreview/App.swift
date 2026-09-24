import AppKit
import SwiftUI
import WorkbenchCore

@main struct SidebarPreviewApp: App {
    init() { SidebarChecks.configure() }
    var body: some Scene {
        WindowGroup("侧栏隔离验收") {
            SidebarPreview().preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .task { await SidebarChecks.runIfRequested() }
        }.defaultSize(width: 1100, height: 760)
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
    @State private var reduceMotion = false
    @State private var groupCreations = 0
    @State private var filter = SidebarRecentFilter.all
    var body: some View {
        WorkspaceSplitView(newConversation: { title = "新建任务"; page = .other }) {
            WorkspaceSidebarShell(page: page, attentionCount: 2, environmentSummary: "1 个 SSH",
                                  onSearch: { showSearch = true },
                                  onNew: { title = "新建会话"; page = .other },
                                  onHome: { title = "工作台"; page = .home },
                                  onInbox: { title = "待处理"; page = .inbox },
                                  onArchive: { title = "已归档"; page = .archive }) {
                SidebarSection("置顶", id: "favorites") {
                    task("打磨原生对话阅读体验", status: "OMP · 运行中", symbol: "circle.dotted")
                        .sidebarProbe("preview.favorite")
                }.sidebarProbe("sidebar.section.favorites")
                SidebarSection("任务组", id: "groups") {
                    Button { title = "Perch 开源"; page = .other } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder").frame(width: 17)
                            Text("Perch 开源")
                            Spacer()
                        }.padding(.horizontal, 10).frame(height: 34)
                    }.buttonStyle(SidebarNavigationStyle(selected: title == "Perch 开源"))
                        .sidebarProbe("preview.group")
                } actions: {
                    Button { groupCreations += 1 } label: {
                        Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("新建任务组").sidebarProbe("preview.newGroup")
                }.sidebarProbe("sidebar.section.groups")
                SidebarSection("最近会话", id: "recent") {
                    task("运行中 · 验证长标题在只显示置顶按钮时仍尽量完整", status: "Kimi · 运行中", symbol: "circle.dotted")
                        .sidebarProbe("preview.running")
                    if filter == .all {
                        task("已完成 · 验证长标题在操作隐藏后重新占满整行", status: "Kimi · 已完成", symbol: "checkmark.circle")
                            .sidebarProbe("preview.completed")
                        task("离线会话", status: "连接中断 · 状态未同步", symbol: "wifi.slash")
                        ForEach(1...20, id: \.self) { index in
                            task("原生工作台 · 会话 \(index)", status: index == 1 ? "Kimi · 等你处理" : "Kimi · 已完成",
                                 symbol: index == 1 ? "exclamationmark.circle" : "checkmark.circle")
                        }
                    }
                    Button("全部会话 →") { title = "全部会话"; page = .other }
                        .buttonStyle(SidebarNavigationStyle()).padding(.leading, 26).padding(10)
                        .sidebarProbe("preview.allSessions")
                } actions: {
                    Menu {
                        Picker("筛选最近会话", selection: $filter) {
                            ForEach(SidebarRecentFilter.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                        }
                    } label: {
                        Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("筛选最近会话").sidebarProbe("preview.filterMenu")
                }.sidebarProbe("sidebar.section.recent")
            } environments: {
                VStack(alignment: .leading, spacing: 16) {
                    Text("环境与 Agent").font(.headline)
                    Label("本机 Agent", systemImage: "desktopcomputer")
                    Label("示例 SSH · 已连接", systemImage: "server.rack")
                    Text("纯虚构数据，不建立连接").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.transaction { if reduceMotion { $0.disablesAnimations = true } }
        } header: {
            Label(title, systemImage: "square.grid.2x2").font(.system(size: 13, weight: .semibold))
        } actions: {
            Image(systemName: "ellipsis")
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2.weight(.semibold)).sidebarProbe("preview.selection", value: title)
                Text("验证分区折叠与状态记忆、固定入口、独立滚动、宽度拖动和环境弹层。")
                    .foregroundStyle(.secondary)
                Text("此窗口只使用虚构数据，不加载工作区或连接远端。")
                Text("新建任务组次数：\(groupCreations)").sidebarProbe("preview.groupCreations", value: "\(groupCreations)")
                Text(LocalizedStringKey(filter.rawValue)).sidebarProbe("preview.filter", value: filter.rawValue)
                Toggle("禁用 SwiftUI 动画（预览）", isOn: $reduceMotion).sidebarProbe("preview.reduceMotion")
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
