import Foundation
import WorkbenchCore

func checkEditLineScans() throws {
    // Frozen Character-level oracle predating both byte scans: CRLF is one
    // Character and must not split; Substring equality remains canonical.
    func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
    func diff(_ old: String?, _ new: String?) -> SessionEditStat? {
        guard old != nil || new != nil else { return nil }
        let a = old.map(lines) ?? [], b = new.map(lines) ?? []
        if old != nil && (new == nil || new!.isEmpty) {
            return .init(additions: 0, deletions: a.count)
        }
        if new != nil && (old == nil || old!.isEmpty) {
            return .init(additions: b.count, deletions: 0)
        }
        var start = 0, aEnd = a.count, bEnd = b.count
        while start < aEnd && start < bEnd && a[start] == b[start] { start += 1 }
        while aEnd > start && bEnd > start && a[aEnd - 1] == b[bEnd - 1] {
            aEnd -= 1; bEnd -= 1
        }
        return .init(additions: bEnd - start, deletions: aEnd - start)
    }
    func patch(_ text: String) -> SessionEditStat {
        var stat = SessionEditStat(additions: 0, deletions: 0)
        for line in lines(text) {
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") { continue }
            if line.hasPrefix("+") { stat.additions += 1 }
            else if line.hasPrefix("-") { stat.deletions += 1 }
        }
        return stat
    }
    func change(_ kind: String, _ text: String) -> SessionEditStat {
        let rows = lines(text)
        let marker = kind == "add" ? "+" : "-"
        let isPatch = rows.contains { $0.hasPrefix("@@") || $0.hasPrefix("+++ ") || $0.hasPrefix("--- ") }
            || (!rows.isEmpty && rows.allSatisfy { $0.isEmpty || $0.hasPrefix(marker) })
        if isPatch { return patch(text) }
        return kind == "add" ? .init(additions: rows.count, deletions: 0) : .init(additions: 0, deletions: rows.count)
    }
    func check(_ tool: String, _ input: [String: Any], _ expected: SessionEditStat?) throws {
        let raw: [String: Any] = ["id": "scan", "role": "assistant", "created_at": "0", "content": [
            ["type": "tool_use", "tool_call_id": "same-id", "tool_name": tool, "input": input],
        ]]
        let message = try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: raw))
        let actual = SessionEditStats.derive(from: [message])
        precondition(actual?.perFile["fixture.swift"] == expected && actual?.total == expected,
                     "edit line scans must equal the frozen Character oracle (\(tool))")
    }
    func checkEdit(_ old: String?, _ new: String?) throws {
        var input: [String: Any] = ["file_path": "fixture.swift"]
        if let old { input["old_string"] = old }
        if let new { input["new_string"] = new }
        try check("Edit", input, diff(old, new))
    }

    let fragments = ["a", "中", "𠀀", "café", "cafe\u{301}", "👨\u{200D}👩", "🇨🇳", "\u{600}",
                     "\u{301}", "\u{903}", "\u{200D}", "\r", "\n", "\r\n", "\u{2028}", "\u{3000}", "+", "-", "@@", " "]
    var texts = ["", "\n", "\n\n", "\r\n", "\r\n\n", "\n\r\n", "a\r\nb\nc\n", "café\nend", "cafe\u{301}\nend",
                 "+\u{301}combined\n+added\n-removed\n", "--- a/file\n+++ b/file\n@@\n-old\n+new\n",
                 String(repeating: "中文 mixed\r\n\n", count: 1000)]
    for fragment in fragments { texts.append("before\n" + fragment + "\nafter\n") }
    var state: UInt64 = 0x20_05_2026
    func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) & 0x7FFF_FFFF)
    }
    for _ in 0..<500 {
        var text = ""
        for _ in 0..<(next() % 80) { text += fragments[next() % fragments.count] }
        texts.append(text)
    }
    try checkEdit(nil, nil)
    for (index, text) in texts.enumerated() {
        try checkEdit(nil, text)
        try checkEdit(text, nil)
        try checkEdit("", text)
        try checkEdit(text, "")
        try checkEdit(text, texts[(index * 7 + 3) % texts.count])
        try checkEdit(text, text.precomposedStringWithCanonicalMapping)
        try check("Write", ["file_path": "fixture.swift", "content": text], .init(additions: lines(text).count, deletions: 0))
        try check("apply_patch", ["file_path": "fixture.swift", "patch": text], patch(text))
        for kind in ["add", "delete"] {
            try check("apply_patch", ["changes": [["path": "fixture.swift", "kind": ["type": kind], "diff": text]]], change(kind, text))
        }
    }
    print("PASS: edit/write/patch line scans equal the Character oracle on CRLF, canonical Unicode, boundary and seeded mixed corpora")
}
