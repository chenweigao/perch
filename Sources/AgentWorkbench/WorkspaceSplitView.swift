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

enum WorkspaceLayoutMetrics {
    static let sidebarInset: CGFloat = 12
    static let sidebarGap: CGFloat = 12
    static let sidebarDefaultWidth: CGFloat = 276
    static let sidebarMinimumWidth: CGFloat = 240
    static let sidebarMaximumWidth: CGFloat = 380
    static let contentMinimumWidth: CGFloat = 600
    static let inspectorDefaultWidth: CGFloat = 340
    static let inspectorMinimumWidth: CGFloat = 280
    static let inspectorMaximumWidth: CGFloat = 420
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

/// AppKit owns the floating glass sidebar, inline inspector, responsive layout, and unified toolbar.
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
        coordinator.sidebarHost.view.setFrameSize(NSSize(width: WorkspaceLayoutMetrics.sidebarDefaultWidth, height: 620))
        coordinator.contentHost.view.setFrameSize(NSSize(width: 900, height: 620))
        coordinator.inspectorHost?.view.setFrameSize(
            NSSize(width: WorkspaceLayoutMetrics.inspectorDefaultWidth, height: 620))
        coordinator.inspectorHost?.view.clipsToBounds = true

        let detailController = WorkbenchDetailController(content: coordinator.contentHost)
        let contentItem = NSSplitViewItem(viewController: detailController)
        contentItem.minimumThickness = WorkspaceLayoutMetrics.contentMinimumWidth
        contentItem.holdingPriority = .required
        controller.addSplitViewItem(contentItem)

        var inspectorItem: NSSplitViewItem?
        if let inspectorHost = coordinator.inspectorHost {
            let item = NSSplitViewItem(inspectorWithViewController: inspectorHost)
            item.minimumThickness = WorkspaceLayoutMetrics.inspectorMinimumWidth
            item.maximumThickness = WorkspaceLayoutMetrics.inspectorMaximumWidth
            item.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
            item.canCollapse = true
            item.isCollapsed = !inspectorVisible
            controller.addSplitViewItem(item)
            coordinator.observe(item)
            inspectorItem = item
        }
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = "WorkbenchWorkspace.v3"
        controller.installFloatingSidebar(coordinator.sidebarHost, detailController: detailController,
                                          inspectorItem: inspectorItem,
                                          inspectorVisible: inspectorVisible)

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
        coordinator.sidebarHost.rootView = WorkspaceFloatingSidebarRoot(content: sidebar, locale: locale)
        coordinator.contentHost.rootView = WorkspaceLocalizedRoot(content: content, locale: locale)
        coordinator.headerHost.rootView = WorkspaceLocalizedRoot(content: header, locale: locale)
        coordinator.actionsHost.rootView = WorkspaceLocalizedRoot(content: actions, locale: locale)
        if let inspector { coordinator.inspectorHost?.rootView = WorkspaceLocalizedRoot(content: inspector, locale: locale) }
        coordinator.setInspectorVisible(inspectorVisible)
        coordinator.updateToolbarLanguage()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: WorkbenchSplitController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1280, height: proposal.height ?? 820)
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        let sidebarHost: NSHostingController<WorkspaceFloatingSidebarRoot<Sidebar>>
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
        private let titleID = NSToolbarItem.Identifier("WorkbenchTitle")
        private let actionsID = NSToolbarItem.Identifier("WorkbenchActions")

        init(_ view: WorkspaceSplitView) {
            sidebarHost = NSHostingController(rootView: WorkspaceFloatingSidebarRoot(
                content: view.sidebar, locale: view.locale))
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
                if self.controller?.isApplyingResponsiveLayout == true { return }
                let visible = !collapsed
                self.controller?.recordInspectorVisibility(visible)
                guard visible != self.desiredInspectorVisible else { return }
                self.desiredInspectorVisible = visible
                self.inspectorVisibilityChanged(visible)
            }
        }

        func setInspectorVisible(_ visible: Bool) {
            desiredInspectorVisible = visible
            controller?.setInspectorDesiredVisible(visible)
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleID, backID, forwardID, titleID, .flexibleSpace, actionsID]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar) + [composeID]
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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
                item.action = #selector(WorkbenchSplitController.toggleSidebar(_:))
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

