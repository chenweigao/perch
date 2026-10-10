import Foundation
import QuartzCore
import WorkbenchCore

/// One-off measurement for the large-conversation first-visit projection cost.
/// Not part of the checked-in suite; run with WORKBENCH_BENCH=1.
func benchPresentationUpdate() throws {
    func messages(_ count: Int) throws -> [KimiMessage] {
        let prose = Array(repeating: "这是一段用于验收的中文说明，包含 **结论**、`identifier` 与普通文本，混排 English words so that line breaking has to handle both scripts.", count: 3).joined(separator: "\n\n")
        var raw: [[String: Any]] = []
        for i in 0..<count {
            let id = String(format: "%05d", i)
            if i % 2 == 0 {
                raw.append(["id": id, "role": "user", "created_at": id,
                            "content": [["type": "text", "text": "第 \(i) 轮：\(prose)"]]])
            } else if i % 6 == 3 {
                raw.append(["id": id, "role": "assistant", "created_at": id, "content": [
                    ["type": "tool_use", "tool_call_id": "tool-\(i)", "tool_name": "Bash",
                     "input": ["command": "run fixture \(i)"]]]])
                raw.append(["id": id + "r", "role": "tool", "created_at": id, "content": [
                    ["type": "tool_result", "tool_call_id": "tool-\(i)", "is_error": false,
                     "output": ["rows": Array(repeating: "中文结果与 english identifiers", count: 16)]]]])
            } else {
                raw.append(["id": id, "role": "assistant", "created_at": id,
                            "content": [["type": "text", "text": "回答如下。\n\n\(prose)\n\n```swift\nlet value = \(i)\n```"]]])
            }
        }
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    for count in [100, 500, 1000, 2000] {
        let input = try messages(count)
        var cold: [Double] = [], append: [Double] = []
        var coldRows = 0, appendedRows = 0
        for _ in 0..<5 {
            let model = ConversationPresentationModel(key: "bench-\(count)")
            let t0 = CACurrentMediaTime()
            coldRows = model.update(.init(messages: input, language: "zh")).rows.count
            cold.append((CACurrentMediaTime() - t0) * 1000)
            var grew = input
            grew.append(try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: [
                "id": "tail", "role": "assistant", "created_at": "tail",
                "content": [["type": "text", "text": "流式追加一段。\n\n" + String(repeating: "增量文本。", count: 10)]]] as [String: Any])))
            let t1 = CACurrentMediaTime()
            appendedRows = model.update(.init(messages: grew, isRunning: true, language: "zh")).rows.count
            append.append((CACurrentMediaTime() - t1) * 1000)
        }
        cold.sort(); append.sort()
        let parts = input.reduce(0) { $0 + $1.content.count }
        let payload = input.reduce(0) { $0 + $1.content.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) } }
        print("source_slots=\(count) actual_messages=\(input.count) actual_parts=\(parts) cold_rows=\(coldRows) appended_rows=\(appendedRows) cold_median_ms=\(String(format: "%.2f", cold[2])) cold_max_ms=\(String(format: "%.2f", cold[4])) append_median_ms=\(String(format: "%.2f", append[2])) text_bytes=\(payload)")
    }
}

