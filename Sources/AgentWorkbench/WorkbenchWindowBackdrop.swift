import AppKit

/// A single frosted window surface. A semantic neutral wash softens desktop
/// color without painting separate sidebar and titlebar surfaces.
final class WorkbenchWindowBackdropView: NSView {
    let materialView = NSVisualEffectView()
    private let neutralWash = NSView()
    private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        materialView.material = .underWindowBackground
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        neutralWash.wantsLayer = true
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
        for child in [materialView, neutralWash] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Keep the system blur but let the real window backdrop contribute more
        // than its default opaque tint. Respect Reduce Transparency immediately.
        materialView.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.78
        effectiveAppearance.performAsCurrentDrawingAppearance {
            neutralWash.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.02).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
