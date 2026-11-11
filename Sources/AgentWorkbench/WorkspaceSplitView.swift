import AppKit
import SwiftUI
import WorkbenchCore

enum WorkbenchChrome {
    /// Compact native toolbar, with a small gutter above the reading sheet.
    static let headerHeight: CGFloat = 40
    static let symbolSize: CGFloat = 14
    static let controlSize: CGFloat = 32
    static let controlSpacing: CGFloat = 16
    static let labelSpacing: CGFloat = 8
    static let sidebarSymbolWidth: CGFloat = 17
}

enum WorkspaceLayoutMetrics {
    /// The reading sheet floats just below the unified window toolbar.
    static let frameInset: CGFloat = 12
    static let contentTopInset: CGFloat = WorkbenchChrome.headerHeight + 4
    /// The gap between the reading sheet and its subordinate command-line sheet.
    static let sheetGutter: CGFloat = 6
    /// Keep a usable reading lane beside the integrated inspector in narrow windows.
    static let inspectorReadingMinimumWidth: CGFloat = 320
    static let sidebarInset: CGFloat = frameInset
    static let sidebarGap: CGFloat = 12
    static let sidebarDefaultWidth: CGFloat = 304
    static let sidebarMinimumWidth: CGFloat = 280
    static let sidebarMaximumWidth: CGFloat = 400
    static let contentMinimumWidth: CGFloat = 600
    static let inspectorDefaultWidth: CGFloat = 312
    static let inspectorMinimumWidth: CGFloat = 280
    static let inspectorMaximumWidth: CGFloat = 400
}

struct WorkbenchToolbarSymbol: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: WorkbenchChrome.symbolSize, weight: .regular))
            .imageScale(.medium)
            .frame(width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize)
            .contentShape(Rectangle())
    }
}

/// One quiet state treatment inside the shared toolbar glass, with no extra elevation.
struct WorkbenchToolbarButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarButton(configuration: configuration, selected: selected)
    }

    private struct ToolbarButton: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label.background {
                RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous)
                    .fill(configuration.isPressed ? WorkbenchTheme.Fill.pressed
                        : selected ? WorkbenchTheme.Fill.selected : hovered ? WorkbenchTheme.Fill.hover : .clear)
                    .padding(2)
            }.onHover { hovered = $0 }
        }
    }
}

/// One translucent window backdrop contains navigation and the toolbar. The
/// workspace sheet floats above it and contains the reader and inspector; their hosts survive resizing.
struct WorkspaceSplitView<Sidebar: View, Header: View, Actions: View, Content: View>: NSViewControllerRepresentable {
    @Environment(\.locale) private var locale
    let newConversation: () -> Void
    let canNavigate: (Int) -> Bool
    let navigate: (Int) -> Void
    let inspectorVisible: Bool
    let sidebar: Sidebar
    let header: Header
    let actions: Actions
    let inspector: AnyView?
    /// The command line is the reader's subordinate sheet: installed once, then
    /// only shown or hidden, so a live shell survives being hidden.
    let commandLine: AnyView?
    let commandLineVisible: Bool
    let content: Content

    init(newConversation: @escaping () -> Void,
         canNavigate: @escaping (Int) -> Bool = { _ in false },
         navigate: @escaping (Int) -> Void = { _ in },
         @ViewBuilder sidebar: () -> Sidebar,
         @ViewBuilder header: () -> Header, @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.newConversation = newConversation
        self.canNavigate = canNavigate
        self.navigate = navigate
        inspectorVisible = false
        self.sidebar = sidebar()
        self.header = header()
        self.actions = actions()
        inspector = nil
        commandLine = nil
        commandLineVisible = false
        self.content = content()
    }

    init<Inspector: View>(newConversation: @escaping () -> Void,
                          canNavigate: @escaping (Int) -> Bool = { _ in false },
                          navigate: @escaping (Int) -> Void = { _ in },
                          inspectorVisible: Bool,
                          commandLineVisible: Bool = false,
                          commandLine: (() -> AnyView)? = nil,
                          @ViewBuilder sidebar: () -> Sidebar,
                          @ViewBuilder header: () -> Header,
                          @ViewBuilder actions: () -> Actions,
                          @ViewBuilder inspector: () -> Inspector,
                          @ViewBuilder content: () -> Content) {
        self.newConversation = newConversation
        self.canNavigate = canNavigate
        self.navigate = navigate
        self.inspectorVisible = inspectorVisible
        self.sidebar = sidebar()
        self.header = header()
        self.actions = actions()
        self.inspector = AnyView(inspector())
        self.commandLineVisible = commandLineVisible
        self.commandLine = commandLine?()
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSViewController(context: Context) -> WorkbenchSplitController {
        let coordinator = context.coordinator
        let controller = WorkbenchSplitController()
        coordinator.controller = controller
        coordinator.sidebarHost.setFrameSize(NSSize(width: WorkspaceLayoutMetrics.sidebarDefaultWidth, height: 620))
        coordinator.contentHost.view.setFrameSize(NSSize(width: 900, height: 620))
        coordinator.inspectorHost?.setFrameSize(
            NSSize(width: WorkspaceLayoutMetrics.inspectorDefaultWidth, height: 620))

        let detailController = WorkbenchDetailController(
            content: coordinator.contentHost,
            header: coordinator.headerHost,
            actions: coordinator.actionsHost)
        let contentItem = NSSplitViewItem(viewController: detailController)
        // The canvas holds the conversation card plus the frame margins on both sides.
        contentItem.minimumThickness = WorkspaceLayoutMetrics.contentMinimumWidth + 2 * WorkspaceLayoutMetrics.frameInset
        contentItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 249)
        controller.addSplitViewItem(contentItem)

        controller.splitView.dividerStyle = .thin
        controller.configureSplitPersistence()
        controller.installFloatingSidebar(coordinator.sidebarHost, detailController: detailController)
        if let inspectorHost = coordinator.inspectorHost {
            controller.installFloatingInspector(inspectorHost, visible: inspectorVisible)
        }
        if let commandLineHost = coordinator.commandLineHost {
            controller.installCommandLineIsland(commandLineHost, visible: commandLineVisible)
        }

        // Session title and actions now live in the main container's unified top bar;
        // the window toolbar keeps navigation controls on the leading glass.
        let toolbar = NSToolbar(identifier: "WorkbenchToolbar.v4")
        toolbar.delegate = coordinator
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        controller.workspaceToolbar = toolbar
        return controller
    }

