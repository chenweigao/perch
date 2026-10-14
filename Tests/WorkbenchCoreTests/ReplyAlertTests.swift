import Foundation
import WorkbenchCore

func checkReplyAlerts() {
    // Alert quote → typed block with the marker consumed.
    do {
        let blocks = ReplyDocument.parse("> [!NOTE]\n> 注意这里的写法。")
        guard case .alert(let kind, let inner) = blocks.first else { fatalError("expected alert, got \(blocks)") }
        expectEqual(kind, .note)
        guard case .paragraph(let runs) = inner.first else { fatalError("expected paragraph body") }
        expectEqual(runs.map(\.text).joined(), "注意这里的写法。")
    }
    // Marker with same-line content keeps the text.
    do {
        let blocks = ReplyDocument.parse("> [!WARNING] 立即处理\n> 第二行")
        guard case .alert(let kind, let inner) = blocks.first else { fatalError("expected alert") }
        expectEqual(kind, .warning)
        guard case .paragraph(let runs) = inner.first else { fatalError("expected paragraph") }
        precondition(runs.map(\.text).joined().contains("立即处理"), "same-line content survives")
    }
    // Case-insensitive marker; unknown markers stay quotes.
    do {
        let blocks = ReplyDocument.parse("> [!caution]\n> 小心。")
        guard case .alert(let kind, _) = blocks.first else { fatalError("expected alert") }
        expectEqual(kind, .caution)
        let plain = ReplyDocument.parse("> [!自定义]\n> 内容")
        guard case .quote = plain.first else { fatalError("unknown marker must stay a quote") }
    }
    // Plain quotes are untouched.
    do {
        let blocks = ReplyDocument.parse("> 普通引用")
        guard case .quote = blocks.first else { fatalError("quote regressed") }
    }
    print("PASS: reply alerts — typed block, marker consumed, case-insensitive, unknown stays quote")
}
