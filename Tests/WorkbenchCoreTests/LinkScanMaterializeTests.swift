import Foundation
import WorkbenchCore

/// Round 16: `linkMatches` hands the data detector contiguous UTF-16 storage
/// instead of the lazily bridged Swift string, so DataDetectors reads the
/// buffer directly instead of paying per-character `character(at:)` bridging.
/// Detection results must be bit-for-bit identical: the same runs, links,
/// flags and math interactions come out of `parse`. The pin serializes parse
/// output to a canonical form and compares a seeded fuzz corpus against a
/// golden digest captured on the unmodified product (per platform, since the
/// Darwin data detector and the Linux regex fallback may legitimately differ
/// on edge shapes), plus fixed structural cases in checkReplyDocument's style
/// and a determinism sweep. The check compiles and passes on the matched
/// baseline (the digest does not depend on how the detector's input string is
/// backed).
func checkLinkScanContiguousUTF16() {
    // Canonical serialization of parse output (public fields only).
    func serRuns(_ runs: [ReplyInline]) -> String {
        runs.map { run in
            var flags = ""
            if run.strong { flags += "b" }
            if run.emphasis { flags += "i" }
            if run.code { flags += "c" }
            if run.strikethrough { flags += "s" }
            if let math = run.math { flags += "m{" + math + "}" }
            if let link = run.link { flags += "l{" + link.absoluteString + "}" }
            return flags.isEmpty ? run.text : run.text + "\u{27E8}" + flags + "\u{27E9}"
        }.joined(separator: "+")
    }
    func ser(_ blocks: [ReplyBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let runs): return "p[" + serRuns(runs) + "]"
            case .heading(let level, let runs): return "h\(level)[" + serRuns(runs) + "]"
            case .code(let language, let source): return "c(\(language)){" + source + "}"
            case .math(let latex): return "m{" + latex + "}"
            case .list(let items):
                return "l[" + items.map { item in item.marker + ":" + ser(item.blocks) }.joined(separator: ",") + "]"
            case .quote(let children): return "q[" + ser(children) + "]"
            case .table(let headers, let rows, let alignments):
                let head = headers.map { "[" + serRuns($0) + "]" }.joined(separator: ",")
                let body = rows.map { row in row.map { "[" + serRuns($0) + "]" }.joined(separator: ",") }.joined(separator: ";")
                let align = alignments.map { alignment in String(describing: alignment) }.joined(separator: ",")
                return "t(" + head + "|" + body + "|" + align + ")"
            case .alert(let kind, let children): return "a(" + kind.rawValue + ")[" + ser(children) + "]"
            case .rule: return "r"
            }
        }.joined(separator: ";")
    }
    func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    // Fixed structural cases (shapes both link backends agree on, mirroring
    // checkReplyDocument's style).
    let discussion = "https://github.com/example/repo/discussions/73"
    let surrounding = "帖子：**\(discussion)**，另见 http://example.com/path?q=1&n=2。"
    guard case .paragraph(let detected) = ReplyDocument.parse(surrounding)[0] else { fatalError("Expected prose links") }
    precondition(detected.map(\.text).joined() == "帖子：\(discussion)，另见 http://example.com/path?q=1&n=2。",
                 "link splitting must conserve the paragraph text")
    precondition(detected.filter { $0.link != nil }.map { $0.link!.absoluteString } == [discussion, "http://example.com/path?q=1&n=2"],
                 "both URLs must be detected with their exact ranges")

    // Math next to a URL: the $ pair lives inside one run and extracts; the
    // URL splits its own run and never gains math flags.
    let mathAndURL = "能量 $E=mc^2$ 与 https://example.com/rel 混合"
    guard case .paragraph(let mixed) = ReplyDocument.parse(mathAndURL)[0] else { fatalError("Expected paragraph") }
    precondition(mixed.contains { $0.math == "E=mc^2" }, "the complete $ pair must extract")
    precondition(mixed.contains { $0.link?.absoluteString == "https://example.com/rel" && $0.math == nil },
                 "the URL run must stay link-only")

    // A $ pair spanning a URL is split by link detection first, so the
    // per-run splitInline never sees a complete pair and the dollars stay
    // literal text — the interaction the materialization must not disturb.
    // A CJK character separates $ from the scheme: glued together ("$xhttps")
    // the Darwin data detector reads "xhttps" as an unknown scheme and keeps
    // no match, while the Linux regex fallback still splits — a backend
    // divergence this pin must not encode (the per-platform fuzz digest
    // covers such shapes on each backend separately).
    let spanning = "见$见https://example.com/a y$尾"
    guard case .paragraph(let spanRuns) = ReplyDocument.parse(spanning)[0] else { fatalError("Expected paragraph") }
    precondition(spanRuns.allSatisfy { $0.math == nil }, "link splitting must keep the spanning dollars literal")
    precondition(spanRuns.map(\.text).joined() == spanning, "run texts must re-join to the source")

    // Determinism sweep + corpus digest. The corpus mixes URL shapes with the
    // characters that interact with detection and math: dollars, CJK,
    // combining sequences, emoji, punctuation the backends trim differently.
    let pieces = ["http://a.co/x", "https://b.org/p?q=1#f", "www.c.net", "见", "处理", "$",
                  "x", " y ", "\n\n", "e\u{0301}", "\u{1F389}", "(", ")", "。", ".",
                  "mailto:c@d.e", "ftp://g.h/i", "**bold**", "`code http://j.k`",
                  "- item ", "> quote ", "$$t$$", "a.b", "1.5", "  ",
                  "已经处理http://m.n/o混合"]
    var seed: UInt64 = 0x7231_366C_6E00_0016
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 11
    }
    var corpus: [String] = []
    for _ in 0..<3000 {
        var text = ""
        for _ in 0..<(1 + Int(next() % 6)) { text += pieces[Int(next() % UInt64(pieces.count))] }
        corpus.append(text)
    }
    var digest: UInt64 = 0
    for text in corpus {
        let first = ser(ReplyDocument.parse(text))
        precondition(ser(ReplyDocument.parse(text)) == first, "parse must be deterministic")
        digest = (digest ^ fnv1a(first)) &* 0x100_0000_01b3
    }
    // Goldens captured on the UNMODIFIED product (15f612f + these tests):
    // macOS 27.0.1 arm64 (Apple Swift, NSDataDetector) and Alibaba Cloud
    // Linux 3 x86-64 (Swift 6.3.3, regex fallback) — the two backends
    // legitimately differ on edge shapes (trailing CJK in URLs, unknown
    // schemes like a glued "xhttps"), so each platform pins its own digest.
    // The materialization re-runs reproduced both digests exactly on their
    // platform (Mac base == cand == 97e345c9136b50c8, 98 PASS both sides).
    let expected: String
    #if canImport(Darwin)
    expected = "97e345c9136b50c8"
    #else
    expected = "5dd61f867727616a"
    #endif
    let got = String(format: "%016llx", digest)
    precondition(got == expected, "link-scan corpus digest changed: \(got) != \(expected)")
    precondition(corpus.count == 3000)
    print("PASS: link detection over contiguous UTF-16 matches the pinned corpus (3000 fuzz texts + structural cases, digest \(got))")
}