    func updateNSViewController(_ controller: WorkbenchSplitController, context: Context) {
        let coordinator = context.coordinator
        coordinator.newConversation = newConversation
        coordinator.canNavigate = canNavigate
        coordinator.navigate = navigate
        coordinator.locale = locale
        coordinator.sidebarHost.rootView = WorkspaceFloatingPanelRoot(content: sidebar, locale: locale)
        coordinator.contentHost.rootView = WorkspaceLocalizedRoot(content: content, locale: locale)
        coordinator.headerHost.rootView = WorkspaceLocalizedRoot(content: header, locale: locale)
        coordinator.actionsHost.rootView = WorkspaceLocalizedRoot(content: actions, locale: locale)
        if let inspector {
            let root = WorkspaceInspectorPanelRoot(content: inspector, locale: locale)
            if let host = coordinator.inspectorHost {
                host.rootView = root
            } else if inspectorVisible {
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                host.safeAreaRegions = []
                host.setFrameSize(NSSize(width: WorkspaceLayoutMetrics.inspectorDefaultWidth, height: 144))
                coordinator.inspectorHost = host
                controller.installFloatingInspector(host, visible: true)
            }
        }
        if let commandLine {
            let root = WorkspaceFloatingPanelRoot(content: commandLine, locale: locale)
            if let host = coordinator.commandLineHost {
                host.rootView = root
            } else {
                let host = NSHostingView(rootView: root)
                host.sizingOptions = []
                host.safeAreaRegions = []
                coordinator.commandLineHost = host
                controller.installCommandLineIsland(host, visible: commandLineVisible)
            }
        }
        coordinator.setCommandLineIslandVisible(commandLineVisible)
        coordinator.setInspectorVisible(inspectorVisible)
        coordinator.updateToolbarLanguage()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: WorkbenchSplitController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1280, height: proposal.height ?? 820)
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        let sidebarHost: NSHostingView<WorkspaceFloatingPanelRoot<Sidebar>>
        let contentHost: NSHostingController<WorkspaceLocalizedRoot<Content>>
        let headerHost: WorkbenchToolbarTitleHost<WorkspaceLocalizedRoot<Header>>
        let actionsHost: NSHostingView<WorkspaceLocalizedRoot<Actions>>
        var inspectorHost: NSHostingView<WorkspaceInspectorPanelRoot<AnyView>>?
        var commandLineHost: NSHostingView<WorkspaceFloatingPanelRoot<AnyView>>?
        weak var controller: WorkbenchSplitController?
        var locale: Locale
        var newConversation: () -> Void
        var canNavigate: (Int) -> Bool
        var navigate: (Int) -> Void
        private let backID = NSToolbarItem.Identifier("WorkbenchBack")
        private let forwardID = NSToolbarItem.Identifier("WorkbenchForward")
        private let toggleID = NSToolbarItem.Identifier("WorkbenchSidebarToggle")
        private let composeID = NSToolbarItem.Identifier("WorkbenchCompose")
        private let toolbarItems = NSHashTable<NSToolbarItem>.weakObjects()

        init(_ view: WorkspaceSplitView) {
            sidebarHost = NSHostingView(rootView: WorkspaceFloatingPanelRoot(
                content: view.sidebar, locale: view.locale))
            contentHost = NSHostingController(rootView: WorkspaceLocalizedRoot(content: view.content, locale: view.locale))
            headerHost = WorkbenchToolbarTitleHost(rootView: WorkspaceLocalizedRoot(content: view.header, locale: view.locale))
            actionsHost = NSHostingView(rootView: WorkspaceLocalizedRoot(content: view.actions, locale: view.locale))
            inspectorHost = (view.inspectorVisible ? view.inspector : nil).map {
                NSHostingView(rootView: WorkspaceInspectorPanelRoot(content: $0, locale: view.locale))
            }
            commandLineHost = view.commandLine.map {
                NSHostingView(rootView: WorkspaceFloatingPanelRoot(content: $0, locale: view.locale))
            }
            locale = view.locale
            newConversation = view.newConversation
            canNavigate = view.canNavigate
            navigate = view.navigate
            super.init()
            sidebarHost.sizingOptions = []
            sidebarHost.safeAreaRegions = []
            contentHost.sizingOptions = []
            headerHost.sizingOptions = [.intrinsicContentSize]
            headerHost.safeAreaRegions = []
            actionsHost.sizingOptions = [.intrinsicContentSize]
            actionsHost.safeAreaRegions = []
            inspectorHost?.sizingOptions = []
            inspectorHost?.safeAreaRegions = []
            commandLineHost?.sizingOptions = []
            commandLineHost?.safeAreaRegions = []
            headerHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
            actionsHost.setContentCompressionResistancePriority(.required, for: .horizontal)
            actionsHost.setContentHuggingPriority(.required, for: .horizontal)
        }

