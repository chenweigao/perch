import Foundation
import WorkbenchCore

func checkReplyStreamParser() {
    func require(_ value: Bool, _ message: String = "check failed") { precondition(value, message) }

    // Every append-only prefix must parse exactly like a full parse of it.
    func stream(_ document: String, chunk: Int, documentLinks: Bool = false) {
        var parser = ReplyStreamParser(documentLinks: documentLinks)
        var end = document.startIndex
        while end < document.endIndex {
            end = document.index(end, offsetBy: chunk, limitedBy: document.endIndex) ?? document.endIndex
            let prefix = String(document[..<end])
            let incremental = parser.update(prefix)
            let full = ReplyDocument.parse(prefix, documentLinks: documentLinks)
            require(incremental == full, "incremental parse diverged at \(prefix.utf8.count) bytes: …\(prefix.suffix(40))")
        }
        require(parser.update(document) == ReplyDocument.parse(document, documentLinks: documentLinks), "final update diverged")
    }

    let documents = [
        "Intro paragraph with **bold** and `code`.\n\n## Heading\n\nMore text here.\n\n- one\n- two\n\nDone.",
        "Title\n===\n\nBody\n\nSub\n---\n\nEnd.",
        "Before\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nAfter\n\n```py\nprint(1)\n```\n\nTail.",
        "- a\n  - nested\n- b\n\n1. first\n2. second\n\n- [ ] task\n- [x] done",
        "> quoted text\n> more\n\n> [!NOTE]\n> alert body\n\nOutside.",
        "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nAfter.",
        "*\n\n**\n\n***\n\n- - -\n\nEnd.",
        "Inline $x^2$ here.\n\n$$\nE = mc^2\n$$\n\nTail.",
        "See [foo] and [bar].\n\n[foo]: https://example.com\n[bar]: https://example.org\n\nMore [foo].",
        #"Inline \(x^2\) and display:\n\n\[E = mc^2\]\n\nTail."#,
        "中文段落 with 😀 emoji.\n\n## 标题\n\n- 项目一\n- 项目二\n\n结尾 👩‍💻.",
        "> quote\nlazy\n\npara\ncontinued line",
        "<div>\nraw\n</div>\n\nAfter.",
        "intro [foo]\n\n[foo]: /url\n\noutro [foo]",
        "para\n\n[foo]",
        "",
        "\n\n\n",
        "   # indented heading\n\n  - indented list\n\nEnd.",
    ]
    for document in documents {
        stream(document, chunk: 1)
        stream(document, chunk: 7)
        stream(document, chunk: 64)
        stream(document.replacingOccurrences(of: "\n", with: "\r\n"), chunk: 1)
        stream(document.replacingOccurrences(of: "\n", with: "\r"), chunk: 7)
    }
    stream("A [link](https://example.com) and a file [f](Sources/Main.swift).", chunk: 3, documentLinks: true)

    // A definition completing across the append boundary must stay correct.
    var straddle = ReplyStreamParser()
    _ = straddle.update("intro [foo]\n\n[foo]")
    require(straddle.update("intro [foo]\n\n[foo]: /url\n\noutro") == ReplyDocument.parse("intro [foo]\n\n[foo]: /url\n\noutro"))

    // Replacements and shrinks fall back to full parses.
    var edits = ReplyStreamParser()
    _ = edits.update("# Title\n\nBody text.")
    require(edits.update("# Title\n\nBody changed.") == ReplyDocument.parse("# Title\n\nBody changed."))
    require(edits.update("# Title") == ReplyDocument.parse("# Title"))
    require(edits.update("") == ReplyDocument.parse(""))
    require(edits.update("Fresh start.") == ReplyDocument.parse("Fresh start."))
    print("PASS: incremental reply parse matches full parses at every streaming prefix")
}
