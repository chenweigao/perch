import AppKit

/// A transient full-size preview for conversation attachments. The transcript
/// only keeps display-sized bitmaps; preview decodes from the fetched data.
@MainActor
enum ImagePreviewPanel {
    private static var panel: NSPanel?

    static func show(data: Data, name: String) {
        guard let image = NSImage(data: data) else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleNone
        let size = image.size
        imageView.frame = NSRect(origin: .zero, size: size)
        scroll.documentView = imageView
        panel.contentView = scroll
        panel.title = name
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let fit = NSSize(width: min(size.width, screen.width * 0.8), height: min(size.height, screen.height * 0.8))
        panel.setContentSize(fit)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 240)
        return panel
    }
}
