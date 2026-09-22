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
    // A long turn pushes the user message out of the snapshot's trailing page. Once the
    // session is idle and the server no longer reports the prompt, its outcome is in the
    // transcript and the bubble must retire instead of showing "Running" forever.
    precondition(KimiPrompt.reconcile(local: [running], remote: [], messages: [], settled: true).isEmpty,
                 "An idle session retires a prompt the server no longer reports")
    precondition(KimiPrompt.reconcile(local: [running], remote: [], messages: []).count == 1,
                 "A running turn keeps its prompt until the turn settles")
    precondition(KimiPrompt.reconcile(local: [running], remote: [running], messages: [], settled: true).count == 1,
                 "A prompt the server still reports is not retired")
    precondition(KimiPrompt.reconcile(local: [prompt], remote: [], messages: [], settled: true).count == 1,
                 "Queued text was never run and is never retired by idleness")
    // A steered prompt leaves the server queue at steer time and its content enters
    // history under a merged id, so the turn settling is its only retirement signal.
    var steered = prompt; steered.status = "steered"
    precondition(KimiPrompt.reconcile(local: [steered], remote: [], messages: [], settled: true).isEmpty,
                 "A steered prompt retires when its turn settles")
    precondition(KimiPrompt.reconcile(local: [steered], remote: [], messages: []).count == 1,
                 "A steered prompt waits for its context while the turn runs")
    var unacked = local; unacked.status = "sending"
    precondition(KimiPrompt.reconcile(local: [unacked], remote: [], messages: [], settled: true).count == 1,
                 "Unacknowledged text is never retired by idleness")
    // An empty user_message_id must fall back to the prompt id for the history match.
    let unnamed = try decoder.decode(KimiPrompt.self, from: Data(#"{"prompt_id":"self-id","user_message_id":"","status":"running","content":[]}"#.utf8))
    let ownMessage = try decoder.decode(KimiMessage.self, from: Data(#"{"id":"self-id","role":"user","content":[],"created_at":"now"}"#.utf8))
    precondition(KimiPrompt.reconcile(local: [unnamed], remote: [], messages: [ownMessage]).isEmpty)
    print("PASS: Kimi pending queue recovery, identity reconciliation, no duplicate bubble")
}
