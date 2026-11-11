import Foundation
import WorkbenchCore

func checkStreamingTextReveal() {
    let prefix = "已显示的正文。"
    var reveal = StreamingTextReveal(prefix)
    precondition(reveal.text == prefix && !reveal.hasBacklog, "Opening history never replays its text")
    let burst = prefix + String(repeating: "平滑追加中文正文与代码。", count: 80)
    reveal.update(burst, smoothing: true)
    precondition(reveal.text == prefix && reveal.hasBacklog, "A cumulative burst starts at the existing prefix")
    var previous = prefix
    for _ in 0..<30 {
        reveal.advance(elapsed: StreamingTextReveal.frameInterval)
        precondition(reveal.text.hasPrefix(previous) && burst.hasPrefix(reveal.text), "Release stays monotonic and never invents text")
        previous = reveal.text
    }
    precondition(reveal.text == burst && !reveal.hasBacklog, "A large burst catches up within 500 ms")
    reveal.update(burst + "未显示的尾部", smoothing: true)
    reveal.update("修订后的同一条消息", smoothing: true)
    precondition(reveal.text == "修订后的同一条消息" && !reveal.hasBacklog, "Replacements cannot retain stale characters")

    let unicode = "👩🏽‍💻é🇨🇳中文👨‍👩‍👧‍👦"
    var characters = StreamingTextReveal("")
    characters.update(unicode, smoothing: true)
    let boundaries = (0...unicode.count).map { String(unicode.prefix($0)) }
    while characters.hasBacklog {
        characters.advance(elapsed: StreamingTextReveal.frameInterval)
        precondition(boundaries.contains(characters.text), "Every visible prefix ends on a complete grapheme")
    }
    precondition(characters.text == unicode)

    var fractional = StreamingTextReveal("")
    fractional.update(String(repeating: "a", count: 12), smoothing: true)
    for _ in 0..<6 { fractional.advance(elapsed: 1.0 / 120) }
    precondition(fractional.text.count == 3, "Fractional frames preserve the 60 characters/sec base rate")
    fractional.update("终止立即显示的完整正文", smoothing: false)
    precondition(!fractional.hasBacklog && fractional.text == "终止立即显示的完整正文")
    fractional.update(String(repeating: "长", count: StreamingTextReveal.maximumLength + 1), smoothing: true)
    precondition(!fractional.hasBacklog && fractional.text.count == StreamingTextReveal.maximumLength + 1,
                 "Oversized output stays immediate and owns no release queue")

    var continuous = StreamingTextReveal("")
    var latest = ""
    for _ in 0..<60 {
        latest += "继续流式追加"
        continuous.update(latest, smoothing: true)
        continuous.advance(elapsed: StreamingTextReveal.frameInterval)
    }
    continuous.update(latest + "最终结果", smoothing: false)
    precondition(continuous.text == latest + "最终结果" && !continuous.hasBacklog, "Completion flushes the newest target without dropping a delta")
    print("PASS: bounded adaptive text release, Unicode boundaries, replacement and immediate completion")
}

func checkReplyStreamSnapshot() {
    let markdown = "# 已有标题\n\n**中文 👩🏽‍💻 é** 与 [链接](https://example.com)\n\n```swift\nlet value = 1\n```"
    let blocks = ReplyDocument.parse(markdown)
    let snapshot = ReplyStreamSnapshot(blocks: blocks)
    precondition(snapshot.text == "已有标题\n\n中文 👩🏽‍💻 é 与 链接\n\nlet value = 1",
                 "Release follows visible content without replaying Markdown delimiters")
    precondition(snapshot.prefix(utf16Length: 0).isEmpty)
    precondition(snapshot.prefix(utf16Length: snapshot.utf16Length) == blocks,
                 "Completion preserves the exact parsed document, including links and code")
    let partial = snapshot.prefix(utf16Length: "已有标题\n\n中文 👩".utf16.count)
    guard case .paragraph(let runs) = partial.last else { preconditionFailure("The first prose block must remain prose") }
    precondition(runs.map(\.text).joined() == "中文 👩🏽‍💻" && runs.first?.strong == true,
                 "A prefix preserves its styling and the full joined emoji")

    let complex = ReplyDocument.parse("> quoted\n\n- first\n- **second**\n\n---\n\n| A | B |\n|---|---|\n| C | D |\n\n$$x^2$$\n\n> [!NOTE]\n> alert")
    let rich = ReplyStreamSnapshot(blocks: complex)
    precondition(rich.prefix(utf16Length: rich.utf16Length) == complex,
                 "Lists, quotes, tables, math and alerts keep their final structure")
    guard case .quote(let inner) = rich.prefix(utf16Length: 3).first,
          case .paragraph(let quote) = inner.first else { preconditionFailure("Quote prefixes must retain their container") }
    precondition(quote.map(\.text).joined() == "quo")
    let table = ReplyStreamSnapshot(blocks: ReplyDocument.parse("| A | B |\n|---|---|\n| C | D |"))
    guard case .table(let headers, let rows, let alignment) = table.prefix(utf16Length: 5).first else {
        preconditionFailure("Streaming table prefixes must retain a complete column layout")
    }
    precondition(headers.map { $0.map(\.text).joined() } == ["A", "B"]
                 && rows.map { $0.map { $0.map(\.text).joined() } } == [["C", ""]] && alignment.count == 2)
    print("PASS: parsed-block release retains Unicode, styling, links and complete rich Markdown")
}
