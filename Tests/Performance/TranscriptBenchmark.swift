import Foundation
import WorkbenchCore

/// Synthetic Chinese history, exercising the production projection with real tail edits.
/// Timing excludes fixture setup and intentionally does not claim UI/frame latency.
@main struct TranscriptBenchmark {
    static func main() throws {
        func message(_ id: String, _ role: String, _ content: [[String: Any]]) -> [String: Any] {
            ["id": id, "role": role, "created_at": "0", "content": content]
        }
        var raw: [[String: Any]] = []
        for turn in 0..<30 {
            raw.append(message("u\(turn)", "user", [["type": "text", "text": "检查第 \(turn) 轮任务"]]))
            for step in 0..<20 {
                let id = "\(turn)-\(step)"
                let thought: [String: Any] = ["type": "thinking", "thinking": String(repeating: "分析中文任务及工具结果。", count: 20)]
                let overview: [String: Any] = ["type": "text", "text": "已检查第 \(step) 步，继续核验。"]
                let call: [String: Any] = ["type": "tool_use", "tool_name": "Bash", "tool_call_id": id, "input": ["command": "git status --short"]]
                raw.append(message("a\(id)", "assistant", [thought, overview, call]))
                let result: [String: Any] = ["type": "tool_result", "tool_call_id": id, "output": String(repeating: "tool output line\n", count: 20)]
                raw.append(message("r\(id)", "tool", [result]))
            }
        }
        let messages = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
        var updates: [[KimiMessage]] = []
        for index in 0..<120 {
            let part: [String: Any] = ["type": "thinking", "thinking": String(repeating: "继续核查进展。", count: index + 1)]
            let data = try JSONSerialization.data(withJSONObject: [message("live", "assistant", [part])])
            updates.append(messages + (try KimiWire.decoder().decode([KimiMessage].self, from: data)))
        }
        let projection = ConversationProjection()
        _ = projection.update(messages, isRunning: true)
        func measure(_ name: String, _ work: ([KimiMessage]) -> Int) -> Double {
            var samples: [Double] = [], sum = 0
            for input in updates {
                let start = ContinuousClock.now
                sum += work(input)
                let duration = start.duration(to: .now).components
                samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            }
            let ordered = samples.sorted()
            let elapsed = samples.reduce(0, +)
            print("\(name): total_ms=\(elapsed) p50_ms=\(ordered[ordered.count / 2]) p95_ms=\(ordered[ordered.count * 95 / 100]) checksum=\(sum)")
            return elapsed
        }
        let before = measure("uncached production projection") { input in
            let entries = ConversationTimelineEntry.make(input, isRunning: true)
            let results = input.flatMap(\.content).filter { $0.type == "tool_result" }
                .reduce(into: [String: KimiPart]()) { if let id = $1.toolCallId { $0[id] = $1 } }
            return entries.count + results.count
        }
        let after = measure("incremental production projection") { input in
            let snapshot = projection.update(input, isRunning: true)
            return snapshot.entries.count + snapshot.results.count
        }
        print("messages=\(messages.count) updates=\(updates.count) projection_speedup=\(before / after)x; CPU projection only, not end-to-end frame latency")
    }
}