private final class WorkbenchNavigationToolbarItem: NSToolbarItem {
    var canNavigate: () -> Bool = { false }

    override func validate() {
        isEnabled = canNavigate()
        (view as? NSButton)?.isEnabled = isEnabled
    }
}

final class WorkbenchDetailController: NSViewController {
    let content: NSViewController
    private var contentLeadingConstraint: NSLayoutConstraint?
    private(set) var contentLeadingInset: CGFloat = 0

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = WorkbenchCanvasView()
        addChild(content)
        let detail = content.view
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.clipsToBounds = true
        view.addSubview(detail)
        let leading = detail.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        contentLeadingConstraint = leading
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            leading,
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setContentLeadingInset(_ inset: CGFloat) {
        guard abs(inset - contentLeadingInset) > 0.5 else { return }
        contentLeadingInset = inset
        contentLeadingConstraint?.constant = inset
    }
}

private final class WorkbenchCanvasView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkbenchTheme.contentBackgroundNS.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class WorkspaceSidebarResizeHandle: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

final class WorkbenchSplitController: NSSplitViewController {
    static let sidebarVisibilityDefaultsKey = "perch.workspace.sidebar.visible.v3"
    static let sidebarWidthDefaultsKey = "perch.workspace.sidebar.width.v3"

    var workspaceToolbar: NSToolbar?
    private weak var floatingSidebarController: NSViewController?
    private weak var detailController: WorkbenchDetailController?
    private weak var inspectorItem: NSSplitViewItem?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarResizeHandle: WorkspaceSidebarResizeHandle?
    private var desiredInspectorVisible = false
    private var lastInspectorWidth = WorkspaceLayoutMetrics.inspectorDefaultWidth
    private var applyingLayout = false
    private(set) var isApplyingResponsiveLayout = false
    private(set) var isSidebarOverlayingContent = false
    private(set) var floatingSidebarWidth: CGFloat
    private(set) var isFloatingSidebarVisible: Bool

    var floatingSidebarView: NSView? { floatingSidebarController?.view }
    var detailCanvasView: NSView? { detailController?.view }
    var detailContentView: NSView? { detailController?.content.view }
    var detailContentLeadingInset: CGFloat { detailController?.contentLeadingInset ?? 0 }

