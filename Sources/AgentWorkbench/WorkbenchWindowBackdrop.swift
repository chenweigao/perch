import AppKit

/// A single frosted window surface. A semantic neutral wash softens desktop
/// color without painting separate sidebar and titlebar surfaces.
final class WorkbenchWindowBackdropView: NSView {
    let materialView = NSVisualEffectView()
    private let neutralWash = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        materialView.material = .sidebar
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        neutralWash.wantsLayer = true
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

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            neutralWash.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
