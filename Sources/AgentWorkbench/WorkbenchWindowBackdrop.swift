import AppKit
import SwiftUI

/// The window's one translucent surface: system Liquid Glass over a non-opaque
/// window, so the blurred desktop tints the frame, navigation and toolbar while
/// the cards above stay opaque. At night the glass floats on `glassUnderlay`, a
/// mostly opaque blue-graphite base that keeps its luminance in the canvas's
/// family instead of the wallpaper's. Panels that float over content reuse it
/// with their own radius. Reduce Transparency swaps the glass for the window color.
final class WorkbenchWindowBackdropView: NSView {
    /// `nil` follows the window's corner, so the glass rim meets the window edge.
    /// Floating panels set their concentric radius as the window corner changes.
    var fixedCornerRadius: CGFloat? {
        didSet { if fixedCornerRadius != oldValue { updateCornerRadius() } }
    }
    private let outline = WorkbenchBackdropOutline()

    /// `outlined` draws a hairline on the glass rim, for a panel that floats over
    /// an opaque card where the glass alone would not show an edge.
    init(cornerRadius: CGFloat? = nil, outlined: Bool = false) {
        fixedCornerRadius = cornerRadius
        super.init(frame: .zero)
        outline.cornerRadius = cornerRadius ?? 0
        outline.outlined = outlined
        let host = NSHostingView(rootView: WorkbenchBackdropGlass(outline: outline))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var glassCornerRadius: CGFloat { outline.cornerRadius }

    /// Decorative only: clicks belong to the panels above it or to the window.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCornerRadius()
    }

    override func layout() {
        super.layout()
        // Entering or leaving full screen changes the window's corner.
        updateCornerRadius()
    }

    /// Also called when the window's chrome changes without resizing this view,
    /// such as installing the toolbar.
    func updateCornerRadius() {
        let radius = fixedCornerRadius ?? window.map(Self.windowCornerRadius(of:)) ?? 0
        if abs(outline.cornerRadius - radius) > 0.25 { outline.cornerRadius = radius }
    }

    /// AppKit publishes no window-corner API; Ghostty's glass background reads the
    /// same key. Unknown releases fall back to square glass, which the window clips.
    static func windowCornerRadius(of window: NSWindow) -> CGFloat {
        guard !window.styleMask.contains(.fullScreen),
              window.responds(to: Selector(("_cornerRadius"))) else { return 0 }
        return window.value(forKey: "_cornerRadius") as? CGFloat ?? 0
    }
}

/// Square until the window reports its corner.
@Observable private final class WorkbenchBackdropOutline {
    var cornerRadius = CGFloat.zero
    var outlined = false
}

private struct WorkbenchBackdropGlass: View {
    let outline: WorkbenchBackdropOutline
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: outline.cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                // The night underlay sits beneath the glass, which blurs it into
                // the desktop's contribution; in light it is clear and the glass
                // keeps its pure desktop tint.
                ZStack {
                    shape.fill(WorkbenchTheme.glassUnderlay)
                    Color.clear.glassEffect(.regular, in: shape)
                }
            }
        }
        .overlay {
            if outline.outlined {
                shape.strokeBorder(WorkbenchTheme.Stroke.hairline, lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }
}
