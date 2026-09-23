import SwiftUI

enum SidebarPage { case home, inbox, archive, other }

/// Only the middle scrolls. The system split-view item owns the floating glass.
struct WorkspaceSidebarShell<Rows: View, Environments: View>: View {
    let page: SidebarPage
    let attentionCount: Int
    let environmentSummary: String
    let onSearch: () -> Void
    let onNew: () -> Void
    let onHome: () -> Void
    let onInbox: () -> Void
    let onArchive: () -> Void
    @ViewBuilder let rows: Rows
    @ViewBuilder let environments: Environments
    @State private var showEnvironments = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 3) {
                navigation("搜索任务", symbol: "magnifyingglass", shortcut: "⌘K", action: onSearch)
                Divider().padding(.vertical, 7)
                navigation("新建会话", symbol: "square.and.pencil", shortcut: "⌘N", action: onNew)
                navigation("工作台", symbol: "square.grid.2x2", selected: page == .home, action: onHome)
                navigation("待处理", symbol: "tray", selected: page == .inbox, count: attentionCount, action: onInbox)
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
            ScrollView {
                // Recents are capped at 20. Lay this short navigation list out
                // eagerly: switching sessions can change row heights and order
                // together, which can trap LazyVStack in placement updates.
                VStack(alignment: .leading, spacing: 3) { rows }
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }.scrollIndicators(.hidden)
            VStack(spacing: 2) {
                Divider().padding(.vertical, 6)
                navigation("已归档", symbol: "archivebox", selected: page == .archive, action: onArchive)
                Button { showEnvironments.toggle() } label: {
                    HStack(spacing: WorkbenchChrome.labelSpacing) {
                        Image(systemName: "desktopcomputer").font(.system(size: WorkbenchChrome.symbolSize, weight: .regular)).imageScale(.medium)
                            .frame(width: WorkbenchChrome.sidebarSymbolWidth)
                        Text("环境")
                        Spacer(minLength: 4)
                        Text(environmentSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(SidebarNavigationStyle()).popover(isPresented: $showEnvironments, arrowEdge: .trailing) { environments }
                SettingsLink {
                    HStack(spacing: WorkbenchChrome.labelSpacing) {
                        Image(systemName: "gearshape").font(.system(size: WorkbenchChrome.symbolSize, weight: .regular)).imageScale(.medium)
                            .frame(width: WorkbenchChrome.sidebarSymbolWidth)
                        Text("设置"); Spacer(); Text("⌘,").foregroundStyle(.tertiary)
                    }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(SidebarNavigationStyle())
            }.padding(.horizontal, 10).padding(.bottom, 10)
        }.font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navigation(_ title: LocalizedStringKey, symbol: String, selected: Bool = false,
                            count: Int = 0, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: WorkbenchChrome.labelSpacing) {
                Image(systemName: symbol).font(.system(size: WorkbenchChrome.symbolSize, weight: .regular)).imageScale(.medium)
                    .frame(width: WorkbenchChrome.sidebarSymbolWidth)
                Text(title); Spacer(minLength: 4)
                if count > 0 { Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary) }
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(SidebarNavigationStyle(selected: selected)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Animate the navigation background alone; labels and page changes stay immediate.
struct SidebarNavigationStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarNavigationBody(configuration: configuration, selected: selected)
    }
}

private struct SidebarNavigationBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var opacity: Double { configuration.isPressed ? 0.09 : selected ? 0.065 : hovered ? 0.03 : 0 }
    var body: some View {
        configuration.label.contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(opacity))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: opacity)
            }
            .onHover { hovered = $0 }
    }
}
