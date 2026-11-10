import AppKit
import SwiftUI
import WorkbenchCore

/// Production transcript geometry with long history, independent of any service.
@MainActor func checkReadingContinuityReview() async throws {
    func row(_ id: String, _ text: String, role: String = "assistant", thinking: Bool = false) -> [String: Any] {
        ["id": id, "role": role, "created_at": "1", "content": [["type": thinking ? "thinking" : "text", thinking ? "thinking" : "text": text]]]
    }
    func decode(_ rows: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    var records: [[String: Any]] = []
    for turn in 0..<40 {
        records += [row("u-\(turn)", "第 \(turn + 1) 轮：检查上下文与文件窗口。", role: "user"),
                    row("t-\(turn)", "核对这轮的处理顺序。", thinking: true),
                    row("a-\(turn)", "第 \(turn + 1) 轮结果：保留既有布局与操作入口。中文和 English 混排，路径 `Sources/DocumentReader.swift`。")]
    }
    records.append(row("latest-u", "继续核对首次打开的边界。", role: "user"))
    for part in 0..<12 {
        records += [row("latest-t-\(part)", "检查 \(part)", thinking: true),
                    row("latest-progress-\(part)", "阶段说明 \(part)：检查路径、缓存与窗口边界。")]
    }
    let answer = (0..<32).map { "阅读锚点 \($0)：结果正文应在流式追加、完成和返回会话时保持原位。" }.joined(separator: "\n\n")
    records.append(row("latest-answer", answer))
    let initial = try decode(records)
    let session = "continuity-review-A"
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    defer { window.orderOut(nil) }
    let host = NSHostingView(rootView: ReadingDesignFixture(messages: initial, running: true, session: session, folds: true))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func settle() async throws { try await Task.sleep(for: .milliseconds(450)); host.layoutSubtreeIfNeeded() }
    func texts() -> [NSTextView] { descendants(host).compactMap { $0 as? NSTextView } }
    let marker = "阅读锚点 2："
    func anchorRect(in target: NSView?) -> NSRect? {
        guard let text = texts().first(where: { $0.string.contains(marker) }),
              let layout = text.layoutManager, let container = text.textContainer else { return nil }
        let characters = (text.string as NSString).range(of: marker)
        let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
        return text.convert(rect, to: target)
    }
    func anchorY() -> CGFloat? { anchorRect(in: nil)?.minY }
    try await settle()
    let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first { ($0.documentView?.bounds.height ?? 0) > 3000 }!
    let clip = scroll.contentView
    ConversationReadingMemory.shared.following[session] = false
    // Use the same explicit search route as the reader; an estimated document
    // height is not a stable way to enter a virtualized long history.
    NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(
        session: session, hit: .init(entryID: "text:latest-answer:0", occurrence: 0, excerpt: "阅读锚点 2："), query: "阅读锚点 2："))
    try await settle()
    guard let rect = anchorRect(in: scroll.documentView) else { preconditionFailure("Long history must mount the chosen glyphs") }
    // Scroll the answer row itself to just below the viewport top, so the saved
    // reading row is the answer entry on any typography. Anchoring by the glyph
    // leaves a process row sliver intersecting the top edge; a pin on that row
    // goes through the completion fold remap (fold top, offset discarded), which
    // is approximate by design and not what this check measures.
    let answerRow = descendants(scroll.documentView!).first { $0.identifier?.rawValue == "text:latest-answer:0" }
    let location = answerRow.map { $0.convert($0.bounds, to: scroll.documentView).minY - 12 } ?? rect.minY - 140
    clip.scroll(to: NSPoint(x: 0, y: location)); scroll.reflectScrolledClipView(clip)
    try await settle()
    let before = anchorY()!
    let output = URL(fileURLWithPath: "/private/tmp/perch-reading-design")
    func snapshot(_ name: String) throws {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    try snapshot("review-long-reading")
    records[records.count - 1] = row("latest-answer", answer + "\n\n新追加：这是同一回复的后续文字。")
    let appended = try decode(records)
    host.rootView = ReadingDesignFixture(messages: appended, running: true, session: session, folds: true)
    try await settle()
    let afterAppend = anchorY()!
    host.rootView = ReadingDesignFixture(messages: appended, running: false, session: session, folds: true)
    try await settle()
    let afterCompletion = anchorY()!
    try snapshot("review-long-completed")
    host.rootView = ReadingDesignFixture(messages: try decode([row("other-u", "另一个会话", role: "user"), row("other-a", "另一个会话的内容")]), session: "continuity-review-B", folds: true)
    try await settle()
    precondition(!texts().contains { $0.string.hasPrefix("阅读锚点") })
    host.rootView = ReadingDesignFixture(messages: appended, session: session, folds: true)
    try await settle()
    let afterReturn = anchorY()!
    let deltas = ["append": abs(afterAppend - before), "completion": abs(afterCompletion - before), "sessionReturn": abs(afterReturn - before)]
    try JSONSerialization.data(withJSONObject: deltas, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("review-reading-position.json"))
    precondition(deltas.values.allSatisfy { $0 <= 2 }, "Reading glyph drift: \(deltas)")
    print("PASS: 40-turn native history; append/completion/session-return glyph drift \(deltas)")
}
