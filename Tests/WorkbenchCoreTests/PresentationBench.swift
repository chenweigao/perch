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
        for _ in 0..<5 {
            let model = ConversationPresentationModel(key: "bench-\(count)")
            let t0 = CACurrentMediaTime()
            _ = model.update(.init(messages: input, language: "zh"))
            cold.append((CACurrentMediaTime() - t0) * 1000)
            // Streaming append: one extra assistant message on the same model.
            var grew = input
            grew.append(try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: [
                "id": "tail", "role": "assistant", "created_at": "tail",
                "content": [["type": "text", "text": "流式追加一段。\n\n" + String(repeating: "增量文本。", count: 10)]]] as [String: Any])))
            let t1 = CACurrentMediaTime()
            _ = model.update(.init(messages: grew, isRunning: true, language: "zh"))
            append.append((CACurrentMediaTime() - t1) * 1000)
        }
        cold.sort(); append.sort()
        let payload = input.reduce(0) { $0 + $1.content.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) } }
        print("messages=\(count) cold_median_ms=\(String(format: "%.2f", cold[2])) cold_max_ms=\(String(format: "%.2f", cold[4])) append_median_ms=\(String(format: "%.2f", append[2])) text_bytes=\(payload)")
    }
}
