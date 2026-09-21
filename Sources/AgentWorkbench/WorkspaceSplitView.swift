import AppKit
import SwiftUI

/// AppKit owns the native glass sidebar, divider restoration, and unified toolbar.
struct WorkspaceSplitView<Sidebar: View, Header: View, Actions: View, Content: View>: NSViewControllerRepresentable {
    let newConversation: () -> Void
    let sidebar: Sidebar
    let header: Header
    let actions: Actions
    let content: Content

    init(newConversation: @escaping () -> Void, @ViewBuilder sidebar: () -> Sidebar,
         @ViewBuilder header: () -> Header, @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.newConversation = newConversation
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
        let contentItem = NSSplitViewItem(viewController: WorkbenchDetailController(content: coordinator.contentHost))
        contentItem.minimumThickness = 600
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(contentItem)
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = "WorkbenchWorkspace"

        let toolbar = NSToolbar(identifier: "WorkbenchToolbar")
        toolbar.delegate = coordinator
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        controller.workspaceToolbar = toolbar
        return controller
    }

    func updateNSViewController(_ controller: WorkbenchSplitController, context: Context) {
        let coordinator = context.coordinator
        coordinator.newConversation = newConversation
        coordinator.sidebarHost.rootView = sidebar
        coordinator.contentHost.rootView = content
        coordinator.headerHost.rootView = header
        coordinator.actionsHost.rootView = actions
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: WorkbenchSplitController,
                      context: Context) -> CGSize? {
        // The workspace fills its window. Never derive window size from all transcript rows.
        CGSize(width: proposal.width ?? 1280, height: proposal.height ?? 820)
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        let sidebarHost: NSHostingController<Sidebar>
        let contentHost: NSHostingController<Content>
        let headerHost: NSHostingView<Header>
        let actionsHost: NSHostingView<Actions>
        weak var controller: WorkbenchSplitController?
        var newConversation: () -> Void
        private let toggleID = NSToolbarItem.Identifier("WorkbenchSidebarToggle")
        private let composeID = NSToolbarItem.Identifier("WorkbenchCompose")
        private let separatorID = NSToolbarItem.Identifier("WorkbenchSidebarSeparator")
        private let titleID = NSToolbarItem.Identifier("WorkbenchTitle")
        private let actionsID = NSToolbarItem.Identifier("WorkbenchActions")

        init(_ view: WorkspaceSplitView) {
            sidebarHost = NSHostingController(rootView: view.sidebar)
            contentHost = NSHostingController(rootView: view.content)
            headerHost = NSHostingView(rootView: view.header)
            actionsHost = NSHostingView(rootView: view.actions)
            newConversation = view.newConversation
            super.init()
            // NSSplitView owns these dimensions; intrinsic SwiftUI measurements would
            // recursively measure the full conversation during every split layout.
            sidebarHost.sizingOptions = []
            contentHost.sizingOptions = []
            headerHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleID, composeID, separatorID, titleID, .flexibleSpace, actionsID]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            if id == separatorID, let controller {
                return NSTrackingSeparatorToolbarItem(identifier: id, splitView: controller.splitView, dividerIndex: 0)
            }
            let item = NSToolbarItem(itemIdentifier: id)
            if id == toggleID {
                item.label = "切换侧栏"
                item.toolTip = "显示或隐藏侧栏"
                item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
                item.target = controller
                item.action = #selector(NSSplitViewController.toggleSidebar(_:))
                item.isBordered = false
            } else if id == composeID {
                item.label = "新建任务"
                item.toolTip = "新建任务 · ⌘N"
                item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: item.label)
                item.target = self
                item.action = #selector(compose)
                item.isBordered = false
            } else if id == titleID {
                item.label = "当前会话"
                item.view = headerHost
                item.isBordered = false
                item.visibilityPriority = .high
            } else if id == actionsID {
                item.label = "会话操作"
                item.view = actionsHost
                item.isBordered = false
                item.visibilityPriority = .user
            }
            if id == toggleID || id == composeID {
                item.view = navigationButton(for: item)
            }
            return item
        }

        private func navigationButton(for item: NSToolbarItem) -> NSButton {
            let button = NSButton(title: "", target: item.target, action: item.action)
            button.image = item.image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 16, weight: .regular, scale: .medium))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.controlSize = .regular
            button.setButtonType(.momentaryPushIn)
            button.bezelStyle = .texturedRounded
            button.isBordered = true
            button.showsBorderOnlyWhileMouseInside = true
            button.toolTip = item.toolTip
            button.setAccessibilityLabel(item.label)
            // Equal native controls share one vertical center and toolbar spacing;
            // the symbols retain their aspect ratios instead of stretching to fit.
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
            return button
        }
        @objc private func compose() { newConversation() }
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
        window.toolbarStyle = .unifiedCompact
        window.toolbar = workspaceToolbar
    }
}
