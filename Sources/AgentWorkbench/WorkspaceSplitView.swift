import AppKit
import SwiftUI
import WorkbenchCore

enum WorkbenchChrome {
    static let headerHeight: CGFloat = 44
    static let symbolSize: CGFloat = 15
    static let controlSize: CGFloat = 32
    static let controlSpacing: CGFloat = 16
    static let labelSpacing: CGFloat = 8
    static let sidebarSymbolWidth: CGFloat = 17
}

enum WorkspaceLayoutMetrics {
    /// The reading sheet floats below the unified window toolbar.
    static let frameInset: CGFloat = 12
    static let contentTopInset: CGFloat = WorkbenchChrome.headerHeight + frameInset
    static let inspectorTopInset: CGFloat = contentTopInset + 12
    static let inspectorBottomInset: CGFloat = 24
    static let inspectorPreferredHeight: CGFloat = 680
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

/// One translucent window backdrop contains navigation and the toolbar. The
/// reading sheet and inspector float above it; their hosts survive resizing.
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
        self.content = content()
    }

    init<Inspector: View>(newConversation: @escaping () -> Void,
                          canNavigate: @escaping (Int) -> Bool = { _ in false },
                          navigate: @escaping (Int) -> Void = { _ in },
                          inspectorVisible: Bool,
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

        let detailController = WorkbenchDetailController(content: coordinator.contentHost)
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

        // Keep legacy saved item order from omitting the new pane-alignment spacers.
        let toolbar = NSToolbar(identifier: "WorkbenchToolbar.v2")
        toolbar.delegate = coordinator
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        controller.workspaceToolbar = toolbar
        controller.alignToolbar = { [weak coordinator] leading, trailing in
            coordinator?.alignToolbar(leading: leading, trailing: trailing)
        }
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
        if let inspector { coordinator.inspectorHost?.rootView = WorkspaceInspectorPanelRoot(content: inspector, locale: locale) }
        coordinator.setInspectorVisible(inspectorVisible)
        coordinator.updateToolbarLanguage()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: WorkbenchSplitController,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1280, height: proposal.height ?? 820)
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        let sidebarHost: NSHostingController<WorkspaceFloatingPanelRoot<Sidebar>>
        let contentHost: NSHostingController<WorkspaceLocalizedRoot<Content>>
        let headerHost: NSHostingView<WorkspaceLocalizedRoot<Header>>
        let actionsHost: NSHostingView<WorkspaceLocalizedRoot<Actions>>
        let inspectorHost: NSHostingController<WorkspaceInspectorPanelRoot<AnyView>>?
        weak var controller: WorkbenchSplitController?
        var locale: Locale
        var newConversation: () -> Void
        var canNavigate: (Int) -> Bool
        var navigate: (Int) -> Void
        private let backID = NSToolbarItem.Identifier("WorkbenchBack")
        private let forwardID = NSToolbarItem.Identifier("WorkbenchForward")
        private let toggleID = NSToolbarItem.Identifier("WorkbenchSidebarToggle")
        private let composeID = NSToolbarItem.Identifier("WorkbenchCompose")
        private let titleID = NSToolbarItem.Identifier("WorkbenchTitle")
        private let actionsID = NSToolbarItem.Identifier("WorkbenchActions")
        private let leadingID = NSToolbarItem.Identifier("WorkbenchLeadingAlignment")
        private let trailingID = NSToolbarItem.Identifier("WorkbenchTrailingAlignment")
        private var leadingWidth: NSLayoutConstraint?
        private var trailingWidth: NSLayoutConstraint?

        init(_ view: WorkspaceSplitView) {
            sidebarHost = NSHostingController(rootView: WorkspaceFloatingPanelRoot(
                content: view.sidebar, locale: view.locale))
            contentHost = NSHostingController(rootView: WorkspaceLocalizedRoot(content: view.content, locale: view.locale))
            headerHost = NSHostingView(rootView: WorkspaceLocalizedRoot(content: view.header, locale: view.locale))
            actionsHost = NSHostingView(rootView: WorkspaceLocalizedRoot(content: view.actions, locale: view.locale))
            inspectorHost = view.inspector.map {
                NSHostingController(rootView: WorkspaceInspectorPanelRoot(content: $0, locale: view.locale))
            }
            locale = view.locale
            newConversation = view.newConversation
            canNavigate = view.canNavigate
            navigate = view.navigate
            super.init()
            sidebarHost.sizingOptions = []
            sidebarHost.safeAreaRegions = []
            contentHost.sizingOptions = []
            inspectorHost?.sizingOptions = []
            inspectorHost?.safeAreaRegions = []
            headerHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        func setInspectorVisible(_ visible: Bool) {
            controller?.setInspectorDesiredVisible(visible)
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [toggleID, leadingID, titleID, .flexibleSpace, actionsID, trailingID]
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar) + [composeID, backID, forwardID]
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let L = LocalizedUIStrings(locale: locale)
            if id == leadingID || id == trailingID {
                let item = NSToolbarItem(itemIdentifier: id)
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                let width = spacer.widthAnchor.constraint(equalToConstant: 1)
                NSLayoutConstraint.activate([width, spacer.heightAnchor.constraint(equalToConstant: 1)])
                item.view = spacer
                item.isBordered = false
                item.visibilityPriority = .high
                if id == leadingID { leadingWidth = width } else { trailingWidth = width }
                return item
            }
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
        /// Native toolbar spacing follows the mounted pane edges, including a
        /// resized sidebar and the inspector's reserved trailing lane.
        func alignToolbar(leading: CGFloat, trailing: CGFloat) {
            guard let controller, headerHost.window != nil, actionsHost.window != nil else { return }
            let titleX = headerHost.convert(headerHost.bounds, to: controller.view).minX
            let actionsX = actionsHost.convert(actionsHost.bounds, to: controller.view).maxX
            if let leadingWidth {
                let width = max(1, leadingWidth.constant + leading - titleX)
                if abs(width - leadingWidth.constant) > 0.5 { leadingWidth.constant = width }
            }
            if let trailingWidth {
                let width = max(1, trailingWidth.constant + actionsX - trailing)
                if abs(width - trailingWidth.constant) > 0.5 { trailingWidth.constant = width }
            }
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

/// The full-width canvas is transparent, so the window frame shows around the
/// conversation card. The card carries the content surface and its rounded edge.
final class WorkbenchDetailController: NSViewController {
    let content: NSViewController
    private var cardLeadingConstraint: NSLayoutConstraint?
    private var cardTrailingConstraint: NSLayoutConstraint?
    /// Sidebar avoidance; 0 while the sidebar is hidden or overlays the card.
    private(set) var contentLeadingInset: CGFloat = 0
    private(set) var contentTrailingInset: CGFloat = 0
    private(set) var cardView: NSView?

    init(content: NSViewController) {
        self.content = content
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
        WorkbenchPanelShadowView.install(behind: card, in: view)
        cardView = card
        let detail = content.view
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.clipsToBounds = true
        card.addSubview(detail)
        let inset = WorkspaceLayoutMetrics.frameInset
        let leading = card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset)
        let trailing = card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset)
        cardLeadingConstraint = leading
        cardTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor, constant: WorkspaceLayoutMetrics.contentTopInset),
            leading,
            trailing,
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset),
            detail.topAnchor.constraint(equalTo: card.topAnchor),
            detail.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    /// The same mounted card adapts to the two floating panels. In wide windows
    /// the frame material remains visible between every pair of rounded surfaces.
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
}

