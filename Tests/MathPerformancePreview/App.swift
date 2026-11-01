import AppKit
import CryptoKit
import Darwin
import SwiftMath
import SwiftUI
import WorkbenchCore

private enum MathBenchmarkError: Error {
    case invalid(String)
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw MathBenchmarkError.invalid(message) }
}

private func milliseconds(_ operation: () throws -> Void) rethrows -> Double {
    let start = CACurrentMediaTime()
    try operation()
    return (CACurrentMediaTime() - start) * 1_000
}

private func distribution(_ samples: [Double]) -> [String: Double] {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return [:] }
    return ["median_ms": sorted[sorted.count / 2],
            "p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "max_ms": sorted.last!, "total_ms": sorted.reduce(0, +)]
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private enum MathFixture {
    static func formula(_ index: Int) -> String {
        switch index % 4 {
        case 0: return #"\frac{x^2+"# + String(index + 1) + #"}{1+\sqrt{y^2+1}}"#
        case 1: return #"\sum_{i=1}^{n} a_i^2+"# + String(index)
        case 2: return #"\boxed{F(s)=c+\frac{s^2}{w}+"# + String(index) + "}"
        default: return #"P(s)=\begin{cases}s(s+1)/2,&s\le w\\w(w+1)/2+(s-w)w,&s>w\end{cases}+"# + String(index)
        }
    }
    static func reply(_ count: Int) -> String {
        let inline = (0..<7).map { #"参数 \(x_"# + String($0) + #"=8\) 与正文同排。"# }.joined(separator: "\n\n")
        let display = (0..<count).map { "## 计算步骤 \($0 + 1)\n\n\\[\n" + formula($0) + "\n\\]\n\n这里是独立的合成数学说明，没有模型或会话信息。" }.joined(separator: "\n\n")
        return inline + "\n\n" + display
    }
}

@MainActor
private func paintedPixels(_ image: NSImage, dark: Bool) throws -> NSBitmapImageRep {
    let width = Int(ceil(image.size.width * 2)), height = Int(ceil(image.size.height * 2))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw MathBenchmarkError.invalid("missing bitmap context")
    }
    context.scaleBy(x: 2, y: 2)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        image.draw(in: CGRect(origin: .zero, size: image.size))
    }
    guard let pixels = context.makeImage() else { throw MathBenchmarkError.invalid("empty bitmap") }
    return NSBitmapImageRep(cgImage: pixels)
}

private func paintedCount(_ bitmap: NSBitmapImageRep) -> Int {
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            if bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.1 { count += 1 }
        }
    }
    return count
}

private func mathSources(_ blocks: [ReplyBlock]) -> [String] {
    blocks.flatMap { block -> [String] in
        switch block {
        case .math(let latex): return [latex]
        case .paragraph(let runs), .heading(_, let runs): return runs.compactMap(\.math)
        case .quote(let inner), .alert(_, let inner): return mathSources(inner)
        case .list(let items): return items.flatMap { mathSources($0.blocks) }
        case .table(let headers, let rows, _): return (headers + rows.flatMap { $0 }).flatMap { $0.compactMap(\.math) }
        case .code, .rule: return []
        }
    }
}

