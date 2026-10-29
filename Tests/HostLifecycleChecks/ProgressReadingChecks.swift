import AppKit
import SwiftUI
import WorkbenchCore

private struct ProgressReadingFixture: View {
    let messages: [KimiMessage]
    var body: some View {
        ConversationScrollView {
            ConversationTranscript(messages: messages, sessionId: "progress-reading", running: ["07-read"], isRunning: true,
                                   foldsProcess: true)
        }.background(WorkbenchTheme.contentBackground)
    }
}

/// The working transcript, before completion folds its progress away.
@MainActor func checkProgressReading() async throws {
    let progress = "我会对同一组 `workspace` 分别测试应用列表与直接接口，验证延迟发生在哪一段。这里保留完整说明，不把整段提升成标题。\n\n请求只读，响应只记录计数与耗时。"
    let summary = ["### 已排除网络耗时", "`maas-performance/models` 的 TTFB 为 69–84ms，无法解释稳定的 2 秒；继续检查 Redis 快照加载和 JSON 解码。"]
    func text(_ id: String, _ value: String, role: String = "assistant") -> [String: Any] {
        ["id": id, "role": role, "created_at": id, "content": [["type": "text", "text": value]]]
    }
    func tool(_ id: String) -> [String: Any] {
        ["id": id, "role": "assistant", "created_at": id, "content": [["type": "tool_use",
            "tool_call_id": id, "tool_name": "Read", "input": ["path": "/fixture/\(id).go"]]]]
    }
    func result(_ id: String) -> [String: Any] {
        ["id": id + "-result", "role": "tool", "created_at": id + "-result", "content": [[
            "type": "tool_result", "tool_call_id": id, "is_error": false, "output": "fixture result"]]]
    }
    let records: [[String: Any]] = [
        text("01-prompt", "继续定位应用列表的 5–6 秒延迟。", role: "user"),
        text("02-progress", progress), tool("03-read"), result("03-read"),
        ["id": "04-summary", "role": "assistant", "created_at": "04", "content": [[
            "type": "thinking", "thinking": "PRIVATE_PROGRESS_REASONING",
            "source": ["kind": "activity_summary", "itemId": "summary", "summaryParts": summary, "state": "final"]]]],
        tool("05-read"), result("05-read"),
        text("06-current", "正在核对 Redis shared snapshot 与缓存 TTL。"), tool("07-read")
    ]
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: records))
    let host = NSHostingView(rootView: ProgressReadingFixture(messages: messages))
    let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 820),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERCH_DESIGN_CAPTURES"] ?? "/private/tmp/perch-progress-reading")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (label, width, appearance) in [("light", 900.0, NSAppearance.Name.aqua), ("dark", 900.0, .darkAqua),
                                       ("narrow-light", 480.0, .aqua), ("narrow-dark", 480.0, .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: width, height: 820))
        try await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        let views = textViews(host), content = views.map(\.string).joined(separator: "\n")
        guard let prose = views.first(where: { $0.string.contains("我会对同一组") }),
              let detail = views.first(where: { $0.string.contains("的 TTFB 为 69–84ms") }),
              let heading = views.first(where: { $0.string == "已排除网络耗时" }) else {
            throw WorkbenchError("Working progress prose was missing or still rendered as plain summary labels")
        }
        precondition(content.contains("请求只读，响应只记录计数与耗时。") && !content.contains("PRIVATE_PROGRESS_REASONING"),
                     "Progress retains all public paragraphs without exposing private reasoning")
        precondition(!detail.string.contains("`"), "Inline code uses the Markdown renderer instead of displaying literal backticks")
        let proseFont = prose.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let detailOffset = (detail.string as NSString).range(of: "的 TTFB").location
        let detailFont = detail.textStorage!.attribute(.font, at: detailOffset, effectiveRange: nil) as! NSFont
        let headingFont = heading.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        precondition(proseFont.pointSize == ReplyStyle.bodySize && detailFont.pointSize == ReplyStyle.bodySize,
                     "Both long progress and its explanation retain the readable body size")
        precondition(NSFontManager.shared.weight(of: proseFont) == NSFontManager.shared.weight(of: .systemFont(ofSize: ReplyStyle.bodySize)),
                     "A long progress paragraph must not inherit heading weight")
        precondition(NSFontManager.shared.weight(of: headingFont) > NSFontManager.shared.weight(of: proseFont),
                     "Explicit Markdown headings retain their hierarchy")
        precondition(prose.isSelectable && detail.isSelectable, "Progress prose stays selectable")
        let proseX = host.convert(prose.bounds, from: prose).minX
        let detailX = host.convert(detail.bounds, from: detail).minX
        precondition(abs(proseX - detailX) < 1, "Progress sources align without a repeated status-icon gutter")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Missing progress snapshot") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("progress-" + label + ".png"))
    }
    print("PASS: working progress body typography, original paragraphs, public provider summary, inline code, alignment and light/dark wrapping")
}
