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
    var uncertain = local
    uncertain.status = "unknown"; uncertain.error = "Send unconfirmed"
    let recovered = KimiPrompt.reconcile(local: [uncertain], remote: [prompt], messages: [])
    precondition(recovered.first?.error == nil, "An authoritative receipt clears the old send uncertainty")
    var steerFailed = prompt
    steerFailed.error = "Steer was not confirmed"
    precondition(KimiPrompt.reconcile(local: [steerFailed], remote: [prompt], messages: []).first?.error == steerFailed.error,
                 "A queued accepted message keeps its unresolved steer warning")
    var running = prompt; running.status = "running"
    precondition(KimiPrompt.reconcile(local: [steerFailed], remote: [running], messages: []).first?.error == nil,
                 "Once the message runs, its old steer warning is no longer actionable")
    print("PASS: Kimi pending queue recovery, identity reconciliation, no duplicate bubble")
}
