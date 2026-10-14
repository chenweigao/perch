import AppKit
import SwiftUI
import SwiftMath
import WorkbenchCore

/// Display math ($$…$$) typeset natively by SwiftMath — no web view, no KaTeX.
/// The image renders once per (latex, mode, appearance) and is cached; the
/// reveal cursor treats the block as an atomic checkpoint.
struct ReplyMathBlock: View {
    let latex: String
    var body: some View {
        if let image = ReplyMathImage.image(latex: latex, size: 16, display: true) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        } else {
            // Unparseable TeX shows its source, never a blank hole.
            SelectableReplyText(latex, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
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

private enum ReplyMathImage {
    private struct Key: Hashable {
        let latex: String
        let size: CGFloat
        let display: Bool
        let dark: Bool
    }
    private static var cache: [Key: NSImage] = [:]
    private static var order: [Key] = []
    private static var failed: Set<String> = []

    static func image(latex: String, size: CGFloat, display: Bool) -> NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = Key(latex: latex, size: size, display: display, dark: dark)
        if let hit = cache[key] { return hit }
        if failed.contains(latex) { return nil }
        let math = MTMathImage(latex: latex, fontSize: size,
                               textColor: dark ? .white : .black,
                               labelMode: display ? .display : .text,
                               textAlignment: .left)
        let (error, image) = math.asImage()
        guard error == nil, let image else {
            failed.insert(latex)
            return nil
        }
        if order.count >= 128 { cache.removeValue(forKey: order.removeFirst()) }
        cache[key] = image
        order.append(key)
        return image
    }
}
