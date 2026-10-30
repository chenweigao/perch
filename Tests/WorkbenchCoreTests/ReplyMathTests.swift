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
    // Backslash and dollar delimiters share the same inline rendering path.
    do {
        let blocks = ReplyDocument.parse(#"隐藏维度 \(H=2560\)，能量 $E=mc^2$。"#)
        guard case .paragraph(let runs) = blocks.first else { fatalError("expected paragraph") }
        let mathRuns = runs.filter { $0.math != nil }
        expectEqual(mathRuns.map(\.math), ["H=2560", "E=mc^2"])
        expectEqual(mathRuns.first?.text, "\u{FFFC}")
    }
    // Multiline display math from the reported reply keeps TeX commands and row breaks.
    do {
        let blocks = ReplyDocument.parse(#"""
        之前

        \[
        P(S)=
        \begin{cases}
        S(S+1)/2, & S\le W\\
        W(W+1)/2+(S-W)W, & S>W
        \end{cases}
        \]

        之后
        """#)
        guard blocks.count == 3, case .math(let latex) = blocks[1] else {
            fatalError("expected backslash display math, got \(blocks)")
        }
        precondition(latex.contains(#"\begin{cases}"#))
        precondition(latex.contains(#"S(S+1)/2"#))
        precondition(latex.contains(#"\\"#))
    }
    // Backslash math also works in nested document blocks.
    do {
        guard case .list(let items) = ReplyDocument.parse(#"- 项 \(a_i\)"#).first,
              case .paragraph(let listRuns) = items.first?.blocks.first else {
            fatalError("expected list math")
        }
        expectEqual(listRuns.first(where: { $0.math != nil })?.math, "a_i")
        let table = ReplyDocument.parse("| 公式 |\n| --- |\n| \\(b_i\\) |")
        guard case .table(_, let rows, _) = table.first else { fatalError("expected table math") }
        expectEqual(rows[0][0].first(where: { $0.math != nil })?.math, "b_i")
    }
    // Ordinary text, escaped delimiters and incomplete streaming input stay text.
    for source in [#"普通 (x) 和 [y]"#, #"未闭合 \(x"#, #"双反斜杠 \\(x\\)"#] {
        let blocks = ReplyDocument.parse(source)
        guard case .paragraph(let runs) = blocks.first else {
            fatalError("expected plain paragraph for \(source), got \(blocks)")
        }
        precondition(runs.allSatisfy { $0.math == nil }, "\(source) must not parse as math")
    }
    // Math inside inline code and fenced code stays code.
    do {
        let blocks = ReplyDocument.parse(#"`$x$` 和 `\(z\)` 和 $y$ 和 \(w\)"#)
        guard case .paragraph(let runs) = blocks.first else { fatalError("expected paragraph") }
        precondition(runs.contains { $0.code && $0.text == "$x$" })
        precondition(runs.contains { $0.code && $0.text == #"\(z\)"# })
        expectEqual(runs.filter { $0.math != nil }.count, 2)
    }
    do {
        let blocks = ReplyDocument.parse(#"""
        ```tex
        \[x\]
        ```

        ~~~text
        \(y\)
        ~~~

        \[z\]
        """#)
        guard blocks.count == 3, case .code(_, let backtickCode) = blocks[0],
              case .code(_, let tildeCode) = blocks[1], case .math(let latex) = blocks[2] else {
            fatalError("expected isolated fenced code, got \(blocks)")
        }
        expectEqual(backtickCode, #"\[x\]"#)
        expectEqual(tildeCode, #"\(y\)"#)
        expectEqual(latex, "z")
    }
    print("PASS: reply math — dollar/backslash delimiters, display blocks, currency guard, code isolation")
}