@main
private struct MathPerformanceApp {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let count = Int(arguments[2]), count > 0 else { exit(2) }
        let mode = arguments[1]
        let output = URL(fileURLWithPath: arguments[3])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if mode == "window" {
            Task { @MainActor in
                do { try save(try await windowBenchmark(count), mode: mode, output: output) }
                catch { saveFailure(error, output: output); exit(1) }
                app.terminate(nil)
            }
            app.run()
        } else {
            do {
                let result: [String: Any]
                switch mode {
                case "parse": result = try parseBenchmark()
                case "typeset": result = try typesetBenchmark(count)
                case "contracts": result = try renderingContracts()
                default: throw MathBenchmarkError.invalid("unknown mode")
                }
                try save(result, mode: mode, output: output)
            } catch {
                saveFailure(error, output: output)
                exit(1)
            }
        }
    }

    @MainActor private static func save(_ measurements: [String: Any], mode: String, output: URL) throws {
        let metadata = Bundle.main.url(forResource: "build", withExtension: "json")!
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
        document["status"] = "passed"
        document["mode"] = mode
        document["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        document["cpu_count"] = ProcessInfo.processInfo.processorCount
        document["physical_memory_bytes"] = ProcessInfo.processInfo.physicalMemory
        document["scope"] = "isolated synthetic AppKit/SwiftUI work; not hardware input latency or certified FPS"
        document["measurements"] = measurements
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        print("PASS: \(mode)")
    }

    private static func saveFailure(_ error: Error, output: URL) {
        let document: [String: Any] = ["status": "failed", "error": String(describing: error)]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted]) {
            try? data.write(to: output, options: .atomic)
        }
        FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    }

    @MainActor private static func parseBenchmark() throws -> [String: Any] {
        let reply = MathFixture.reply(30)
        let plain = String(repeating: "普通中文与 English 文本。 ", count: 400)
        let escaped = String(repeating: #"普通 \path\value 文本。 "#, count: 400)
        var cases = [("reply", reply), ("plain", plain), ("ordinary_backslashes", escaped)]
        for count in [256, 1024, 4096] {
            cases.append(("unclosed_\(count)", String(repeating: #"\(x "#, count: count)))
        }
        var records: [String: Any] = [:]
        for (name, source) in cases {
            var samples: [Double] = []
            var blocks: [ReplyBlock] = []
            for _ in 0..<5 { samples.append(milliseconds { blocks = ReplyDocument.parse(source) }) }
            let math = mathSources(blocks)
            if name == "reply" { try require(math.count == 37, "synthetic reply lost formulas: \(math.count)") }
            if name.hasPrefix("unclosed") { try require(math.isEmpty, "unclosed delimiters became math") }
            let text = ReplyPlainText.render(blocks)
            records[name] = ["utf8_bytes": source.utf8.count, "duration": distribution(samples),
                             "semantic_sha256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()]
        }
        let units = Array(reply.utf16)
        for step in [16, 64] {
            var samples: [Double] = []
            for length in stride(from: step, to: units.count, by: step) {
                let prefix = String(decoding: units.prefix(length), as: UTF16.self)
                samples.append(milliseconds { _ = ReplyDocument.parse(prefix) })
            }
            records["stream_\(step)"] = ["updates": samples.count, "duration": distribution(samples)]
        }
        return records
    }

    @MainActor private static func typesetBenchmark(_ count: Int) throws -> [String: Any] {
        let formulas = (0..<count).map(MathFixture.formula)
        let before = residentBytes()
        var cold: [Double] = [], draws: [Double] = [], warm: [Double] = []
        for formula in formulas {
            try autoreleasepool {
                var image: NSImage?
                cold.append(milliseconds {
                    let attributed = ReplyMathAttachment.string(latex: formula, size: 16)
                    image = (attributed.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
                })
                try require(image != nil, "formula fell back to source")
                draws.append(try milliseconds {
                    _ = try paintedPixels(image!, dark: false)
                    _ = try paintedPixels(image!, dark: true)
                })
            }
        }
        let after = residentBytes()
        for formula in formulas.suffix(min(32, count)) {
            warm.append(milliseconds { _ = ReplyMathAttachment.string(latex: formula, size: 16) })
        }
        var result: [String: Any] = ["formula_count": count, "cold_attachment": distribution(cold),
                                   "first_light_dark_draw": distribution(draws), "warm_attachment": distribution(warm),
                                   "rss_before_bytes": before, "rss_after_bytes": after]
        #if MATH_PERFORMANCE_CHECKS
        result["cache"] = ReplyMathImage.metrics
        try require(ReplyMathImage.metrics["cached_bytes"]! <= ReplyMathImage.maxCachedBytes, "cache exceeded byte budget")
        #endif
        return result
    }

    @MainActor private static func renderingContracts() throws -> [String: Any] {
        var checks: [String] = []
        #if MATH_PERFORMANCE_CHECKS
        ReplyMathImage.resetForChecks()
        for latex in [#"x^2+\frac{1}{2}"#, #"\frac{a_i}{b_i}"#, #"\boxed{\frac{x}{y}}"#,
                      #"\color{#FF0000}{x}+y"#] {
            for size in [CGFloat(14), CGFloat(18)] {
                for dark in [false, true] {
                    guard let image = ReplyMathImage.image(latex: latex, size: size, display: false, dark: dark) else {
                        throw MathBenchmarkError.invalid("missing production math pixels")
                    }
                    let boxed = ReplyMath.boxedContent(latex)
                    let reference = MTMathImage(latex: boxed ?? latex, fontSize: size, textColor: dark ? .white : .black,
                                                labelMode: .text, textAlignment: .left)
                    let (error, expected) = reference.asImage()
                    try require(error == nil && expected != nil, "reference typesetter failed")
                    let inset: CGFloat = boxed == nil ? 0 : 4
                    try require(abs(image.size.width - expected!.size.width - 2 * inset) < 0.001 &&
                                abs(image.size.height - expected!.size.height - 2 * inset) < 0.001, "math geometry changed")
                    let pixels = try paintedPixels(image, dark: dark)
                    let painted = paintedCount(pixels)
                    try require(painted > 20, "blank production formula")
                    if boxed == nil {
                        let referencePixels = try paintedPixels(expected!, dark: dark)
                        let ratio = Double(painted) / Double(max(1, paintedCount(referencePixels)))
                        var difference = 0.0, weight = 0.0
                        for y in 0..<pixels.pixelsHigh {
                            for x in 0..<pixels.pixelsWide {
                                let actual = Double(pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                                let reference = Double(referencePixels.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                                difference += abs(actual - reference)
                                weight += reference
                            }
                        }
                        let deviation = difference / max(1, weight)
                        if deviation >= 0.2 || ratio <= 0.8 || ratio >= 1.2 {
                            let folder = URL(fileURLWithPath: CommandLine.arguments[3]).deletingLastPathComponent()
                            try pixels.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("actual-glyphs.png"))
                            try referencePixels.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("reference-glyphs.png"))
                            let diagnostic: [String: Any] = ["latex": latex, "size": Double(size), "dark": dark,
                                "coverage_ratio": ratio, "alpha_deviation": deviation,
                                "logical_width": Double(image.size.width), "logical_height": Double(image.size.height),
                                "width_pixels": pixels.pixelsWide, "height_pixels": pixels.pixelsHigh,
                                "drawing": ReplyMathImage.drawingMetrics]
                            try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted])
                                .write(to: folder.appendingPathComponent("glyph-difference.json"))
                        }
                        try require(ratio > 0.8 && ratio < 1.2, "formula pixel coverage changed: \(ratio)")
                        try require(deviation < 0.2, "formula glyph pixels displaced: \(deviation), size=\(size), dark=\(dark)")
                    }
                    if !latex.contains("color") {
                        var correctInk = 0
                        for y in 0..<pixels.pixelsHigh {
                            for x in 0..<pixels.pixelsWide {
                                if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 {
                                    if dark ? color.redComponent > 0.8 : color.redComponent < 0.2 { correctInk += 1 }
                                }
                            }
                        }
                        try require(correctInk > 10, "formula appearance ink is wrong")
                    }
                    if latex.contains("color") {
                        func redPixels(_ bitmap: NSBitmapImageRep) -> Int {
                            var red = 0
                            for y in 0..<bitmap.pixelsHigh {
                                for x in 0..<bitmap.pixelsWide {
                                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                       color.alphaComponent > 0.1, color.redComponent > color.greenComponent + 0.2,
                                       color.redComponent > color.blueComponent + 0.2 { red += 1 }
                                }
                            }
                            return red
                        }
                        let expectedRed = redPixels(try paintedPixels(expected!, dark: dark))
                        try require(expectedRed > 10, "invalid color fixture")
                        let red = redPixels(pixels)
                        let ratio = Double(red) / Double(expectedRed)
                        try require(red > 10 && ratio > 0.8 && ratio < 1.2, "explicit TeX color lost")
                    }
                }
            }
        }
        checks.append("nonblank light/dark, font-size geometry, boxed border dimensions and explicit TeX color")
        ReplyMathImage.resetForChecks()
        _ = ReplyMathImage.image(latex: #"x^2+\frac{1}{2}"#, size: 16, display: false, dark: false)
        _ = ReplyMathImage.image(latex: #"x^2+\frac{1}{2}"#, size: 16, display: false, dark: true)
        try require(ReplyMathImage.metrics["typesets"] == 1, "monochrome formula typeset more than once")
        checks.append("one monochrome typeset across appearance changes")
        for index in 0..<512 {
            _ = ReplyMathImage.image(latex: MathFixture.formula(index), size: 20, display: false, dark: false)
            _ = ReplyMathImage.image(latex: #"\invalidcommand"# + String(index) + String(repeating: "x", count: 600),
                                     size: 16, display: false, dark: false)
        }
        try require(ReplyMathImage.metrics["entries"]! <= 128 &&
                    ReplyMathImage.metrics["cached_bytes"]! <= ReplyMathImage.maxCachedBytes, "successful cache unbounded")
        try require(ReplyMathImage.metrics["failures"]! <= 128 &&
                    ReplyMathImage.metrics["failed_bytes"]! <= ReplyMathImage.maxFailedBytes, "negative cache unbounded")
        checks.append("successful and failed cache entry/byte budgets under churn")
        return ["checks": checks, "cache": ReplyMathImage.metrics]
        #else
        return ["checks": ["baseline renderer measured without candidate-only cache contracts"]]
        #endif
    }

    @MainActor private static func windowBenchmark(_ count: Int) async throws -> [String: Any] {
        let source = MathFixture.reply(count)
        try require(mathSources(ReplyDocument.parse(source)).count == count + 7, "window fixture lost formulas")
        let before = residentBytes()
        let start = CACurrentMediaTime()
        let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 800, height: 720),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 720))
        scroll.hasVerticalScroller = true
        let controller = NSHostingController(rootView: KimiMarkdown(text: source).preferredColorScheme(.light)
            .frame(width: 700, alignment: .leading).padding(24).fixedSize(horizontal: false, vertical: true))
        controller.sizingOptions = []
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: 748, height: 1)
        scroll.documentView = host
        window.contentView = scroll
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.frame.size.height = max(1, controller.sizeThatFits(in: CGSize(width: 748, height: CGFloat.greatestFiniteMagnitude)).height)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let firstDisplay = (CACurrentMediaTime() - start) * 1_000
        try require(host.frame.height > 720, "math document did not produce scrollable content")
        var samples: [Double] = [], gaps: [Double] = []
        var previous = CACurrentMediaTime()
        for step in 0..<80 {
            try await Task.sleep(for: .milliseconds(16))
            let now = CACurrentMediaTime()
            gaps.append((now - previous) * 1_000)
            let fraction = step < 40 ? Double(step) / 39 : Double(79 - step) / 39
            samples.append(milliseconds {
                let y = max(0, host.frame.height - scroll.contentView.bounds.height) * fraction
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
            })
            previous = now
        }
        let after = residentBytes()
        window.close()
        return ["display_formula_count": count, "inline_formula_count": 7,
                "initial_layout_display_ms": firstDisplay, "scroll_work": distribution(samples),
                "scheduled_tick_gap": distribution(gaps), "document_height_points": host.frame.height,
                "rss_before_bytes": before, "rss_after_bytes": after]
    }
}
