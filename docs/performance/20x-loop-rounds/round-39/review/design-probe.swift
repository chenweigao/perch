import Foundation
import WorkbenchCore

func messages(_ values: [[String: Any]]) throws -> [KimiMessage] {
    try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: values))
}
func rawMessage(_ id: String, _ role: String, _ parts: [[String: Any]]) -> [String: Any] {
    ["id": id, "role": role, "created_at": id, "content": parts]
}
func sameBuffer<T>(_ lhs: [T], _ rhs: [T]) -> Bool {
    lhs.withUnsafeBufferPointer { l in rhs.withUnsafeBufferPointer { r in l.baseAddress == r.baseAddress && l.count == r.count } }
}
func bytes(_ entries: [ConversationTimelineEntry]) -> [[UInt8]] {
    entries.flatMap(\.messages).flatMap(\.content).flatMap { part in [part.text, part.thinking].compactMap { $0 }.map { Array($0.utf8) } }
}

let wire: [String: Any] = [
    "as_of_seq": 1, "epoch": "review",
    "session": ["id": "s", "title": "synthetic", "updated_at": "1", "busy": true, "main_turn_active": true],
    "messages": ["items": [rawMessage("u", "user", [["type": "text", "text": "prompt"]]), rawMessage("a", "assistant", [["type": "text", "text": "persisted answer"]])], "has_more": false],
    "in_flight_turn": ["turn_id": 1, "assistant_text": "live answer", "thinking_text": "first thought", "running_tools": []],
    "pending_approvals": [], "pending_questions": []
]
var conv = KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: JSONSerialization.data(withJSONObject: wire)))
let rawBefore = conv.messages
let displayBefore = conv.displayMessages
let tv = ToolVisibilityProjection()
let normalizedBefore = tv.update(displayBefore, sessionID: "s")
let entriesBefore = ConversationTimelineEntry.make(normalizedBefore.messages, isRunning: true)
let narrativeBefore = ActivityNarrativeProjection.make(entries: entriesBefore, tools: normalizedBefore.tools, isRunning: true)
let event: [String: Any] = ["type": "thinking.delta", "session_id": "s", "epoch": "review", "volatile": true, "offset": conv.live!.thinkingUTF16Length, "payload": ["agentId": "main", "turnId": 1, "delta": " appended"]]
let neededSnapshot = conv.apply(try KimiWire.decoder().decode(KimiEvent.self, from: JSONSerialization.data(withJSONObject: event)))
precondition(!neededSnapshot)
let displayAfter = conv.displayMessages
let normalizedAfter = tv.update(displayAfter, sessionID: "s")
let entriesAfter = ConversationTimelineEntry.make(normalizedAfter.messages, isRunning: true)
let narrativeAfter = ActivityNarrativeProjection.make(entries: entriesAfter, tools: normalizedAfter.tools, isRunning: true)
let changed = entriesBefore.indices.filter { entriesBefore[$0] != entriesAfter[$0] }
precondition(entriesBefore.count == entriesAfter.count && changed.contains(entriesBefore.count - 2) && !changed.contains(entriesBefore.count - 1))
print("THINKING_DELTA_ENTRIES presentations=\(entriesBefore.map { String(describing: $0.presentation) }) changed=\(changed) tail_index=\(entriesBefore.count-1)")
print("BUFFER_IDENTITY raw=\(sameBuffer(rawBefore, conv.messages)) display=\(sameBuffer(displayBefore, displayAfter)) normalized=\(sameBuffer(normalizedBefore.messages, normalizedAfter.messages)) normalized_first_content=\(sameBuffer(normalizedBefore.messages[0].content, normalizedAfter.messages[0].content))")
print("THINKING_DELTA_NARRATIVE unchanged=\(narrativeBefore == narrativeAfter)")
precondition(narrativeBefore == narrativeAfter)

let nfc = try messages([rawMessage("u", "user", [["type": "text", "text": "prompt"]]), rawMessage("a", "assistant", [["type": "text", "text": "é"]])])
let nfd = try messages([rawMessage("u", "user", [["type": "text", "text": "prompt"]]), rawMessage("a", "assistant", [["type": "text", "text": "e\u{0301}"]])])
let nfcEntries = ConversationTimelineEntry.make(nfc, isRunning: true)
let nfdEntries = ConversationTimelineEntry.make(nfd, isRunning: true)
precondition(nfc == nfd && nfcEntries == nfdEntries && bytes(nfcEntries) != bytes(nfdEntries))
print("CANONICAL_FALLBACK messages_equal=\(nfc == nfd) entries_equal=\(nfcEntries == nfdEntries) bytes_equal=\(bytes(nfcEntries) == bytes(nfdEntries)) nfc=\(bytes(nfcEntries)) nfd=\(bytes(nfdEntries))")
print("PASS: independent real-API design-boundary probes")
