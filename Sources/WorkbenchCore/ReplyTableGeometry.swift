import Foundation

/// Column widths for reply tables.
///
/// Widths come from arithmetic over estimated single-line content widths, never
/// from TextKit, so a table asks the text views for row heights only — the same
/// measurement the equal-split grid already made — and no width can feed back
/// into the transcript's layout graph.
public struct ReplyTableGeometry {
    public var fontSize: CGFloat
    /// Horizontal cell padding on one side.
    public var cellPadding: CGFloat
    /// Column total when its content is genuinely narrow, such as a `#` column.
    public var narrowColumnWidth: CGFloat
    /// Column total for ordinary content; the floor the reading contract documents.
    public var standardColumnWidth: CGFloat
    /// Content width a column may claim from its own content, so one long cell
    /// cannot eat a table that has to share the reading column. A viewport wider
    /// than the whole table still stretches columns past this.
    public var maximumContentWidth: CGFloat

    public init(fontSize: CGFloat = 13, cellPadding: CGFloat = 12, narrowColumnWidth: CGFloat = 44,
                standardColumnWidth: CGFloat = 124, maximumContentWidth: CGFloat = 420) {
        self.fontSize = fontSize
        self.cellPadding = cellPadding
        self.narrowColumnWidth = narrowColumnWidth
        self.standardColumnWidth = standardColumnWidth
        self.maximumContentWidth = maximumContentWidth
    }

    /// Estimated single-line advance: wide glyphs about 1 em, inline code about
    /// 0.62 em, other text about 0.55 em. Only the relative weights matter, so
    /// this never builds an attributed string.
    public static func estimatedContentWidth(_ runs: [ReplyInline], fontSize: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        for run in runs {
            let narrow = run.code ? fontSize * 0.62 : fontSize * 0.55
            for scalar in run.text.unicodeScalars {
                width += isWide(scalar) ? fontSize : narrow
            }
        }
        return width
    }

    /// Widest cell per column, headers included, as content width without padding.
    public static func contentWidths(headers: [[ReplyInline]], rows: [[[ReplyInline]]], fontSize: CGFloat) -> [CGFloat] {
        guard !headers.isEmpty else { return [] }
        var widths = headers.map { estimatedContentWidth($0, fontSize: fontSize) }
        for row in rows {
            for column in 0..<min(widths.count, row.count) {
                widths[column] = max(widths[column], estimatedContentWidth(row[column], fontSize: fontSize))
            }
        }
        return widths
    }

    /// Column totals for a table that cannot fit: narrow content shrinks to
    /// `narrowColumnWidth`, everything else keeps `standardColumnWidth`.
    public func minimumWidths(contentWidths: [CGFloat]) -> [CGFloat] {
        contentWidths.map { min(max($0 + cellPadding * 2, narrowColumnWidth), standardColumnWidth) }
    }

    /// Column totals for `available` points, including padding.
    ///
    /// Floors first; the surplus then goes to columns whose content still needs
    /// room, weighted by unmet demand and capped by `maximumContentWidth`.
    /// Whatever is left keeps the table viewport-wide, spread by content weight so
    /// narrow columns do not balloon. Below the floors the table overflows and the
    /// enclosing scroll view takes over. Rounding is whole points, deterministic,
    /// and never exceeds `available`, so the table cannot out-scroll its container.
    public func columnWidths(contentWidths: [CGFloat], available: CGFloat?) -> [CGFloat] {
        let floors = minimumWidths(contentWidths: contentWidths)
        guard !floors.isEmpty else { return [] }
        let floorTotal = floors.reduce(0, +)
        guard let available, available.isFinite, available > floorTotal else { return floors }
        let caps = contentWidths.map { min($0, maximumContentWidth) + cellPadding * 2 }
        var widths = floors
        var surplus = available - floorTotal
        // Water-fill unmet demand. Each pass saturates at least one column or
        // exhausts the surplus, so the bound only caps pathological column counts.
        for _ in 0..<8 {
            guard surplus > 0.5 else { break }
            let demands = widths.indices.map { max(0, caps[$0] - widths[$0]) }
            let total = demands.reduce(0, +)
            guard total > 0 else { break }
            var spent: CGFloat = 0
            for index in widths.indices {
                let share = min(demands[index], surplus * demands[index] / total)
                widths[index] += share
                spent += share
            }
            surplus -= spent
        }
        if surplus > 0.5 {
            let weights = contentWidths.map { max(1, $0) }
            let total = weights.reduce(0, +)
            for index in widths.indices { widths[index] += surplus * weights[index] / total }
        }
        return Self.wholePoints(widths, total: available)
    }

    /// Whole points within one point below `total`, largest fractional part first
    /// and lowest index on a tie, so repeated passes cannot drift.
    static func wholePoints(_ widths: [CGFloat], total: CGFloat) -> [CGFloat] {
        var values = widths.map { $0.rounded(.down) }
        var remainder = Int((total - values.reduce(0, +)).rounded(.down))
        guard remainder > 0 else { return values }
        let order = widths.indices.sorted { lhs, rhs in
            let left = widths[lhs] - values[lhs]
            let right = widths[rhs] - values[rhs]
            return left == right ? lhs < rhs : left > right
        }
        var cursor = 0
        while remainder > 0 {
            values[order[cursor % order.count]] += 1
            remainder -= 1
            cursor += 1
        }
        return values
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
