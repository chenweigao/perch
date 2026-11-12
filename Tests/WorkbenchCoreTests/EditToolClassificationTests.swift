import Foundation
import WorkbenchCore

func checkEditToolClassification() throws {
    let patch = "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new"
    let payload: [String: Any] = ["old_string": "a\nb\nc", "new_string": "a\nx\nc",
                                  "content": "one\ntwo", "patch": patch]
    let tools = ["Edit", "eDiT", "edit_file", "EDIT_FILE", "Write", "wRiTe", "write_file", "WRITE_FILE",
                 "apply_patch", "APPLY_PATCH", "Read", "read_file", "Bash", "Glob", "Grep", "edit-file",
                 "writefile", "applyPatch", "apply_patch_extra", "", " Edit ", "Edİt", "Wrıte", "ＥＤＩＴ", "工具"]
    let paths: [[String: Any]] = [
        [:], ["file_path": "fixture.swift"], ["filePath": "camel.swift"], ["path": "fallback.swift"],
        ["file_path": "first.swift", "filePath": "second.swift", "path": "third.swift"],
        ["file_path": NSNull(), "filePath": "second.swift", "path": "third.swift"],
        ["file_path": 7, "filePath": [], "path": "third.swift"],
        ["file_path": "", "filePath": "https://blocked.example/x"],
        ["file_path": "https://blocked.example/x", "path": "not-a-fallback.swift"],
        ["filePath": "prefix://suffix", "path": "not-a-fallback.swift"],
        ["path": "C:\\repo\\file.swift"], ["path": "repo/cafe\u{301}.swift"], ["path": "repo/𠀀.swift"],
        ["path": "repo：／／file.swift"], ["path": "x:\u{301}//y"], ["path": "项目://路径"],
    ]

    // Freeze the old public outcome: resolve/check path first, then dispatch
    // by the exact old lowercased aliases. Known payloads have fixed counts;
    // line algorithms have their independent Character oracle in another check.
    func reference(_ tool: String, _ input: [String: Any]) -> [String: SessionEditStat]? {
        let path = input["file_path"] as? String ?? input["filePath"] as? String ?? input["path"] as? String
        guard let path, !path.contains("://") else { return nil }
        let stat: SessionEditStat
        switch tool.lowercased() {
        case "edit", "edit_file": stat = .init(additions: 1, deletions: 1)
        case "write", "write_file": stat = .init(additions: 2, deletions: 0)
        case "apply_patch": stat = .init(additions: 1, deletions: 1)
        default: return nil
        }
        return [path: stat]
    }
    func message(_ tool: String, _ input: [String: Any]) throws -> KimiMessage {
        let raw: [String: Any] = ["id": "same-id", "role": "assistant", "created_at": "0", "content": [
            ["type": "tool_use", "tool_call_id": "same-call", "tool_name": tool, "input": input],
        ]]
        return try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func verify(_ messages: [KimiMessage], _ expected: [String: SessionEditStat]?) {
        let actual = SessionEditStats.derive(from: messages)
        let total = expected.map { values in
            values.values.reduce(SessionEditStat(additions: 0, deletions: 0)) {
                .init(additions: $0.additions + $1.additions, deletions: $0.deletions + $1.deletions)
            }
        }
        precondition(actual?.perFile == expected && actual?.total == total,
                     "tool classification must preserve old aliases, path precedence, Unicode/URL rejection and counts")
    }
    for tool in tools {
        for path in paths {
            let input = payload.merging(path) { _, next in next }
            verify([try message(tool, input)], reference(tool, input))
        }
    }
    let changes: [[String: Any]] = [
        ["path": "changed.swift", "kind": ["type": "update"], "diff": patch],
        ["path": "https://blocked.example/x", "kind": "add", "diff": "+ignored"],
        ["path": "empty.swift", "kind": "add", "diff": ""],
    ]
    for tool in tools {
        for path in paths {
            var input = payload.merging(path) { _, next in next }
            input["changes"] = changes
            // Normalized fileChange envelopes in tally bypass compute's path
            // even when the envelope-level file_path is URL-ish or absent.
            let expected = tool.lowercased() == "apply_patch"
                ? ["changed.swift": SessionEditStat(additions: 1, deletions: 1),
                   "empty.swift": SessionEditStat(additions: 0, deletions: 0)] : reference(tool, input)
            verify([try message(tool, input)], expected)
        }
    }
    let read = try message("Read", payload.merging(["file_path": "ignored.swift"]) { _, next in next })
    let editInput = payload.merging(["file_path": "kept.swift"]) { _, next in next }
    let edit = try message("Edit", editInput)
    verify([read, edit, read], reference("Edit", editInput))
    print("PASS: edit tool classification preserves known/unknown aliases, Unicode folding, path precedence, URL rejection and normalized changes")
}
