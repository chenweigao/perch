import SwiftUI
import WorkbenchCore

enum SidebarPage { case home, inbox, archive, sessions, groups, other }

/// Only the middle scrolls. The system split-view item owns the floating glass.
struct WorkspaceSidebarShell<Rows: View, Environments: View>: View {
    let page: SidebarPage
    let attentionCount: Int
    let environmentSummary: String
    var environmentNeedsAttention = false
    let onSearch: () -> Void
    let onNew: () -> Void
    let onHome: () -> Void
    let onInbox: () -> Void
    let onArchive: () -> Void
    var onAllSessions: (() -> Void)? = nil
    var onGroups: (() -> Void)? = nil
    var scrollRows = true
    var scrollTargetID: String? = nil
    var scrollContext = ""
    @ViewBuilder let rows: Rows
    @ViewBuilder let environments: Environments
    @State private var showSettings = false
    @State private var showEnvironments = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    navigation("搜索项目与会话", symbol: "magnifyingglass", shortcut: "⌘K", action: onSearch)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("sidebar.search")
                    Button(action: onNew) {
                        Image(systemName: "square.and.pencil").frame(width: 28, height: 34)
                    }.buttonStyle(SidebarNavigationStyle()).help("新建会话")
                        .accessibilityLabel("新建会话").accessibilityIdentifier("sidebar.new")
                }.padding(.bottom, 9)
                navigation("工作台", symbol: "square.grid.2x2", selected: page == .home, action: onHome)
                navigation("待处理", symbol: "tray", selected: page == .inbox, count: attentionCount, action: onInbox)
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
            if scrollRows {
            ScrollViewReader { proxy in
            ScrollView {
                // Project rows are bounded until explicitly expanded. Keep stable
                // eager layout when selection and catalog order change together.
                VStack(alignment: .leading, spacing: 3) { rows }
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }.scrollIndicators(.hidden)
                .onChange(of: [scrollTargetID, scrollContext], initial: true) { _, _ in
                    if let scrollTargetID { proxy.scrollTo(scrollTargetID, anchor: .center) }
                }
            }
            } else { rows.padding(.horizontal, 10).padding(.bottom, 10) }
            VStack(spacing: 2) {
                if let onAllSessions {
                    navigation("全部会话", symbol: "bubble.left.and.bubble.right", selected: page == .sessions, action: onAllSessions)
                        .accessibilityIdentifier("sidebar.allSessions")
                }
                if let onGroups {
                    navigation("任务组", symbol: "square.stack.3d.up", selected: page == .groups, action: onGroups)
                        .accessibilityIdentifier("sidebar.groups")
                }
                Divider().padding(.vertical, 6)
                Button {
                    showEnvironments = false
                    showSettings.toggle()
                } label: {
                    HStack(spacing: WorkbenchChrome.labelSpacing) {
                        Image(systemName: "gearshape").font(.system(size: WorkbenchChrome.symbolSize, weight: .regular)).imageScale(.medium)
                            .frame(width: WorkbenchChrome.sidebarSymbolWidth)
                            .overlay(alignment: .topTrailing) {
                                if environmentNeedsAttention {
                                    Circle().fill(.orange).frame(width: 6, height: 6)
                                }
                            }
                        Text("设置与环境"); Spacer(); Text("⌘,").foregroundStyle(.tertiary)
                    }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(SidebarNavigationStyle())
                    .accessibilityIdentifier("sidebar.settings")
                    .accessibilityValue(environmentNeedsAttention ? Text("环境需要处理") : Text(""))
                    .popover(isPresented: $showSettings, arrowEdge: .trailing) {
                        if showEnvironments {
                            environments
                        } else {
                            VStack(spacing: 3) {
                                navigation("环境管理", symbol: "desktopcomputer") { showEnvironments = true }
                                    .help(environmentSummary)
                                if environmentNeedsAttention {
                                    Text("环境需要处理").font(.caption).foregroundStyle(.orange)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                                }
                                navigation("已归档会话", symbol: "archivebox", selected: page == .archive) {
                                    showSettings = false
                                    onArchive()
                                }
                                Divider().padding(.vertical, 3)
                                navigation("通用设置", symbol: "gearshape", shortcut: "⌘,") {
                                    showSettings = false
                                    openSettings()
                                }
                            }.font(.system(size: 13)).padding(10).frame(width: 220)
                        }
                    }
            }.padding(.horizontal, 10).padding(.bottom, 10)
        }.font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navigation(_ title: LocalizedStringKey, symbol: String, selected: Bool = false,
                            count: Int = 0, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: WorkbenchChrome.labelSpacing) {
                Image(systemName: symbol).font(.system(size: WorkbenchChrome.symbolSize, weight: .regular)).imageScale(.medium)
                    .frame(width: WorkbenchChrome.sidebarSymbolWidth)
                Text(title).lineLimit(1); Spacer(minLength: 4)
                if count > 0 { Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary) }
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary).fixedSize() }
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(SidebarNavigationStyle(selected: selected)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The header and row list have separate lifetimes; collapse never navigates.
struct SidebarProjectHeader: View {
    let project: SidebarProject
    let expanded: Bool
    let canCreate: Bool
    let onToggle: () -> Void
    let onNew: () -> Void
    @State private var hovered = false
    private enum Focus { case toggle, create }
    @FocusState private var focused: Focus?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium)).frame(width: 10).foregroundStyle(.secondary)
                    Image(systemName: project.location == nil ? "bubble.left.and.bubble.right" : "folder")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if project.disambiguate, let detail = project.detail {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                }.padding(.leading, 9).frame(height: project.disambiguate ? 46 : 34).contentShape(Rectangle())
            }.buttonStyle(SidebarNavigationStyle()).focused($focused, equals: .toggle)
                .help(project.detail ?? project.title)
                .accessibilityLabel(project.title)
                .accessibilityValue(expanded ? Text("已展开") : Text("已收起"))
                .accessibilityIdentifier("sidebar.project.\(project.id)")
                .contextMenu { Button("新建会话", action: onNew).disabled(!canCreate) }
            ZStack {
                Text("\(project.sessions.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .opacity(hovered || focused != nil ? 0 : 1).accessibilityHidden(true)
                Button(action: onNew) { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(SidebarNavigationStyle()).disabled(!canCreate)
                    .focused($focused, equals: .create)
                    .help("在此项目新建会话").accessibilityLabel("在此项目新建会话")
                    .opacity(hovered || focused != nil ? 1 : 0).allowsHitTesting(hovered || focused != nil)
            }.frame(width: 28)
        }.padding(.top, 3).onHover { hovered = $0 }
    }
}

struct SidebarSection<Content: View, Actions: View>: View {
    let title: LocalizedStringKey
    let id: String
    let content: Content
    let actions: Actions
    @AppStorage private var isExpanded: Bool

    init(_ title: LocalizedStringKey, id: String, @ViewBuilder content: () -> Content,
         @ViewBuilder actions: () -> Actions) {
        self.title = title; self.id = id
        self.content = content(); self.actions = actions()
        _isExpanded = AppStorage(wrappedValue: true, "sidebar.\(id).expanded")
    }

    init(_ title: LocalizedStringKey, id: String, @ViewBuilder content: () -> Content) where Actions == EmptyView {
        self.init(title, id: id, content: content, actions: { EmptyView() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium)).frame(width: 10).accessibilityHidden(true)
                        Text(title)
                        Spacer(minLength: 0)
                    }.frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(SidebarNavigationStyle())
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(isExpanded ? Text("已展开") : Text("已收起"))
                    .accessibilityIdentifier("sidebar.section.\(id)")
                actions
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 7)
            if isExpanded { content }
        }
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
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(opacity))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: opacity)
            }
            .onHover { hovered = $0 }
    }
}
