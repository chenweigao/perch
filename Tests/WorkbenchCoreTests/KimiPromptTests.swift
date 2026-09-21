import Foundation
import WorkbenchCore

func checkKimiPrompts() throws {
    let decoder = KimiWire.decoder()
    let prompt = try decoder.decode(KimiPrompt.self, from: Data(#"{"prompt_id":"p","user_message_id":"user-p","status":"queued","content":[{"type":"text","text":"guidance"}]}"#.utf8))
    let local = KimiPrompt(id: "p", content: [.object(["text": .string("guidance")])])
    precondition(KimiPrompt.reconcile(local: [local], remote: [prompt], messages: []).count == 1)
    precondition(KimiPrompt.reconcile(local: [], remote: [prompt], messages: []).first?.text == "guidance")
    let message = try decoder.decode(KimiMessage.self, from: Data(#"{"id":"user-p","role":"user","content":[{"type":"text","text":"guidance"}],"created_at":"now"}"#.utf8))
    precondition(KimiPrompt.reconcile(local: [prompt], remote: [], messages: [message]).isEmpty)
    let other = KimiPrompt(id: "other", content: [.object(["text": .string("guidance")])])
    precondition(KimiPrompt.reconcile(local: [other], remote: [], messages: [message]).count == 1, "Same text is not the same submission")
    precondition(KimiPrompt.reconcile(local: [prompt], remote: [], messages: []).count == 1, "Keep accepted text until its history arrives")
    print("PASS: Kimi pending queue recovery, identity reconciliation, no duplicate bubble")
}
