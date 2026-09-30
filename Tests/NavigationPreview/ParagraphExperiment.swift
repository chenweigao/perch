import AppKit
import SwiftUI
import QuartzCore

extension NavigationRunner {
    /// Compare mounted native glyph positions, links, copying and streaming identity.
    /// This is a renderer contract check, not a hardware scrolling measurement.
    func paragraphExperiment() async throws -> [String: Any] {
        let source = """
        ## Heading marker

        Alpha 中文 **bold** *italic* ~~strike~~ `inline` [link](https://example.com/path).

        Beta 👩🏽‍💻 é paragraph with a hard break.\u{20}\u{20}
        HardLine preserves its line without adding paragraph spacing.

        Gamma /tmp/paragraph-fixture.swift and mixed English 中文文本。

        > QuoteAlpha normal paragraph.
        >
        > QuoteBeta compact paragraph.

        - ListAlpha first paragraph.

          ListBeta compact paragraph.

        ```swift
        let boundary = "CodeMarker"
        ```

        AfterCode final paragraph.

        ![](https://example.com/empty-alt.png)

        AfterEmpty paragraph.

        `CodeOnlyMarker`

        AfterInlineCode paragraph.
        """
        let markers = ["Heading marker", "Alpha", "Beta", "HardLine", "Gamma", "QuoteAlpha", "QuoteBeta", "ListAlpha", "ListBeta", "CodeMarker", "AfterCode", "AfterEmpty", "CodeOnlyMarker", "AfterInlineCode"]
        func texts(_ view: NSView) -> [ReplyTextView] {
            (view as? ReplyTextView).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        func settle(_ host: NSView) async throws {
            for _ in 0..<8 {
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            }
        }
        var samples: [[String: Any]] = []
        for width in [CGFloat(700), 340] {
            var positions: [[String: CGFloat]] = []
            for grouped in [false, true] {
                let host = NSHostingView(rootView: KimiMarkdown(text: source, coalescesParagraphs: grouped).frame(width: width))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1300), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                defer { window.close() }
                try await settle(host)
                let views = texts(host)
                var glyphs: [String: CGFloat] = [:]
                for marker in markers {
                    guard let view = views.first(where: { $0.string.contains(marker) }),
                          let manager = view.layoutManager, let container = view.textContainer else { throw NavigationError("Missing paragraph marker: \(marker)") }
                    let chars = (view.string as NSString).range(of: marker)
                    let range = manager.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
                    let rect = view.convert(manager.boundingRect(forGlyphRange: range, in: container), to: host)
                    glyphs[marker] = rect.minY
                }
                guard let origin = glyphs[markers[0]] else { throw NavigationError("Missing paragraph origin") }
                glyphs = glyphs.mapValues { $0 - origin }
                positions.append(glyphs)
                guard let linkView = views.first(where: { $0.string.contains("Alpha") }), let storage = linkView.textStorage else { throw NavigationError("Missing link view") }
                let linkRange = (linkView.string as NSString).range(of: "link")
                guard (storage.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/path" else { throw NavigationError("Grouped paragraph lost link") }
                if grouped {
                    guard let view = views.first(where: { $0.string.contains("Alpha") && $0.string.contains("Gamma") }) else { throw NavigationError("Adjacent paragraphs were not coalesced") }
                    window.makeFirstResponder(view)
                    let copyRange = NSRange(location: 0, length: (view.string as NSString).length)
                    view.setSelectedRange(copyRange)
                    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                    let types = view.writablePasteboardTypes
                    guard let type = types.first(where: { $0 == .string || $0.rawValue == "NSStringPboardType" }),
                          view.writeSelection(to: board, types: types), board.string(forType: type) == view.string else { throw NavigationError("Cross-paragraph Unicode copy failed") }
                }
                samples.append(["width": width, "grouped": grouped, "native_text_views": views.count, "host_width": host.bounds.width, "text_widths": views.map { $0.bounds.width },
                                "native_content_bottom": glyphs["AfterCode"]!, "glyph_y": glyphs, "links": true, "unicode_copy": grouped])
            }
            let deltas = Dictionary(uniqueKeysWithValues: markers.map { ($0, abs(positions[0][$0]! - positions[1][$0]!)) })
            // Preserve the detailed observation even when a candidate fails visual parity.
            samples.append(["width": width, "glyph_deltas": deltas, "max_glyph_delta": deltas.values.max() ?? 0])
            guard (deltas.values.max() ?? 0) <= 2 else { throw NavigationError("Paragraph glyph positions drifted beyond rounding tolerance") }
        }
        let prefix = "First paragraph 中文 👩🏽‍💻"
        let host = NSHostingView(rootView: KimiMarkdown(text: prefix, coalescesParagraphs: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await settle(host)
        guard let text = texts(host).first else { throw NavigationError("Missing streaming paragraph") }
        window.makeFirstResponder(text)
        let selection = (text.string as NSString).range(of: "中文 👩🏽‍💻")
        text.setSelectedRange(selection)
        host.rootView = KimiMarkdown(text: prefix + "\n\nSecond paragraph", coalescesParagraphs: true)
        try await settle(host)
        let stableIdentity = texts(host).contains { $0 === text && $0.string.contains("Second paragraph") }
        let stableSelection = text.selectedRange() == selection
        guard stableIdentity, stableSelection else { throw NavigationError("Streaming coalesced text lost identity or selection") }
        host.rootView = KimiMarkdown(text: "Replacement", coalescesParagraphs: true)
        try await settle(host)
        guard texts(host).contains(where: { $0.string == "Replacement" }), !texts(host).contains(where: { $0.string.contains(prefix) }) else { throw NavigationError("Replacement retained stale paragraph") }
        var streaming: [[String: Any]] = []
        let longSource = (0..<128).map { "Paragraph \($0) 中文 👩🏽‍💻 é and enough prose to wrap in a narrow column." }.joined(separator: "\n\n")
        for grouped in [false, true] {
            let root = NSHostingView(rootView: KimiMarkdown(text: longSource, coalescesParagraphs: grouped).frame(width: 500))
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = root; panel.orderFront(nil)
            defer { panel.close() }
            try await settle(root)
            let initialViews = texts(root)
            guard initialViews.count == (grouped ? 16 : 128) else { throw NavigationError("Paragraph group budget did not bind") }
            let initialIDs = initialViews.map(ObjectIdentifier.init)
            var elapsed: [Double] = []
            NavigationRenderMetrics.stages.removeAll()
            for tick in 1...40 {
                let start = CACurrentMediaTime()
                root.rootView = KimiMarkdown(text: longSource + String(repeating: " tail", count: tick), coalescesParagraphs: grouped).frame(width: 500)
                try await settle(root)
                elapsed.append((CACurrentMediaTime() - start) * 1000)
                guard texts(root).map(ObjectIdentifier.init) == initialIDs,
                      texts(root).contains(where: { $0.string.hasSuffix(String(repeating: " tail", count: tick)) }) else { throw NavigationError("Streaming recreated a completed paragraph group or missed update") }
            }
            elapsed.sort()
            streaming.append(["grouped": grouped, "paragraphs": 128, "native_text_views": initialViews.count,
                              "median_ms": elapsed[elapsed.count / 2], "p95_ms": elapsed[Int(Double(elapsed.count - 1) * 0.95)],
                              "render_stages": NavigationRenderMetrics.report, "identity_preserved": true])
        }
        return ["streaming_samples": streaming, "paragraph_samples": samples, "streaming_identity": stableIdentity, "streaming_selection": stableSelection,
                "replacement": true]
    }
}