        func setInspectorVisible(_ visible: Bool) {
            controller?.setInspectorDesiredVisible(visible)
        }

        func setCommandLineIslandVisible(_ visible: Bool) {
            controller?.setCommandLineIslandVisible(visible)
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleID]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleID, composeID, backID, forwardID, .flexibleSpace]
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let L = LocalizedUIStrings(locale: locale)
            if id == backID || id == forwardID {
                let direction = id == backID ? -1 : 1
                let item = WorkbenchNavigationToolbarItem(itemIdentifier: id)
                toolbarItems.add(item)
                item.label = L(direction == -1 ? "Back" : "Forward")
                item.toolTip = item.label + (direction == -1 ? " · ⌘[" : " · ⌘]")
                item.image = NSImage(systemSymbolName: direction == -1 ? "arrow.left" : "arrow.right",
                                     accessibilityDescription: item.label)
                item.target = self
                item.action = direction == -1 ? #selector(goBack) : #selector(goForward)
                item.isBordered = false
                item.canNavigate = { [weak self] in self?.canNavigate(direction) ?? false }
                item.view = navigationButton(for: item)
                item.validate()
                return item
            }
            let item = NSToolbarItem(itemIdentifier: id)
            toolbarItems.add(item)
            if id == toggleID {
                item.label = L("切换侧栏")
                item.toolTip = L("显示或隐藏侧栏")
                item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
                item.target = controller
                item.action = #selector(WorkbenchSplitController.toggleSidebar(_:))
                item.isBordered = false
            } else if id == composeID {
                item.label = L("新建会话")
                item.toolTip = L("新建会话 · ⌘N")
                item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: item.label)
                item.target = self
                item.action = #selector(compose)
                item.isBordered = false
            }
            if id == toggleID || id == composeID {
                item.view = navigationButton(for: item)
            }
            return item
        }

        func updateToolbarLanguage() {
            // Reading items while AppKit is materializing toolbar placeholders
            // can reenter the delegate through hosted SwiftUI updates.
            guard controller?.workspaceToolbarInstalled == true else { return }
            let L = LocalizedUIStrings(locale: locale)
            // Never ask NSToolbar.items to expand placeholders from a SwiftUI update.
            for item in toolbarItems.allObjects {
                switch item.itemIdentifier {
                case backID: item.label = L("Back"); item.toolTip = item.label + " · ⌘["
                case forwardID: item.label = L("Forward"); item.toolTip = item.label + " · ⌘]"
                case toggleID: item.label = L("切换侧栏"); item.toolTip = L("显示或隐藏侧栏")
                case composeID: item.label = L("新建会话"); item.toolTip = L("新建会话 · ⌘N")
                default: break
                }
                if let button = item.view as? NSButton {
                    button.toolTip = item.toolTip
                    button.setAccessibilityLabel(item.label)
                }
            }
        }

        private func navigationButton(for item: NSToolbarItem) -> NSButton {
            // The title convenience initializer calls sizeToFit, which can
            // flush SwiftUI and reenter NSToolbar's placeholder loader here.
            // These controls already have a fixed 32 pt layout contract.
            let button = NSButton(frame: NSRect(x: 0, y: 0,
                width: WorkbenchChrome.controlSize, height: WorkbenchChrome.controlSize))
            button.title = ""
            button.target = item.target
            button.action = item.action
            button.image = item.image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: WorkbenchChrome.symbolSize, weight: .regular, scale: .medium))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.controlSize = .small
            button.contentTintColor = .secondaryLabelColor
            button.setButtonType(.momentaryPushIn)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.showsBorderOnlyWhileMouseInside = true
            button.toolTip = item.toolTip
            button.setAccessibilityLabel(item.label)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: WorkbenchChrome.controlSize),
                button.heightAnchor.constraint(equalToConstant: WorkbenchChrome.controlSize),
            ])
            return button
        }
        @objc private func compose() { newConversation() }
        @objc private func goBack() { navigate(-1); controller?.workspaceToolbar?.validateVisibleItems() }
        @objc private func goForward() { navigate(1); controller?.workspaceToolbar?.validateVisibleItems() }
    }
}

final class WorkbenchToolbarTitleHost<Content: View>: NSHostingView<Content> {
    var didLayout: (() -> Void)?

    override func layout() {
        super.layout()
        didLayout?()
    }
}

private final class WorkbenchNavigationToolbarItem: NSToolbarItem {
    var canNavigate: () -> Bool = { false }

    override func validate() {
        isEnabled = canNavigate()
        (view as? NSButton)?.isEnabled = isEnabled
    }
}

/// The full-width canvas is transparent, so the window frame shows around the
/// conversation card. The card carries the content surface and its rounded edge.
final class WorkbenchDetailController: NSViewController {
    let content: NSViewController
    let header: NSView
    let actions: NSView
    private var cardLeadingConstraint: NSLayoutConstraint?
    private var cardTrailingConstraint: NSLayoutConstraint?
    private var readingTrailingConstraint: NSLayoutConstraint?
    private var headerLeadingConstraint: NSLayoutConstraint?
    /// Sidebar avoidance; 0 while the sidebar is hidden or overlays the card.
    private(set) var contentLeadingInset: CGFloat = 0
    private(set) var contentTrailingInset: CGFloat = 0
    private var card: WorkbenchContentCardView?
    private var cardShadow: WorkbenchPanelShadowView?
    private var headerBar: NSView?
    private var islandCard: WorkbenchContentCardView?
    private var islandShadow: WorkbenchPanelShadowView?
    private var islandHeightConstraint: NSLayoutConstraint?
    private var cardBottomDirect: NSLayoutConstraint?
    private var cardBottomToIsland: NSLayoutConstraint?
    private(set) var isIslandVisible = false
    var cardView: NSView? { card }
    var headerBarView: NSView? { headerBar }
    var headerTitleView: NSView? { header }
    var headerActionsView: NSView? { actions }

