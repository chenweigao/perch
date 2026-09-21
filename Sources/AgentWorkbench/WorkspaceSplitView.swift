import AppKit
import SwiftUI
import WorkbenchCore

/// AppKit owns the native glass sidebar, divider restoration, and unified toolbar.
struct WorkspaceSplitView<Sidebar: View, Header: View, Actions: View, Content: View>: NSViewControllerRepresentable {
    @Environment(\.locale) private var locale
    let newConversation: () -> Void
    let canNavigate: (Int) -> Bool
    let navigate: (Int) -> Void
    let sidebar: Sidebar
    let header: Header
    let actions: Actions
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
        self.sidebar = sidebar()
        self.header = header()
        self.actions = actions()
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSViewController(context: Context) -> WorkbenchSplitController {
        let coordinator = context.coordinator
        let controller = WorkbenchSplitController()
        coordinator.controller = controller
        coordinator.sidebarHost.view.setFrameSize(NSSize(width: 270, height: 620))
        coordinator.contentHost.view.setFrameSize(NSSize(width: 900, height: 620))

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: coordinator.sidebarHost)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .none
        let contentItem = NSSplitViewItem(viewController: WorkbenchDetailController(content: coordinator.contentHost))
        contentItem.minimumThickness = 600
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(contentItem)
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = "WorkbenchWorkspace"

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
        coordinator.locale = locale
        coordinator.sidebarHost.rootView = WorkspaceLocalizedRoot(content: sidebar, locale: locale)
        coordinator.contentHost.rootView = WorkspaceLocalizedRoot(content: content, locale: locale)
        coordinator.headerHost.rootView = WorkspaceLocalizedRoot(content: header, locale: locale)
        coordinator.actionsHost.rootView = WorkspaceLocalizedRoot(content: actions, locale: locale)
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
        weak var controller: WorkbenchSplitController?
        var locale: Locale
        var newConversation: () -> Void
        var canNavigate: (Int) -> Bool
        var navigate: (Int) -> Void
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
            locale = view.locale
            newConversation = view.newConversation
            canNavigate = view.canNavigate
            navigate = view.navigate
            super.init()
            // NSSplitView owns these dimensions; intrinsic SwiftUI measurements would
            // recursively measure the full conversation during every split layout.
            sidebarHost.sizingOptions = []
            contentHost.sizingOptions = []
            headerHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
                item.label = L("新建任务")
                item.toolTip = L("新建任务 · ⌘N")
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
                case composeID: item.label = L("新建任务"); item.toolTip = L("新建任务 · ⌘N")
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
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .medium))
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
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28),
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
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar = workspaceToolbar
    }
}

/// Each AppKit hosting root starts a new SwiftUI environment tree.
struct WorkspaceLocalizedRoot<Content: View>: View {
    let content: Content
    let locale: Locale
    var body: some View { content.environment(\.locale, locale) }
}
