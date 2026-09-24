import Foundation
import WorkbenchCore

func checkReplyTableGeometry() {
    func table(_ markdown: String) -> (headers: [[ReplyInline]], rows: [[[ReplyInline]]]) {
        guard case .table(let headers, let rows, _) = ReplyDocument.parse(markdown)[0] else { fatalError("Expected a table") }
        return (headers, rows)
    }
    let geometry = ReplyTableGeometry()

    // Wide glyphs advance about twice what Latin text does; only the ratio matters.
    guard case .paragraph(let wide) = ReplyDocument.parse("中文")[0],
          case .paragraph(let narrow) = ReplyDocument.parse("ab")[0] else {
        fatalError("Expected paragraphs")
    }
    precondition(ReplyTableGeometry.estimatedContentWidth(wide, fontSize: 13) > ReplyTableGeometry.estimatedContentWidth(narrow, fontSize: 13))
    precondition(ReplyTableGeometry.estimatedContentWidth([], fontSize: 13) == 0)

    // A narrow `#` column, short labels and one paragraph column.
    let long = String(repeating: "长", count: 40)
    let sample = table("""
    | # | 场景 | 说明 | 列数 |
    | --- | --- | --- | --- |
    | 1 | 窄列混排 | \(long) | 四列 |
    """)
    let contents = ReplyTableGeometry.contentWidths(headers: sample.headers, rows: sample.rows, fontSize: geometry.fontSize)
    precondition(contents.count == 4)
    let minimums = geometry.minimumWidths(contentWidths: contents)
    precondition(minimums[0] == geometry.narrowColumnWidth, "A one-character column keeps only the narrow floor")
    precondition(minimums[2] == geometry.standardColumnWidth, "A paragraph column never floors below the contract width")

    let widths = geometry.columnWidths(contentWidths: contents, available: 700)
    precondition(widths.reduce(0, +) == 700, "A table that fits still fills the reading column")
    precondition(widths[0] <= geometry.narrowColumnWidth + 2, "A one-character column must not keep the standard floor")
    precondition(widths[2] > widths[1] && widths[2] > widths[3], "The paragraph column takes the surplus")
    precondition(widths.allSatisfy { $0 == $0.rounded() && $0 >= geometry.narrowColumnWidth })

    // While content still competes for room the cap holds: one long cell cannot
    // eat the table. Above it, the leftover keeps the table viewport-wide.
    let tight = geometry.columnWidths(contentWidths: contents, available: 600)
    precondition(tight.reduce(0, +) == 600)
    precondition(tight[0] == geometry.narrowColumnWidth)
    precondition(tight[2] <= geometry.maximumContentWidth + geometry.cellPadding * 2, "One long cell cannot eat the table")
    precondition(tight[2] > tight[1] * 2, "The paragraph column dominates a tighter viewport")

    // Below the floors the table overflows instead of shrinking further, which is
    // what lets the enclosing scroll view keep its documented behaviour.
    let floorTotal = minimums.reduce(0, +)
    precondition(geometry.columnWidths(contentWidths: contents, available: floorTotal - 1) == minimums)
    precondition(geometry.columnWidths(contentWidths: contents, available: floorTotal) == minimums)
    // Widths depend on content and available width alone: no pass-to-pass drift.
    precondition(geometry.columnWidths(contentWidths: contents, available: 700) == widths)
    precondition(geometry.columnWidths(contentWidths: contents, available: nil) == minimums)

    // Ragged and empty input stays valid while providers stream a partial table.
    precondition(ReplyTableGeometry.contentWidths(headers: [], rows: [], fontSize: 13).isEmpty)
    precondition(geometry.columnWidths(contentWidths: [], available: 700).isEmpty)
    let ragged = table("| 甲 | 乙 |\n| --- | --- |\n| 只填了第一列 |")
    let raggedWidths = geometry.columnWidths(
        contentWidths: ReplyTableGeometry.contentWidths(headers: ragged.headers, rows: ragged.rows, fontSize: geometry.fontSize),
        available: 400)
    precondition(raggedWidths.count == 2 && raggedWidths.reduce(0, +) == 400)

    // Whole points that still sum to the exact total at awkward widths.
    for step in 0...40 {
        let available = 320.5 + CGFloat(step) * 11.25
        let values = geometry.columnWidths(contentWidths: contents, available: available)
        precondition(values.allSatisfy { $0 == $0.rounded() && $0 > 0 })
        precondition(values.reduce(0, +) == available.rounded(.down) || available <= floorTotal,
                     "Rounding stays within a point and never exceeds the promised width")
    }

    // A wide table keeps every column readable and overflows rather than crushing.
    let seven = table("| 一 | 二 | 三 | 四 | 五 | 六 | 七 |\n| --- | --- | --- | --- | --- | --- | --- |\n| \(long) | b | c | d | e | f | g |")
    let sevenWidths = geometry.columnWidths(
        contentWidths: ReplyTableGeometry.contentWidths(headers: seven.headers, rows: seven.rows, fontSize: geometry.fontSize),
        available: 700)
    precondition(sevenWidths.count == 7)
    precondition(sevenWidths.reduce(0, +) >= geometry.minimumWidths(contentWidths: ReplyTableGeometry.contentWidths(
        headers: seven.headers, rows: seven.rows, fontSize: geometry.fontSize)).reduce(0, +))
    precondition(sevenWidths.dropFirst().allSatisfy { $0 >= geometry.narrowColumnWidth })

    print("PASS: reply table column widths, narrow-column floors, capped surplus, deterministic rounding")
}
