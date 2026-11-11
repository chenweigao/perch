import Foundation

public enum ReplyAlignment: Equatable, Sendable { case leading, center, trailing }

/// Cell values retain math and literal code so exporting never copies a text
/// attachment placeholder or interprets literal characters as Markdown.
public struct TableCell: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String), code(String), math(String)
    }
    public let parts: [Part]
    public init(_ text: String) { parts = [.text(text)] }
    public init(parts: [Part]) { self.parts = parts }
    public init(inlines: [ReplyInline]) {
        parts = inlines.map { run in
            if let math = run.math { return .math(math) }
            return run.code ? .code(run.text) : .text(run.text)
        }
    }
    public var text: String {
        parts.map { part in
            switch part {
            case .text(let text), .code(let text): return text
            case .math(let source): return "$\(source)$"
            }
        }.joined()
    }
}

/// One cell model feeds both serializers; alignments and empty values survive.
public struct TableData: Equatable, Sendable {
    public let headerCells: [TableCell]
    public let cellRows: [[TableCell]]
    public let alignments: [ReplyAlignment]
    public var headers: [String] { headerCells.map(\.text) }
    public var rows: [[String]] { cellRows.map { $0.map(\.text) } }
    public init(headers: [String], rows: [[String]], alignments: [ReplyAlignment]) {
        self.headerCells = headers.map(TableCell.init)
        self.cellRows = rows.map { $0.map(TableCell.init) }
        self.alignments = alignments
    }
    public init(headerCells: [TableCell], cellRows: [[TableCell]], alignments: [ReplyAlignment]) {
        self.headerCells = headerCells
        self.cellRows = cellRows
        self.alignments = alignments
    }
}

public enum TableSerialization {
    /// GFM pipe table: `|` escapes as `\|`, in-cell line breaks become `<br>`.
    /// Rows are padded to the header's width; extra cells are dropped because a
    /// pipe table must stay rectangular.
    public static func markdown(_ table: TableData) -> String {
        func literal(_ text: String) -> String {
            var result = ""
            for character in text {
                switch character {
                case "\r\n", "\n", "\r": result += "<br>"
                case "&": result += "&amp;"
                case "<": result += "&lt;"
                case ">": result += "&gt;"
                case "\\", "|", "*", "_", "`", "[", "]", "!", "$", "~": result += "\\" + String(character)
                default: result.append(character)
                }
            }
            return result
        }
        func cell(_ value: TableCell) -> String {
            value.parts.map { part in
                switch part {
                case .text(let text): return literal(text)
                case .math(let source):
                    return "$" + source.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "|", with: "\\|") + "$"
                case .code(let text):
                    let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                    let fence = String(repeating: "`", count: longest + 1)
                    let value = text.replacingOccurrences(of: "|", with: "\\|")
                    let padding = text.hasPrefix("`") || text.hasSuffix("`") || (text.hasPrefix(" ") && text.hasSuffix(" ") && !text.allSatisfy(\.isWhitespace)) ? " " : ""
                    return fence + padding + value + padding + fence
                }
            }.joined()
        }
        func row(_ cells: [TableCell]) -> String {
            "| " + (0..<table.headerCells.count).map { index in
                index < cells.count ? cell(cells[index]) : ""
            }.joined(separator: " | ") + " |"
        }
        let separators = (0..<table.headerCells.count).map { index -> String in
            switch index < table.alignments.count ? table.alignments[index] : .leading {
            case .leading: return "---"
            case .center: return ":---:"
            case .trailing: return "---:"
            }
        }
        return ([row(table.headerCells), "| " + separators.joined(separator: " | ") + " |"]
            + table.cellRows.map(row)).joined(separator: "\n")
    }

    /// RFC 4180: quotes double, fields containing comma/quote/newline quote-wrap,
    /// records end CRLF. The file export adds a BOM on top so Excel reads Chinese.
    public static func csv(_ table: TableData) -> String {
        func field(_ text: String) -> String {
            guard text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func record(_ cells: [TableCell]) -> String {
            (0..<table.headerCells.count).map { index in
                index < cells.count ? field(cells[index].text) : ""
            }.joined(separator: ",")
        }
        return ([record(table.headerCells)] + table.cellRows.map(record)).joined(separator: "\r\n") + "\r\n"
    }
}
