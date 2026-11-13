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
    // Whitespace-adjacent exhaustive walk, pinning the never-binding prefilter:
    // for every scalar, the byte path must equal exactly what the property
    // logic that decides the strict fallback dictates. A scalar detected as a
    // binder (or as non-ASCII whitespace) must yield the Character-accurate
    // split/join; every other scalar — including all scalars inside the pinned
    // never-binding ranges — must come back from the fast path as itself.
    // Scalars whose real fusion disagrees with the property logic (Thai/Lao/
    // Myanmar Sara-Am class, Apple corporate-PUA on macOS, emoji skin-tone
    // modifiers) are a pre-existing fast-path contract gap; this walk
    // characterizes them per platform, so a future fix — or Unicode drift —
    // fails here loudly instead of moving excerpts silently.
    var binding = 0, fastPath = 0, characterizedGap = 0
    var misses: [String] = []
    var probe: UInt32 = 0x80
    while probe < 0x110000 {
        if probe >= 0xD800 && probe <= 0xDFFF { probe = 0xE000; continue }
        if let scalar = Unicode.Scalar(probe) {
            let text = " " + String(scalar) + " "
            let category = scalar.properties.generalCategory
            let detected = probe == 0x200D || scalar.properties.isGraphemeExtend
                || category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
                || scalar.properties.isWhitespace
            // GB9b runs the other way: a Prepend scalar absorbs the trailing
            // space of the probe, which also forces the strict path.
            let prependFuses = (String(scalar) + " ").count == 1
            let expected = (detected || prependFuses)
                ? text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                : String(scalar)
            let got = text.collapsedWhitespace
            if got != expected {
                misses.append("U+\(String(probe, radix: 16, uppercase: true)) expected=\(expected.debugDescription) got=\(got.debugDescription)")
            }
            if detected { binding += 1 } else { fastPath += 1 }
            if !detected, (" " + String(scalar)).count == 1 { characterizedGap += 1 }
        }
        probe += 1
    }
    for miss in misses { print("WHITESPACE-ADJACENT MISMATCH \(miss)") }
    precondition(misses.isEmpty, "whitespace-adjacent walk: \(misses.count) mismatches")
    print("PASS: collapsedWhitespace whitespace-adjacent walk (\(binding) strict-path, \(fastPath) fast-path, \(characterizedGap) characterized gaps)")
    print("PASS: collapsedWhitespace prepend set matches stdlib fusion (\(fusing.count) fusing scalars)")
    print("PASS: collapsedWhitespace equals Character-accurate split/join on adversarial whitespace")
}
