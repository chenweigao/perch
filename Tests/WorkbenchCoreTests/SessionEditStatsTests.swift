import Foundation
import WorkbenchCore

private func editMessage(_ id: String, _ tool: String, _ inputJSON: String) throws -> KimiMessage {
    try KimiWire.decoder().decode(KimiMessage.self, from: Data("""
    {"id":"\(id)","role":"assistant","created_at":"0","content":[
      {"type":"tool_use","tool_name":"\(tool)","tool_call_id":"call-\(id)","input":\(inputJSON)}
    ]}
    """.utf8))
}

func checkSessionEditStats() throws {
    // Edit: only the changed middle counts; shared prefix/suffix are context.
    do {
        let message = try editMessage("1", "Edit", #"{"path":"a.swift","old_string":"a\nb\nc","new_string":"a\nx\nc"}"#)
        let stats = SessionEditStats.derive(from: [message])
        expectEqual(stats?.perFile["a.swift"], SessionEditStat(additions: 1, deletions: 1))
    }
    // Pure deletion and pure addition.
    do {
        let message = try editMessage("2", "edit_file", #"{"path":"b.swift","old_string":"gone\ntwo"}"#)
        expectEqual(SessionEditStats.derive(from: [message])?.perFile["b.swift"],
                    SessionEditStat(additions: 0, deletions: 2))
        let fresh = try editMessage("3", "Edit", #"{"path":"c.swift","new_string":"one\ntwo\nthree"}"#)
        expectEqual(SessionEditStats.derive(from: [fresh])?.perFile["c.swift"],
                    SessionEditStat(additions: 3, deletions: 0))
    }
    // Write counts content lines; repeated edits of one path accumulate.
    do {
        let first = try editMessage("4", "Write", #"{"path":"d.md","content":"alpha\nbeta"}"#)
        let second = try editMessage("5", "write_file", #"{"path":"d.md","content":"alpha\nbeta\ngamma"}"#)
        let stats = SessionEditStats.derive(from: [first, second])
        expectEqual(stats?.perFile["d.md"], SessionEditStat(additions: 5, deletions: 0))
        expectEqual(stats?.total, SessionEditStat(additions: 5, deletions: 0))
    }
    // Patches count +/- lines but not the +++/--- file headers.
    do {
        let message = try editMessage("6", "apply_patch",
            #"{"path":"e.swift","patch":"--- a/e.swift\n+++ b/e.swift\n@@ -1,2 +1,2 @@\n-old\n+new\n context"}"#)
        expectEqual(SessionEditStats.derive(from: [message])?.perFile["e.swift"],
                    SessionEditStat(additions: 1, deletions: 1))
    }
    // URL-ish paths and unknown tools are not edits; empty derivation hides.
    do {
        let remote = try editMessage("7", "Edit", #"{"path":"https://example.com/x","new_string":"data"}"#)
        let read = try editMessage("8", "Read", #"{"path":"f.swift"}"#)
        let noop = try editMessage("9", "Edit", #"{"path":"g.swift"}"#)
        precondition(SessionEditStats.derive(from: [remote]) == nil, "URL path must not resolve")
        precondition(SessionEditStats.derive(from: [read]) == nil, "read-only tools are not edits")
        precondition(SessionEditStats.derive(from: [noop]) == nil, "edit without payload is not counted")
    }
    // Reused IDs and revised inputs must not reuse another snapshot's stats.
    let prior = try editMessage("reused", "Edit", #"{"path":"first.swift","new_string":"a"}"#)
    let next = try editMessage("reused", "Edit", #"{"path":"second.swift","new_string":"b\nc"}"#)
    _ = SessionEditStats.derive(from: [prior])
    expectEqual(SessionEditStats.derive(from: [next])?.perFile,
                ["second.swift": SessionEditStat(additions: 2, deletions: 0)])
    // Exact bridge fileChange envelope, including multiple files and diff headers.
    let codex = try editMessage("codex", "apply_patch", #"{"changes":[{"path":"one.swift","kind":{"type":"update"},"diff":"--- a/one.swift\n+++ b/one.swift\n@@ -1 +1 @@\n-old\n+new"},{"path":"two.swift","kind":{"type":"add"},"diff":"+first\n+second"}]}"#)
    let codexStats = SessionEditStats.derive(from: [codex])
    expectEqual(codexStats?.perFile["one.swift"], SessionEditStat(additions: 1, deletions: 1))
    expectEqual(codexStats?.perFile["two.swift"], SessionEditStat(additions: 2, deletions: 0))
    expectEqual(codexStats?.total, SessionEditStat(additions: 3, deletions: 1))
    // Line boundaries are Character boundaries: CR LF is one Character, so it does
    // not separate lines, while a trailing LF still counts; equal lines compare by
    // canonical equivalence, and a combining mark changes a patch line's marker.
    do {
        let crlf = try editMessage("crlf", "Write", #"{"path":"crlf.txt","content":"a\r\nb\r\nc"}"#)
        expectEqual(SessionEditStats.derive(from: [crlf])?.perFile["crlf.txt"], SessionEditStat(additions: 1, deletions: 0))
        let mixed = try editMessage("mixed", "Write", #"{"path":"mixed.txt","content":"a\rb\nc\r\n\nd\n"}"#)
        expectEqual(SessionEditStats.derive(from: [mixed])?.perFile["mixed.txt"], SessionEditStat(additions: 4, deletions: 0))
        let empty = try editMessage("empty-write", "Write", #"{"path":"empty.txt","content":""}"#)
        expectEqual(SessionEditStats.derive(from: [empty])?.perFile["empty.txt"], SessionEditStat(additions: 1, deletions: 0))
        let equivalent = try editMessage("nfc", "Edit", #"{"path":"nfc.txt","old_string":"café\n中文 👩🏽‍💻\nend","new_string":"café\n中文 👩🏽‍💻\nend"}"#)
        expectEqual(SessionEditStats.derive(from: [equivalent])?.perFile["nfc.txt"], SessionEditStat(additions: 0, deletions: 0))
        let windows = try editMessage("crlf-edit", "Edit", #"{"path":"w.txt","old_string":"same\r\nold\nkeep","new_string":"same\r\nnew\nkeep"}"#)
        expectEqual(SessionEditStats.derive(from: [windows])?.perFile["w.txt"], SessionEditStat(additions: 1, deletions: 1))
        let marked = try editMessage("marked", "apply_patch", #"{"path":"m.swift","patch":"+́combined\n+added\n-removed\n\n"}"#)
        expectEqual(SessionEditStats.derive(from: [marked])?.perFile["m.swift"], SessionEditStat(additions: 1, deletions: 1))
    }
    print("PASS: session edit stats — diff middle, write lines, patch headers, accumulation, URL/unknown rejection, Character line boundaries")
}
