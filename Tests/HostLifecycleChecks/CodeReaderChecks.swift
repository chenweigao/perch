import AppKit
import SwiftUI
import QuartzCore
import WorkbenchCore

@MainActor func checkCodeReader() async throws {
    setbuf(stdout, nil)
    func kind(_ tokens: [CodeToken], _ source: String, _ needle: String) -> CodeToken.Kind? {
        let offset = (source as NSString).range(of: needle).location
        return tokens.first { NSLocationInRange(offset, $0.range) }?.kind
    }
    let python = "url = \"https://example.com\"\r\nvalue = 9 // 2 # 注释 👩🏽‍💻\r\ntext = '''line one\nline two'''\n"
    let pyTokens = try await CodeHighlighter.shared.highlight(python, language: "python")
    precondition(kind(pyTokens, python, "example") == .string)
    precondition(kind(pyTokens, python, "// 2") != .comment)
    precondition(kind(pyTokens, python, "注释") == .comment)
    precondition(kind(pyTokens, python, "line two") == .string)
    precondition(NSMaxRange(pyTokens.last!.range) == python.utf16.count)
    let swift = "/* block\ncomment */\nlet value = \"中文 e\u{301} 👩🏽‍💻\"\n"
    let swiftTokens = try await CodeHighlighter.shared.highlight(swift, language: "swift")
    precondition(kind(swiftTokens, swift, "comment") == .comment && kind(swiftTokens, swift, "中文") == .string)
    precondition(CodeLanguage.file("thing.py") == "python" && CodeLanguage.canonical("tsx") == "typescript")
    let unknown = try await CodeHighlighter.shared.highlight(swift, language: "not-a-language")
    precondition(unknown.isEmpty)
    let count = await CodeHighlighter.shared.parseCount
    _ = try await CodeHighlighter.shared.highlight(python, language: "python")
    let afterCache = await CodeHighlighter.shared.parseCount
    precondition(afterCache == count, "Repeated cards must reuse token data")

    print("CHECK: language grammar and cache passed")
    let sample = "def value():\n    return \"https://example.com 中文 👩🏽‍💻\" # comment\n"
    let source = String(repeating: sample, count: 45_000) + "# LAST_NEEDLE\n"
    precondition(source.utf8.count > 3 * 1_048_576)
    let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 960, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let start = CACurrentMediaTime()
    window.contentView = NSHostingView(rootView: RemoteSourceText(text: source, line: nil, numbered: true, sourcePath: "fixture.py"))
    window.orderFront(nil); window.displayIfNeeded()
    print("METRIC: source mount ms=\((CACurrentMediaTime() - start) * 1000), bytes=\(source.utf8.count)")
    try await Task.sleep(for: .milliseconds(100))
    window.displayIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let view = descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "PerchReviewSource" }!
    let scroll = view.enclosingScrollView!
    let highlighting = view.layoutManager!.delegate as! CodeHighlightController
    precondition(view.layoutManager!.allowsNonContiguousLayout && !view.layoutManager!.backgroundLayoutEnabled)
    precondition(view.string == source)
    let selection = (source as NSString).range(of: "中文 👩🏽‍💻")
    view.setSelectedRange(selection)
    for _ in 0..<400 where !highlighting.ready { try await Task.sleep(for: .milliseconds(25)) }
    precondition(highlighting.ready && highlighting.error == nil && !highlighting.tokens.isEmpty,
                 "Large files must remain highlighted: \(String(describing: highlighting.error))")
    precondition(view.selectedRange() == selection && view.string == source, "Async color cannot replace text or selection")
    let parsed = await CodeHighlighter.largeFiles.parseCount
    let cacheStart = CACurrentMediaTime()
    let cached = try await CodeHighlighter.engine(for: source).highlight(source, language: "python")
    let afterLargeCache = await CodeHighlighter.largeFiles.parseCount
    precondition(afterLargeCache == parsed && cached.count == highlighting.tokens.count, "Reopening a large file must reuse bounded tokens")
    print("METRIC: large-file cached colors ms=\((CACurrentMediaTime() - cacheStart) * 1000)")
    let largeCacheBytes = await CodeHighlighter.largeFiles.cacheBytes
    precondition(largeCacheBytes <= 32 * 1_048_576)
    // Start an uncached large parse, then switch this same reader to a small file.
    highlighting.update(source: source + "# uncached replacement\n", language: "python")
    try await Task.sleep(for: .milliseconds(50))
    let switched = "let immediate = 123"
    let switchStart = CACurrentMediaTime()
    highlighting.update(source: switched, language: "swift")
    for _ in 0..<100 where !highlighting.ready { try await Task.sleep(for: .milliseconds(10)) }
    precondition(highlighting.ready && highlighting.error == nil && NSMaxRange(highlighting.tokens.last!.range) == switched.utf16.count,
                 "Small-file colors must not wait for an obsolete large-file parse")
    print("METRIC: large-to-small colors ms=\((CACurrentMediaTime() - switchStart) * 1000)")
    highlighting.update(source: source, language: "python")
    for _ in 0..<400 where !highlighting.ready { try await Task.sleep(for: .milliseconds(25)) }
    precondition(highlighting.ready && highlighting.error == nil)
    print("CHECK: large highlights and selection passed")
    let probe = CodeDrawingProbe(highlighting)
    view.layoutManager!.delegate = probe
    let image = NSImage(size: NSSize(width: 720, height: 300))
    image.lockFocus()
    NSColor.textBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: 720, height: 300).fill()
    let visibleGlyphs = view.layoutManager!.glyphRange(forBoundingRect: NSRect(x: 0, y: 0, width: 720, height: 300), in: view.textContainer!)
    view.layoutManager!.drawGlyphs(forGlyphRange: visibleGlyphs, at: .zero)
    image.unlockFocus()
    precondition(probe.coloredRuns > 0, "Native drawing must actually request syntax colors")
    view.layoutManager!.delegate = highlighting
    print("CHECK: drawing uses colors")
    let beforeStorage = view.textStorage!.copy() as! NSAttributedString
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        for width: CGFloat in [480, 1100] {
            window.setContentSize(NSSize(width: width, height: 600)); window.displayIfNeeded()
            precondition(view.selectedRange() == selection)
        }
    }
    let search = FileSearchController(view: view, highlighting: highlighting)
    search.update(text: source, query: "return", index: 0)
    for _ in 0..<100 where search.searching { try await Task.sleep(for: .milliseconds(20)) }
    precondition(highlighting.matches.count == 45_000, "Search must reach beyond the former 5,000-match cap")
    let scans = search.searchCount
    let nextStart = CACurrentMediaTime()
    for index in 1...20 { search.update(text: source, query: "return", index: index) }
    print("METRIC: 20 next-result jumps ms=\((CACurrentMediaTime() - nextStart) * 1000)")
    precondition(search.searchCount == scans && view.textStorage!.isEqual(to: beforeStorage), "Navigation must not scan or recolor storage")
    search.update(text: source, query: "LAST_NEEDLE", index: 0)
    for _ in 0..<100 where search.searching { try await Task.sleep(for: .milliseconds(20)) }
    precondition(view.selectedRange() == (source as NSString).range(of: "LAST_NEEDLE"))
    precondition((scroll.verticalRulerView as! RemoteSourceGutter).lineNumber(at: view.selectedRange().location) == 90_001)
    let glyph = view.layoutManager!.glyphRange(forCharacterRange: view.selectedRange(), actualCharacterRange: nil)
    let rect = view.layoutManager!.boundingRect(forGlyphRange: glyph, in: view.textContainer!).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    precondition(scroll.contentView.bounds.intersects(rect), "End-of-file selection must be visible")
    // Late searches and token requests must not republish into replacement content.
    search.update(text: source, query: "return", index: 0)
    search.update(text: "replacement", query: "missing", index: 0)
    for _ in 0..<100 where search.searching { try await Task.sleep(for: .milliseconds(20)) }
    precondition(highlighting.matches.isEmpty)
    highlighting.update(source: source, language: "python", debounce: true)
    highlighting.update(source: "let replacement = 42", language: "swift")
    for _ in 0..<100 where !highlighting.ready { try await Task.sleep(for: .milliseconds(20)) }
    precondition(NSMaxRange(highlighting.tokens.last!.range) == "let replacement = 42".utf16.count)
    highlighting.reset(); search.cancel()

    let reply = SelectableReplyText.acquire(delegate: SelectableReplyText.Coordinator())
    reply.update(ReplyTextAttributes.code(swift)); reply.highlightCode(language: "swift")
    for _ in 0..<100 where reply.codeHighlighting?.ready != true { try await Task.sleep(for: .milliseconds(20)) }
    precondition(reply.codeHighlighting!.tokens.map(\.range) == swiftTokens.map(\.range))
    SelectableReplyText.recycle(reply)
    precondition(reply.codeHighlighting!.tokens.isEmpty && reply.string.isEmpty)
    let restoredText = String(repeating: sample, count: 1000)
    let host = NSHostingView(rootView: RemoteSourceText(text: restoredText, line: nil, numbered: true, initialOffset: 1200, sourcePath: "restore.py"))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(150))
    window.displayIfNeeded()
    let restored = descendants(host).compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "PerchReviewSource" }!
    let restoredScroll = restored.enclosingScrollView!
    print("CHECK: restored offset \(restoredScroll.contentView.bounds.origin.y), extent \(restored.frame.height)")
    // NSTextView's native adjustScroll aligns a requested offset to a line.
    precondition(abs(restoredScroll.contentView.bounds.origin.y - 1200) < 20, "Lazy sizing must restore the saved reading line")
    let restoredY = restoredScroll.contentView.bounds.origin.y
    restored.setSelectedRange(selection)
    host.rootView = RemoteSourceText(text: restoredText, line: nil, numbered: false, initialOffset: 1200, sourcePath: "restore.py")
    try await Task.sleep(for: .milliseconds(100))
    precondition(restored.selectedRange() == selection && abs(restoredScroll.contentView.bounds.origin.y - restoredY) < 1,
                 "Toggling line numbers must retain selection and reading position")
    print("PASS: highlight.js grammar/Unicode/CRLF, >3MiB highlights, native lazy layout, 45,000 matches, reuse, end jump, stale work, selection and card reuse")
}

@MainActor private final class CodeDrawingProbe: NSObject, @MainActor NSLayoutManagerDelegate {
    let controller: CodeHighlightController
    var coloredRuns = 0
    init(_ controller: CodeHighlightController) { self.controller = controller }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any], forDrawingToScreen toScreen: Bool, atCharacterIndex index: Int, effectiveRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        let result = controller.layoutManager(layoutManager, shouldUseTemporaryAttributes: attrs, forDrawingToScreen: toScreen, atCharacterIndex: index, effectiveRange: effectiveRange)
        if result?[.foregroundColor] != nil { coloredRuns += 1 }
        return result
    }
}
