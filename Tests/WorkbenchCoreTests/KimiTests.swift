import Foundation
import WorkbenchCore

func checkKimiProtocol() throws {
    func require(_ value: Bool, _ message: String = "check failed") { precondition(value, message) }
    let session = #"{"id":"s1","title":"测试","updated_at":"2026-09-20","busy":true,"pending_interaction":"none","metadata":{"cwd":"/tmp"},"agent_config":{"model":"test/model"}}"#
    let decodedSession = try KimiWire.decode(KimiSession.self, from: Data("{\"code\":0,\"data\":\(session)}".utf8))
    require(decodedSession.updatedAt == "2026-09-20" && decodedSession.model == "test/model")
    let rawValue = try KimiWire.decode(JSONValue.self, from: Data(#"{"code":0,"data":{"raw_key":{"tool_name":"test"}}}"#.utf8))
    require(rawValue["raw_key"]["tool_name"].string == "test", "Untyped payload keys stay unchanged")
    let delta = try KimiWire.decodeEvent(from: Data(#"{"type":"assistant.delta","session_id":"s1","payload":{"delta":"中文","raw_key":1}}"#.utf8))
    require(delta.sessionId == "s1" && delta.payload["delta"].string == "中文" && delta.payload["raw_key"].int == 1)
    do {
        _ = try KimiWire.decodeEvent(from: Data(#"{"type":"ack","code":1,"msg":"subscription denied"}"#.utf8))
        preconditionFailure("expected ack error before decoding missing payload")
    } catch { require(error.localizedDescription == "subscription denied") }
    func snapshot(_ seq: Int = 10, text: String = "你好😀", epoch: String = "e1") throws -> KimiSnapshot {
        let escaped = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        return try KimiWire.decoder().decode(KimiSnapshot.self, from: Data("""
        {"as_of_seq":\(seq),"epoch":"\(epoch)","session":\(session),"messages":{"items":[],"has_more":false},"in_flight_turn":{"turn_id":1,"assistant_text":\(escaped),"thinking_text":"","running_tools":[]},"pending_approvals":[],"pending_questions":[]}
        """.utf8))
    }
    func event(_ type: String, seq: Int = 11, offset: Int = 4, delta: String = "继续", epoch: String = "e1") throws -> KimiEvent {
        try KimiWire.decoder().decode(KimiEvent.self, from: Data("""
        {"type":"\(type)","session_id":"s1","epoch":"\(epoch)","seq":\(seq),"volatile":\(type.hasSuffix("delta")),"offset":\(offset),"payload":{"agentId":"main","turnId":1,"delta":"\(delta)"}}
        """.utf8))
    }
    var c = try KimiConversation(snapshot())
    require(c.messages.isEmpty && c.displayMessages.last?.content.first?.text == "你好😀", "Volatile output must enter the shared transcript")
    require(c.snapshot.session.cwd == "/tmp" && c.snapshot.session.model == "test/model")
    require(!c.apply(try event("assistant.delta")))
    require(c.live?.assistantText == "你好😀继续")
    require(!c.apply(try event("assistant.delta")))
    require(c.live?.assistantText == "你好😀继续", "duplicate deltas must not append")
    require(c.apply(try event("assistant.delta", offset: 20)), "a missing delta requires snapshot")
    require(!c.apply(try event("turn.ended", seq: 9)), "old durable events are ignored")
    require(c.apply(try event("turn.ended", epoch: "e2")), "epoch changes require snapshot")
    for kind in ["prompt.queued", "prompt.steered", "turn.steer", "compaction.started", "compaction.blocked", "compaction.cancelled", "compaction.completed", "goal.updated"] {
        var steered = try KimiConversation(snapshot())
        require(steered.apply(try event(kind, seq: 21)), "Control events must refresh history, busy state and context usage")
    }
    c.reconcile(try snapshot(20, text: "恢复😀"))
    require(c.lastSeq == 20 && c.live?.assistantText == "恢复😀")
    require(!c.apply(try event("assistant.delta", seq: 11, offset: 0, delta: "旧步骤不能混入")))
    require(c.live?.assistantText == "恢复😀")
    func history(_ ids: [String], more: Bool) throws -> KimiPage<KimiMessage> {
        let rows = ids.map { "{\"id\":\"\($0)\",\"role\":\"user\",\"content\":[],\"created_at\":\"\($0)\"}" }.joined(separator: ",")
        return try KimiWire.decoder().decode(KimiPage<KimiMessage>.self, from: Data("{\"items\":[\(rows)],\"has_more\":\(more)}".utf8))
    }
    c.prepend(try history(["02", "03"], more: true))
    c.prepend(try history(["02", "01"], more: false))
    require(c.messages.map(\.id) == ["01", "02", "03"] && !c.hasOlder)
    for newTurn in [false, true] {
        let user = newTurn ? ",{\"id\":\"u2\",\"role\":\"user\",\"created_at\":\"2\",\"content\":[{\"type\":\"text\",\"text\":\"再来一次\"}]}" : ""
        let data = Data("""
        {"as_of_seq":1,"epoch":"e1","session":\(session),"messages":{"items":[{"id":"a","role":"assistant","created_at":"1","content":[{"type":"text","text":"相同内容"}]}\(user)],"has_more":false},"in_flight_turn":{"turn_id":1,"assistant_text":"相同内容","thinking_text":"","running_tools":[]},"pending_approvals":[],"pending_questions":[]}
        """.utf8)
        let value = KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: data))
        require(value.displayMessages.count == (newTurn ? 3 : 1), "Deduplicate only inside the current turn")
    }
    let errorData = Data(#"{"code":1,"msg":"meaningful error","data":{"different":"shape"}}"#.utf8)
    do { _ = try KimiWire.decode(KimiSession.self, from: errorData); preconditionFailure("expected error") }
    catch { require(error.localizedDescription == "meaningful error") }
    let interactionData = Data("""
    {"as_of_seq":22,"epoch":"e1","session":\(session),"messages":{"items":[],"has_more":true},"pending_approvals":[{"approval_id":"a1","tool_name":"Shell","action":"run command","tool_input_display":{"command":"printf ok"},"agent_id":"main"}],"pending_questions":[{"question_id":"q1","questions":[{"id":"choice","question":"Choose","options":[{"id":"yes","label":"Yes"}],"multi_select":false,"allow_other":true}]}]}
    """.utf8)
    let interactions = try KimiWire.decoder().decode(KimiSnapshot.self, from: interactionData)
    require(interactions.pendingApprovals[0].toolInputDisplay["command"].string == "printf ok")
    require(interactions.pendingQuestions[0].questions[0].allowOther == true)
    if let directory = ProcessInfo.processInfo.environment["WORKBENCH_KIMI_FIXTURE_DIR"] {
        let live = try KimiWire.decode(KimiSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("snapshot.json")))
        let list = try KimiWire.decode(KimiPage<KimiSession>.self, from: Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("sessions.json")))
        require(!list.items.isEmpty && !live.messages.items.isEmpty)
        require(live.messages.items.map(\.createdAt) == live.messages.items.map(\.createdAt).sorted())
        print("PASS: live Kimi snapshot (\(live.messages.items.count) messages), session page (\(list.items.count) sessions)")
    }
    print("PASS: Kimi UTF-16 streaming, overlap, gaps, epochs, business errors, interactions")
}
