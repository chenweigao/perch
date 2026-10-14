import Foundation
import QuartzCore
import WorkbenchCore

/// Synchronous status-bar derivation for an edit-heavy loaded session window.
/// Not part of the checked-in suite; run with WORKBENCH_BENCH=activity.
/// It measures pure model work per snapshot update, not layout, rendering or FPS.
func benchConversationActivity() throws {
    func fixture(turns: Int) throws -> [KimiMessage] {
        let prose = String(repeating: "说明这一轮的结论与 English identifiers，保持中文混排。", count: 12)
        let oldBlock = (0..<24).map { "    let value\($0) = compute(\($0)) // 原有实现" }.joined(separator: "\n")
        let newBlock = (0..<28).map { "    let value\($0) = computeFaster(\($0)) // 新实现" }.joined(separator: "\n")
        let written = (0..<220).map { "line \($0): 写入的文件内容 with mixed text" }.joined(separator: "\n")
        let readOutput = (0..<80).map { "\($0)\t源代码行 source line" }.joined(separator: "\n")
        var raw: [[String: Any]] = []
        raw.reserveCapacity(turns * 9)
        for turn in 0..<turns {
            let id = String(format: "%05d", turn)
            raw.append(["id": "user-\(id)", "role": "user", "created_at": id,
                        "content": [["type": "text", "text": "第 \(turn) 轮：请修改实现并验证。"]]])
            raw.append(["id": "read-\(id)", "role": "assistant", "created_at": id, "content": [
                ["type": "tool_use", "tool_call_id": "read-\(id)", "tool_name": "Read",
                 "input": ["file_path": "/fixture/Sources/File\(turn % 40).swift"]]]])
            raw.append(["id": "read-result-\(id)", "role": "user", "created_at": id, "content": [
                ["type": "tool_result", "tool_call_id": "read-\(id)", "is_error": false, "output": readOutput]]])
            raw.append(["id": "edit-\(id)", "role": "assistant", "created_at": id, "content": [
                ["type": "tool_use", "tool_call_id": "edit-\(id)", "tool_name": "Edit",
                 "input": ["file_path": "/fixture/Sources/File\(turn % 40).swift",
                           "old_string": oldBlock, "new_string": newBlock]]]])
            raw.append(["id": "edit-result-\(id)", "role": "user", "created_at": id, "content": [
                ["type": "tool_result", "tool_call_id": "edit-\(id)", "is_error": false, "output": "ok"]]])
            if turn % 5 == 0 {
                raw.append(["id": "write-\(id)", "role": "assistant", "created_at": id, "content": [
                    ["type": "tool_use", "tool_call_id": "write-\(id)", "tool_name": "Write",
                     "input": ["file_path": "/fixture/Generated/Out\(turn).swift", "content": written]]]])
                raw.append(["id": "write-result-\(id)", "role": "user", "created_at": id, "content": [
                    ["type": "tool_result", "tool_call_id": "write-\(id)", "is_error": false, "output": "ok"]]])
            }
            raw.append(["id": "reply-\(id)", "role": "assistant", "created_at": id,
                        "content": [["type": "text", "text": prose]]])
        }
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
    for turns in [50, 200, 1000] {
        let messages = try fixture(turns: turns)
        var derive: [Double] = [], activity: [Double] = [], running: [Double] = []
        var checksum = 0
        for _ in 0..<15 {
            let t0 = CACurrentMediaTime()
            checksum &+= SessionEditStats.derive(from: messages)?.total.additions ?? 0
            derive.append((CACurrentMediaTime() - t0) * 1000)
            let t1 = CACurrentMediaTime()
            let ids = ToolVisibilityProjection.runningIDs(in: messages, busy: true)
            running.append((CACurrentMediaTime() - t1) * 1000)
            let t2 = CACurrentMediaTime()
            let summary = ConversationActivity(messages: messages, isRunning: true, running: ids, online: true,
                                               isResponding: true)
            activity.append((CACurrentMediaTime() - t2) * 1000)
            checksum &+= summary.edits?.total.deletions ?? 0
        }
        print("activity_bench turns=\(turns) messages=\(messages.count) edit_stats_median_ms=\(String(format: "%.3f", median(derive))) running_ids_median_ms=\(String(format: "%.3f", median(running))) activity_init_median_ms=\(String(format: "%.3f", median(activity))) checksum=\(checksum)")
    }
}
