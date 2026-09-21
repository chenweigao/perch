import SwiftUI
import WorkbenchCore

enum WorkbenchChrome {
    static let headerHeight: CGFloat = 44
}

/// Title changes follow workspace selection, independently of streaming state.
struct WorkbenchHeader: View {
    @ObservedObject var model: WorkbenchModel
    private var item: WorkspaceSession? { model.showDashboard ? nil : model.selectedItem }
    private var title: String {
        if model.showDashboard { return model.showArchived ? "已归档" : model.onlyAttention ? "待处理" : model.showSessionDirectory ? "全部会话" : model.selectedGroup?.name ?? "工作台" }
        return item?.title ?? "正在恢复会话…"
    }
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item?.reference.kind.symbol ?? (model.showArchived ? "archivebox" : model.onlyAttention ? "tray" : model.showSessionDirectory ? "list.bullet" : model.selectedGroup == nil ? "square.grid.2x2" : "folder"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }.frame(minWidth: 100, maxWidth: 440, alignment: .leading)
            .help(item.map { "\($0.title)\n\($0.reference.kind.label) · \($0.hostName)\n\($0.directory)" } ?? title)
    }
}

/// Only toolbar status observes the active stream; title and sidebar do not.
struct WorkbenchHeaderActions: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var kimi: KimiConnection
    @ObservedObject var native: NativeAgentConnection
    private var item: WorkspaceSession? { model.showDashboard ? nil : model.selectedItem }
    private var status: String? {
        if model.showDashboard { return nil }
        if model.showKimi, let session = kimi.conversation?.snapshot.session, session.busy { return session.status }
        if model.showNative, let session = native.snapshot {
            if !session.interactions.isEmpty { return "等你处理" }
            if session.busy { return "运行中" }
        }
        return nil
    }
    private var canStop: Bool {
        (model.showKimi && kimi.online && kimi.snapshotReady && kimi.conversation?.snapshot.session.busy == true)
        || (model.showNative && native.online && native.snapshot?.busy == true)
    }
    var body: some View {
        HStack(spacing: 12) {
            if let item, !item.directory.isEmpty {
                Label(URL(fileURLWithPath: item.directory).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 110).fixedSize(horizontal: true, vertical: false).help(item.directory)
            }
            if let status {
                HStack(spacing: 5) {
                    Circle().fill(status.contains("处理") || status.contains("确认") ? Color.orange : Color.secondary).frame(width: 5, height: 5)
                    Text(status).font(.system(size: 11))
                }.foregroundStyle(.secondary).fixedSize()
            }
            if !model.showDashboard, model.selectedHost != nil {
                Button { model.toggleFileViewer() } label: {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11))
                        .frame(width: 28, height: 28).workbenchControlSurface()
                }.buttonStyle(.plain).help("查看远端文件（只读）").accessibilityLabel("查看远端文件")
            }
            if canStop {
                Button { if model.showKimi { kimi.abort() } else { native.stop() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9)).frame(width: 28, height: 28)
                        .workbenchControlSurface()
                }.buttonStyle(.plain).help("停止当前任务").accessibilityLabel("停止当前任务")
            }
            if !model.showDashboard {
                Menu {
                    if model.showKimi { Button("同步会话") { kimi.reloadSelected() }.disabled(!kimi.online) }
                    else if model.showNative { Button("重新连接") { native.connect() } }
                    else {
                        Button(model.selectedConnection.wantsConnection ? "断开本地连接" : "连接终端") {
                            if model.selectedConnection.wantsConnection { model.selectedConnection.disconnect() }
                            else { model.selectedConnection.connect() }
                        }
                        Button("新建远端终端…") { model.showNewTerminal = true }
                    }
                    if let item { Divider(); SessionActionsMenu(model: model, item: item) }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).workbenchControlSurface() }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("会话操作")
            } else {
                if model.selectedGroup != nil {
                    Button { model.editGroup(model.selectedGroup) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).help("编辑任务组")
                }
                Menu {
                    Button("原生对话…") { model.showNewKimi = true }
                    Button("远端终端…") { model.showNewTerminal = true }.disabled(!model.selectedConnection.online)
                    Button("任务组…") { model.editGroup() }
                } label: { Label("新建", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}
