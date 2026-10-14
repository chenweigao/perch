import Foundation
import WorkbenchCore

func checkReplyMath() {
    // Display math paragraph → atomic block.
    do {
        let blocks = ReplyDocument.parse("之前\n\n$$x^2 + y^2$$\n\n之后")
        guard blocks.count == 3, case .math(let latex) = blocks[1] else {
            fatalError("expected display math block, got \(blocks)")
        }
        expectEqual(latex, "x^2 + y^2")
    }
    // Inline math splits runs and carries the object replacement char.
    do {
        let blocks = ReplyDocument.parse("质能方程 $E=mc^2$ 成立")
        guard case .paragraph(let runs) = blocks.first else { fatalError("expected paragraph") }
        let mathRuns = runs.filter { $0.math != nil }
        expectEqual(mathRuns.count, 1)
        expectEqual(mathRuns.first?.math, "E=mc^2")
        expectEqual(mathRuns.first?.text, "\u{FFFC}")
        expectEqual(runs.first?.text, "质能方程 ")
    }
    // Currency and spaced dollars stay text.
    for source in ["价格是 $5 和 $10", "$ 开了个头 $", "no math at all"] {
        let blocks = ReplyDocument.parse(source)
        guard case .paragraph(let runs) = blocks.first else { continue }
        precondition(runs.allSatisfy { $0.math == nil }, "\(source) must not parse as math")
    }
    // \( … \) inline math arrives unescaped as plain parens through
    // swift-markdown, so only $…$ forms are detected (documented boundary).
    do {
        let blocks = ReplyDocument.parse("即 $a_i$ 项")
        guard case .paragraph(let runs) = blocks.first else { fatalError("expected paragraph") }
        expectEqual(runs.first(where: { $0.math != nil })?.math, "a_i")
    }
    // Math inside code stays code; math runs are never linked.
    do {
        let blocks = ReplyDocument.parse("`$x$` 和 $y$")
        guard case .paragraph(let runs) = blocks.first else { fatalError("expected paragraph") }
        precondition(runs.contains { $0.code && $0.text == "$x$" })
        expectEqual(runs.filter { $0.math != nil }.count, 1)
    }
    print("PASS: reply math — display blocks, inline split, currency guard, code isolation")
}
