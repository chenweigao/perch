import Foundation
import WorkbenchCore

// A deliberately heavier history than the streaming workload's 24 turns: the
// acceptance task asks for at least 60 turns, continuing to 200. Content is
// mixed on purpose, because uniform paragraphs would not exercise table layout,
// horizontal code scrolling, collapsed tool groups, thinking rows, or turns that
// never produced a final overview.
//
// This lives in the navigation fixture rather than in the shared streaming
// workload so the streaming fixture hash — and therefore every recorded
// throughput comparison — stays unchanged.
enum NavigationHistory {
    /// `salt` makes each fixture session a distinct conversation. Without it every
    /// session shares one set of message IDs, so a switch looks like an edit of the
    /// same rows rather than a move to different ones.
    static func conversation(turns: Int, salt: String = "") throws -> KimiConversation {
        var messages: [[String: Any]] = []
        func message(_ suffix: String, _ role: String, _ content: [[String: Any]]) -> [String: Any] {
            let id = salt + suffix
            return ["id": id, "role": role, "created_at": id, "content": content]
        }
        let prose = Array(repeating: "这是一段用于验收的中文说明，包含 **结论**、`identifier` 与普通文本，"
                          + "混排 English words so that line breaking has to handle both scripts.",
                          count: 3).joined(separator: "\n\n")
        for turn in 0..<turns {
            let id = String(format: "%04d", turn)
            switch turn % 5 {
            case 0:
                // Rich reply: Chinese prose, a table and a code block.
                messages.append(message(id + "a", "user", [["type": "text", "text": "第 \(turn + 1) 轮：请给出可核对的结论。"]]))
                messages.append(message(id + "b", "assistant", [["type": "text", "text": """
                ## 第 \(turn + 1) 轮结果

                \(prose)

                | 检查项 | 结果 | 次数 |
                | --- | --- | ---: |
                | 中文换行 | 正常 | 100 |
                | 表格列宽 | 正常 | 24 |

                ```swift
                let session = "fixture-\(turn)"
                let status = await render(session)
                ```
                """]]))
            case 1:
                // Thinking, a tool call and its result, then a final reply.
                messages.append(message(id + "a", "user", [["type": "text", "text": "第 \(turn + 1) 轮：读取配置后再回答。"]]))
                messages.append(message(id + "b", "assistant", [
                    ["type": "thinking", "thinking": "需要先确认配置内容，再判断是否影响结论。\n" + prose],
                    ["type": "tool_use", "tool_call_id": "tool-\(turn)", "tool_name": "Read",
                     "input": ["path": "/fixture/config-\(turn).json"]]
                ]))
                messages.append(message(id + "c", "tool", [[
                    "type": "tool_result", "tool_call_id": "tool-\(turn)", "is_error": false,
                    "output": ["summary": "本地合成结果，不执行真实读取。",
                               "rows": Array(repeating: "中文结果与 english identifiers", count: 16)]
                ]]))
                messages.append(message(id + "d", "assistant", [["type": "text", "text": "配置无影响。\n\n" + prose]]))
            case 2:
                // Tool-only turn: no final overview, so the transcript must show
                // its explicit no-text notice instead of inventing a summary.
                messages.append(message(id + "a", "user", [["type": "text", "text": "第 \(turn + 1) 轮：只执行，不用总结。"]]))
                messages.append(message(id + "b", "assistant", [
                    ["type": "tool_use", "tool_call_id": "only-\(turn)", "tool_name": "Bash",
                     "input": ["command": "printf 'fixture-\(turn)'"]]
                ]))
                messages.append(message(id + "c", "tool", [[
                    "type": "tool_result", "tool_call_id": "only-\(turn)", "is_error": false,
                    "output": ["stdout": "fixture-\(turn)"]
                ]]))
            case 3:
                // Thinking-only turn.
                messages.append(message(id + "a", "user", [["type": "text", "text": "第 \(turn + 1) 轮：先想一下。"]]))
                messages.append(message(id + "b", "assistant", [
                    ["type": "thinking", "thinking": Array(repeating: prose, count: 2).joined(separator: "\n\n")]
                ]))
            default:
                // A very long user message followed by a list-heavy reply.
                messages.append(message(id + "a", "user", [["type": "text", "text":
                    "第 \(turn + 1) 轮：" + Array(repeating: prose, count: 4).joined(separator: "\n\n")]]))
                messages.append(message(id + "b", "assistant", [["type": "text", "text": """
                - 中文与 English 混排保持可读。
                - 工具细节仍可展开检查。
                  - 嵌套项也要对齐。
                - 远端任务不受本地测试影响。

                > 这里的时间只代表 Mac 本地渲染。
                """]]))
            }
        }
        let session: [String: Any] = [
            "id": "navigation-fixture", "title": "导航验收", "updated_at": "2026-09-21", "busy": false,
            "metadata": ["cwd": "/fixture"], "agent_config": ["model": "fixture/deterministic"]
        ]
        let snapshot: [String: Any] = [
            "as_of_seq": 1, "epoch": "navigation-epoch", "session": session,
            "messages": ["items": messages, "has_more": false],
            "pending_approvals": [], "pending_questions": []
        ]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        return KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: data))
    }
}