/// An opaque content surface inside the window frame. It clips its page to the
/// panel radius so scrolling content and terminals keep the rounded edge; the
/// hairline is drawn above the page.
private final class WorkbenchContentCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // AppKit keeps the layer's masking in step with this flag.
        clipsToBounds = true
        layer?.cornerRadius = WorkbenchTheme.Radius.panel
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkbenchTheme.contentBackgroundNS.cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(WorkbenchTheme.Stroke.hairline).cgColor
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
    @discardableResult static func install(behind panel: NSView, in parent: NSView) -> WorkbenchPanelShadowView {
        let shadow = WorkbenchPanelShadowView()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        shadow.wantsLayer = true
        shadow.clipsToBounds = false
        shadow.layer?.cornerRadius = WorkbenchTheme.Radius.panel
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
                effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.45 : 0.20)
            elevation.shadowBlurRadius = 18
            elevation.shadowOffset = NSSize(width: 0, height: -5)
            shadow = elevation
        }
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds,
            cornerWidth: WorkbenchTheme.Radius.panel, cornerHeight: WorkbenchTheme.Radius.panel, transform: nil)
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
    var alignToolbar: ((CGFloat, CGFloat) -> Void)?
    private var floatingSidebarController: NSViewController?
    private var floatingInspectorController: NSViewController?
    private weak var detailController: WorkbenchDetailController?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var inspectorWidthConstraint: NSLayoutConstraint?
    private var sidebarResizeHandle: WorkspaceSidebarResizeHandle?
    private var inspectorResizeHandle: WorkspaceSidebarResizeHandle?
    private var sidebarOverlayBackdrop: WorkbenchWindowBackdropView?
    private var inspectorShadowView: WorkbenchPanelShadowView?
    private var applyingLayout = false
    private(set) var isSidebarOverlayingContent = false
    private(set) var isInspectorOverlayingContent = false
    private(set) var floatingSidebarWidth: CGFloat
    private(set) var isFloatingSidebarVisible: Bool
    private(set) var floatingInspectorWidth: CGFloat
    private(set) var isFloatingInspectorVisible = false

    private(set) var frameMaterialView: NSVisualEffectView?
    var floatingSidebarView: NSView? { floatingSidebarController?.view }
    var floatingInspectorView: NSView? { floatingInspectorController?.view }
    var detailCanvasView: NSView? { detailController?.view }
    var detailCardView: NSView? { detailController?.cardView }
    var detailContentView: NSView? { detailController?.content.view }
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        splitView = NSSplitView()
        splitView.isVertical = true
        view = NSView()
        let backdrop = WorkbenchWindowBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        frameMaterialView = backdrop.materialView
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

    private func installFloatingPanel(_ panel: NSView, leading: Bool, width: CGFloat,
                                      handleAction: Selector) -> (NSLayoutConstraint, WorkspaceSidebarResizeHandle) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let widthConstraint = panel.widthAnchor.constraint(equalToConstant: width)
        let handle = WorkspaceSidebarResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: handleAction))
        view.addSubview(handle, positioned: .above, relativeTo: panel)
        let horizontal = leading
            ? panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: WorkspaceLayoutMetrics.sidebarInset)
            : panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -WorkspaceLayoutMetrics.sidebarInset)
        let handleHorizontal = leading
            ? handle.leadingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -5)
            : handle.trailingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 5)
        let bottom = leading
            ? panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -WorkspaceLayoutMetrics.sidebarInset)
            : panel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -WorkspaceLayoutMetrics.inspectorBottomInset)
        if !leading {
            let height = panel.heightAnchor.constraint(equalToConstant: WorkspaceLayoutMetrics.inspectorPreferredHeight)
            height.priority = .init(rawValue: 999)
            height.isActive = true
        }
        NSLayoutConstraint.activate([
            horizontal,
            panel.topAnchor.constraint(equalTo: view.topAnchor,
                                       constant: leading ? WorkspaceLayoutMetrics.sidebarInset : WorkspaceLayoutMetrics.inspectorTopInset),
            bottom,
            widthConstraint,
            handleHorizontal,
            handle.widthAnchor.constraint(equalToConstant: 10),
            handle.topAnchor.constraint(equalTo: panel.topAnchor),
            handle.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return (widthConstraint, handle)
    }

    func installFloatingSidebar(_ sidebar: NSViewController,
                                detailController: WorkbenchDetailController) {
        floatingSidebarController = sidebar
        self.detailController = detailController
        let (width, handle) = installFloatingPanel(sidebar.view, leading: true, width: floatingSidebarWidth,
                                                   handleAction: #selector(resizeSidebar(_:)))
        sidebarWidthConstraint = width
        sidebarResizeHandle = handle
        sidebar.view.isHidden = !isFloatingSidebarVisible
        handle.isHidden = !isFloatingSidebarVisible
        // Only narrow overlay mode needs its own backing, otherwise navigation
        // is drawn directly on the single window material.
        let overlay = WorkbenchWindowBackdropView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = WorkbenchTheme.Radius.panel
        overlay.clipsToBounds = true
        view.addSubview(overlay, positioned: .below, relativeTo: sidebar.view)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: sidebar.view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor),
        ])
        sidebarOverlayBackdrop = overlay
        updateWorkspaceLayout()
    }

    func installFloatingInspector(_ inspector: NSViewController, visible: Bool) {
        floatingInspectorController = inspector
        isFloatingInspectorVisible = visible
        let (width, handle) = installFloatingPanel(inspector.view, leading: false, width: floatingInspectorWidth,
                                                   handleAction: #selector(resizeInspector(_:)))
        inspectorWidthConstraint = width
        inspectorResizeHandle = handle
        inspector.view.isHidden = !visible
        handle.isHidden = !visible
        inspectorShadowView = WorkbenchPanelShadowView.install(behind: inspector.view, in: view)
        inspectorShadowView?.isHidden = !visible
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWorkspaceLayout()
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
        window.toolbarStyle = .unified
        window.toolbar = workspaceToolbar
        DispatchQueue.main.async { [weak self] in self?.updateWorkspaceLayout() }
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
        guard visible != isFloatingInspectorVisible else { return }
        isFloatingInspectorVisible = visible
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

        // The canvas and conversation host stay mounted. When there is room for
        // 600pt of content, the card yields to both panels so their rounded edges
        // sit on the frame material instead of disappearing into one white sheet.
        let availableWidth = view.bounds.width
        let avoidance = WorkspaceLayoutMetrics.sidebarInset + floatingSidebarWidth +
            WorkspaceLayoutMetrics.sidebarGap
        let avoidSidebar = isFloatingSidebarVisible &&
            availableWidth >= WorkspaceLayoutMetrics.contentMinimumWidth + avoidance +
                WorkspaceLayoutMetrics.frameInset - 0.5
        let leading = avoidSidebar ? avoidance : WorkspaceLayoutMetrics.frameInset
        let inspectorAvoidance = WorkspaceLayoutMetrics.sidebarInset + floatingInspectorWidth +
            WorkspaceLayoutMetrics.sidebarGap
        let avoidInspector = isFloatingInspectorVisible && availableWidth - leading - inspectorAvoidance >=
            WorkspaceLayoutMetrics.contentMinimumWidth - 0.5
        detailController?.setContentInsets(leading: avoidSidebar ? avoidance : 0,
                                          trailing: avoidInspector ? inspectorAvoidance : 0)
        isSidebarOverlayingContent = isFloatingSidebarVisible && !avoidSidebar
        sidebarOverlayBackdrop?.isHidden = !isSidebarOverlayingContent
        isInspectorOverlayingContent = isFloatingInspectorVisible && !avoidInspector
        floatingSidebarView?.isHidden = !isFloatingSidebarVisible
        sidebarResizeHandle?.isHidden = !isFloatingSidebarVisible
        floatingInspectorView?.isHidden = !isFloatingInspectorVisible
        inspectorShadowView?.isHidden = !isFloatingInspectorVisible
        inspectorResizeHandle?.isHidden = !isFloatingInspectorVisible
        if let card = detailCardView {
            let cardFrame = card.convert(card.bounds, to: view)
            let trailing = isInspectorOverlayingContent
                ? view.bounds.maxX - WorkspaceLayoutMetrics.sidebarInset - floatingInspectorWidth - WorkspaceLayoutMetrics.sidebarGap
                : cardFrame.maxX - WorkbenchTheme.Reading.inset
            alignToolbar?(cardFrame.minX + WorkbenchTheme.Reading.inset, trailing)
        }
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

/// The inspector is a card of the frame like the conversation: the same opaque
/// surface, radius and hairline, floating over the canvas' trailing lane.
struct WorkspaceInspectorPanelRoot<Content: View>: View {
    let content: Content
    let locale: Locale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.panel, style: .continuous)
        content
            .environment(\.locale, locale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchTheme.contentBackground)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(WorkbenchTheme.Stroke.hairline), lineWidth: 1))
    }
}

/// Each AppKit hosting root starts a new SwiftUI environment tree.
struct WorkspaceLocalizedRoot<Content: View>: View {
    let content: Content
    let locale: Locale
    var body: some View { content.environment(\.locale, locale) }
}
