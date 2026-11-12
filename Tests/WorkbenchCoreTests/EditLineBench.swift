import Foundation
import WorkbenchCore

/// Same fixture in baseline/candidate. Model-only; input construction/decoding
/// and the independent Character oracle are outside every timed interval.
func benchEditLines() throws {
    func expected(_ old: String, _ new: String) -> SessionEditStat {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        if new.isEmpty { return .init(additions: 0, deletions: a.count) }
        if old.isEmpty { return .init(additions: b.count, deletions: 0) }
        var start = 0, aEnd = a.count, bEnd = b.count
        while start < aEnd && start < bEnd && a[start] == b[start] { start += 1 }
        while aEnd > start && bEnd > start && a[aEnd - 1] == b[bEnd - 1] { aEnd -= 1; bEnd -= 1 }
        return .init(additions: bEnd - start, deletions: aEnd - start)
    }
    var results: [[String: Any]] = []
    for size in [8, 64, 512] {
        let rows = (0..<size).map { "let value\($0) = compute(\($0)) // 中文 café" }
        let old = rows.joined(separator: "\n")
        func local(_ index: Int) -> String {
            var changed = rows
            changed[index] += " // changed"
            return changed.joined(separator: "\n")
        }
        var inserted = rows
        inserted.insert("inserted line", at: size / 2)
        let emojiRows = rows.map { $0 + " 👩🏽‍💻 \u{600} x" }
        var emojiChanged = emojiRows
        emojiChanged[size / 2] += " delta"
        let cases: [(String, String, String)] = [
            ("bulk", old, (0..<(size + 4)).map { "replacement \($0) 中文" }.joined(separator: "\n")),
            ("first", old, local(0)), ("middle", old, local(size / 2)), ("last", old, local(size - 1)),
            ("insert", old, inserted.joined(separator: "\n")),
            ("unchanged", old, old), ("canonical", old, old.decomposedStringWithCanonicalMapping),
            ("trailing_empty", old + "\n\n", local(size / 2) + "\n\n"),
            ("crlf", rows.joined(separator: "\r\n"), local(size / 2).replacingOccurrences(of: "\n", with: "\r\n")),
            ("unicode", emojiRows.joined(separator: "\n"), emojiChanged.joined(separator: "\n")),
        ]
        for (name, a, b) in cases {
            let one = expected(a, b)
            let batch = 24
            let raw: [[String: Any]] = (0..<batch).map { index in
                ["id": "edit-\(index)", "role": "assistant", "created_at": "0", "content": [
                    ["type": "tool_use", "tool_call_id": "edit-\(index)", "tool_name": "Edit", "input": [
                        "file_path": "fixture-\(index).swift", "old_string": a, "new_string": b,
                    ]],
                ]]
            }
            let messages = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
            // Decoding two JSON strings avoids depending on source-literal
            // pointer sharing for unchanged/canonical benchmarks.
            let total = SessionEditStat(additions: one.additions * batch, deletions: one.deletions * batch)
            for _ in 0..<2 { precondition(SessionEditStats.derive(from: messages)?.total == total) }
            var samples: [Double] = []
            var checksum = 0
            for _ in 0..<9 {
                let start = benchNow()
                let value = SessionEditStats.derive(from: messages)
                samples.append((benchNow() - start) * 1000)
                precondition(value?.total == total)
                precondition(value?.perFile.count == batch)
                checksum += value!.total.additions + value!.total.deletions
            }
            results.append(["case": name, "source_rows": size, "messages": batch,
                            "source_bytes": a.utf8.count + b.utf8.count, "samples_ms": samples,
                            "median_ms": samples.sorted()[4], "expected_additions": total.additions,
                            "expected_deletions": total.deletions, "checksum": checksum])
        }
    }
    let report: [String: Any] = ["benchmark": "edit-lines", "scope": "decoded synthetic edit model; no UI, real data or FPS", "results": results]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
