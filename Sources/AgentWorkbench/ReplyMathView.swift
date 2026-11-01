import AppKit
import SwiftUI
import SwiftMath
import WorkbenchCore

/// Display math ($$…$$ / \[…\]) typeset natively by SwiftMath — no web view, no KaTeX.
/// Single-color formulas share one typeset layout and cached light/dark pixels;
/// the reveal cursor treats the block as an atomic checkpoint.
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

enum ReplyMathImage {
    private struct Key: Hashable {
        let latex: String
        let size: CGFloat
        let display: Bool
    }
    private struct Entry {
        let light: NSImage
        let dark: NSImage
        let adaptive: NSImage
        let cost: Int
    }
    static let maxCachedBytes = 16 * 1024 * 1024
    static let maxFailedBytes = 64 * 1024
    private static var cache: [Key: Entry] = [:]
    private static var order: [Key] = []
    private static var cachedBytes = 0
    private static var failed: Set<String> = []
    private static var failedOrder: [String] = []
    private static var failedBytes = 0

    static func image(latex: String, size: CGFloat, display: Bool) -> NSImage? {
        entry(latex: latex, size: size, display: display)?.adaptive
    }

    static func image(latex: String, size: CGFloat, display: Bool, dark: Bool) -> NSImage? {
        entry(latex: latex, size: size, display: display).map { dark ? $0.dark : $0.light }
    }

    private static func entry(latex: String, size: CGFloat, display: Bool) -> Entry? {
        let key = Key(latex: latex, size: size, display: display)
        if let hit = cache[key] { return hit }
        if failed.contains(latex) { return nil }
        let sourceBytes = latex.utf8.count
        guard sourceBytes <= 100_000, size.isFinite, size > 0 else { return nil }
        let typesetProbe = PerfDiagnostics.begin()
        defer {
            PerfDiagnostics.end("math_typeset", typesetProbe,
                                detail: (display ? "mode=display" : "mode=inline") + " bytes=\(sourceBytes)")
        }
        let boxed = ReplyMath.boxedContent(latex)
        let content = boxed ?? latex
        func typeset(_ ink: NSColor) -> NSImage? {
            #if MATH_PERFORMANCE_CHECKS
            typesets += 1
            #endif
            let math = MTMathImage(latex: content, fontSize: size, textColor: ink,
                                   labelMode: display ? .display : .text, textAlignment: .left)
            let (error, image) = math.asImage()
            return error == nil ? image : nil
        }
        guard let source = typeset(.black) else {
            rememberFailure(latex)
            return nil
        }
        let inset: CGFloat = boxed == nil ? 0 : 4
        let logicalSize = NSSize(width: source.size.width + 2 * inset,
                                 height: source.size.height + 2 * inset)
        guard let lightRaster = rasterize(source, size: logicalSize, inset: inset, ink: .black) else { return nil }
        let colored = content.contains(#"\color"#) || content.contains(#"\textcolor"#)
        let darkRaster: (image: CGImage, cost: Int)?
        if colored {
            darkRaster = typeset(.white).flatMap { rasterize($0, size: logicalSize, inset: inset, ink: .white) }
        } else {
            darkRaster = whiteRaster(lightRaster.image)
        }
        guard let darkRaster else { return nil }
        let light = NSImage(cgImage: lightRaster.image, size: logicalSize)
        let dark = NSImage(cgImage: darkRaster.image, size: logicalSize)
        let adaptive = NSImage(size: logicalSize, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
        let entry = Entry(light: light, dark: dark, adaptive: adaptive,
                          cost: lightRaster.cost + darkRaster.cost + sourceBytes)
        if entry.cost <= maxCachedBytes {
            while !order.isEmpty, order.count >= 128 || cachedBytes + entry.cost > maxCachedBytes {
                if let removed = cache.removeValue(forKey: order.removeFirst()) { cachedBytes -= removed.cost }
            }
            cache[key] = entry
            order.append(key)
            cachedBytes += entry.cost
        }
        return entry
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 4_000_000 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func rasterize(_ image: NSImage, size: NSSize, inset: CGFloat,
                                  ink: NSColor) -> (image: CGImage, cost: Int)? {
        guard size.width.isFinite, size.height.isFinite, size.width <= 4_096, size.height <= 4_096,
              let context = bitmapContext(width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2))) else { return nil }
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = CGRect(origin: .zero, size: size)
        if inset > 0 {
            ink.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        image.draw(in: rect.insetBy(dx: inset, dy: inset))
        guard let pixels = context.makeImage() else { return nil }
        return (pixels, context.bytesPerRow * context.height)
    }

    private static func whiteRaster(_ image: CGImage) -> (image: CGImage, cost: Int)? {
        guard let context = bitmapContext(width: image.width, height: image.height),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * context.bytesPerRow + column * 4
                let alpha = data[offset + 3]
                data[offset] = alpha
                data[offset + 1] = alpha
                data[offset + 2] = alpha
            }
        }
        guard let pixels = context.makeImage() else { return nil }
        return (pixels, context.bytesPerRow * context.height)
    }

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
    static var metrics: [String: Int] {
        ["typesets": typesets, "cached_bytes": cachedBytes, "entries": cache.count,
         "failed_bytes": failedBytes, "failures": failed.count]
    }
    static func resetForChecks() {
        cache.removeAll()
        order.removeAll()
        cachedBytes = 0
        failed.removeAll()
        failedOrder.removeAll()
        failedBytes = 0
        typesets = 0
    }
    #endif
}
