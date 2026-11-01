import AppKit
import SwiftUI
import SwiftMath
import WorkbenchCore

/// Display math ($$…$$ / \[…\]) typeset natively by SwiftMath — no web view, no KaTeX.
/// Native light/dark coverage is cached independently to preserve glyph pixels;
/// the reveal cursor treats the block as an atomic checkpoint.
struct ReplyMathBlock: View {
    let latex: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // Display math is set at the body size, as in typeset text, in the row's
        // color scheme rather than the app's appearance.
        if let raster = ReplyMathImage.raster(latex: latex, size: ReplyStyle.bodySize, display: true,
                                              dark: colorScheme == .dark) {
            Image(decorative: raster.pixels, scale: 2, orientation: .up)
                .frame(width: raster.size.width, height: raster.size.height, alignment: .bottomLeading)
                .clipped()
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
        let lightPixels: CGImage
        let darkPixels: CGImage
        let size: NSSize
        let cost: Int
    }
    static let maxCachedEntries = 256
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

    static func raster(latex: String, size: CGFloat, display: Bool, dark: Bool) -> (pixels: CGImage, size: NSSize)? {
        entry(latex: latex, size: size, display: display, appearance: dark).map { (dark ? $0.darkPixels : $0.lightPixels, $0.size) }
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
        let inks: [NSColor] = appearance.map { [$0 ? .white : .black] } ?? [.black, .white]
        let inset: CGFloat = boxed == nil ? 0 : 4
        let colored = content.contains(#"\color"#) || content.contains(#"\textcolor"#)
        var logicalSize = NSSize.zero
        var rasters: [(image: CGImage, cost: Int)] = []
        for ink in inks {
            guard let source = typeset(ink) else {
                rememberFailure(latex)
                return nil
            }
            if rasters.isEmpty {
                logicalSize = NSSize(width: source.size.width + 2 * inset, height: source.size.height + 2 * inset)
            }
            guard let bitmap = rasterize(source, size: logicalSize, inset: inset, ink: ink) else { return nil }
            if colored {
                rasters.append(bitmap)
            } else {
                guard let compact = grayAlpha(bitmap.image) else { return nil }
                rasters.append(compact)
            }
        }
        guard let first = rasters.first, let last = rasters.last else { return nil }
        let lightPixels = first.image
        let darkPixels = last.image
        let pixelCost = rasters.reduce(0) { $0 + $1.cost }
        let light = pixelImage(lightPixels, size: logicalSize)
        let dark = pixelImage(darkPixels, size: logicalSize)
        let adaptive = NSImage(size: logicalSize, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect)
            return true
        }
        adaptive.cacheMode = .never
        let entry = Entry(light: light, dark: dark, adaptive: adaptive, lightPixels: lightPixels,
                          darkPixels: darkPixels, size: logicalSize, cost: pixelCost + sourceBytes)
        if entry.cost <= maxCachedBytes {
            while !order.isEmpty, order.count >= maxCachedEntries || cachedBytes + entry.cost > maxCachedBytes {
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

    private static func grayAlpha(_ image: CGImage) -> (image: CGImage, cost: Int)? {
        guard image.bitsPerPixel == 32, image.alphaInfo == .premultipliedLast,
              let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.bytesPerRow * image.height else { return nil }
        var gray = [UInt8](repeating: 0, count: image.width * image.height * 2)
        for row in 0..<image.height {
            for column in 0..<image.width {
                let input = row * image.bytesPerRow + column * 4
                let output = (row * image.width + column) * 2
                gray[output] = pixels[input]
                gray[output + 1] = pixels[input + 3]
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let compact = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                                    bitsPerPixel: 16, bytesPerRow: image.width * 2,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else { return nil }
        return (compact, gray.count)
    }

    private static func pixelRect(_ rect: CGRect, image: CGImage, size: NSSize) -> CGRect {
        CGRect(origin: rect.origin,
               size: CGSize(width: rect.width * CGFloat(image.width) / (size.width * 2),
                            height: rect.height * CGFloat(image.height) / (size.height * 2)))
    }

    private static func pixelImage(_ pixels: CGImage, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            #if MATH_PERFORMANCE_CHECKS
            lastDrawing = (rect, context.ctm)
            #endif
            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: rect)
            context.draw(pixels, in: pixelRect(rect, image: pixels, size: size))
            return true
        }
        image.cacheMode = .never
        return image
    }

    #if MATH_PERFORMANCE_CHECKS
    private static var lastDrawing: (rect: CGRect, transform: CGAffineTransform)?
    static var drawingMetrics: [String: Double] {
        guard let drawing = lastDrawing else { return [:] }
        return ["rect_width": Double(drawing.rect.width), "rect_height": Double(drawing.rect.height),
                "rect_x": Double(drawing.rect.minX), "rect_y": Double(drawing.rect.minY),
                "transform_a": Double(drawing.transform.a), "transform_d": Double(drawing.transform.d),
                "transform_tx": Double(drawing.transform.tx), "transform_ty": Double(drawing.transform.ty)]
    }
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
         "cached_bytes": cachedBytes, "entries": cache.count,
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
        requests = 0
        hits = 0
        lastDrawing = nil
    }
    #endif
}
