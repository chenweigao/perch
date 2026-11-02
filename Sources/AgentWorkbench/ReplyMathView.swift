import AppKit
import SwiftUI
import SwiftMath
import WorkbenchCore

/// Display math ($$…$$ / \[…\]) typeset natively by SwiftMath — no web view, no KaTeX.
/// Native images remain lazy and appearance-specific to preserve glyph pixels;
/// the reveal cursor treats the block as an atomic checkpoint.
struct ReplyMathBlock: View {
    let latex: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // Display math is set at the body size, as in typeset text, in the row's
        // color scheme rather than the app's appearance.
        if let image = ReplyMathImage.displayImage(latex: latex, size: ReplyStyle.bodySize,
                                                   dark: colorScheme == .dark) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
                .accessibilityLabel(latex)
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

enum ReplyMathImage {
    private struct Key: Hashable {
        let latex: String
        let size: CGFloat
        let display: Bool
        let appearance: Bool?
    }
    private struct Entry {
        let light: NSImage
        let dark: NSImage
        let adaptive: NSImage
        let costEstimate: Int
    }
    static let maxCachedEntries = 256
    static let maxInlineEntries = 128
    static let maxCachedBytes = 24 * 1024 * 1024
    static let maxFailedBytes = 64 * 1024
    private static var cache: [Key: Entry] = [:]
    private static var order: [Key] = []
    private static var inlineEntries = 0
    private static var cachedCostEstimate = 0
    private static var failed: Set<String> = []
    private static var failedOrder: [String] = []
    private static var failedBytes = 0

    static func image(latex: String, size: CGFloat, display: Bool) -> NSImage? {
        entry(latex: latex, size: size, display: display)?.adaptive
    }

    static func image(latex: String, size: CGFloat, display: Bool, dark: Bool) -> NSImage? {
        entry(latex: latex, size: size, display: display).map { dark ? $0.dark : $0.light }
    }

    static func displayImage(latex: String, size: CGFloat, dark: Bool) -> NSImage? {
        entry(latex: latex, size: size, display: true, appearance: dark).map { dark ? $0.dark : $0.light }
    }

    private static func entry(latex: String, size: CGFloat, display: Bool, appearance: Bool? = nil) -> Entry? {
        #if MATH_PERFORMANCE_CHECKS
        requests += 1
        #endif
        let key = Key(latex: latex, size: size, display: display, appearance: appearance)
        if let hit = cache[key] {
            #if MATH_PERFORMANCE_CHECKS
            hits += 1
            #endif
            return hit
        }
        if failed.contains(latex) { return nil }
        let sourceBytes = latex.utf8.count
        guard sourceBytes <= 100_000, size.isFinite, size > 0 else { return nil }
        let probe = PerfDiagnostics.begin()
        defer {
            PerfDiagnostics.end("math_typeset", probe,
                                detail: (display ? "mode=display" : "mode=inline") + " bytes=\(sourceBytes)")
        }
        let boxed = ReplyMath.boxedContent(latex)
        let content = boxed ?? latex
        let inks: [NSColor] = appearance.map { [$0 ? .white : .black] } ?? [.black, .white]
        var images: [NSImage] = []
        var estimate = sourceBytes
        for ink in inks {
            #if MATH_PERFORMANCE_CHECKS
            typesets += 1
            #endif
            let math = MTMathImage(latex: content, fontSize: size, textColor: ink,
                                   labelMode: display ? .display : .text, textAlignment: .left)
            let (error, source) = math.asImage()
            guard error == nil, let source else {
                rememberFailure(latex)
                return nil
            }
            let image: NSImage
            if boxed != nil {
                let inset: CGFloat = 4
                let imageSize = NSSize(width: source.size.width + 2 * inset, height: source.size.height + 2 * inset)
                image = NSImage(size: imageSize, flipped: false) { rect in
                    ink.setStroke()
                    let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                    border.lineWidth = 1
                    border.stroke()
                    source.draw(in: rect.insetBy(dx: inset, dy: inset))
                    return true
                }
            } else {
                image = source
            }
            images.append(image)
            let width = ceil(image.size.width * 2), height = ceil(image.size.height * 2)
            if width.isFinite, height.isFinite, width >= 0, height >= 0,
               width <= 8_192, height <= 8_192, width * height <= 4_000_000 {
                estimate += Int(width * height) * 4
            } else {
                estimate = maxCachedBytes + 1
            }
        }
        guard let light = images.first, let dark = images.last else { return nil }
        let adaptive = NSImage(size: light.size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
        // Admission estimates source and 2x raster capacity, not display-list memory or process RSS.
        let entry = Entry(light: light, dark: dark, adaptive: adaptive, costEstimate: estimate)
        if estimate <= maxCachedBytes {
            if appearance == nil {
                while inlineEntries >= maxInlineEntries,
                      let index = order.firstIndex(where: { $0.appearance == nil }) { removeEntry(at: index) }
            }
            while !order.isEmpty, order.count >= maxCachedEntries || cachedCostEstimate + estimate > maxCachedBytes {
                removeEntry(at: 0)
            }
            cache[key] = entry
            order.append(key)
            if appearance == nil { inlineEntries += 1 }
            cachedCostEstimate += estimate
        }
        return entry
    }

    private static func removeEntry(at index: Int) {
        let key = order.remove(at: index)
        guard let removed = cache.removeValue(forKey: key) else { return }
        if key.appearance == nil { inlineEntries -= 1 }
        cachedCostEstimate -= removed.costEstimate
    }

    #if MATH_PERFORMANCE_CHECKS
    static var drawingMetrics: [String: Double] { [:] }
    #endif

    private static func rememberFailure(_ latex: String) {
        let cost = latex.utf8.count
        guard cost <= maxFailedBytes else { return }
        while !failedOrder.isEmpty, failedOrder.count >= 128 || failedBytes + cost > maxFailedBytes {
            let removed = failedOrder.removeFirst()
            failed.remove(removed)
            failedBytes -= removed.utf8.count
        }
        failed.insert(latex)
        failedOrder.append(latex)
        failedBytes += cost
    }

    #if MATH_PERFORMANCE_CHECKS
    private static var typesets = 0
    private static var requests = 0
    private static var hits = 0
    static var metrics: [String: Int] {
        ["typesets": typesets, "requests": requests, "cache_hits": hits,
         "cost_estimate_bytes": cachedCostEstimate, "entries": cache.count, "inline_entries": inlineEntries,
         "failed_bytes": failedBytes, "failures": failed.count]
    }
    static func resetForChecks() {
        cache.removeAll()
        order.removeAll()
        inlineEntries = 0
        cachedCostEstimate = 0
        failed.removeAll()
        failedOrder.removeAll()
        failedBytes = 0
        typesets = 0
        requests = 0
        hits = 0
    }
    #endif
}
