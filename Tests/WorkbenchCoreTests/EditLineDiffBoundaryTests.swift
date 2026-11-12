import Foundation
import WorkbenchCore

func checkEditLineDiffBoundaries() throws {
    func reference(_ old: String, _ new: String) -> SessionEditStat {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        if new.isEmpty { return .init(additions: 0, deletions: a.count) }
        if old.isEmpty { return .init(additions: b.count, deletions: 0) }
        var common = 0, x = a.count, y = b.count
        while common < x && common < y && a[common] == b[common] { common += 1 }
        while x > common && y > common && a[x - 1] == b[y - 1] { x -= 1; y -= 1 }
        return .init(additions: y - common, deletions: x - common)
    }
    func check(_ old: String, _ new: String) throws {
        let expected = reference(old, new)
        let raw: [String: Any] = ["id": "boundary", "role": "assistant", "created_at": "0", "content": [
            ["type": "tool_use", "tool_call_id": "boundary", "tool_name": "Edit", "input": [
                "path": "boundary.swift", "old_string": old, "new_string": new,
            ]],
        ]]
        let message = try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: raw))
        let result = SessionEditStats.derive(from: [message])
        precondition(result?.total == expected && result?.perFile["boundary.swift"] == expected,
                     "line fast paths and prefix/suffix overlap must equal Character oracle")
    }
    let prefixes = ["", "\n", "\n\n", "\r\n", "same\n", "same\n\n", "a\u{301}\n", "\u{600}\n", "👩🏽‍💻\n"]
    let middles = ["", "x", "x\n", "\r\n", "x\n\n", "a\u{301}", "cafe\u{301}", "café"]
    let suffixes = ["", "\n", "\n\n", "\r\n", "tail", "\n\rtail\n"]
    for prefix in prefixes {
        for a in middles {
            for b in middles {
                for suffix in suffixes {
                    try check(prefix + a + suffix, prefix + b + suffix)
                }
            }
        }
    }
    // Shared prefix may exhaust one side; suffix must not consume it again.
    for text in ["x", "\n", "\n\n", "\r\n\n", "same\n", "café\n👨‍👩‍👧\n"] {
        try check(text, text + "\n")
        try check(text + "\n", text)
        try check(text, text.decomposedStringWithCanonicalMapping)
    }
    // Exercise either side of the short-input working-set threshold, including
    // unequal-sized inputs. Byte length never changes the reference semantics.
    for size in [1023, 1024, 1025] {
        let text = String(repeating: "x", count: size - 3) + "\na\n"
        try check(text, String(repeating: "x", count: size - 3) + "\nb\n")
        try check(String(repeating: "x", count: size), String(repeating: "y", count: size))
        try check(text, text + "\n\n")
    }
    print("PASS: line fast paths preserve prefix/suffix overlap, final empty lines, CRLF and canonical Unicode boundaries")
}
