import Foundation
import WorkbenchCore

func checkKimiTranscript() throws {
    func require(_ value: Bool, _ message: String = "check failed") { precondition(value, message) }

    // The REST page mixes snake_case envelope keys with the transcript's own
    // camelCase records, and its items are a union of turns and markers.
    let pageJSON = #"""
    {"code":0,"data":{"agent_id":"agent_01","has_more":true,"seq":41,"items":[
      {"kind":"turn","turnId":"t1","ordinal":1,"state":"completed","prompt":"检查输入","steps":[
        {"kind":"step","stepId":"t1.1","turnId":"t1","ordinal":1,"state":"completed","frames":[
          {"kind":"thinking","frameId":"t1.1.f1","text":"先看代码"},
          {"kind":"text","frameId":"t1.1.f2","role":"assistant","text":"开始检查"},
          {"kind":"tool","frameId":"t1.1.f3","toolCallId":"call_1","name":"Read","state":"done","input":{"path":"/fixture/A.swift"},"output":"struct A {}"}]},
        {"kind":"step","stepId":"t1.2","turnId":"t1","ordinal":2,"state":"failed","endMessage":"模型请求失败","frames":[
          {"kind":"notice","frameId":"t1.2.f1","level":"warning","message":"重试一次"}]}]},
      {"kind":"marker","markerId":"m1","marker":"compaction"}]}}
    """#
    let page = try KimiWire.decode(KimiTranscriptPage.self, from: Data(pageJSON.utf8))
    require(page.agentId == "agent_01" && page.hasMore && page.seq == 41)
    require(page.items.count == 2 && page.items.last?.kind == "marker")

    var transcript = KimiSubagentTranscript(agentId: "agent_01")
    transcript.load(page, prepend: false)
    require(transcript.turns.map(\.turnId) == ["t1"], "Markers carry nothing this view renders")
    require(transcript.hasMoreOlder && transcript.seq == 41)
    let frames = transcript.turns[0].steps?.flatMap { $0.frames ?? [] } ?? []
    require(frames.map(\.kind) == ["thinking", "text", "tool", "notice"])
    require(frames[0].text == "先看代码" && frames[1].role == "assistant")
    require(frames[2].tool?.id == "call_1" && frames[2].tool?.status == .succeeded)
    require(frames[2].tool?.input?["path"].string == "/fixture/A.swift")
    require(frames[2].tool?.output?.string == "struct A {}")
    require(frames[0].tool == nil && frames[3].tool == nil, "Only tool frames become tool cards")
    require(frames[3].message == "重试一次" && frames[3].level == "warning")
    require(transcript.turns[0].steps?[1].endMessage == "模型请求失败")

    func batch(_ ops: String, seq: Int) throws -> KimiTranscriptOpsBatch {
        try KimiWire.decodeTranscript(KimiTranscriptOpsBatch.self, from: Data("""
        {"type":"transcript.ops","session_id":"s1","epoch":"e1","seq":\(seq),"volatile":true,"payload":{"type":"transcript.ops","agent_id":"agent_01","seq":\(seq),"ops":[\(ops)]}}
        """.utf8))
    }

    // A live turn arrives as a header, then its step header, then whole frames.
    transcript.apply(try batch(#"{"op":"turn.upsert","turn":{"kind":"turn","turnId":"t2","ordinal":2,"state":"running","origin":{"kind":"user"},"prompt":"继续"}}"#, seq: 42))
    require(transcript.turns.map(\.turnId) == ["t1", "t2"] && transcript.turns[1].prompt == "继续")
    transcript.apply(try batch(#"{"op":"step.upsert","turnId":"t2","step":{"kind":"step","stepId":"t2.1","turnId":"t2","ordinal":1,"state":"running"}}"#, seq: 42))
    transcript.apply(try batch(#"{"op":"frame.upsert","turnId":"t2","stepId":"t2.1","frame":{"kind":"tool","frameId":"t2.1.f1","toolCallId":"call_2","name":"Bash","state":"running","input":{"command":"npm test"}}}"#, seq: 42))
    require(transcript.turns[1].steps?.count == 1)
    require(transcript.turns[1].steps?[0].frames?.first?.tool?.status == .running)

    // The same frame upserted again replaces it; a repeated header keeps frames.
    transcript.apply(try batch(#"{"op":"frame.upsert","turnId":"t2","stepId":"t2.1","frame":{"kind":"tool","frameId":"t2.1.f1","toolCallId":"call_2","name":"Bash","state":"error","error":"exit 1"}}"#, seq: 43))
    let retried = transcript.turns[1].steps?[0].frames ?? []
    require(retried.count == 1 && retried[0].tool?.status == .failed && retried[0].error == "exit 1")
    transcript.apply(try batch(#"{"op":"step.upsert","turnId":"t2","step":{"kind":"step","stepId":"t2.1","turnId":"t2","ordinal":1,"state":"completed"}}"#, seq: 44))
    require(transcript.turns[1].steps?[0].state == "completed")
    require(transcript.turns[1].steps?[0].frames?.count == 1, "A step header must not drop the frames already folded in")
    transcript.apply(try batch(#"{"op":"turn.upsert","turn":{"kind":"turn","turnId":"t2","ordinal":2,"state":"completed","origin":{"kind":"user"}}}"#, seq: 45))
    require(transcript.turns[1].state == "completed" && transcript.turns[1].steps?.count == 1,
            "A turn header must not drop the steps already folded in")
    require(transcript.seq == 45)

    // Operations for turns and steps this client never saw are dropped, not invented.
    let dropped = #"""
    {"op":"step.upsert","turnId":"t9","step":{"kind":"step","stepId":"t9.1","turnId":"t9","ordinal":1,"state":"running"}},
    {"op":"frame.upsert","turnId":"t1","stepId":"t1.9","frame":{"kind":"text","frameId":"x","text":"丢掉的帧"}},
    {"op":"append","target":{"type":"frame","turnId":"t2","stepId":"t2.1","frameId":"t2.1.f1"},"offset":0,"text":"增量"},
    {"op":"meta.merge","meta":{"activity":"turn"}}
    """#
    transcript.apply(try batch(dropped, seq: 46))
    require(transcript.turns.map(\.turnId) == ["t1", "t2"])
    require((transcript.turns[0].steps?.count ?? 0) == 2 && (transcript.turns[1].steps?[0].frames?.count ?? 0) == 1)

    // The subscription reset carries no turns, so it is a watermark only.
    let reset = try KimiWire.decodeTranscript(KimiTranscriptReset.self, from: Data(#"{"type":"transcript.reset","session_id":"s1","payload":{"type":"transcript.reset","agent_id":"agent_01","has_more_older":true,"seq":47,"snapshot":{"items":[{"kind":"marker","markerId":"m2","marker":"compaction"}],"tasks":[],"interactions":[],"attachments":[],"todos":[],"prompts":[],"meta":{}}}}"#.utf8))
    transcript.apply(reset)
    require(transcript.turns.map(\.turnId) == ["t1", "t2"], "An empty reset must not discard the page already read")
    require(transcript.seq == 47)
    transcript.apply(try KimiWire.decodeTranscript(KimiTranscriptReset.self, from: Data(#"{"type":"transcript.reset","session_id":"s1","payload":{"type":"transcript.reset","agent_id":"agent_01","has_more_older":false,"seq":48,"snapshot":{"items":[{"kind":"turn","turnId":"t3","ordinal":3,"state":"running","steps":[]}],"tasks":[],"interactions":[],"attachments":[],"todos":[],"prompts":[],"meta":{}}}}"#.utf8)))
    require(transcript.turns.map(\.turnId) == ["t3"] && !transcript.hasMoreOlder, "A reset that carries turns replaces them")

    // An older page goes first, drops duplicates and keeps the newest watermark.
    let older = try KimiWire.decode(KimiTranscriptPage.self, from: Data(#"{"code":0,"data":{"agent_id":"agent_01","has_more":false,"seq":39,"items":[{"kind":"turn","turnId":"t0","ordinal":0,"state":"completed","steps":[]},{"kind":"turn","turnId":"t3","ordinal":3,"state":"running","steps":[]}]}}"#.utf8))
    transcript.load(older, prepend: true)
    require(transcript.turns.map(\.turnId) == ["t0", "t3"], "Older turns go first and duplicates are dropped")
    require(transcript.seq == 48, "An older page must not move the watermark back")
    require(!transcript.hasMoreOlder)

    transcript.apply(try batch(#"{"op":"items.remove","ids":["t3"]}"#, seq: 49))
    require(transcript.turns.map(\.turnId) == ["t0"])

    // A tool frame without a state stays uncertain rather than reading as done.
    let unknown = try KimiWire.decode(KimiTranscriptFrame.self, from: Data(#"{"code":0,"data":{"kind":"tool","frameId":"f","toolCallId":"call_9","name":"Bash"}}"#.utf8))
    require(unknown.tool?.status == .missingResult && unknown.tool?.name == "Bash")
    let unnamed = try KimiWire.decode(KimiTranscriptFrame.self, from: Data(#"{"code":0,"data":{"kind":"tool","frameId":"f","toolCallId":"call_9","state":"done"}}"#.utf8))
    require(unnamed.tool?.name == "call_9", "A frame without a name falls back to its call id")
    print("PASS: subagent transcript page, operation folding, reset watermarks, older pages and tool frame mapping")
}
