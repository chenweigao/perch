import AppKit
import SwiftUI
import QuartzCore
import WorkbenchCore

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

extension NavigationRunner {
    /// Compare native rows with the SwiftUI layout using actual glyphs and selection.
    func nativeUserRows(assistant: Bool = false) async throws -> [String: Any] {
        func texts(_ view: NSView) -> [ReplyTextView] {
            (view as? ReplyTextView).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        let role = assistant ? "assistant" : "user"
        let cases = [
            ("短问题 中文 👩🏽‍💻", ["短问题"]),
            ("Alpha **bold** *italic* ~~strike~~ `inline` [link](https://example.com/path).\n\nBeta 中文 👩🏽‍💻 é.  \nHardLine 保持换行。\n\nGamma /tmp/fixture.swift:42 结尾。", ["Alpha", "Beta", "HardLine", "Gamma"]),
            ((0..<12).map { "段落编号\($0)结束：中英文 mixed wrapping " + String(repeating: "较长的文本。", count: 8) }.joined(separator: "\n\n"), (0..<12).map { "段落编号\($0)结束" }),
            ("LongStart " + String(repeating: "English 中文 👩🏽‍💻 é line wrapping. ", count: 80) + " LongEnd", ["LongStart", "LongEnd"])
        ]
        var observations: [[String: Any]] = []
        for width in [CGFloat(700), 340] {
            for dark in [false, true] {
                for (source, markers) in cases {
                    let raw: [String: Any] = ["id": "native-row-parity", "role": role, "created_at": "fixture",
                        "content": [["type": "text", "text": source]]]
                    let message = try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: raw))
                    let original = NSHostingController(rootView: VStack(alignment: .leading, spacing: 12) {
                        KimiMessageView(message: message, tools: [:], api: nil, sessionId: "parity")
                        if assistant { ReplyCopyButton(text: source) }
                    }.frame(width: width).environment(\.colorScheme, dark ? .dark : .light))
                    original.sizingOptions = []; original.safeAreaRegions = []
                    guard let attributed = NativeParagraphContent.make(source) else { throw NavigationError("Native \(role) fixture rejected prose") }
                    let userView = assistant ? nil : NativeUserMessageView.acquire()
                    let assistantView = assistant ? NativeAssistantMessageView.acquire() : nil
                    userView?.update(attributed, dark: dark)
                    assistantView?.update(attributed, source: source, dark: dark)
                    let native: NSView = assistant ? assistantView! : userView!
                    defer {
                        if let userView { NativeUserMessageView.recycle(userView) }
                        if let assistantView { NativeAssistantMessageView.recycle(assistantView) }
                    }
                    var glyphs: [[String: CGPoint]] = [], heights: [CGFloat] = []
                    for isNative in [false, true] {
                        let view: NSView = isNative ? native : original.view
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = view; window.orderFront(nil)
                        defer { window.close() }
                        let size = isNative ? (assistantView?.measure(width: width) ?? userView!.measure(width: width)) : original.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                        window.setContentSize(size)
                        if isNative { userView?.place(width: width); assistantView?.place(width: width) }
                        for _ in 0..<5 {
                            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                            view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
                        }
                        heights.append(size.height)
                        var positions: [String: CGPoint] = [:]
                        for marker in markers {
                            guard let text = texts(view).first(where: { $0.string.contains(marker) }), let manager = text.layoutManager, let container = text.textContainer else { throw NavigationError("Native \(role) lost marker: \(marker)") }
                            let range = manager.glyphRange(forCharacterRange: (text.string as NSString).range(of: marker), actualCharacterRange: nil)
                            positions[marker] = text.convert(manager.boundingRect(forGlyphRange: range, in: container), to: view).origin
                        }
                        glyphs.append(positions)
                        if source.contains("Alpha"), let text = texts(view).first(where: { $0.string.contains("Alpha") && $0.string.contains("Gamma") }) {
                            let link = (text.string as NSString).range(of: "link")
                            let file = (text.string as NSString).range(of: "/tmp/fixture.swift:42")
                            guard (text.textStorage?.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com/path",
                                  (text.textStorage?.attribute(.link, at: file.location, effectiveRange: nil) as? URL)?.scheme == "perch-file" else { throw NavigationError("Native \(role) lost link") }
                            text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
                            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                            guard let type = text.writablePasteboardTypes.first(where: { $0 == .string || $0.rawValue == "NSStringPboardType" }), text.writeSelection(to: board, types: [type]), board.string(forType: type) == text.string else { throw NavigationError("Native \(role) Unicode copy failed") }
                        }
                    }
                    let drift = markers.map { max(abs(glyphs[0][$0]!.x - glyphs[1][$0]!.x), abs(glyphs[0][$0]!.y - glyphs[1][$0]!.y)) }.max() ?? 0
                    observations.append(["width": width, "dark": dark, "paragraphs": attributed.count, "heights": heights, "max_glyph_drift": drift])
                    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NAVIGATION_RESULTS"]!)
                    try JSONSerialization.data(withJSONObject: ["cases": observations], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-\(role)-parity.json"))
                    guard abs(heights[0] - heights[1]) <= 1, drift <= 1 else { throw NavigationError("Native \(role) layout differs from SwiftUI: heights \(heights), drift \(drift)") }
                }
            }
        }
        guard NativeParagraphContent.make("# Heading") == nil, NativeParagraphContent.make("```swift\nlet a = 1\n```") == nil else { throw NavigationError("Complex content did not keep its existing renderer") }
        return ["cases": observations, "complex_markdown_retains_swiftui": true, "links_and_unicode_copy": true]
    }

    func nativeAssistantContracts() async throws -> [String: Any] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func buttonImage(_ view: NSView) throws -> Data {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NavigationError("Cannot capture copy feedback") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NavigationError("Cannot encode copy feedback") }
            return data
        }
        func message(_ source: String, role: String = "assistant", metadata: [String: Any]? = nil) throws -> KimiMessage {
            var raw: [String: Any] = ["id": "assistant-contract", "role": role, "created_at": "fixture",
                                     "content": [["type": "text", "text": source]]]
            if let metadata { raw["metadata"] = metadata }
            return try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        let session = "native-assistant-contract"
        func root(_ messages: [KimiMessage], running: Bool = false, rtl: Bool = false) -> some View {
            ConversationTranscript(messages: messages, sessionId: session, isRunning: running)
                .frame(width: 500).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .environment(\.colorScheme, .light)
        }
        let source = "Alpha **bold** 中文 👩🏽‍💻\n\nBeta https://example.com /tmp/fixture.swift:42"
        let host = NSHostingView(rootView: root([try message(source)]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(2))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            }
        }
        func nativeRows() -> [NativeAssistantMessageView] { descendants(host).compactMap { $0 as? NativeAssistantMessageView } }
        func textViews() -> [ReplyTextView] { descendants(host).compactMap { $0 as? ReplyTextView } }
        try await settle()
        guard let initial = nativeRows().first, nativeRows().count == 1,
              let row = initial.superview, let text = textViews().first else { throw NavigationError("Completed assistant did not enter native row path") }
        let selection = (text.string as NSString).range(of: "中文 👩🏽‍💻")
        text.setSelectedRange(selection)
        host.rootView = root([try message(source + " appended")])
        try await settle()
        guard nativeRows().first === initial, initial.superview === row, text.selectedRange() == selection else { throw NavigationError("Assistant append lost row identity or selection") }
        host.rootView = root([try message("Replacement")])
        try await settle()
        guard nativeRows().first === initial, textViews().map(\.string) == ["Replacement"], textViews().allSatisfy({ $0.selectedRange().length == 0 }) else { throw NavigationError("Assistant replacement retained outgoing text or selection") }
        host.rootView = root([try message(source)], running: true)
        try await settle()
        let live = ConversationPresentationModel(key: session).update(.init(messages: [try message(source)], isRunning: true, language: "en"))
        guard live.rows.first?.entry.presentation == .progress, live.displayedRows(activity: { _ in nil }).isEmpty,
              live.narrative.current?.source == .commentary, nativeRows().isEmpty, textViews().isEmpty else {
            throw NavigationError("Live commentary did not retain its existing activity-bar projection")
        }
        host.rootView = root([try message(source)])
        try await settle()
        guard nativeRows().count == 1, let completedRow = nativeRows()[0].superview,
              completedRow.identifier == row.identifier else { throw NavigationError("Completed stream failed to restore its row identity") }
        for complex in ["# Heading", "```swift\nlet fallbackMarker = 1\n```", "- List item", "> Quote", "| A | B |\n| --- | --- |\n| 1 | 2 |", "![](https://example.com/alt.png)"] {
            host.rootView = root([try message(complex)])
            try await settle()
            guard nativeRows().isEmpty, descendants(host).contains(where: { $0 === completedRow }) else { throw NavigationError("Complex assistant lost its existing renderer or outer row: \(complex)") }
        }
        host.rootView = root([try message(source)], rtl: true)
        try await settle()
        guard nativeRows().isEmpty else { throw NavigationError("RTL assistant used LTR native layout") }
        host.rootView = root([try message(source)])
        try await settle()
        guard let restored = nativeRows().first, restored.superview === completedRow else { throw NavigationError("Plain assistant failed to return to native row") }
        guard let actions = restored.subviews.first(where: { !($0 is ReplyTextView) }),
              actions.frame.width == 24, actions.frame.height == 24 else { throw NavigationError("Assistant copy button lost its hit target") }
        window.makeKeyAndOrderFront(nil)
        try await settle()
        func clickCopy() throws {
            let location = actions.convert(NSPoint(x: 12, y: 12), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw NavigationError("Cannot create copy-button mouse events") }
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
        }
        let board = NSPasteboard.general
        let savedItems = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        var ownChange = board.changeCount
        defer { if board.changeCount == ownChange { board.clearContents(); board.writeObjects(savedItems) } }
        let idleImage = try buttonImage(actions)
        try clickCopy()
        try await settle()
        ownChange = board.changeCount
        guard board.string(forType: .string) == source else { throw NavigationError("Assistant copy button did not copy full Markdown source") }
        let copiedImage = try buttonImage(actions)
        guard copiedImage != idleImage else { throw NavigationError("Assistant copy feedback did not render") }
        host.rootView = root([try message("Different reply")])
        try await settle()
        guard try buttonImage(actions) == idleImage else { throw NavigationError("Assistant replacement retained copied feedback") }
        try clickCopy()
        try await settle()
        ownChange = board.changeCount
        guard board.string(forType: .string) == "Different reply" else { throw NavigationError("Assistant copy action retained previous reply") }
        for excluded in [try message(source, metadata: ["origin": ["kind": "compaction_summary"]]),
                         try message("<system-reminder>Runtime</system-reminder>"),
                         try message("Skill summary\n<skill-loaded trigger=\"user-slash\">Context</skill-loaded>")] {
            host.rootView = root([excluded])
            try await settle()
            guard nativeRows().isEmpty else { throw NavigationError("Summary or runtime context entered plain assistant renderer") }
        }
        host.rootView = root([])
        try await settle()
        let giant = (0..<80).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        guard let content = NativeParagraphContent.make(giant) else { throw NavigationError("Pool fixture is not prose") }
        var held: [NativeAssistantMessageView] = []
        for _ in 0..<20 {
            let view = NativeAssistantMessageView.acquire()
            view.update(content, source: giant, dark: false)
            guard let first = descendants(view).compactMap({ $0 as? ReplyTextView }).first else { throw NavigationError("Pool row missing text") }
            first.setSelectedRange(NSRange(location: 0, length: 3))
            held.append(view)
        }
        for view in held { NativeAssistantMessageView.recycle(view) }
        held.removeAll()
        let pool = NativeAssistantMessageView.poolState
        guard pool["rows"] as? Int == 16, pool["texts"] as? Int == 8, pool["cleared"] as? Bool == true else { throw NavigationError("Assistant row pool exceeded its budget or kept private state") }
        return ["production_lifecycle": true, "streaming_retains_swiftui": true, "same_id_shape_changes": true,
                "copy_button_source_and_feedback": true, "pool": pool]
    }
}
