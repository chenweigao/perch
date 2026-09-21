import CryptoKit
import Foundation
import WorkbenchCore

/// Shared verbatim by both binaries. Never uses real tasks, servers, or files.
enum PerformanceScenario: String, CaseIterable, Identifiable {
    case assistant, thinking
    var id: String { rawValue }
    var label: String { self == .assistant ? "正文流" : "思考流" }
}

struct PerformanceWorkload {
    static let version = "transcript-pipeline-v2"
    static let historyTurns = 24
    static let eventCount = 120
    static let trials = 3
    let scenario: PerformanceScenario
    let snapshot: Data
    let events: [Data]
    let finalText: String
    let fingerprint: String

    init(scenario: PerformanceScenario = .assistant) throws {
        self.scenario = scenario
        var messages: [[String: Any]] = []
        for turn in 0..<Self.historyTurns {
            let prefix = String(format: "%03d", turn)
            let message: (String, String, [[String: Any]]) -> [String: Any] = { suffix, role, content in
                ["id": prefix + suffix, "role": role, "created_at": prefix + suffix, "content": content]
            }
            messages.append(message("a", "user", [["type": "text", "text": "请检查第 \(turn + 1) 轮中文对话的流式阅读体验，保留上下文和工具结果，并给出可核对的结论。"]]))
            messages.append(message("b", "assistant", [
                ["type": "text", "text": "正在读取配置与执行结果。这段进度说明应该按既有折叠规则保留，不影响最终回复。"],
                ["type": "tool_use", "tool_call_id": "tool-\(turn)", "tool_name": "Read", "input": ["path": "/fixture/config-\(turn).json"]]
            ]))
            messages.append(message("c", "tool", [["type": "tool_result", "tool_call_id": "tool-\(turn)", "output": ["summary": "本地合成工具结果，不执行文件读取。", "rows": Array(repeating: "中文结果与 english identifiers / 执行过程", count: 12)], "is_error": false]]))
            let prose = Array(repeating: "这是一段用于验收的中文说明，包含 **清晰的结论**、`streaming_offset` 和普通文本。界面应让历史内容保持稳定，仅更新当前输出；阅读和选择文字不应因为频繁状态变化而中断。", count: 4).joined(separator: "\n\n")
            let answer = """
            ## 第 \(turn + 1) 轮检查结果

            \(prose)

            - 中文内容与 English 混排保持可读。
            - 工具细节仍可展开检查。
            - 远端任务不会被这个本地测试控制。

            ```swift
            let session = "fixture-\(turn)"
            let status = await render(session)
            ```

            | 检查 | 结果 | 次数 |
            | --- | --- | ---: |
            | 中文输入 | 保留 | 100 |
            | 内容更新 | 连续 | 120 |

            > 这里的时间只代表 Mac 本地渲染，不代表模型生成速度。
            """
            messages.append(message("d", "assistant", [["type": "text", "text": answer]]))
        }
        messages.append(["id": "live-user", "role": "user", "created_at": "999", "content": [["type": "text", "text": "现在开始同一组流式事件，请持续输出检查结果。"]]])
        let session: [String: Any] = ["id": "performance-fixture", "title": "本地性能验收", "updated_at": "2026-09-20", "busy": true, "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/deterministic"]]
        let object: [String: Any] = [
            "as_of_seq": 1, "epoch": "fixture-epoch", "session": session,
            "messages": ["items": messages, "has_more": false],
            "in_flight_turn": ["turn_id": 42, "assistant_text": "", "thinking_text": "", "running_tools": []],
            "pending_approvals": [], "pending_questions": []
        ]
        snapshot = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var text = ""
        var stream: [Data] = []
        for index in 0..<Self.eventCount {
            let delta: String
            if index % 12 == 0 { delta = "\n\n### 检查组 \(index / 12 + 1)\n\n" }
            else if index % 12 == 10 { delta = "\n\n- 校验中文与 **重点标记**。\n- 保留 `UTF-16` 偏移与上下文。\n\n" }
            else { delta = "第\(index + 1)项：中文内容随着事件逐步补齐，历史消息应保持稳定；这里同时包含 Markdown 与 English，验证真实文本布局和显示。 " }
            let event: [String: Any] = ["type": scenario == .assistant ? "assistant.delta" : "thinking.delta", "session_id": "performance-fixture", "epoch": "fixture-epoch", "seq": 1, "volatile": true, "offset": text.utf16.count, "payload": ["agentId": "main", "turnId": 42, "delta": delta]]
            stream.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            text += delta
        }
        events = stream
        finalText = text
        var hash = SHA256()
        hash.update(data: snapshot)
        for data in stream { hash.update(data: data) }
        fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func output(in conversation: KimiConversation) -> String {
        (scenario == .assistant ? conversation.live?.assistantText : conversation.live?.thinkingText) ?? ""
    }
    func conversation() throws -> KimiConversation {
        KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: snapshot))
    }
}