/// Native release fixture for repeated token-like replacements of one stable tail
/// message. It measures synchronous presentation work, not provider, layout or FPS.
func benchPresentationTokenUpdates() throws {
    let warmupUpdates = 5
    let measuredUpdates = 30

    func fixture(turns: Int) throws -> [KimiMessage] {
        var raw: [[String: Any]] = []
        raw.reserveCapacity(turns * 4)
        for turn in 0..<turns {
            let id = String(format: "%05d", turn)
            let tool = "tool-\(id)"
            raw.append(["id": "user-\(id)", "role": "user", "created_at": id,
                        "content": [["type": "text", "text": "第 \(turn) 轮问题"]]])
            raw.append(["id": "work-\(id)", "role": "assistant", "created_at": id, "content": [
                ["type": "thinking", "thinking": "检查第 \(turn) 轮"],
                ["type": "tool_use", "tool_call_id": tool, "tool_name": "Read",
                 "input": ["path": "fixture-\(turn).txt"]]]])
            raw.append(["id": "result-\(id)", "role": "tool", "created_at": id, "content": [
                ["type": "tool_result", "tool_call_id": tool, "is_error": false,
                 "output": "第 \(turn) 轮结果"]]])
            raw.append(["id": "reply-\(id)", "role": "assistant", "created_at": id,
                        "content": [["type": "text", "text": "第 \(turn) 轮回答"]]])
        }
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func tail(_ turns: Int, update: Int) throws -> KimiMessage {
        let turn = turns - 1
        let id = String(format: "%05d", turn)
        return try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: [
            "id": "reply-\(id)", "role": "assistant", "created_at": id,
            "content": [["type": "text", "text": "第 \(turn) 轮回答" + String(repeating: " 增量", count: update + 1)]]
        ] as [String: Any]))
    }

    func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

    var results: [[String: Any]] = []
    for turns in [200, 2000] {
        var messages = try fixture(turns: turns)
        let replacements = try (0..<(warmupUpdates + measuredUpdates)).map { try tail(turns, update: $0) }
        var recorded: ConversationPresentationUpdateMetrics?
        let model = ConversationPresentationModel(key: "token-tail-\(turns)", metricsHandler: { recorded = $0 })
        var snapshot = model.update(.init(messages: messages, isRunning: true, language: "zh"))
        var samples: [[String: Any]] = []
        for update in replacements.indices {
            let replacementStarted = CACurrentMediaTime()
            var next = messages
            next[next.index(before: next.endIndex)] = replacements[update]
            let replacementMilliseconds = (CACurrentMediaTime() - replacementStarted) * 1_000
            recorded = nil
            snapshot = model.update(.init(messages: next, isRunning: true, language: "zh"))
            guard let metrics = recorded else { preconditionFailure("Missing presentation metrics") }
            messages = next
            if update >= warmupUpdates {
                samples.append([
                    "fixture_tail_replace_ms": replacementMilliseconds,
                    "input_comparison_ms": milliseconds(metrics.inputComparisonNanoseconds),
                    "state_reset_ms": milliseconds(metrics.stateResetNanoseconds),
                    "tool_projection_ms": milliseconds(metrics.toolProjectionNanoseconds),
                    "turn_projection_ms": milliseconds(metrics.turnProjectionNanoseconds),
                    "narrative_ms": milliseconds(metrics.narrativeNanoseconds),
                    "row_projection_ms": milliseconds(metrics.rowProjectionNanoseconds),
                    "summary_ms": milliseconds(metrics.summaryNanoseconds),
                    "retained_cost_ms": milliseconds(metrics.retainedCostNanoseconds),
                    "total_ms": milliseconds(metrics.totalNanoseconds),
                    "cache_hit": metrics.cacheHit,
                    "turns_reused": metrics.reusedTurnCount,
                    "turns_rebuilt": metrics.rebuiltTurnCount
                ])
            }
        }
        results.append([
            "scenario": "same-id-tail-token-replacement",
            "fixture_turns": turns,
            "actual_messages": messages.count,
            "actual_parts": messages.reduce(0) { $0 + $1.content.count },
            "actual_rows": snapshot.rows.count,
            "actual_navigation": snapshot.navigation.count,
            "warmup_updates": warmupUpdates,
            "measured_updates": samples.count,
            "samples": samples,
            "scope": "release WorkbenchCore fixture; excludes provider transport, SwiftUI/AppKit layout, FPS and physical input"
        ])
    }
    let data = try JSONSerialization.data(withJSONObject: [
        "schema": 1,
        "benchmark": "presentation-token",
        "timing_note": "stage intervals do not overlap; total_ms includes timestamp instrumentation but excludes the metrics callback; fixture_tail_replace_ms is outside model.update and must not be added to the stages",
        "results": results
    ], options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
