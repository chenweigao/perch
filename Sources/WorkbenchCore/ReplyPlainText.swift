import Foundation

/// A reply as plain text: what a reader sees, without Markdown syntax. Lists keep
/// their markers, quotes and alerts are prefixed with "> ", tables become
/// tab-separated rows, and code and math keep their source.
public enum ReplyPlainText {
    public static func text(from source: String) -> String {
        render(ReplyDocument.parse(source))
    }

    public static func render(_ blocks: [ReplyBlock]) -> String {
        blocks.map(block).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func block(_ block: ReplyBlock) -> String {
        switch block {
        case .paragraph(let runs), .heading(_, let runs): return inline(runs)
        case .code(_, let source): return source
        case .math(let latex): return latex
        case .list(let items): return list(items)
        case .quote(let inner), .alert(_, let inner): return quoted(render(inner))
        case .table(let headers, let rows, _):
            return ([headers] + rows).map { $0.map(inline).joined(separator: "\t") }.joined(separator: "\n")
        case .rule: return "———"
        }
    }

    /// Link text stays as written; a web link whose text differs keeps its address.
    private static func inline(_ runs: [ReplyInline]) -> String {
        runs.map { run -> String in
            if let math = run.math { return "$" + math + "$" }
            if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? ""),
               link.absoluteString != run.text {
                return run.text + " (" + link.absoluteString + ")"
            }
            return run.text
        }.joined()
    }

    /// Continuation lines align under the item text, so nested lists stay readable.
    private static func list(_ items: [ReplyListItem]) -> String {
        items.map { item in
            let body = item.blocks.map(block).filter { !$0.isEmpty }.joined(separator: "\n")
            let lines = body.components(separatedBy: "\n")
            let indent = String(repeating: " ", count: item.marker.count + 1)
            return ([item.marker + " " + (lines.first ?? "")] + lines.dropFirst().map { $0.isEmpty ? $0 : indent + $0 })
                .joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func quoted(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }
}
