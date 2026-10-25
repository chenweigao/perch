import AppKit
import SwiftUI
import WorkbenchCore

enum WorkbenchChrome {
    static let headerHeight: CGFloat = 44
    static let symbolSize: CGFloat = 13
    static let controlSize: CGFloat = 28
    static let controlSpacing: CGFloat = 16
    static let labelSpacing: CGFloat = 8
    static let sidebarSymbolWidth: CGFloat = 17
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

/// AppKit owns the native glass sidebar, inspector, divider restoration, and unified toolbar.
struct WorkspaceSplitView<Sidebar: View, Header: View, Actions: View, Content: View>: NSViewControllerRepresentable {
    @Environment(\.locale) private var locale
    let newConversation: () -> Void
    let canNavigate: (Int) -> Bool
    let navigate: (Int) -> Void
    let inspectorVisible: Bool
    let inspectorVisibilityChanged: (Bool) -> Void
    let sidebar: Sidebar
    let header: Header
    let actions: Actions
    let inspector: AnyView?
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
        inspectorVisibilityChanged = { _ in }
        self.sidebar = sidebar()
        self.header = header()
        self.actions = actions()
        inspector = nil
        self.content = content()
    }

    init<Inspector: View>(newConversation: @escaping () -> Void,
                          canNavigate: @escaping (Int) -> Bool = { _ in false },
                          navigate: @escaping (Int) -> Void = { _ in },
                          inspectorVisible: Bool,
                          inspectorVisibilityChanged: @escaping (Bool) -> Void,
                          @ViewBuilder sidebar: () -> Sidebar,
                          @ViewBuilder header: () -> Header,
                          @ViewBuilder actions: () -> Actions,
                          @ViewBuilder inspector: () -> Inspector,
                          @ViewBuilder content: () -> Content) {
        self.newConversation = newConversation
        self.canNavigate = canNavigate
        self.navigate = navigate
        self.inspectorVisible = inspectorVisible
        self.inspectorVisibilityChanged = inspectorVisibilityChanged
        self.sidebar = sidebar()
        self.header = header()
        self.actions = actions()
        self.inspector = AnyView(inspector())
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSViewController(context: Context) -> WorkbenchSplitController {
        let coordinator = context.coordinator
        let controller = WorkbenchSplitController()
        coordinator.controller = controller
        coordinator.sidebarHost.view.setFrameSize(NSSize(width: 270, height: 620))
        coordinator.contentHost.view.setFrameSize(NSSize(width: 900, height: 620))
        coordinator.inspectorHost?.view.setFrameSize(NSSize(width: 340, height: 620))
        coordinator.inspectorHost?.view.clipsToBounds = true

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: coordinator.sidebarHost)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .none
        let contentItem = NSSplitViewItem(viewController: WorkbenchDetailController(content: coordinator.contentHost))
        contentItem.minimumThickness = 600
        contentItem.holdingPriority = .required
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(contentItem)
        if let inspectorHost = coordinator.inspectorHost {
            let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
            inspectorItem.minimumThickness = 280
            inspectorItem.maximumThickness = 420
            inspectorItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
            inspectorItem.canCollapse = true
            inspectorItem.isCollapsed = !inspectorVisible
            controller.addSplitViewItem(inspectorItem)
            coordinator.observe(inspectorItem)
        }
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = "WorkbenchWorkspace.v2"

        let toolbar = NSToolbar(identifier: "WorkbenchToolbar")
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
        coordinator.inspectorVisibilityChanged = inspectorVisibilityChanged
        coordinator.locale = locale
        coordinator.sidebarHost.rootView = WorkspaceLocalizedRoot(content: sidebar, locale: locale)
        coordinator.contentHost.rootView = WorkspaceLocalizedRoot(content: content, locale: locale)
        coordinator.headerHost.rootView = WorkspaceLocalizedRoot(content: header, locale: locale)
        coordinator.actionsHost.rootView = WorkspaceLocalizedRoot(content: actions, locale: locale)
        if let inspector { coordinator.inspectorHost?.rootView = WorkspaceLocalizedRoot(content: inspector, locale: locale) }
        coordinator.setInspectorVisible(inspectorVisible)
        coordinator.updateToolbarLanguage()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: WorkbenchSplitController,
                      context: Context) -> CGSize? {
        // The workspace fills its window. Never derive window size from all transcript rows.
        CGSize(width: proposal.width ?? 1280, height: proposal.height ?? 820)
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        let sidebarHost: NSHostingController<WorkspaceLocalizedRoot<Sidebar>>
        let contentHost: NSHostingController<WorkspaceLocalizedRoot<Content>>
        let headerHost: NSHostingView<WorkspaceLocalizedRoot<Header>>
        let actionsHost: NSHostingView<WorkspaceLocalizedRoot<Actions>>
        let inspectorHost: NSHostingController<WorkspaceLocalizedRoot<AnyView>>?
        weak var controller: WorkbenchSplitController?
        weak var inspectorItem: NSSplitViewItem?
        var locale: Locale
        var newConversation: () -> Void
        var canNavigate: (Int) -> Bool
        var navigate: (Int) -> Void
        var inspectorVisibilityChanged: (Bool) -> Void
        private var desiredInspectorVisible: Bool
        private var inspectorCollapseObservation: NSKeyValueObservation?
        private let backID = NSToolbarItem.Identifier("WorkbenchBack")
        private let forwardID = NSToolbarItem.Identifier("WorkbenchForward")
        private let toggleID = NSToolbarItem.Identifier("WorkbenchSidebarToggle")
        private let composeID = NSToolbarItem.Identifier("WorkbenchCompose")
        private let separatorID = NSToolbarItem.Identifier("WorkbenchSidebarSeparator")
        private let titleID = NSToolbarItem.Identifier("WorkbenchTitle")
        private let actionsID = NSToolbarItem.Identifier("WorkbenchActions")

        init(_ view: WorkspaceSplitView) {
            sidebarHost = NSHostingController(rootView: WorkspaceLocalizedRoot(content: view.sidebar, locale: view.locale))
            contentHost = NSHostingController(rootView: WorkspaceLocalizedRoot(content: view.content, locale: view.locale))
            headerHost = NSHostingView(rootView: WorkspaceLocalizedRoot(content: view.header, locale: view.locale))
            actionsHost = NSHostingView(rootView: WorkspaceLocalizedRoot(content: view.actions, locale: view.locale))
            inspectorHost = view.inspector.map {
                NSHostingController(rootView: WorkspaceLocalizedRoot(content: $0, locale: view.locale))
            }
            locale = view.locale
            newConversation = view.newConversation
            canNavigate = view.canNavigate
            navigate = view.navigate
            inspectorVisibilityChanged = view.inspectorVisibilityChanged
            desiredInspectorVisible = view.inspectorVisible
            super.init()
            // NSSplitView owns these dimensions; intrinsic SwiftUI measurements would
            // recursively measure the full conversation during every split layout.
            sidebarHost.sizingOptions = []
            contentHost.sizingOptions = []
            inspectorHost?.sizingOptions = []
            headerHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        func observe(_ item: NSSplitViewItem) {
            inspectorItem = item
            inspectorCollapseObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                guard let self, let collapsed = change.newValue else { return }
                let visible = !collapsed
                guard visible != self.desiredInspectorVisible else { return }
                self.desiredInspectorVisible = visible
                self.inspectorVisibilityChanged(visible)
            }
        }

        func setInspectorVisible(_ visible: Bool) {
            desiredInspectorVisible = visible
            guard let inspectorItem, inspectorItem.isCollapsed != !visible else { return }
            inspectorItem.isCollapsed = !visible
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleID, backID, forwardID, separatorID, titleID, .flexibleSpace, actionsID]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar) + [composeID]
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            if id == separatorID, let controller {
                return NSTrackingSeparatorToolbarItem(identifier: id, splitView: controller.splitView, dividerIndex: 0)
            }
            let L = LocalizedUIStrings(locale: locale)
            if id == backID || id == forwardID {
                let direction = id == backID ? -1 : 1
                let item = WorkbenchNavigationToolbarItem(itemIdentifier: id)
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
            if id == toggleID {
                item.label = L("切换侧栏")
                item.toolTip = L("显示或隐藏侧栏")
                item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
                item.target = controller
                item.action = #selector(NSSplitViewController.toggleSidebar(_:))
                item.isBordered = false
            } else if id == composeID {
                item.label = L("新建会话")
                item.toolTip = L("新建会话 · ⌘N")
                item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: item.label)
                item.target = self
                item.action = #selector(compose)
                item.isBordered = false
            } else if id == titleID {
                item.label = L("当前会话")
                item.view = headerHost
                item.isBordered = false
                item.visibilityPriority = .high
            } else if id == actionsID {
                item.label = L("会话操作")
                item.view = actionsHost
                item.isBordered = false
                item.visibilityPriority = .user
            }
            if id == toggleID || id == composeID {
                item.view = navigationButton(for: item)
            }
            return item
        }
        func updateToolbarLanguage() {
            let L = LocalizedUIStrings(locale: locale)
            for item in controller?.workspaceToolbar?.items ?? [] {
                switch item.itemIdentifier {
                case backID: item.label = L("Back"); item.toolTip = item.label + " · ⌘["
                case forwardID: item.label = L("Forward"); item.toolTip = item.label + " · ⌘]"
                case toggleID: item.label = L("切换侧栏"); item.toolTip = L("显示或隐藏侧栏")
                case composeID: item.label = L("新建会话"); item.toolTip = L("新建会话 · ⌘N")
                case titleID: item.label = L("当前会话")
                case actionsID: item.label = L("会话操作")
                default: break
                }
                if let button = item.view as? NSButton {
                    button.toolTip = item.toolTip
                    button.setAccessibilityLabel(item.label)
                }
            }
        }

        private func navigationButton(for item: NSToolbarItem) -> NSButton {
            let button = NSButton(title: "", target: item.target, action: item.action)
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
            // Equal native controls share one vertical center and toolbar spacing;
            // the symbols retain their aspect ratios instead of stretching to fit.
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

/// AppKit does not automatically validate toolbar items backed by custom views.
private final class WorkbenchNavigationToolbarItem: NSToolbarItem {
    var canNavigate: () -> Bool = { false }

    override func validate() {
        isEnabled = canNavigate()
        (view as? NSButton)?.isEnabled = isEnabled
    }
}

/// The sidebar may extend behind the toolbar, but the transcript viewport must not.
/// Constrain and clip the detail host itself; a SwiftUI inset still lets scrolling
/// content draw through the transparent titlebar.
private final class WorkbenchDetailController: NSViewController {
    let content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        addChild(content)
        let detail = content.view
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.clipsToBounds = true
        view.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            detail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

final class WorkbenchSplitController: NSSplitViewController {
    var workspaceToolbar: NSToolbar?
    private var adaptingToAvailableWidth = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let availableWidth = view.window?.contentView?.bounds.width else { return }
        adaptPanesToAvailableWidth(availableWidth)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar = workspaceToolbar
    }

    private func adaptPanesToAvailableWidth(_ availableWidth: CGFloat) {
        guard !adaptingToAvailableWidth, availableWidth > 0 else { return }

        func requiredWidth(_ items: [NSSplitViewItem]) -> CGFloat {
            let dividers = CGFloat(max(0, items.count - 1)) * splitView.dividerThickness
            return items.reduce(dividers) { $0 + $1.minimumThickness }
        }

        var targetVisibleItems = splitViewItems
        guard requiredWidth(targetVisibleItems) > availableWidth + 0.5 else { return }
        let collapsibleItems = splitViewItems.filter(\.canCollapse).sorted {
            $0.holdingPriority.rawValue < $1.holdingPriority.rawValue
        }
        var targetCollapsedItems: [NSSplitViewItem] = []
        for item in collapsibleItems {
            guard requiredWidth(targetVisibleItems) > availableWidth + 0.5 else { break }
            targetCollapsedItems.append(item)
            targetVisibleItems.removeAll { $0 === item }
        }

        adaptingToAvailableWidth = true
        defer { adaptingToAvailableWidth = false }
        for item in targetCollapsedItems where !item.isCollapsed {
            item.isCollapsed = true
        }
        let targetCollapsedIDs = Set(targetCollapsedItems.map { ObjectIdentifier($0) })
        for item in collapsibleItems where item.isCollapsed && !targetCollapsedIDs.contains(ObjectIdentifier(item)) {
            item.isCollapsed = false
        }
    }
}

/// Each AppKit hosting root starts a new SwiftUI environment tree.
struct WorkspaceLocalizedRoot<Content: View>: View {
    let content: Content
    let locale: Locale
    var body: some View { content.environment(\.locale, locale) }
}
