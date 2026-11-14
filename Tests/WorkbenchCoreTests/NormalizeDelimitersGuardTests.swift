import Foundation
import WorkbenchCore

/// Round 17: `ReplyMath.normalizeDelimiters`'s entry guard moved from two
/// grapheme-aware `contains` substring searches to a single UTF-8 byte scan
/// with a grapheme-exactness argument (ASCII next byte ⇒ the paren Character
/// cannot be extended) and the original searches kept as the fallback for
/// inconclusive pairs. The observable contract — which sources get the
/// delimiter scan at all, and therefore the exact parse output — must not
/// move by a single bit, including the guard/scan mismatch corners: a
/// paren extended by a combining mark is invisible to `contains("\\(")` but
/// the byte-level Boundaries pass converts such a pair anyway whenever
/// another exact pair opened the gate.
///
/// The fuzz corpus deliberately avoids URL shapes (no dots-with-schemes,
/// colons, slashes, at-signs) so link detection never fires differently
/// between the Darwin data detector and the Linux regex fallback: one golden
/// digest holds on every platform and CI can enforce it (the round-16
/// lesson — DataDetectors output is macOS-build-dependent). It likewise
/// excludes GB9b Prepend scalars: the re-review's counterexample
/// ("\u{0600}\(x\)") exposed that the ORIGINAL guard already behaved
/// differently per platform there. macOS Characters fuse a Prepend sign with
/// the backslash (GB9b), so contains("\(") misses and the source stays
/// literal. On Linux the corelibs substring SEARCH does not apply GB9b (it
/// admits the pair and the source converts) while the stdlib Character
/// iteration used downstream DOES fuse (the converted "$" absorbs the sign,
/// so no math extracts) — mechanism inferred from the probe records
/// (round-17/checks/), behavior pinned per platform as-is. The byte guard's
/// inconclusive-pair fallback delegates to each platform's own contains, so
/// it reproduces both legacy behaviors exactly; the structural cases pin
/// each side.
func checkNormalizeDelimitersByteGuard() {
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
    func joinedParagraphText(_ blocks: [ReplyBlock]) -> String {
        blocks.map { block -> String in
            if case .paragraph(let runs) = block { return runs.map(\.text).joined() }
            return ""
        }.joined(separator: "\n")
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

    // --- structural cases through the public parse path ---
    // Inline and display conversion.
    precondition(hasMath(ReplyDocument.parse("x\\(a+b\\)y")), "exact inline pair converts")
    if case .math(let latex)? = ReplyDocument.parse("\\[E=mc^2\\]").first {
        precondition(latex == "E=mc^2", "display pair converts, got \(latex)")
    } else { fatalError("display math block expected") }

    // Paren extended by a combining mark, ALONE: `contains("\\(")` misses it
    // (the paren's Character carries the mark), so the guard keeps the source
    // unchanged — literal text, no math.
    let extended = "\\(\u{0308}x\\)"
    let extendedBlocks = ReplyDocument.parse(extended)
    precondition(!hasMath(extendedBlocks), "extended-paren pair alone must stay literal")
    // Exact output, not just absence of math: cmark resolves the backslash
    // escapes, so the literal paragraph is "(◌̈x)". A wrongly admitted
    // source would normalize to "$◌̈x$" — splitInline still extracts no math
    // there (the opener's Character carries the mark), so only the text
    // comparison catches the admission change (re-review finding 4).
    // Both platforms: the mark-carrying paren Character never equals "(",
    // so neither contains search admits and cmark unescapes to "(◌̈x)".
    precondition(joinedParagraphText(extendedBlocks) == "(\u{0308}x)",
                 "extended-paren source stays byte-literal on both platforms")

    // Extended paren WITH an earlier exact pair: the gate opens on the exact
    // pair and the byte-level Boundaries pass converts BOTH pairs — the
    // documented guard/scan asymmetry the byte guard must reproduce exactly.
    let mixed = "\\(a\\) \\(\u{0308}b\\)"
    let mixedBlocks = ReplyDocument.parse(mixed)
    precondition(hasMath(mixedBlocks), "exact pair opens the gate for the extended one")
    // Exact shape: normalization converts BOTH pairs (the byte-level
    // Boundaries pass runs once the gate opened), giving "$a$ $◌̈b$";
    // splitInline extracts only the first pair as math (the second opener's
    // Character carries the mark), so the literal tail keeps the dollars.
    precondition(ser(mixedBlocks).contains("m{a}"), "the first pair extracts as math")
    precondition(joinedParagraphText(mixedBlocks) == "\u{FFFC} $\u{0308}b$",
                 "mixed source exact shape")

    // Even backslash run before the paren: guard sees the byte pair, the scan
    // finds no odd-run marker and returns the source unchanged.
    precondition(!hasMath(ReplyDocument.parse("\\\\(x\\\\)")), "even backslash runs stay literal")
    // Code span and fenced block isolate their contents.
    precondition(!hasMath(ReplyDocument.parse("`\\(x\\)`")), "code span content stays literal")
    precondition(!hasMath(ReplyDocument.parse("```\n\\(x\\)\n```")), "fenced content stays literal")
    // CRLF and CJK adjacency.
    precondition(hasMath(ReplyDocument.parse("\\(x\\)\r\n\\[y\\]")), "CRLF-separated pairs convert")
    precondition(hasMath(ReplyDocument.parse("汉\\(甲\\)汉")), "CJK-adjacent pair converts")
    // Bracket pair.
    precondition(hasMath(ReplyDocument.parse("p\\[q\\]s")), "bracket pair converts")

    // GB9b Prepend corner (re-review finding 1): U+0600 fuses FORWARD with
    // the backslash into one Character, so the original contains("\(") never
    // matches and the whole source must stay literal — the byte pair alone
    // must NOT fast-accept. Asserted on the exact cmark-unescaped text.
    let prepend = "\u{0600}\\(x\\)"
    let prependBlocks = ReplyDocument.parse(prepend)
    precondition(!hasMath(prependBlocks), "Prepend-fused backslash must not open the gate")
    #if canImport(Darwin)
    // macOS Characters fuse U+0600 with the backslash (GB9b), so the
    // grapheme-aware contains("\(") never matches: the source stays literal
    // and cmark resolves the escapes to "(x)".
    precondition(joinedParagraphText(prependBlocks) == "\u{0600}(x)",
                 "macOS: Prepend-fused source must stay literal")
    #else
    // Legacy corelibs behavior: its substring search matches the pair
    // through the Prepend sign, so the source converts — but the converted
    // opening "$" then fuses with the sign into one Character and splitInline
    // extracts no math. The guard's fallback reproduces exactly this.
    precondition(joinedParagraphText(prependBlocks) == "\u{0600}$x$",
                 "Linux: legacy conversion with sign-fused dollars")
    #endif
    precondition(!hasMath(ReplyDocument.parse("\u{0600}\\(")), "Prepend-fused EOF pair stays literal")
    // Positive control for the fallback flavor: a CJK (non-Prepend,
    // non-ASCII) predecessor is inconclusive at byte level, falls back to
    // the grapheme search, and admits exactly as before.
    let cjkAdjacent = "汉\\(x\\)汉"
    precondition(hasMath(ReplyDocument.parse(cjkAdjacent)), "CJK-adjacent pair converts via fallback")
    precondition(joinedParagraphText(ReplyDocument.parse(cjkAdjacent)) == "汉\u{FFFC}汉",
                 "CJK-adjacent exact shape")

    // --- fuzz corpus digest (platform-independent by construction) ---
    let pieces = ["\\(", "\\)", "\\[", "\\]", "\\", "(", ")", "[", "]", "$", "$$",
                  "`", "``", "~~~", "x", " ", "\n", "\r\n", "\u{0308}", "\u{0301}",
                  "e\u{0301}", "汉", "a\tb", "\\x", "\u{3000}", "\u{2028}", "\u{00A0}",
                  "mark\u{0300}\\(", "\\(mark\u{0300}", "**b**", "> q", "- i"]
    precondition(!pieces.contains(where: { $0.contains(".") || $0.contains(":") || $0.contains("/") || $0.contains("@") }),
                 "corpus must stay clear of URL shapes so one digest holds on every platform")
    var seed: UInt64 = 0x7231_376E_6400_0017
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
    precondition(mathTexts > 100, "the corpus must exercise the converting path densely, got \(mathTexts)")
    // Golden captured on the UNMODIFIED product (76940c0 + this pin) and
    // identical on macOS 27.0.1 arm64 and Alibaba Cloud Linux 3 x86-64 — the
    // URL-free corpus keeps both link backends out, so one value pins every
    // platform (and CI). The fuzz pieces deliberately exclude GB9b Prepend
    // scalars: there the two platforms' substring-search semantics for the
    // OLD guard legitimately diverge (structural cases above pin each
    // platform's own legacy behavior), which would split the golden.
    let expected = "d90ac2cad4b58020"
    let got = String(format: "%016llx", digest)
    precondition(got == expected, "normalize-delimiters guard corpus digest changed: \(got) != \(expected)")
    print("PASS: normalizeDelimiters byte guard preserves parse output across structural corners and 3000 fuzz texts (digest \(got), \(mathTexts) converting)")
}
