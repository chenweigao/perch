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
    print("PASS: table serialization keeps Chinese, quotes, commas, line breaks and empty cells")
}
