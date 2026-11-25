import Foundation

/// How wide the workspace window is, relative to what its panels need.
/// See docs/design/layout.md「宽度分档」.
public enum WorkspaceWidthClass: String, Sendable {
    /// Sidebar, reader and inspector all fit side by side.
    case wide
    /// Sidebar and reader fit side by side; with the inspector open the
    /// sidebar steps aside when the inspector alone still fits.
    case regular
    /// The reader does not fit beside the sidebar: the sidebar overlays it.
    case compact
}

/// Where the sidebar, reader and inspector go for one window width. Pure, so the
/// width classes can be checked without a window; `WorkbenchSplitController`
/// applies the result.
public struct WorkspaceWidthPlan: Equatable, Sendable {
    public struct Metrics: Equatable, Sendable {
        public var frameInset: Double
        public var sidebarGap: Double
        public var contentMinimum: Double
        public var inspectorReadingMinimum: Double
        public init(frameInset: Double, sidebarGap: Double, contentMinimum: Double, inspectorReadingMinimum: Double) {
            self.frameInset = frameInset
            self.sidebarGap = sidebarGap
            self.contentMinimum = contentMinimum
            self.inspectorReadingMinimum = inspectorReadingMinimum
        }
    }

    public let widthClass: WorkspaceWidthClass
    /// The sidebar is wanted but hidden so the inspector does not cover the reader.
    public let sidebarYields: Bool
    /// The reader asked for a yielding sidebar back; it then overlays the reader.
    public let revealedOverInspector: Bool
    public let sidebarShown: Bool
    /// The reader starts after the sidebar instead of under it.
    public let sidebarAvoided: Bool
    public let sidebarOverlaysContent: Bool
    /// The reader card's leading edge, from the window's leading edge.
    public let contentLeading: Double
    /// The inspector lane's width; 0 when it is closed.
    public let inspectorWidth: Double

    public static func resolve(availableWidth: Double, sidebarWidth: Double, inspectorWidth: Double,
                               sidebarVisible: Bool, inspectorVisible: Bool,
                               revealedOverInspector: Bool, metrics: Metrics) -> WorkspaceWidthPlan {
        let minimum = metrics.contentMinimum - 0.5
        let avoidance = metrics.frameInset + sidebarWidth + metrics.sidebarGap
        let inspectorAvoidance = metrics.frameInset + inspectorWidth
        let fitsSidebar = availableWidth - avoidance - metrics.frameInset >= minimum
        let fitsBoth = availableWidth - avoidance - inspectorAvoidance >= minimum
        let fitsInspectorAlone = availableWidth - metrics.frameInset - inspectorAvoidance >= minimum
        let bothOpen = sidebarVisible && inspectorVisible
        // A reveal only means something while the sidebar would otherwise yield.
        let revealed = revealedOverInspector && bothOpen && !fitsBoth
        // The reply keeps priority over navigation: rather than letting the
        // inspector cover it, the sidebar steps aside while the reader still fits.
        let yields = bothOpen && fitsSidebar && !fitsBoth && fitsInspectorAlone && !revealed
        let shown = sidebarVisible && !yields
        let avoided = shown && fitsSidebar
        let leading = avoided ? avoidance : metrics.frameInset
        let lane = inspectorVisible
            ? min(inspectorWidth, max(0, availableWidth - leading - metrics.frameInset - metrics.inspectorReadingMinimum))
            : 0
        return WorkspaceWidthPlan(
            widthClass: fitsBoth ? .wide : fitsSidebar ? .regular : .compact,
            sidebarYields: yields, revealedOverInspector: revealed, sidebarShown: shown,
            sidebarAvoided: avoided, sidebarOverlaysContent: shown && !avoided,
            contentLeading: leading, inspectorWidth: lane)
    }
}
