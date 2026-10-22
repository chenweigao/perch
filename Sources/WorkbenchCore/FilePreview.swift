import Foundation

public enum FilePreviewKind: String, Codable, Sendable {
    case source, markdown, image, pdf, table, html
    public init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff": self = .image
        case "pdf": self = .pdf
        case "csv", "tsv": self = .table
        case "html", "htm": self = .html
        default: self = .source
        }
    }
    public var isBinary: Bool { self == .image || self == .pdf }
    public var initialReadLimit: Int { isBinary ? 16 * 1_048_576 : RemoteFileCommand.readLimit }
}

public struct FileReadingTab: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var offset: Double = 0
    public var reading = true
    public var id: String { path }
    public init(path: String) { self.path = path }
}

/// A bounded RFC 4180 reader for previews; quoted delimiters, escaped quotes,
/// CRLF and multiline cells retain their meaning. It never imports or executes cells.
public struct DelimitedPreview: Equatable, Sendable {
    public let rows: [[String]]
    public let truncated: Bool
    public init(_ text: String, delimiter: Character = ",", rowLimit: Int = 200, columnLimit: Int = 40) {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false, skipLF = false, truncated = false, rowStarted = false
        func finishField() { if row.count < columnLimit { row.append(field) } else { truncated = true }; field = "" }
        func finishRow() { finishField(); rows.append(row); row = []; rowStarted = false }
        for character in text {
            if rows.count >= rowLimit { truncated = true; break }
            if skipLF { skipLF = false; if character == "\n" { continue } }
            rowStarted = true
            if quoted {
                if afterQuote {
                    if character == "\"" { field.append(character); afterQuote = false; continue }
                    quoted = false; afterQuote = false
                } else {
                    if character == "\"" { afterQuote = true } else { field.append(character) }
                    continue
                }
            }
            switch character {
            case "\"" where field.isEmpty: quoted = true
            case delimiter: finishField()
            case "\r": finishRow(); skipLF = true
            case "\n", "\r\n": finishRow()
            default: field.append(character)
            }
        }
        if rows.count < rowLimit && (rowStarted || !field.isEmpty || !row.isEmpty) { finishRow() }
        self.rows = rows; self.truncated = truncated
    }
}
