import Foundation

public enum ReplyAlignment: Equatable, Sendable { case leading, center, trailing }

/// A rendered table as plain cell text plus column alignments: the single
/// source for the row's copy and export actions, so Markdown, CSV and the
/// on-screen cells can never drift apart.
public struct TableData: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]
    public let alignments: [ReplyAlignment]
    public init(headers: [String], rows: [[String]], alignments: [ReplyAlignment]) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
    }
}

public enum TableSerialization {
    /// GFM pipe table: `|` escapes as `\|`, in-cell line breaks become `<br>`.
    /// Rows are padded to the header's width; extra cells are dropped because a
    /// pipe table must stay rectangular.
    public static func markdown(_ table: TableData) -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "\r", with: "<br>")
        }
        func row(_ cells: [String]) -> String {
            "| " + (0..<table.headers.count).map { index in
                index < cells.count ? cell(cells[index]) : ""
            }.joined(separator: " | ") + " |"
        }
        let separators = (0..<table.headers.count).map { index -> String in
            switch index < table.alignments.count ? table.alignments[index] : .leading {
            case .leading: return "---"
            case .center: return ":---:"
            case .trailing: return "---:"
            }
        }
        return ([row(table.headers), "| " + separators.joined(separator: " | ") + " |"]
            + table.rows.map(row)).joined(separator: "\n")
    }

    /// RFC 4180: quotes double, fields containing comma/quote/newline quote-wrap,
    /// records end CRLF. The file export adds a BOM on top so Excel reads Chinese.
    public static func csv(_ table: TableData) -> String {
        func field(_ text: String) -> String {
            guard text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func record(_ cells: [String]) -> String {
            (0..<table.headers.count).map { index in
                index < cells.count ? field(cells[index]) : ""
            }.joined(separator: ",")
        }
        return ([record(table.headers)] + table.rows.map(record)).joined(separator: "\r\n") + "\r\n"
    }
}
