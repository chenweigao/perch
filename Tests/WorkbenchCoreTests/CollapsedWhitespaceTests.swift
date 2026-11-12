import Foundation
import WorkbenchCore

/// The byte fast path of `collapsedWhitespace` must equal the Character-accurate
/// split/join on adversarial whitespace: non-ASCII whitespace (U+3000, NBSP,
/// U+2000), combining marks right after a space (they fuse into one
/// non-whitespace Character), CRLF, ZWJ sequences and variation selectors.
func checkCollapsedWhitespace() {
    let cases = [
        "", " ", "   ", "\t", "\r\n", "a", "  a  ",
        "plain 多个   空格", "tab\ta", "crlf\r\nx", "a\r\rb",
        "中文\u{3000}中文", "nbsp\u{A0}y", "en quad\u{2000}here",
        "para sep\u{2029}x", "ogham\u{1680}y", "narrow nbsp\u{202F}z",
        "mark after space \u{301}combines", "a\u{301} b", " x\u{903}devanagari",
        "emoji 👨\u{200D}👩\u{200D}👧 family", "sel\u{FE0F} x",
        "space then zwj \u{200D}x", "mix \u{1680} ogham \u{2029} para",
        "trailing space before mark \u{301}", "\u{3000}leading ideographic",
        String(repeating: "word 中文\tmixed ", count: 120),
    ]
    for text in cases {
        let expected = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let got = text.collapsedWhitespace
        if got != expected {
            print("MISMATCH input=\(text.debugDescription) expected=\(expected.debugDescription) got=\(got.debugDescription)")
        }
        precondition(got == expected, "collapsedWhitespace mismatch for \(text.debugDescription)")
    }
    var corpus = ""
    let pieces = ["a", " ", "\t", "中", "\u{3000}", "\u{301}", "\r\n", "👨\u{200D}👩", "\u{A0}", "x", "\u{903}", "\u{200A}"]
    for i in 0..<3000 { corpus += pieces[i % pieces.count] }
    let corpusExpected = corpus.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let corpusGot = corpus.collapsedWhitespace
    if corpusGot != corpusExpected {
        var divergence = min(corpusGot.count, corpusExpected.count)
        for (offset, pair) in zip(corpusGot, corpusExpected).enumerated() where pair.0 != pair.1 {
            divergence = offset
            break
        }
        let window = 12
        print("MISMATCH corpus at char \(divergence) (lens \(corpusGot.count)/\(corpusExpected.count)): got \(corpusGot.prefix(divergence + window).suffix(2 * window).debugDescription) expected \(corpusExpected.prefix(divergence + window).suffix(2 * window).debugDescription)")
    }
    precondition(corpusGot == corpusExpected, "collapsedWhitespace corpus mismatch")
    print("PASS: collapsedWhitespace equals Character-accurate split/join on adversarial whitespace")
}
