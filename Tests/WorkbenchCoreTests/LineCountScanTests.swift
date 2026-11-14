import Foundation
import WorkbenchCore

/// Round 15's SWAR line-count scan must preserve the documented separator
/// contract exactly: a separator is an LF whose previous byte is not a CR
/// (CR LF is one Character and does not separate), and a trailing newline is
/// counted (ccgui parity). The oracle is the Character-based split the
/// contract was written against — `split(separator: "\n",
/// omittingEmptySubsequences: false)` — with the empty string's single line
/// handled explicitly (Swift's split yields no elements there while both the
/// byte rule and ccgui's JS split count one line).
///
/// Every case goes through the public derive path (a synthesized Write call),
/// so the pin covers the shipped call chain, not a private helper. Coverage:
/// exhaustive piece combinations {\n, \r, \r\n, \n\r, \u{000B}, \u{000C},
/// a, 汉, ""} to depth 4,
/// a word-boundary length grid (0…40 around the 8-byte scan words, with
/// separators at the boundaries and a leading-CR sandwich), and 20,000 seeded
/// fuzz strings. The check compiles and passes on the matched baseline (the
/// scalar scan it replaces has the same contract).
func checkEditStatsLineCountScan() throws {
    func oracle(_ text: String) -> Int {
        text.isEmpty ? 1 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
    func writeWindow(_ content: String) throws -> [KimiMessage] {
        let raw: [[String: Any]] = [
            ["id": "w0", "role": "assistant", "created_at": "1", "content": [
                ["type": "tool_use", "tool_call_id": "w0", "tool_name": "Write",
                 "input": ["file_path": "/fixture/F.swift", "content": content]]]]]
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    var cases = 0
    var vtffCases = 0
    var adjacencyCases = 0
    func check(_ text: String) throws {
        let stats = SessionEditStats.derive(from: try writeWindow(text))
        let got = stats?.total.additions ?? -1
        let want = oracle(text)
        precondition(got == want && stats?.total.deletions == 0,
                     "line count mismatch for bytes \(Array(text.utf8)): got \(got), want \(want)")
        cases += 1
        let caseBytes = Array(text.utf8)
        if caseBytes.contains(0x0B) || caseBytes.contains(0x0C) { vtffCases += 1 }
        // The borrow-propagation defect needs the offending ADJACENCY (an LF
        // immediately followed by VT, or a CR immediately followed by FF),
        // not mere presence of either byte; count both notions separately.
        if zip(caseBytes, caseBytes.dropFirst()).contains(where: {
            ($0 == 0x0A && $1 == 0x0B) || ($0 == 0x0D && $1 == 0x0C)
        }) { adjacencyCases += 1 }
    }

    // Exhaustive separator/filler combinations.
    let pieces = ["\n", "\r", "\r\n", "\n\r", "\u{000B}", "\u{000C}", "a", "汉", ""]
    func walk(_ prefix: String, depth: Int) throws {
        try check(prefix)
        guard depth < 4 else { return }
        for piece in pieces { try walk(prefix + piece, depth: depth + 1) }
    }
    try walk("", depth: 0)

    // Word-boundary grid: the scan consumes 8 bytes per word, so lengths
    // around multiples of 8 with separators at the edges exercise the
    // cross-word CR carry and the scalar tail.
    for len in 0...40 {
        try check(String(repeating: "a", count: len))
        try check(String(repeating: "a", count: len) + "\n")
        try check(String(repeating: "a", count: len) + "\r\n")
        try check(String(repeating: "\n", count: len))
        try check(String(repeating: "\r\n", count: len))
        try check(String(repeating: "a\n", count: len))
        try check(String(repeating: "a\r\n", count: len))
        try check(String(repeating: "汉\n", count: len))
        try check("x" + String(repeating: "\r\n", count: len) + "\r")
        try check("\r" + String(repeating: "\n", count: len))
    }

    // Review B1 regression pins: the inexact SWAR subtraction mask marked
    // 0x01-valued bytes following a zero byte through borrow propagation —
    // LF followed by vertical tab and CR followed by form feed corrupted the
    // LF/CR masks (and at byte 7 the cross-word carry). These are the exact
    // counterexamples from the review, plus the same adjacency placed at every
    // offset across a word boundary and inside the scalar tail.
    try check("\n\u{000B}aaaaaa")
    try check("\r\u{000C}\naaaaa")
    try check("aaaaaa\r\u{000C}\naaaaaaa")
    for filler in 0...12 {
        let pad = String(repeating: "a", count: filler)
        try check(pad + "\n\u{000B}rest")
        try check(pad + "\r\u{000C}\nrest")
        try check(pad + "\n\u{000C}\r\nrest")
        try check(pad + "\u{000B}\nrest")
        try check(pad + "\u{000C}\rrest")
        try check("\n\u{000B}" + pad + "\r\u{000C}\n" + pad)
        try check(pad + "\r\u{000B}\na")
    }

    // Seeded fuzz over separator-heavy pieces.
    var seed: UInt64 = 0x7231_356C_6300_0000
    func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 11
    }
    let fuzzPieces = ["a", "b", "\n", "\r", "\r\n", "\n\r", "\r\r", "\n\n", "\u{000B}", "\u{000C}",
                      "\n\u{000B}", "\r\u{000C}", "汉", " ", "x\ty"]
    for _ in 0..<20000 {
        var text = ""
        for _ in 0..<(1 + Int(next() % 24)) { text += fuzzPieces[Int(next() % UInt64(fuzzPieces.count))] }
        try check(text)
    }
    precondition(cases > 20000, "the corpus must stay exhaustive, got \(cases)")
    precondition(vtffCases > 2000,
                 "the corpus must densely cover VT/FF-containing cases, got \(vtffCases)")
    precondition(adjacencyCases > 2000,
                 "the corpus must densely cover the LF→VT / CR→FF borrow-propagation adjacencies, got \(adjacencyCases)")
    print("PASS: edit-stat line counting matches the Character-split oracle across \(cases) cases (\(vtffCases) containing VT/FF, \(adjacencyCases) with an LF→VT or CR→FF adjacency)")
}