    init(content: NSViewController, header: NSView, actions: NSView) {
        self.content = content
        self.header = header
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.clipsToBounds = false
        addChild(content)
        let card = WorkbenchContentCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        cardShadow = WorkbenchPanelShadowView.install(behind: card, in: view)
        self.card = card
        let detail = content.view
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.clipsToBounds = true
        card.addSubview(detail)
        let headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(headerBar)
        self.headerBar = headerBar
        header.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(header)
        headerBar.addSubview(actions)
        let inset = WorkspaceLayoutMetrics.frameInset
        let leading = card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset)
        let trailing = card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset)
        let cardBottom = card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset)
        let headerLeading = header.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: WorkbenchTheme.Reading.inset)
        cardLeadingConstraint = leading
        cardTrailingConstraint = trailing
        cardBottomDirect = cardBottom
        headerLeadingConstraint = headerLeading
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor, constant: inset),
            leading,
            trailing,
            cardBottom,
            headerBar.topAnchor.constraint(equalTo: card.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: WorkbenchChrome.headerHeight),
            headerLeading,
            header.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            detail.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            detail.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let readingTrailing = detail.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        readingTrailing.isActive = true
        readingTrailingConstraint = readingTrailing
    }

    /// The outer sheet keeps its identity and edge while its internal reading lane resizes.
    func setContentInsets(leading: CGFloat, trailing: CGFloat) {
        if abs(leading - contentLeadingInset) > 0.5 {
            contentLeadingInset = leading
            cardLeadingConstraint?.constant = max(WorkspaceLayoutMetrics.frameInset, leading)
        }
        if abs(trailing - contentTrailingInset) > 0.5 {
            contentTrailingInset = trailing
            cardTrailingConstraint?.constant = -max(WorkspaceLayoutMetrics.frameInset, trailing)
        }
    }

    func setHeaderLeadingInset(_ inset: CGFloat) {
        if let headerLeadingConstraint, abs(headerLeadingConstraint.constant - inset) > 0.5 {
            headerLeadingConstraint.constant = inset
        }
    }

    func setInspectorWidth(_ width: CGFloat) {
        readingTrailingConstraint?.constant = -width
    }

    /// One clipped sheet contains the reader and its full-height auxiliary lane,
    /// separated only by whitespace (Qoder-style), never a hard vertical rule.
    func installInspector(_ inspector: NSView) -> (NSView, NSLayoutConstraint) {
        _ = view
        let sheet = card!
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        if let headerBar {
            sheet.addSubview(panel, positioned: .below, relativeTo: headerBar)
        } else {
            sheet.addSubview(panel)
        }
        inspector.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(inspector)
        let width = panel.widthAnchor.constraint(equalToConstant: WorkspaceLayoutMetrics.inspectorDefaultWidth)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: sheet.topAnchor),
            panel.bottomAnchor.constraint(equalTo: sheet.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            width,
            inspector.topAnchor.constraint(equalTo: panel.topAnchor, constant: WorkbenchChrome.headerHeight),
            inspector.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        return (panel, width)
    }

    /// Concentric with the window corner; see `WorkbenchTheme.Radius.framePanel`.
    func setCornerRadius(_ radius: CGFloat) {
        card?.cornerRadius = radius
        cardShadow?.cornerRadius = radius
        islandCard?.cornerRadius = radius
        islandShadow?.cornerRadius = radius
    }

    /// The command line is the reading sheet's subordinate sheet: the same opaque
    /// surface family, directly below it, with the window glass showing in the
    /// gap. Installed once; afterwards only shown or hidden so a live shell
    /// survives being hidden.
    func installIsland(_ island: NSView) {
        guard islandCard == nil, let card else { return }
        let islandCard = WorkbenchContentCardView()
        islandCard.cornerRadius = card.cornerRadius
        islandCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(islandCard)
        let shadow = WorkbenchPanelShadowView.install(behind: islandCard, in: view)
        shadow.cornerRadius = islandCard.cornerRadius
        islandShadow = shadow
        island.translatesAutoresizingMaskIntoConstraints = false
        island.clipsToBounds = true
        islandCard.addSubview(island)
        let inset = WorkspaceLayoutMetrics.frameInset
        let height = islandCard.heightAnchor.constraint(
            equalToConstant: Self.islandHeight(forCanvasHeight: view.bounds.height))
        let toIsland = card.bottomAnchor.constraint(equalTo: islandCard.topAnchor,
                                                    constant: -WorkspaceLayoutMetrics.sheetGutter)
        NSLayoutConstraint.activate([
            // Pinned to the reading sheet, not the canvas, so the island follows
            // the card when the floating sidebar pushes its leading edge right.
            islandCard.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            islandCard.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            islandCard.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset),
            height,
            island.topAnchor.constraint(equalTo: islandCard.topAnchor),
            island.leadingAnchor.constraint(equalTo: islandCard.leadingAnchor),
            island.trailingAnchor.constraint(equalTo: islandCard.trailingAnchor),
            island.bottomAnchor.constraint(equalTo: islandCard.bottomAnchor),
        ])
        islandHeightConstraint = height
        cardBottomToIsland = toIsland
        self.islandCard = islandCard
        islandCard.isHidden = !isIslandVisible
        shadow.isHidden = !isIslandVisible
    }

    func setIslandVisible(_ visible: Bool) {
        guard visible != isIslandVisible, let islandCard, let islandShadow else { return }
        isIslandVisible = visible
        if visible { updateIslandHeight() }
        if !visible, let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: islandCard) {
            // A hidden terminal must not keep eating keys.
            view.window?.makeFirstResponder(nil)
        }
        cardBottomDirect?.isActive = !visible
        cardBottomToIsland?.isActive = visible
        islandCard.isHidden = !visible
        islandShadow.isHidden = !visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().layoutSubtreeIfNeeded()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if isIslandVisible { updateIslandHeight() }
    }

    private func updateIslandHeight() {
        islandHeightConstraint?.constant = Self.islandHeight(forCanvasHeight: view.bounds.height)
    }

    private static func islandHeight(forCanvasHeight height: CGFloat) -> CGFloat {
        let proposed = min(460, max(260, height * 0.4))
        // The reading sheet keeps a usable 240pt even on short windows.
        let budget = height - WorkspaceLayoutMetrics.contentTopInset -
            WorkspaceLayoutMetrics.frameInset - WorkspaceLayoutMetrics.sheetGutter - 240
        return max(160, min(proposed, budget))
    }
}