    init() {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: Self.sidebarWidthDefaultsKey) as? NSNumber
        floatingSidebarWidth = Self.clampedSidebarWidth(
            storedWidth.map(CGFloat.init(truncating:)) ?? WorkspaceLayoutMetrics.sidebarDefaultWidth)
        if defaults.object(forKey: Self.sidebarVisibilityDefaultsKey) == nil {
            isFloatingSidebarVisible = true
        } else {
            isFloatingSidebarVisible = defaults.bool(forKey: Self.sidebarVisibilityDefaultsKey)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installFloatingSidebar(_ sidebar: NSViewController,
                                detailController: WorkbenchDetailController,
                                inspectorItem: NSSplitViewItem?,
                                inspectorVisible: Bool) {
        self.floatingSidebarController = sidebar
        self.detailController = detailController
        self.inspectorItem = inspectorItem
        desiredInspectorVisible = inspectorVisible

        let panel = sidebar.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let width = panel.widthAnchor.constraint(equalToConstant: floatingSidebarWidth)
        sidebarWidthConstraint = width

        let handle = WorkspaceSidebarResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(resizeSidebar(_:))))
        view.addSubview(handle, positioned: .above, relativeTo: panel)
        sidebarResizeHandle = handle

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                           constant: WorkspaceLayoutMetrics.sidebarInset),
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                       constant: WorkspaceLayoutMetrics.sidebarInset),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                          constant: -WorkspaceLayoutMetrics.sidebarInset),
            width,
            handle.leadingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -5),
            handle.widthAnchor.constraint(equalToConstant: 10),
            handle.topAnchor.constraint(equalTo: panel.topAnchor),
            handle.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        panel.isHidden = !isFloatingSidebarVisible
        handle.isHidden = !isFloatingSidebarVisible
        updateWorkspaceLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWorkspaceLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar = workspaceToolbar
    }

    override func toggleSidebar(_ sender: Any?) {
        setFloatingSidebarVisible(!isFloatingSidebarVisible)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    func setFloatingSidebarVisible(_ visible: Bool) {
        guard visible != isFloatingSidebarVisible else { return }
        isFloatingSidebarVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.sidebarVisibilityDefaultsKey)
        floatingSidebarView?.isHidden = !visible
        sidebarResizeHandle?.isHidden = !visible
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
        desiredInspectorVisible = visible
        updateWorkspaceLayout()
    }

    func recordInspectorVisibility(_ visible: Bool) {
        desiredInspectorVisible = visible
    }

    private func updateWorkspaceLayout() {
        guard !applyingLayout, view.bounds.width > 0 else { return }
        applyingLayout = true
        defer { applyingLayout = false }

        let availableWidth = view.bounds.width
        if let inspectorItem, !inspectorItem.isCollapsed {
            let measured = inspectorItem.viewController.view.bounds.width
            if measured >= WorkspaceLayoutMetrics.inspectorMinimumWidth - 1 {
                lastInspectorWidth = min(WorkspaceLayoutMetrics.inspectorMaximumWidth,
                                         max(WorkspaceLayoutMetrics.inspectorMinimumWidth, measured))
            }
        }

        let avoidance = WorkspaceLayoutMetrics.sidebarInset + floatingSidebarWidth +
            WorkspaceLayoutMetrics.sidebarGap
        let divider = inspectorItem == nil ? 0 : splitView.dividerThickness
        let widthWithInspector = WorkspaceLayoutMetrics.contentMinimumWidth +
            (isFloatingSidebarVisible ? avoidance : 0) + lastInspectorWidth + divider
        let showInspector = desiredInspectorVisible && availableWidth >= widthWithInspector - 0.5

        if let inspectorItem, inspectorItem.isCollapsed == showInspector {
            isApplyingResponsiveLayout = true
            inspectorItem.isCollapsed = !showInspector
            isApplyingResponsiveLayout = false
        }

        let detailWidth = availableWidth - (showInspector ? lastInspectorWidth + divider : 0)
        let avoidSidebar = isFloatingSidebarVisible &&
            detailWidth >= WorkspaceLayoutMetrics.contentMinimumWidth + avoidance - 0.5
        detailController?.setContentLeadingInset(avoidSidebar ? avoidance : 0)
        isSidebarOverlayingContent = isFloatingSidebarVisible && !avoidSidebar
        floatingSidebarView?.isHidden = !isFloatingSidebarVisible
        sidebarResizeHandle?.isHidden = !isFloatingSidebarVisible
    }

    @objc private func resizeSidebar(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: view)
        setFloatingSidebarWidth(floatingSidebarWidth + translation.x)
        recognizer.setTranslation(.zero, in: view)
    }

    private static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(WorkspaceLayoutMetrics.sidebarMaximumWidth,
            max(WorkspaceLayoutMetrics.sidebarMinimumWidth, width))
    }
}

struct WorkspaceFloatingSidebarRoot<Content: View>: View {
    let content: Content
    let locale: Locale

    var body: some View {
        content
            .environment(\.locale, locale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .workbenchFloatingSurface()
    }
}

/// Each AppKit hosting root starts a new SwiftUI environment tree.
struct WorkspaceLocalizedRoot<Content: View>: View {
    let content: Content
    let locale: Locale
    var body: some View { content.environment(\.locale, locale) }
}
