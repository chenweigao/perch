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
        "arabic \u{600} number sign", "\u{600} leading prepend",
        "malayalam \u{D4E} letter", "double \u{600}\u{600} prepend",
        "kaithi \u{110BD} digit", "a\u{600}b c",
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

    // GB9b: a Prepend scalar absorbs a following space into its own Character.
    // The fast path bails on a pinned Prepend set; walk every scalar and
    // compare against this toolchain's own grapheme breaking (fusion = the
    // scalar plus a space form one Character), so a Unicode data update
    // surfaces here instead of diverging silently.
    var fusing: [UInt32] = []
    var value: UInt32 = 0x80
    while value < 0x110000 {
        if value >= 0xD800 && value <= 0xDFFF { value = 0xE000; continue }
        if let scalar = Unicode.Scalar(value) {
            var probe = String(scalar)
            probe.append(" ")
            if probe.count == 1 { fusing.append(value) }
        }
        value += 1
    }
    for fusingValue in fusing {
        guard let scalar = Unicode.Scalar(fusingValue) else { continue }
        let text = "x" + String(scalar) + " y"
        let expected = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        precondition(text.collapsedWhitespace == expected,
                     "prepend fast-path miss at U+\(String(fusingValue, radix: 16, uppercase: true))")
    }
    print("PASS: collapsedWhitespace prepend set matches stdlib fusion (\(fusing.count) fusing scalars)")
    print("PASS: collapsedWhitespace equals Character-accurate split/join on adversarial whitespace")
}
