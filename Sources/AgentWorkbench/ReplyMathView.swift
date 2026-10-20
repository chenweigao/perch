import AppKit
import SwiftUI
import SwiftMath
import WorkbenchCore

/// Display math ($$…$$) typeset natively by SwiftMath — no web view, no KaTeX.
/// Each formula typesets once per (latex, size, mode), in light and dark ink, and
/// is cached; the reveal cursor treats the block as an atomic checkpoint.
struct ReplyMathBlock: View {
    let latex: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // Display math is set at the body size, as in typeset text, in the row's
        // color scheme rather than the app's appearance.
        if let image = ReplyMathImage.image(latex: latex, size: ReplyStyle.bodySize, display: true,
                                            dark: colorScheme == .dark) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            // Unparseable TeX shows its source, never a blank hole.
            SelectableReplyText(latex, font: .monospacedSystemFont(ofSize: ReplyStyle.codeSize, weight: .regular))
        }
    }
}

/// Inline math becomes a text attachment so it flows inside paragraphs.
enum ReplyMathAttachment {
    static func string(latex: String, size: CGFloat) -> NSAttributedString {
        guard let image = ReplyMathImage.image(latex: latex, size: size, display: false) else {
            return NSAttributedString(string: latex)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Baseline-align: sit the formula's optical middle on the x-height middle.
        let font = NSFont.systemFont(ofSize: size)
        let offset = -(image.size.height / 2) + font.xHeight / 2
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: offset), size: image.size)
        return NSAttributedString(attachment: attachment)
    }
}

/// Both inks typeset the same glyphs, so the light and dark renderings share one
/// size: native and SwiftUI rows measure the same formula in either appearance.
private enum ReplyMathImage {
    private struct Key: Hashable {
        let latex: String
        let size: CGFloat
        let display: Bool
    }
    private struct Entry {
        let light: NSImage
        let dark: NSImage
        /// Draws `light` or `dark` for the appearance it is drawn in.
        let adaptive: NSImage
    }
    private static var cache: [Key: Entry] = [:]
    private static var order: [Key] = []
    private static var failed: Set<String> = []

    /// For text attachments. TextKit draws an attachment in its text view's
    /// appearance, so inline math follows the row's appearance rather than the
    /// app's, and a cached attributed string stays right after either changes.
    static func image(latex: String, size: CGFloat, display: Bool) -> NSImage? {
        entry(latex: latex, size: size, display: display)?.adaptive
    }

    /// One appearance's rendering, for SwiftUI views that know their color scheme.
    static func image(latex: String, size: CGFloat, display: Bool, dark: Bool) -> NSImage? {
        entry(latex: latex, size: size, display: display).map { dark ? $0.dark : $0.light }
    }

    private static func entry(latex: String, size: CGFloat, display: Bool) -> Entry? {
        let key = Key(latex: latex, size: size, display: display)
        if let hit = cache[key] { return hit }
        if failed.contains(latex) { return nil }
        let typesetProbe = PerfDiagnostics.begin()
        defer {
            PerfDiagnostics.end("math_typeset", typesetProbe,
                                detail: (display ? "mode=display" : "mode=inline") + " bytes=\(latex.utf8.count)")
        }
        func typeset(_ ink: NSColor) -> NSImage? {
            let math = MTMathImage(latex: latex, fontSize: size, textColor: ink,
                                   labelMode: display ? .display : .text,
                                   textAlignment: .left)
            let (error, image) = math.asImage()
            return error == nil ? image : nil
        }
        guard let light = typeset(.black), let dark = typeset(.white) else {
            failed.insert(latex)
            return nil
        }
        let adaptive = NSImage(size: light.size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
        if order.count >= 128 { cache.removeValue(forKey: order.removeFirst()) }
        let entry = Entry(light: light, dark: dark, adaptive: adaptive)
        cache[key] = entry
        order.append(key)
        return entry
    }
}
