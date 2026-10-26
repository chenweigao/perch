import SwiftUI
import WorkbenchCore

enum SidebarPage { case home, inbox, archive, sessions, groups, other }

/// Only the middle scrolls. The workspace overlay owns the floating glass.
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
    /// Set while no machine is configured: the footer then offers the add-machine sheet.
    var onAddMachine: (() -> Void)? = nil
    var scrollRows = true
    var scrollTargetID: String? = nil
    @ViewBuilder let rows: Rows
    @ViewBuilder let environments: Environments
    @State private var showSettings = false
    @State private var showEnvironments = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    // A field-like target: tinted, never bordered, same height as rows.
                    navigation("搜索项目与会话", symbol: "magnifyingglass", shortcut: "⌘K", action: onSearch)
                        .background(.primary.opacity(WorkbenchTheme.Fill.surface), in: RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius))
                        .accessibilityIdentifier("sidebar.search")
                    Button(action: onNew) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: SidebarMetrics.iconSize, weight: .regular)).imageScale(.medium)
                            .frame(width: SidebarMetrics.rowHeight, height: SidebarMetrics.rowHeight)
                    }.buttonStyle(SidebarNavigationStyle()).help("新建会话")
                        .accessibilityLabel("新建会话").accessibilityIdentifier("sidebar.new")
                }.padding(.bottom, 8)
                navigation("工作台", symbol: "square.grid.2x2", selected: page == .home, action: onHome)
                navigation("待处理", symbol: "tray", selected: page == .inbox, count: attentionCount, action: onInbox)
            }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            if scrollRows {
            ScrollViewReader { proxy in
            ScrollView {
                // Project rows are bounded until explicitly expanded. Keep stable
                // eager layout when selection and catalog order change together.
                VStack(alignment: .leading, spacing: 2) { rows }
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }.scrollIndicators(.hidden)
                .onChange(of: scrollTargetID, initial: true) { _, target in
                    // Visible selections stay under the pointer. Offscreen selections
                    // (for example from search) move only enough to become visible.
                    // Catalog regrouping alone must not pull the reader back here.
                    if let target { proxy.scrollTo(target) }
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
                if let onAddMachine {
                    // First run: adding a machine is one visible row, not only ⚙ → 环境管理 → +.
                    navigation("添加机器…", symbol: "server.rack", shortcut: "⇧⌘N", action: onAddMachine)
                        .accessibilityIdentifier("sidebar.addMachine")
                }
                Button {
                    showEnvironments = false
                    showSettings.toggle()
                } label: {
                    HStack(spacing: SidebarMetrics.labelSpacing) {
                        Image(systemName: "gearshape").font(.system(size: SidebarMetrics.iconSize, weight: .regular)).imageScale(.medium)
                            .frame(width: SidebarMetrics.iconWidth)
                            .overlay(alignment: .topTrailing) {
                                if environmentNeedsAttention {
                                    Circle().fill(.orange).frame(width: 6, height: 6)
                                }
                            }
                        Text("设置与环境"); Spacer(); shortcutHint("⌘,")
                    }.padding(.horizontal, SidebarMetrics.rowInset).frame(height: SidebarMetrics.rowHeight).contentShape(Rectangle())
                }.buttonStyle(SidebarNavigationStyle())
                    .accessibilityIdentifier("sidebar.settings")
                    .accessibilityValue(environmentNeedsAttention ? Text("环境需要处理") : Text(""))
                    .popover(isPresented: $showSettings, arrowEdge: .trailing) {
                        if showEnvironments {
                            environments
                        } else {
                            VStack(spacing: 3) {
                                navigation("环境管理", symbol: "server.rack") { showEnvironments = true }
                                    .help(environmentSummary)
                                if environmentNeedsAttention {
                                    Text("环境需要处理").font(.subheadline).foregroundStyle(.orange)
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
            HStack(spacing: SidebarMetrics.labelSpacing) {
                Image(systemName: symbol).font(.system(size: SidebarMetrics.iconSize, weight: .regular)).imageScale(.medium)
                    .frame(width: SidebarMetrics.iconWidth)
                Text(title).lineLimit(1); Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: SidebarMetrics.detailSize, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let shortcut { shortcutHint(shortcut) }
            }.padding(.horizontal, SidebarMetrics.rowInset).frame(height: SidebarMetrics.rowHeight).contentShape(Rectangle())
        }.buttonStyle(SidebarNavigationStyle(selected: selected)).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// ⌘K, ⌘, and the like: verbatim, one size and tone in every row.
    private func shortcutHint(_ shortcut: String) -> some View {
        Text(shortcut).font(.system(size: SidebarMetrics.shortcutSize)).foregroundStyle(.tertiary).fixedSize()
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
    @State private var pressed = false
    private enum Focus { case toggle, create }
    @FocusState private var focused: Focus?

    var body: some View {
        // One highlight spans the whole row, the count / + column included, like the
        // other rows. + keeps its own hit target and hover inside it.
        HStack(spacing: 0) {
            Button(action: onToggle) {
                // Chevron, then the icon in the column its sessions use below it.
                HStack(spacing: 0) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(width: SidebarMetrics.disclosureWidth)
                        .padding(.trailing, SidebarMetrics.disclosureSpacing)
                    Image(systemName: project.location == nil ? "bubble.left.and.bubble.right" : "folder")
                        .font(.system(size: SidebarMetrics.iconSize)).imageScale(.medium).foregroundStyle(.secondary)
                        .frame(width: SidebarMetrics.iconWidth)
                        .padding(.trailing, SidebarMetrics.labelSpacing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.title).font(.system(size: SidebarMetrics.titleSize, weight: .medium)).lineLimit(1)
                        if project.disambiguate, let detail = project.detail {
                            Text(detail).font(.system(size: SidebarMetrics.detailSize)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                }.padding(.leading, SidebarMetrics.rowInset)
                    .frame(height: project.disambiguate ? SidebarMetrics.subtitleRowHeight : SidebarMetrics.rowHeight)
                    .contentShape(Rectangle())
            }.buttonStyle(SidebarPressStyle(pressed: $pressed)).focused($focused, equals: .toggle)
                .help(project.detail ?? project.title)
                .accessibilityLabel(project.title)
                .accessibilityValue(expanded ? Text("已展开") : Text("已收起"))
                .accessibilityIdentifier("sidebar.project.\(project.id)")
                .contextMenu { Button("在此项目新建会话", action: onNew).disabled(!canCreate) }
            ZStack {
                Text("\(project.sessions.count)").font(.system(size: SidebarMetrics.detailSize)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(hovered || focused != nil ? 0 : 1).accessibilityHidden(true)
                Button(action: onNew) {
                    // Fills the 28 pt trailing column; the row stays taller than the button.
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                }
                    .buttonStyle(SidebarNavigationStyle()).disabled(!canCreate)
                    .focused($focused, equals: .create)
                    .help("在此项目新建会话").accessibilityLabel("在此项目新建会话")
                    .opacity(hovered || focused != nil ? 1 : 0).allowsHitTesting(hovered || focused != nil)
            }.frame(width: 28)
        }.background { SidebarHighlight(hovered: hovered, pressed: pressed) }
            .contentShape(Rectangle()).onHover { hovered = $0 }
            .padding(.top, 2)
    }
}

/// The main button of a row that draws its own full-width highlight: it reports
/// the press to the row instead of drawing a background of its own.
private struct SidebarPressStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, isPressed in pressed = isPressed }
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 0) {
                        SidebarSectionTitle(title: Text(title), expanded: isExpanded)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, SidebarMetrics.rowInset)
                        .frame(height: SidebarMetrics.sectionHeaderHeight).contentShape(Rectangle())
                }.buttonStyle(SidebarNavigationStyle())
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(isExpanded ? Text("已展开") : Text("已收起"))
                    .accessibilityIdentifier("sidebar.section.\(id)")
                actions
            }.font(.system(size: SidebarMetrics.sectionTitleSize)).foregroundStyle(.secondary)
                .padding(.top, SidebarMetrics.sectionTopSpacing).padding(.bottom, SidebarMetrics.sectionBottomSpacing)
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
    var body: some View {
        configuration.label.contentShape(Rectangle())
            .background { SidebarHighlight(selected: selected, hovered: hovered, pressed: configuration.isPressed) }
            .onHover { hovered = $0 }
    }
}