/// An opaque content surface inside the window frame. It clips its page to the
/// panel radius so scrolling content and terminals keep the rounded edge; the
/// hairline is drawn above the page. The reader and internal inspector share it.
private final class WorkbenchContentCardView: NSView {
    var cornerRadius: CGFloat = WorkbenchTheme.Radius.framePanel(
        windowCorner: 0, inset: WorkspaceLayoutMetrics.frameInset) {
        didSet { if cornerRadius != oldValue { layer?.cornerRadius = cornerRadius } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // AppKit keeps the layer's masking in step with this flag.
        clipsToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkbenchTheme.contentBackgroundNS.cgColor
            layer?.borderColor = WorkbenchTheme.Stroke.hairlineNS.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

private final class WorkspaceSidebarResizeHandle: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

/// Separate from clipped AppKit content and SwiftUI-owned hosting layers so
/// their rendering cannot mask or replace the elevation shadow.
private final class WorkbenchPanelShadowView: NSView {
    var cornerRadius: CGFloat = WorkbenchTheme.Radius.framePanel(
        windowCorner: 0, inset: WorkspaceLayoutMetrics.frameInset) {
        didSet {
            guard cornerRadius != oldValue else { return }
            layer?.cornerRadius = cornerRadius
            needsLayout = true
        }
    }

    @discardableResult static func install(behind panel: NSView, in parent: NSView) -> WorkbenchPanelShadowView {
        let shadow = WorkbenchPanelShadowView()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        shadow.wantsLayer = true
        shadow.clipsToBounds = false
        shadow.layer?.cornerRadius = shadow.cornerRadius
        shadow.layer?.cornerCurve = .continuous
        parent.addSubview(shadow, positioned: .below, relativeTo: panel)
        NSLayoutConstraint.activate([
            shadow.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            shadow.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            shadow.topAnchor.constraint(equalTo: panel.topAnchor),
            shadow.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return shadow
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkbenchTheme.contentBackgroundNS.cgColor
            let elevation = NSShadow()
            elevation.shadowColor = NSColor.black.withAlphaComponent(
                effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.38 : 0.16)
            elevation.shadowBlurRadius = 20
            elevation.shadowOffset = NSSize(width: 0, height: -6)
            shadow = elevation
        }
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds,
            cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Elevation for a translucent panel: the same shadow as an opaque card, cut
/// out under the panel itself so the glass above still samples the content
/// behind it instead of a darkened fill.
private final class WorkbenchOuterShadowView: NSView {
    var cornerRadius: CGFloat = WorkbenchTheme.Radius.framePanel(
        windowCorner: 0, inset: WorkspaceLayoutMetrics.frameInset) {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }
    private let cutout = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        cutout.fillRule = .evenOdd
        layer?.mask = cutout
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let elevation = NSShadow()
            elevation.shadowColor = WorkbenchTheme.Elevation.panelShadow
            elevation.shadowBlurRadius = 12
            elevation.shadowOffset = NSSize(width: 0, height: -5)
            shadow = elevation
        }
    }

    override func layout() {
        super.layout()
        let panel = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        layer?.shadowPath = panel
        // Keep everything around the panel (where the shadow falls), drop its interior.
        let mask = CGMutablePath()
        mask.addRect(bounds.insetBy(dx: -64, dy: -64))
        mask.addPath(panel)
        cutout.frame = bounds
        cutout.path = mask
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class WorkbenchSplitController: NSSplitViewController {
    static let sidebarVisibilityDefaultsKey = "perch.workspace.sidebar.visible.v3"
    static let sidebarWidthDefaultsKey = "perch.workspace.sidebar.width.v5"
    static let inspectorWidthDefaultsKey = "perch.workspace.inspector.width.v2"

    var workspaceToolbar: NSToolbar?
    var didInstallToolbar: (() -> Void)?
    private(set) var workspaceToolbarInstalled = false
    private var appAppearance: AppAppearance = .system
    private var appearanceObserver: NSObjectProtocol?
    var alignToolbar: ((CGFloat) -> Void)?
    private(set) var floatingSidebarView: NSView?
    private(set) var floatingInspectorView: NSView?
    private weak var detailController: WorkbenchDetailController?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var inspectorWidthConstraint: NSLayoutConstraint?
    private var sidebarResizeHandle: WorkspaceSidebarResizeHandle?
    private var inspectorResizeHandle: WorkspaceSidebarResizeHandle?
    private var sidebarOverlayBackdrop: WorkbenchWindowBackdropView?
    private var sidebarOverlayShadow: WorkbenchOuterShadowView?
    private var applyingLayout = false
    /// Installing the toolbar changes the window corner and lays the window out
    /// while AppKit materializes toolbar items; updating hosted panels then can
    /// flush SwiftUI into those items mid-load. The pass after install applies it.
    private var installingToolbar = false
    private(set) var isSidebarOverlayingContent = false
    private(set) var isInspectorOverlayingContent = false
    /// Too narrow for sidebar, a 600 pt card and the inspector, yet wide enough
    /// without the sidebar: the sidebar steps aside, as a split view collapses
    /// its sidebar on resize, instead of the inspector covering the reply. The
    /// saved visibility is unchanged; widening the window brings it back.
    private(set) var isSidebarYieldingToInspector = false
    /// The reader asked for the sidebar while it was yielding: it then overlays
    /// as before, until the inspector closes or the window fits all three.
    private var sidebarRevealedOverInspector = false
    /// Concentric with the window corner across `frameInset`, for every frame panel.
    private(set) var panelCornerRadius = WorkbenchTheme.Radius.framePanel(
        windowCorner: 0, inset: WorkspaceLayoutMetrics.frameInset)
    private(set) var floatingSidebarWidth: CGFloat
    private(set) var isFloatingSidebarVisible: Bool
    private(set) var floatingInspectorWidth: CGFloat
    private(set) var isFloatingInspectorVisible = false
    /// Whether the sidebar is on screen; it may be visible by preference yet yielding.
    var isSidebarShown: Bool { isFloatingSidebarVisible && !isSidebarYieldingToInspector }

    private(set) var windowBackdropView: WorkbenchWindowBackdropView?
    var sidebarOverlayBackdropView: WorkbenchWindowBackdropView? { sidebarOverlayBackdrop }
    var detailCanvasView: NSView? { detailController?.view }
    var detailCardView: NSView? { detailController?.cardView }
    var detailContentView: NSView? { detailController?.content.view }
    var headerBarView: NSView? { detailController?.headerBarView }
    var headerTitleView: NSView? { detailController?.headerTitleView }
    var headerActionsView: NSView? { detailController?.headerActionsView }
    var detailContentLeadingInset: CGFloat { detailController?.contentLeadingInset ?? 0 }
    var detailContentTrailingInset: CGFloat { detailController?.contentTrailingInset ?? 0 }

    init() {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: Self.sidebarWidthDefaultsKey) as? NSNumber
        floatingSidebarWidth = Self.clampedSidebarWidth(
            storedWidth.map(CGFloat.init(truncating:)) ?? WorkspaceLayoutMetrics.sidebarDefaultWidth)
        let storedInspectorWidth = defaults.object(forKey: Self.inspectorWidthDefaultsKey) as? NSNumber
        floatingInspectorWidth = Self.clampedInspectorWidth(
            storedInspectorWidth.map(CGFloat.init(truncating:)) ?? WorkspaceLayoutMetrics.inspectorDefaultWidth)
        if defaults.object(forKey: Self.sidebarVisibilityDefaultsKey) == nil {
            isFloatingSidebarVisible = true
        } else {
            isFloatingSidebarVisible = defaults.bool(forKey: Self.sidebarVisibilityDefaultsKey)
        }
        super.init(nibName: nil, bundle: nil)
        syncAppearancePreference()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.syncAppearancePreference() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    }

    override func loadView() {
        splitView = NSSplitView()
        splitView.isVertical = true
        view = NSView()
        let backdrop = WorkbenchWindowBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        windowBackdropView = backdrop
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func installSidebarPanel(_ panel: NSView, width: CGFloat,
                                      handleAction: Selector) -> (NSLayoutConstraint, WorkspaceSidebarResizeHandle) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let widthConstraint = panel.widthAnchor.constraint(equalToConstant: width)
        let handle = WorkspaceSidebarResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: handleAction))
        view.addSubview(handle, positioned: .above, relativeTo: panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: WorkspaceLayoutMetrics.sidebarInset),
            panel.topAnchor.constraint(equalTo: view.topAnchor,
                                       constant: WorkspaceLayoutMetrics.contentTopInset),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -WorkspaceLayoutMetrics.sidebarInset),
            widthConstraint,
            handle.leadingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -5),
            handle.widthAnchor.constraint(equalToConstant: 10),
            handle.topAnchor.constraint(equalTo: panel.topAnchor),
            handle.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return (widthConstraint, handle)
    }

    func installFloatingSidebar(_ sidebar: NSView,
                                detailController: WorkbenchDetailController) {
        floatingSidebarView = sidebar
        self.detailController = detailController
        let (width, handle) = installSidebarPanel(sidebar, width: floatingSidebarWidth,
                                                   handleAction: #selector(resizeSidebar(_:)))
        sidebarWidthConstraint = width
        sidebarResizeHandle = handle
        sidebar.isHidden = !isFloatingSidebarVisible
        handle.isHidden = !isFloatingSidebarVisible
        // Only narrow overlay mode needs its own backing: a floating glass panel
        // over the card. Otherwise navigation sits directly on the window glass.
        // Unclipped, so the glass keeps its rim; over a white card the rim alone
        // does not read, so it adds a hairline and an elevation shadow around it.
        let overlayShadow = WorkbenchOuterShadowView()
        overlayShadow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayShadow, positioned: .below, relativeTo: sidebar)
        let overlay = WorkbenchWindowBackdropView(cornerRadius: panelCornerRadius, outlined: true)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay, positioned: .below, relativeTo: sidebar)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: sidebar.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            overlayShadow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            overlayShadow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            overlayShadow.topAnchor.constraint(equalTo: sidebar.topAnchor),
            overlayShadow.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])
        sidebarOverlayBackdrop = overlay
        sidebarOverlayShadow = overlayShadow
        updateWorkspaceLayout()
    }

    /// The inspector is an internal lane of the conversation sheet, with one separator.
    func installFloatingInspector(_ inspector: NSView, visible: Bool) {
        let (panel, width) = detailController!.installInspector(inspector)
        let handle = WorkspaceSidebarResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(resizeInspector(_:))))
        panel.superview!.addSubview(handle, positioned: .above, relativeTo: panel)
        NSLayoutConstraint.activate([
            handle.centerXAnchor.constraint(equalTo: panel.leadingAnchor),
            handle.widthAnchor.constraint(equalToConstant: 10),
            handle.topAnchor.constraint(equalTo: panel.topAnchor, constant: WorkbenchChrome.headerHeight),
            handle.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        floatingInspectorView = panel
        isFloatingInspectorVisible = visible
        inspectorWidthConstraint = width
        inspectorResizeHandle = handle
        panel.isHidden = !visible
        handle.isHidden = !visible
        updateWorkspaceLayout()
    }

    /// The command-line sheet lives beside the reading sheet, not inside it.
    func installCommandLineIsland(_ island: NSView, visible: Bool) {
        detailController?.installIsland(island)
        detailController?.setIslandVisible(visible)
    }

    func setCommandLineIslandVisible(_ visible: Bool) {
        detailController?.setIslandVisible(visible)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWorkspaceLayout()
        // Align the native toolbar (traffic lights + sidebar toggle) with the main
        // container's unified header vertical center.
        if let window = view.window, let card = detailCardView {
            let cardFrame = card.convert(card.bounds, to: nil)
            // Window coordinates: card top is measured from the window's bottom edge.
            // The native toolbar (traffic lights + sidebar toggle) must share the
            // same vertical center as the unified header inside the main container.
            let headerCenterY = cardFrame.minY + WorkbenchChrome.headerHeight / 2
            if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
                var frame = container.frame
                let delta = headerCenterY - frame.midY
                if abs(delta) > 0.5 {
                    frame.origin.y += delta
                    container.frame = frame
                }
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureSplitPersistence()
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unifiedCompact
        if appAppearance != .system { applyAppearance() }
        // The toolbar style sets the window's corner; the glass follows it.
        windowBackdropView?.updateCornerRadius()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            // Let the WindowGroup finish its appearance transaction before
            // AppKit materializes hosted toolbar items on that same window.
            if window.toolbar !== self.workspaceToolbar {
                self.workspaceToolbarInstalled = false
                self.installingToolbar = true
                window.toolbar = self.workspaceToolbar
                self.installingToolbar = false
                self.workspaceToolbarInstalled = true
                self.didInstallToolbar?()
            }
            self.windowBackdropView?.updateCornerRadius()
            self.updateWorkspaceLayout()
        }
    }

    func setAppearance(_ appearance: AppAppearance) {
        guard appearance != appAppearance else { return }
        appAppearance = appearance
        if isViewLoaded { applyAppearance() }
    }

    private func syncAppearancePreference() {
        setAppearance(AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.defaultsKey) ?? "system") ?? .system)
    }

    private func applyAppearance() {
        switch appAppearance {
        case .system: view.window?.appearance = nil
        case .light: view.window?.appearance = NSAppearance(named: .aqua)
        case .dark: view.window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func configureSplitPersistence() {
        let name = "WorkbenchWorkspace.v4"
        splitView.identifier = NSUserInterfaceItemIdentifier(name)
        splitView.autosaveName = name
    }

    // The base implementation assumes the split view has at least one divider;
    // the full-canvas workspace holds a single item and has none.
    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { false }

    override func toggleSidebar(_ sender: Any?) {
        // A yielding sidebar is hidden by width, not by preference: asking for
        // it brings it back over the card rather than flipping the preference.
        if isSidebarYieldingToInspector {
            sidebarRevealedOverInspector = true
            updateWorkspaceLayout()
            return
        }
        setFloatingSidebarVisible(!isFloatingSidebarVisible)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    func setFloatingSidebarVisible(_ visible: Bool) {
        guard visible != isFloatingSidebarVisible else { return }
        isFloatingSidebarVisible = visible
        if !visible { sidebarRevealedOverInspector = false }
        UserDefaults.standard.set(visible, forKey: Self.sidebarVisibilityDefaultsKey)
        floatingSidebarView?.isHidden = !(visible && !isSidebarYieldingToInspector)
        sidebarResizeHandle?.isHidden = !(visible && !isSidebarYieldingToInspector)
        updateWorkspaceLayout()
    }

    func setFloatingSidebarWidth(_ width: CGFloat) {
        let clamped = Self.clampedSidebarWidth(width)
        guard abs(clamped - floatingSidebarWidth) > 0.5 else { return }
        floatingSidebarWidth = clamped
        sidebarWidthConstraint?.constant = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.sidebarWidthDefaultsKey)
        updateWorkspaceLayout()
    }

    func setInspectorDesiredVisible(_ visible: Bool) {
        guard visible != isFloatingInspectorVisible else { return }
        isFloatingInspectorVisible = visible
        if !visible { sidebarRevealedOverInspector = false }
        floatingInspectorView?.isHidden = !visible
        inspectorResizeHandle?.isHidden = !visible
        updateWorkspaceLayout()
    }

    func setFloatingInspectorWidth(_ width: CGFloat) {
        let clamped = Self.clampedInspectorWidth(width)
        guard abs(clamped - floatingInspectorWidth) > 0.5 else { return }
        floatingInspectorWidth = clamped
        inspectorWidthConstraint?.constant = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.inspectorWidthDefaultsKey)
        updateWorkspaceLayout()
    }

    private func updateWorkspaceLayout() {
        guard !applyingLayout, view.bounds.width > 0 else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        updatePanelCornerRadius()

        // The outer sheet stays fixed; its reader yields space to the internal inspector.
        let availableWidth = view.bounds.width
        let minimum = WorkspaceLayoutMetrics.contentMinimumWidth - 0.5
        let avoidance = WorkspaceLayoutMetrics.sidebarInset + floatingSidebarWidth +
            WorkspaceLayoutMetrics.sidebarGap
        let inspectorAvoidance = WorkspaceLayoutMetrics.frameInset + floatingInspectorWidth
        let fitsSidebar = availableWidth - avoidance - WorkspaceLayoutMetrics.frameInset >= minimum
        let fitsBoth = availableWidth - avoidance - inspectorAvoidance >= minimum
        let fitsInspectorAlone = availableWidth - WorkspaceLayoutMetrics.frameInset - inspectorAvoidance >= minimum
        let bothOpen = isFloatingSidebarVisible && isFloatingInspectorVisible
        if !bothOpen || fitsBoth { sidebarRevealedOverInspector = false }
        // The reply keeps priority over navigation: rather than letting the
        // inspector cover it, the sidebar steps aside while the card still fits.
        isSidebarYieldingToInspector = bothOpen && fitsSidebar && !fitsBoth && fitsInspectorAlone &&
            !sidebarRevealedOverInspector
        let sidebarShown = isSidebarShown
        let avoidSidebar = sidebarShown && fitsSidebar
        let leading = avoidSidebar ? avoidance : WorkspaceLayoutMetrics.frameInset
        detailController?.setContentInsets(leading: avoidSidebar ? avoidance : 0,
                                          trailing: 0)
        let inspectorWidth = isFloatingInspectorVisible
            ? min(floatingInspectorWidth, max(0, availableWidth - leading -
                WorkspaceLayoutMetrics.frameInset - WorkspaceLayoutMetrics.inspectorReadingMinimumWidth))
            : 0
        detailController?.setInspectorWidth(inspectorWidth)
        if isFloatingInspectorVisible { inspectorWidthConstraint?.constant = inspectorWidth }
        isSidebarOverlayingContent = sidebarShown && !avoidSidebar
        let headerLeading: CGFloat
        if isSidebarOverlayingContent {
            headerLeading = floatingSidebarWidth + WorkspaceLayoutMetrics.sidebarGap + WorkbenchTheme.Reading.inset
        } else if !avoidSidebar {
            headerLeading = 120
        } else {
            headerLeading = WorkbenchTheme.Reading.inset
        }
        detailController?.setHeaderLeadingInset(headerLeading)
        sidebarOverlayBackdrop?.isHidden = !isSidebarOverlayingContent
        sidebarOverlayShadow?.isHidden = !isSidebarOverlayingContent
        isInspectorOverlayingContent = false
        floatingSidebarView?.isHidden = !sidebarShown
        sidebarResizeHandle?.isHidden = !sidebarShown
        floatingInspectorView?.isHidden = !isFloatingInspectorVisible
        inspectorResizeHandle?.isHidden = !isFloatingInspectorVisible
        if let canvas = detailCanvasView {
            // Insets above describe the new layout; the card's frame still
            // describes the previous one until AppKit lays out its descendants.
            let canvasX = canvas.convert(canvas.bounds, to: view).minX
            alignToolbar?(canvasX + leading + WorkbenchTheme.Reading.inset)
        }
    }

    /// The window corner changes with the toolbar style and full screen; every
    /// frame panel follows it so all of them stay concentric with the window.
    private func updatePanelCornerRadius() {
        guard !installingToolbar else { return }
        let corner = view.window.map(WorkbenchWindowBackdropView.windowCornerRadius(of:)) ?? 0
        let radius = WorkbenchTheme.Radius.framePanel(windowCorner: corner, inset: WorkspaceLayoutMetrics.frameInset)
        guard abs(radius - panelCornerRadius) > 0.25 else { return }
        panelCornerRadius = radius
        detailController?.setCornerRadius(radius)
        sidebarOverlayBackdrop?.fixedCornerRadius = radius
        sidebarOverlayShadow?.cornerRadius = radius
    }

    @objc private func resizeSidebar(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: view)
        setFloatingSidebarWidth(floatingSidebarWidth + translation.x)
        recognizer.setTranslation(.zero, in: view)
    }

    @objc private func resizeInspector(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: view)
        setFloatingInspectorWidth(floatingInspectorWidth - translation.x)
        recognizer.setTranslation(.zero, in: view)
    }

    private static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(WorkspaceLayoutMetrics.sidebarMaximumWidth,
            max(WorkspaceLayoutMetrics.sidebarMinimumWidth, width))
    }

    private static func clampedInspectorWidth(_ width: CGFloat) -> CGFloat {
        min(WorkspaceLayoutMetrics.inspectorMaximumWidth,
            max(WorkspaceLayoutMetrics.inspectorMinimumWidth, width))
    }
}

/// Navigation shares the window backdrop instead of adding another glass card.
struct WorkspaceFloatingPanelRoot<Content: View>: View {
    let content: Content
    let locale: Locale

    var body: some View {
        content
            .environment(\.locale, locale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The inspector inherits the conversation sheet's surface and clipping.
struct WorkspaceInspectorPanelRoot<Content: View>: View {
    let content: Content
    let locale: Locale

    var body: some View {
        content
            .environment(\.locale, locale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Each AppKit hosting root starts a new SwiftUI environment tree.
struct WorkspaceLocalizedRoot<Content: View>: View {
    let content: Content
    let locale: Locale
    var body: some View { content.environment(\.locale, locale) }
}
