import Foundation
import WorkbenchCore

/// The 8-column acceptance sample: Chinese, empty cells, commas, quotes and
/// in-cell newlines must survive both serializers.
func checkTableSerialization() {
    let table = TableData(
        headers: ["名称", "状态", "备注"],
        rows: [
            ["构建", "通过", "包含, 逗号"],
            ["部署", "失败 \"重试\"", "第一行\n第二行"],
            ["", "", ""],
        ],
        alignments: [.leading, .center, .trailing])
    let markdown = TableSerialization.markdown(table)
    let expectedMarkdown = """
    | 名称 | 状态 | 备注 |
    | --- | :---: | ---: |
    | 构建 | 通过 | 包含, 逗号 |
    | 部署 | 失败 "重试" | 第一行<br>第二行 |
    |  |  |  |
    """
    precondition(markdown == expectedMarkdown, "Markdown must keep alignments and escape line breaks\n\(markdown)")
    let csv = TableSerialization.csv(table)
    let expectedCSV = "名称,状态,备注\r\n构建,通过,\"包含, 逗号\"\r\n部署,\"失败 \"\"重试\"\"\",\"第一行\n第二行\"\r\n,,\r\n"
    precondition(csv == expectedCSV, "CSV must quote-wrap commas/quotes/newlines and keep empty cells\n\(csv)")

    let pipes = TableData(headers: ["a|b"], rows: [["x|y"], ["plain"]], alignments: [])
    precondition(TableSerialization.markdown(pipes).contains("a\\|b") && TableSerialization.markdown(pipes).contains("x\\|y"),
                 "Pipes in cell text escape")
    precondition(TableSerialization.markdown(pipes).contains("| a\\|b |\n| --- |"),
                 "Missing alignments fall back to plain separators")
    precondition(TableSerialization.csv(pipes) == "a|b\r\nx|y\r\nplain\r\n", "Pipes need no CSV quoting")

    let short = TableData(headers: ["a", "b", "c"], rows: [["only"]], alignments: [])
    precondition(TableSerialization.csv(short) == "a,b,c\r\nonly,,\r\n", "Short rows pad with empty cells")
    precondition(TableSerialization.markdown(short) == "| a | b | c |\n| --- | --- | --- |\n| only |  |  |",
                 "Short rows pad in Markdown too")

    func parsedTable(_ source: String) -> TableData {
        guard case let .table(headers, rows, alignments)? = ReplyDocument.parse(source).first else {
            preconditionFailure("Serialized Markdown must remain a table")
        }
        return TableData(headerCells: headers.map { TableCell(inlines: $0) },
                         cellRows: rows.map { $0.map { TableCell(inlines: $0) } }, alignments: alignments)
    }
    let literal = TableData(headers: ["literal"],
                            rows: [["*value*"], ["<name> & &amp;"], ["\\path []_~`!"], ["a|b"]], alignments: [])
    let literalRoundtrip = parsedTable(TableSerialization.markdown(literal))
    precondition(literalRoundtrip.rows == literal.rows,
                 "Markdown copy must preserve literal syntax and HTML-sensitive text")
    precondition(TableSerialization.csv(literal).contains("<name> & &amp;"), "CSV retains the original cell values")

    let formula = parsedTable("| formula | literal |\n| --- | --- |\n| $x^2$ | `*value*` |\n| $\\frac{a}{b}$ | `<name>` |\n")
    let formulaMarkdown = TableSerialization.markdown(formula)
    let formulaCSV = TableSerialization.csv(formula)
    precondition(!formulaMarkdown.contains("\u{FFFC}") && !formulaCSV.contains("\u{FFFC}"),
                 "Math attachments must export their formula, not their replacement character")
    precondition(formulaMarkdown.contains("$x^2$") && formulaCSV.contains("$x^2$"), "Both outputs preserve math content")
    precondition(parsedTable(formulaMarkdown).rows == formula.rows, "Math and literal code survive Markdown copy")
    let code = TableData(headerCells: [TableCell("code")],
                         cellRows: [[TableCell(parts: [.code("`tick`|*")])]], alignments: [])
    precondition(parsedTable(TableSerialization.markdown(code)).rows == code.rows, "Code fences and table pipes round-trip")
    print("PASS: table serialization keeps Chinese, quotes, commas, line breaks and empty cells")
}
