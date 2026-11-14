import Foundation
import WorkbenchCore

/// Round 19: `ReplyMath.splitInline`'s per-run guard moved from the
/// Character-level `run.text.contains("$")` to the byte-level
/// `run.text.utf8.contains(36)`. Equivalence argument: 0x24 is
/// self-synchronizing in UTF-8, so a Character equal to "$" implies the byte
/// (superset direction); for the extra admitted runs — every "$" scalar fused
/// into a larger Character, e.g. GB9b after a Prepend scalar — `split` walks
/// Characters, finds no bare "$", and its terminal flush returns a single run
/// with the identical text and flags, so the parse output is value-identical.
///
/// The pin freezes a seeded fuzz corpus of $-rich texts (currency, math,
/// Prepend fusion, combining marks, ZWJ, CJK content, digit-after-closer and
/// whitespace-adjacency rules) as a serialized parse-output digest, plus
/// structural cases for every documented splitInline rule. The corpus avoids
/// URL shapes so neither link backend feeds the digest (round-16/17 lesson);
/// splitInline itself is pure stdlib Character logic, so ONE golden is
/// expected to hold across platforms — captured on the unmodified product and
/// verified on both before embedding.
func checkSplitInlineByteGuard() {
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
    func hasMath(_ blocks: [ReplyBlock]) -> Bool {
        blocks.contains { block in
            switch block {
            case .math: return true
            case .paragraph(let runs), .heading(_, let runs): return runs.contains { $0.math != nil }
            case .list(let items): return items.contains { hasMath($0.blocks) }
            case .quote(let children), .alert(_, let children): return hasMath(children)
            case .table(let headers, let rows, _):
                return headers.contains { hasMath([.paragraph($0)]) }
                    || rows.contains { $0.contains { hasMath([.paragraph($0)]) } }
            case .code, .rule: return false
            }
        }
    }

    // --- structural cases: every documented splitInline rule ---
    precondition(hasMath(ReplyDocument.parse("见 $x$ 尾")), "bare inline pair extracts")
    precondition(!hasMath(ReplyDocument.parse("价格 $100 与 $200 并列")),
                 "digit right after the closer keeps currency literal")
    precondition(!hasMath(ReplyDocument.parse("a $ b$c")), "whitespace after the opener is not math")
    precondition(!hasMath(ReplyDocument.parse("no dollars at all 完全没有")), "$-free runs skip")
    precondition(hasMath(ReplyDocument.parse("$甲$")), "CJK math content extracts")
    // Prepend-fused dollar: the Character carries U+0600, so no bare "$"
    // exists; the byte guard admits the run and split() no-ops value-equal.
    let prependDollar = "\u{0600}$x$"
    precondition(!hasMath(ReplyDocument.parse(prependDollar)),
                 "Prepend-fused dollars never extract")
    // Combining mark on the opener: Character "$◌̈" is not "$".
    precondition(!hasMath(ReplyDocument.parse("$\u{0308}x$")), "mark-fused opener does not extract")
    // Emphasis around math: flags ride through the split.
    let emphasized = ReplyDocument.parse("**能量 $E$ 守恒**")
    precondition(hasMath(emphasized), "math inside strong extracts")
    if case .paragraph(let runs)? = emphasized.first {
        precondition(runs.first { $0.math != nil }?.strong == true, "the math run keeps the strong flag")
    } else { fatalError("expected paragraph") }
    // Code isolation: `$` inside code never becomes math (run.code skips),
    // while a sibling pair in the same paragraph still extracts.
    precondition(!hasMath(ReplyDocument.parse("`$x$`")), "code span dollars stay literal")
    if case .paragraph(let mixedRuns)? = ReplyDocument.parse("`$x$` 与 $y$").first {
        precondition(mixedRuns.contains { $0.code && $0.text == "$x$" && $0.math == nil },
                     "the code run keeps its literal dollars")
        precondition(mixedRuns.contains { $0.math == "y" }, "the sibling pair still extracts")
    } else { fatalError("expected paragraph") }

    // --- fuzz corpus digest ---
    let pieces = ["$", "$$", "x", " y ", "见", "甲", "\u{0308}", "\u{0301}", "$\u{0308}",
                  "\u{0600}", "\u{0600}$", "$x$", "100", "5", " ", "\n", "\n\n", "**b**",
                  "`c`", "$ ", " $", "e\u{0301}", "\u{1F389}", "\u{200D}", "a$1", "$甲$",
                  "> q", "- i", "# h", "\\", "~~s~~"]
    precondition(!pieces.contains(where: { $0.contains("://") || $0.contains("www") || $0.contains("@") }),
                 "corpus must stay clear of URL shapes so one digest holds on every platform")
    var seed: UInt64 = 0x7231_3973_7000_0019
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 11
    }
    var corpus: [String] = []
    for _ in 0..<3000 {
        var text = ""
        for _ in 0..<(1 + Int(next() % 8)) { text += pieces[Int(next() % UInt64(pieces.count))] }
        corpus.append(text)
    }
    var digest: UInt64 = 0
    var mathTexts = 0
    for text in corpus {
        let first = ser(ReplyDocument.parse(text))
        precondition(ser(ReplyDocument.parse(text)) == first, "parse must be deterministic")
        if first.contains("m{") { mathTexts += 1 }
        digest = (digest ^ fnv1a(first)) &* 0x100_0000_01b3
    }
    precondition(mathTexts > 200, "the corpus must exercise math extraction densely, got \(mathTexts)")
    // Golden captured on the UNMODIFIED product (89e5976 + this pin) and
    // identical on all four combinations of {Mac mini macOS 27.0.1 / Swift 6.4,
    // Alibaba Cloud Linux 3 / Swift 6.3.3} × {baseline, candidate} —
    // splitInline is pure stdlib Character logic (no Foundation link backends
    // involved), so ONE value pins every platform and CI can enforce it.
    let expected = "5d1506ed4a822a53"
    let got = String(format: "%016llx", digest)
    precondition(got == expected, "split-inline guard corpus digest changed: \(got) != \(expected)")
    print("PASS: splitInline byte guard preserves parse output across structural rules and 3000 fuzz texts (digest \(got), \(mathTexts) extracting)")
}
