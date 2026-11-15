import Foundation
import WorkbenchCore

/// Pins the contiguous byte-range path of `fullLineDiff` (round-23 candidate):
/// same-platform differential against a verbatim copy of the pre-change array
/// algorithm, driven through the public `SessionEditStats.derive` API with
/// JSON-decoded messages so the compared strings never share a base pointer.
///
/// Equivalence argument: byte-identical line bounds decide a pair as equal
/// (canonical equivalence is reflexive — identical bytes are identical
/// strings); byte- or length-differing pairs fall back to the original
/// canonical `Substring` comparison on exactly the Substrings `lines(_:)`
/// would materialize. The prefix/suffix scans therefore stop at the same
/// positions on every input, and the tally is unchanged. The differential
/// below hammers that claim; the coverage counters prove both the byte-confirm
/// branch and the canonical-fallback branch (equal and unequal outcomes) ran,
/// and that all three `lineDiff` routing paths were exercised.
///
/// The frozen Character-oracle contract itself stays pinned by
/// `checkEditLineScans`; this file pins candidate-vs-previous behavior.
func checkEditLineByteRangeDiff() throws {
    // MARK: - Verbatim reference: the pre-round-23 algorithm chain.

    // `lines(_:)` copied verbatim (both storage paths).
    func referenceLines(_ text: String) -> [Substring] {
        let utf8 = text.utf8
        if let result = utf8.withContiguousStorageIfAvailable({ bytes -> [Substring] in
            var result: [Substring] = []
            var start = utf8.startIndex
            for offset in bytes.indices where bytes[offset] == 0x0A && (offset == 0 || bytes[offset - 1] != 0x0D) {
                let index = utf8.index(utf8.startIndex, offsetBy: offset)
                result.append(text[start..<index])
                start = utf8.index(after: index)
            }
            result.append(text[start...])
            return result
        }) { return result }
        var result: [Substring] = []
        var start = utf8.startIndex
        var index = start
        var previous: UInt8 = 0
        while index != utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0A && previous != 0x0D {
                result.append(text[start..<index])
                start = utf8.index(after: index)
            }
            previous = byte
            utf8.formIndex(after: &index)
        }
        result.append(text[start...])
        return result
    }
    // `lineCount` as the scalar fallback the product itself keeps for foreign
    // storage; SWAR-vs-scalar equivalence is pinned by checkLineCountScans.
    func referenceLineCount(_ text: String) -> Int {
        var count = 1
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A && previous != 0x0D { count += 1 }
            previous = byte
        }
        return count
    }
    func referenceFirstLine(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Range<Int> {
        var end = start
        while end < bytes.count {
            if bytes[end] == 0x0A && (end == 0 || bytes[end - 1] != 0x0D) { break }
            end += 1
        }
        return start..<end
    }
    func referenceLastLine(_ bytes: UnsafeBufferPointer<UInt8>, before end: Int) -> Range<Int> {
        var start = end
        while start > 0 {
            start -= 1
            if bytes[start] == 0x0A && (start == 0 || bytes[start - 1] != 0x0D) {
                return (start + 1)..<end
            }
        }
        return 0..<end
    }
    func referenceSubstring(_ text: String, bytes range: Range<Int>) -> Substring {
        let utf8 = text.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let end = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
        return text[start..<end]
    }
    // `fullLineDiff` before the byte-range path: pure array walk.
    func referenceFullLineDiff(_ old: String, _ new: String) -> SessionEditStat {
        let oldLines = referenceLines(old), newLines = referenceLines(new)
        var start = 0
        while start < oldLines.count && start < newLines.count && oldLines[start] == newLines[start] { start += 1 }
        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > start && newEnd > start && oldLines[oldEnd - 1] == newLines[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        return SessionEditStat(additions: newEnd - start, deletions: oldEnd - start)
    }
    enum ReferencePath { case earlyCount, smallFullLineDiff, probeCount, probeFullLineDiff }
    // `lineDiff` routing copied verbatim, instrumented only with the path tag.
    func referenceLineDiff(old: String?, new: String?) -> (stat: SessionEditStat?, path: ReferencePath?) {
        if let old, new == nil || new!.isEmpty {
            return (SessionEditStat(additions: 0, deletions: referenceLineCount(old)), .earlyCount)
        }
        if let new, old == nil || old!.isEmpty {
            return (SessionEditStat(additions: referenceLineCount(new), deletions: 0), .earlyCount)
        }
        guard let old, let new else { return (nil, nil) }
        if old.utf8.count <= 1024 && new.utf8.count <= 1024 {
            return (referenceFullLineDiff(old, new), .smallFullLineDiff)
        }
        let bounded = old.utf8.withContiguousStorageIfAvailable { a in
            new.utf8.withContiguousStorageIfAvailable { b -> (SessionEditStat, ReferencePath) in
                let firstOld = referenceFirstLine(a, from: 0), firstNew = referenceFirstLine(b, from: 0)
                let firstMatches = referenceSubstring(old, bytes: firstOld) == referenceSubstring(new, bytes: firstNew)
                if firstOld.upperBound == a.count && firstNew.upperBound == b.count {
                    return firstMatches
                        ? (SessionEditStat(additions: 0, deletions: 0), .probeCount)
                        : (SessionEditStat(additions: 1, deletions: 1), .probeCount)
                }
                if !firstMatches,
                   referenceSubstring(old, bytes: referenceLastLine(a, before: a.count))
                       != referenceSubstring(new, bytes: referenceLastLine(b, before: b.count)) {
                    return (SessionEditStat(additions: referenceLineCount(new),
                                            deletions: referenceLineCount(old)), .probeCount)
                }
                return (referenceFullLineDiff(old, new), .probeFullLineDiff)
            }
        }
        if let result = bounded ?? nil { return result }
        return (referenceFullLineDiff(old, new), .probeFullLineDiff)
    }

    // MARK: - Driving one (old, new) pair through the public API.

    func editMessage(id: String, path: String, old: String?, new: String?) throws -> [String: Any] {
        var input: [String: Any] = ["file_path": path]
        if let old { input["old_string"] = old }
        if let new { input["new_string"] = new }
        return ["id": id, "role": "assistant", "created_at": "0", "content": [
            ["type": "tool_use", "tool_call_id": id, "tool_name": "Edit", "input": input],
        ]]
    }
    func deriveStats(_ raw: [[String: Any]]) throws -> [String: SessionEditStat] {
        let messages = try KimiWire.decoder().decode([KimiMessage].self,
                                                     from: JSONSerialization.data(withJSONObject: raw))
        return SessionEditStats.derive(from: messages)?.perFile ?? [:]
    }

    // MARK: - Coverage counters (computed from the reference side).

    var byteIdenticalPairs = 0        // byte-confirm branch decided "equal"
    var byteDiffCanonEqualPairs = 0   // fallback branch decided "equal" (NFC/NFD no-ops)
    var byteDiffCanonDiffPairs = 0    // fallback branch decided "unequal"
    var pathCounts: [ReferencePath: Int] = [:]
    func countLinePairs(_ old: String, _ new: String) {
        let a = Array(old.utf8), b = Array(new.utf8)
        let oldLines = referenceLines(old), newLines = referenceLines(new)
        for index in 0..<min(oldLines.count, newLines.count) {
            let x = oldLines[index], y = newLines[index]
            let bytesEqual = Array(x.utf8) == Array(y.utf8)
            if bytesEqual {
                byteIdenticalPairs += 1
            } else if x == y {
                byteDiffCanonEqualPairs += 1
            } else {
                byteDiffCanonDiffPairs += 1
            }
        }
        _ = a; _ = b
    }

    // MARK: - Corpus.

    let fragments = ["a", "let value = compute()", "中", "𠀀", "café", "cafe\u{301}", "👨\u{200D}👩",
                     "👩🏽\u{200D}💻", "🇨🇳", "\u{600}", "\u{301}", "\u{903}", "\u{200D}", " ",
                     "x\u{2028}y", "x\u{3000}y", String(repeating: "long ascii run ", count: 40)]
    let separators = ["\n", "\r\n", "\n\n", "\r\n\n"]
    var seed: UInt64 = 0x2026_1115_7231_0023
    func next() -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) & 0x7FFF_FFFF)
    }
    func randomText(maxFragments: Int) -> String {
        var text = ""
        for _ in 0..<(next() % (maxFragments + 1)) {
            text += fragments[next() % fragments.count]
            text += separators[next() % separators.count]
        }
        if next() % 2 == 0 { text += fragments[next() % fragments.count] }
        return text
    }
    func mutate(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.isEmpty { lines = [""] }
        switch next() % 6 {
        case 0: return text  // identical
        case 1: lines[next() % lines.count] += " // changed"
        case 2: lines.insert("inserted \(next())", at: next() % lines.count)
        case 3: if lines.count > 1 { lines.remove(at: next() % lines.count) }
        case 4: return text.decomposedStringWithCanonicalMapping  // NFD: byte-differs, canonically equal
        default: lines = lines.map { $0.replacingOccurrences(of: "\n", with: "\r\n") + " tail" }
        }
        return lines.joined(separator: "\n")
    }

    var raw: [[String: Any]] = []
    var expectations: [(path: String, stat: SessionEditStat?)] = []
    func addPair(_ old: String?, _ new: String?) throws {
        let index = expectations.count
        let path = "fixture-\(index).swift"
        raw.append(try editMessage(id: "edit-\(index)", path: path, old: old, new: new))
        let reference = referenceLineDiff(old: old, new: new)
        if let path2 = reference.path { pathCounts[path2, default: 0] += 1 }
        if let old, let new, !(old.isEmpty || new.isEmpty) { countLinePairs(old, new) }
        expectations.append((path, reference.stat))
    }

    // Structural cases: small (<=1024) and large (>1024, probe routing).
    let smallRows = (0..<12).map { "let value\($0) = compute(\($0)) // 中文 café" }
    let small = smallRows.joined(separator: "\n")
    let largeRows = (0..<120).map { "let value\($0) = compute(\($0)) // 中文 café row" }
    let large = largeRows.joined(separator: "\n")
    precondition(large.utf8.count > 1024 && small.utf8.count <= 1024)
    func largeWith(_ mutation: (inout [String]) -> Void) -> String {
        var rows = largeRows
        mutation(&rows)
        return rows.joined(separator: "\n")
    }
    try addPair(small, small)                                        // small identical
    try addPair(small, largeWith { $0[6] += " // changed" })         // mixed sizes
    try addPair(large, large)                                        // large identical → probe→fullLineDiff
    try addPair(large, large.decomposedStringWithCanonicalMapping)   // large canonical: every line falls back
    try addPair(large, largeWith { $0[60] += " // changed" })        // middle changed
    try addPair(large, largeWith { $0[0] += " // changed" })         // first changed, last matches
    try addPair(large, largeWith { $0[119] += " // changed" })       // last changed, first matches
    try addPair(large, largeWith { $0 = $0.map { _ in "bulk 替换" } })  // bulk: probe count path
    try addPair(large, large + "\n\n")                               // trailing empties
    try addPair(large, largeWith { $0.insert("inserted", at: 60) })  // insert shifts suffix
    let singleLine = String(repeating: "one huge line 中文 ", count: 200)
    try addPair(singleLine, singleLine)                              // no separator, identical
    try addPair(singleLine, singleLine + " x")                       // no separator, differs
    let crlfLarge = largeRows.joined(separator: "\r\n")
    try addPair(crlfLarge, crlfLarge)                                // CRLF: one line, identical
    try addPair(crlfLarge, crlfLarge + "\r\ntail")                   // CRLF pair differs
    try addPair(nil, large); try addPair(large, nil)                 // early count paths
    try addPair("", large); try addPair(large, "")
    try addPair("", "")

    // Seeded differential fuzz: independent pairs and mutation pairs.
    for _ in 0..<700 {
        let old = randomText(maxFragments: 60)
        if old.isEmpty { continue }
        if next() % 2 == 0 {
            try addPair(old, mutate(old))
        } else {
            try addPair(old, randomText(maxFragments: 60))
        }
    }
    // Large-text fuzz: crosses the 1024-byte probe boundary with repeats.
    for _ in 0..<60 {
        let base = String(repeating: randomText(maxFragments: 8) + "\n", count: 30)
        try addPair(base, mutate(base))
    }

    // MARK: - One decode for the whole corpus; per-file tallies are independent.

    let actual = try deriveStats(raw)
    var mismatches = 0
    var firstMismatch = ""
    for (path, expected) in expectations {
        let got = actual[path]
        if got != expected {
            mismatches += 1
            if firstMismatch.isEmpty { firstMismatch = "\(path): got \(String(describing: got)) want \(String(describing: expected))" }
        }
    }
    precondition(mismatches == 0,
                 "byte-range fullLineDiff must equal the previous array algorithm (\(mismatches) mismatches; first: \(firstMismatch))")

    // MARK: - Coverage guards: every branch of the new code must have run.

    precondition(expectations.count >= 750, "corpus too small: \(expectations.count)")
    precondition(byteIdenticalPairs > 500, "byte-confirm branch under-exercised: \(byteIdenticalPairs)")
    precondition(byteDiffCanonEqualPairs > 50, "canonical-fallback-equal branch under-exercised: \(byteDiffCanonEqualPairs)")
    precondition(byteDiffCanonDiffPairs > 50, "canonical-fallback-unequal branch under-exercised: \(byteDiffCanonDiffPairs)")
    for path in [ReferencePath.smallFullLineDiff, .probeFullLineDiff, .probeCount, .earlyCount] {
        precondition((pathCounts[path] ?? 0) > 0, "routing path unexercised: \(path)")
    }
    print("PASS: edit-line byte-range diff — \(expectations.count) pairs zero mismatches vs the previous array algorithm "
        + "(byte-identical confirmations \(byteIdenticalPairs), canonical fallbacks equal \(byteDiffCanonEqualPairs) "
        + "/ unequal \(byteDiffCanonDiffPairs); paths small \(pathCounts[.smallFullLineDiff] ?? 0), "
        + "probeFull \(pathCounts[.probeFullLineDiff] ?? 0), probeCount \(pathCounts[.probeCount] ?? 0), "
        + "early \(pathCounts[.earlyCount] ?? 0))")
}
