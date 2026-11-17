import Foundation
import WorkbenchCore

func decode(_ raw: [[String: Any]]) throws -> [KimiMessage] {
    try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
}
func prompt(_ id: String) -> [String: Any] {
    ["id": id, "role": "user", "created_at": "1", "content": [["type": "text", "text": id]]]
}
func reply(_ id: String, tool: Bool = false) -> [String: Any] {
    ["id": id, "role": "assistant", "created_at": "2", "content": tool
        ? [["type": "tool_use", "tool_call_id": "T", "tool_name": "Read", "input": ["file_path": "/x"]]]
        : [["type": "text", "text": "reply \(id)"]]]
}
let live = try KimiWire.decoder().decode(KimiLiveTool.self, from: JSONSerialization.data(withJSONObject:
    ["tool_call_id": "T", "name": "Read", "args": ["file_path": "/x"]]))
let warm = ToolVisibilityProjection()
let oracle = ToolVisibilityProjection()
let initial = try decode([prompt("A"), reply("a", tool: true)])
_ = warm.update(initial, sessionID: "s", live: [live])
_ = oracle.update(initial, sessionID: "s", live: [live])
let previous = try decode([prompt("A"), reply("a", tool: true), prompt("B"), reply("b"), prompt("L"), reply("l")])
let prior = warm.update(previous, splittingAt: 4, sessionID: "s", live: [live])
_ = oracle.update(previous, sessionID: "s", live: [live])
precondition(prior.prefix.chunks != nil)
let next = try decode([prompt("N"), reply("n"), prompt("A"), reply("a"), prompt("B"), reply("b"), prompt("L"), reply("l"),
    ["id": "result", "role": "tool", "created_at": "3", "content": [["type": "tool_result", "tool_call_id": "T", "is_error": false, "output": "done"]]]])
let result = warm.update(next, splittingAt: 6, sessionID: "s", live: [live])
let full = oracle.update(next, sessionID: "s", live: [live])
let joined = result.prefix.messages + result.tail.messages
let joinedTools = result.prefix.tools.merging(result.tail.tools) { _, latest in latest }
print("prior_chunks=\(prior.prefix.chunks!.count) next_chunks=\(result.prefix.chunks?.count ?? -1) separable=\(result.separable)")
print("messages_equal=\(joined == full.messages) tools_equal=\(joinedTools == full.tools)")
print("warm_ids=\(joined.map(\.id))")
print("full_ids=\(full.messages.map(\.id))")
print("warm_prefix_T=\(String(describing: result.prefix.tools[\"T\"]?.status)) full_T=\(String(describing: full.tools[\"T\"]?.status))")
precondition(joined == full.messages && joinedTools == full.tools, "consumed identity subtraction lost the unchanged observed term")
