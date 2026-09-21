import Foundation
import WorkbenchCore

func checkReplyDocument() {
    func text(_ runs: [ReplyInline]) -> String { runs.map(\.text).joined() }
    let paragraphs = ReplyDocument.parse("中文第一行\n仍在同一段。\n\n第二段。")
    guard paragraphs.count == 2, case .paragraph(let first) = paragraphs[0] else { fatalError("Paragraphs must follow Markdown, not source lines") }
    precondition(text(first) == "中文第一行 仍在同一段。")

    let lists = ReplyDocument.parse("3. 第一项\n4. 第二项\n\n   继续说明\n   - 嵌套项目\n\n- [x] 已完成\n- [ ] 未完成")
    guard case .list(let ordered) = lists[0], case .list(let tasks) = lists[1] else { fatalError("Expected lists") }
    precondition(ordered.map(\.marker) == ["3.", "4."] && ordered[1].blocks.count == 3)
    precondition(tasks.map(\.marker) == ["☑", "☐"])

    let table = ReplyDocument.parse("| 名称 | 数量 |\n| :--- | ---: |\n| A\\|B | **2** |")
    guard case .table(let headers, let rows, let alignments) = table[0] else { fatalError("Expected native table") }
    precondition(headers.count == 2 && text(rows[0][0]) == "A|B" && rows[0][1][0].strong)
    precondition(alignments == [.leading, .trailing])

    let partial = ReplyDocument.parse("正文\n\n````swift\nlet example = \"```\"\n  print(example)\n")
    guard case .code(let language, let code) = partial[1] else { fatalError("Streaming unclosed fence must remain code") }
    precondition(language == "swift" && code == "let example = \"```\"\n  print(example)")
    guard case .paragraph(let inline) = ReplyDocument.parse("**粗体**、*斜体*、`code`、~~旧~~ [链接](https://example.com) [无效](javascript:alert)")[0] else { fatalError("Expected inlines") }
    precondition(inline.contains { $0.strong } && inline.contains { $0.emphasis } && inline.contains { $0.code } && inline.contains { $0.strikethrough })
    precondition(inline.first { $0.text == "链接" }?.link?.scheme == "https")
    precondition(inline.first { $0.text == "无效" }?.link == nil)
    let discussion = "https://github.com/deepseek-ai/deepseek-harness/discussions/7358"
    guard case .paragraph(let bare) = ReplyDocument.parse(discussion)[0] else { fatalError("Expected bare URL paragraph") }
    precondition(text(bare) == discussion && bare.count == 1 && bare[0].link?.absoluteString == discussion)
    let surrounding = "帖子：**\(discussion)**，另见 http://example.com/path?q=1&n=2。"
    guard case .paragraph(let detected) = ReplyDocument.parse(surrounding)[0] else { fatalError("Expected prose links") }
    precondition(text(detected) == "帖子：\(discussion)，另见 http://example.com/path?q=1&n=2。")
    precondition(detected.filter { $0.link != nil }.map { $0.link!.absoluteString } == [discussion, "http://example.com/path?q=1&n=2"])
    precondition(detected.first { $0.link?.absoluteString == discussion }?.strong == true)
    guard case .paragraph(let preserved) = ReplyDocument.parse("`\(discussion)` [\(discussion)](https://example.com/target)")[0] else { fatalError("Expected code and explicit link") }
    precondition(preserved.first { $0.code }?.link == nil)
    precondition(preserved.filter { $0.link != nil }.map { $0.link!.absoluteString } == ["https://example.com/target"])
    guard case .code(_, let urlCode) = ReplyDocument.parse("```\n\(discussion)\n```")[0] else { fatalError("Expected URL code block") }
    precondition(urlCode == discussion)
    guard case .heading(_, let heading) = ReplyDocument.parse("## \(discussion)")[0],
          case .list(let linkedList) = ReplyDocument.parse("- \(discussion)")[0],
          case .paragraph(let item) = linkedList[0].blocks[0],
          case .table(_, let linkedRows, _) = ReplyDocument.parse("| 链接 |\n| --- |\n| \(discussion) |")[0] else { fatalError("Expected links in document blocks") }
    precondition(heading[0].link?.absoluteString == discussion && item[0].link?.absoluteString == discussion && linkedRows[0][0][0].link?.absoluteString == discussion)
    precondition(ReplyDocument.parse("").isEmpty)
    // Every partial update is valid input while providers stream fences, tables and emphasis.
    let streaming = "## 中文\n\n**结果**\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```sh\nprintf '你好'\n```"
    for end in streaming.indices { _ = ReplyDocument.parse(String(streaming[..<end])) }
    print("PASS: reply paragraphs, nested lists, tables, safe links, bare URLs and partial streaming Markdown")
}
