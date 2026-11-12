import Foundation
import WorkbenchCore

func checkTurnExcerpt() throws {
    // Frozen pre-optimization implementation: Character budgets include the
    // inserted space and are evaluated after joining, not via UTF16 length.
    func reference(_ message: KimiMessage) -> String {
        if let cron = message.cronFire {
            return String(cron.prompt.prefix(320)).collapsedWhitespace
        }
        var value = ""
        for part in message.content where part.type == "text" && !part.isRuntimeContext {
            value += " " + String((part.skillContextSplit?.prefix ?? part.text ?? "").prefix(320 - value.count))
            if value.count >= 320 { break }
        }
        return value.collapsedWhitespace
    }
    let fragments = ["a", "中", "𠀀", "👨\u{200D}👩\u{200D}👧", "🇨🇳", "a\u{301}",
                     "\u{301}", "\u{600}", "\u{903}", "\u{200D}", "\r\n", "\r", "\n", " ", "\t", "\u{3000}"]
    var corpus = ""
    for index in 0..<3000 { corpus += fragments[(index * 7 + index / 13) % fragments.count] }
    var texts = ["", "plain", "  中文说明  ", corpus,
        "User activated the skill \"config\". Follow the loaded skill instructions.\n\n<skill-loaded name=\"config\">private body</skill-loaded>",
        "<cron-fire cron=\"0 9 * * *\"><prompt> \n \(corpus) \n </prompt></cron-fire>"]
    for count in [0, 1, 2, 318, 319, 320, 321, 640] {
        for fragment in fragments { texts.append(String(repeating: fragment, count: count)) }
    }
    for text in texts {
        let variants: [[[String: Any]]] = [
            [["type": "text", "text": text]],
            [["type": "text", "text": text], ["type": "text", "text": "after"]],
            [["type": "text", "text": "before \u{600}"], ["type": "text", "text": text]],
            [["type": "image", "name": "image"], ["type": "text", "text": text]],
            [["type": "text", "text": "<system-reminder>hidden</system-reminder>"], ["type": "text", "text": text]],
        ]
        for content in variants {
            let raw: [[String: Any]] = [
                ["id": "u", "role": "user", "created_at": "1", "content": content],
                ["id": "a", "role": "assistant", "created_at": "2", "content": content],
            ]
            let messages = try KimiWire.decoder().decode([KimiMessage].self,
                from: JSONSerialization.data(withJSONObject: raw))
            let summaries = ConversationProjection().update(messages, isRunning: false).navigation
            precondition(summaries.count == 1)
            let expectedPrompt = reference(messages[0])
            let prompt = expectedPrompt.isEmpty
                ? String(messages[0].content.compactMap(\.name).joined(separator: ", ").prefix(320)) : expectedPrompt
            let answer = messages.last { $0.role == "assistant" && $0.content.contains { $0.type == "text" && !$0.isRuntimeContext && !($0.text ?? "").isEmpty } }
            precondition(summaries[0].prompt == prompt && summaries[0].reply == answer.map(reference) ?? "",
                         "single/multi-part excerpts must equal the original Character-budget algorithm")
        }
    }
    print("PASS: single-part excerpt fast path equals original Character budgets across Unicode boundaries and mixed parts")
}
