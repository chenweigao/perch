import SwiftUI

enum SidebarPage { case home, inbox, archive, other }

/// Only the middle scrolls. The system split-view item owns the floating glass.
struct WorkspaceSidebarShell<Rows: View, Environments: View>: View {
    let page: SidebarPage
    let attentionCount: Int
    let environmentSummary: String
    let onSearch: () -> Void
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
                    .keyboardShortcut("k")
                Divider().padding(.vertical, 7)
                navigation("工作台", symbol: "square.grid.2x2", selected: page == .home, action: onHome)
                navigation("待处理", symbol: "tray", selected: page == .inbox, count: attentionCount, action: onInbox)
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) { rows }
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }.scrollIndicators(.hidden)
            VStack(spacing: 2) {
                Divider().padding(.vertical, 6)
                navigation("已归档", symbol: "archivebox", selected: page == .archive, action: onArchive)
                Button { showEnvironments.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "desktopcomputer").frame(width: 17)
                        Text("环境")
                        Spacer(minLength: 4)
                        Text(environmentSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain).popover(isPresented: $showEnvironments, arrowEdge: .trailing) { environments }
                SettingsLink {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape").frame(width: 17); Text("设置"); Spacer(); Text("⌘,").foregroundStyle(.tertiary)
                    }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 10).padding(.bottom, 10)
        }.font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navigation(_ title: String, symbol: String, selected: Bool = false,
                            count: Int = 0, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 17)
                Text(title); Spacer(minLength: 4)
                if count > 0 { Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary) }
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                .background(selected ? .black.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
