import Foundation

extension ConversationPresentationModel {
    public static func round36ReviewProbe() throws {
        var comparisons = 0
        func turn(_ tag: String, process: Bool = true, duplicate: String? = nil) throws -> HistoryTurn {
            let messageID = duplicate ?? "a-\(tag)"
            let content: [[String: Any]] = process
                ? [["type":"thinking", "thinking":"analysis \(tag)"], ["type":"text", "text":"working \(tag)"],
                   ["type":"tool_use", "tool_call_id":"t-\(tag)", "tool_name":"Read", "input":["file_path":"/repo/a"]]]
                : [["type":"text", "text":"answer \(tag)"]]
            let raw: [[String: Any]] = [
                ["id":"u-\(tag)", "role":"user", "created_at":"1", "content":[["type":"text", "text":"prompt \(tag)"]]],
                ["id":messageID, "role":"assistant", "created_at":"2", "content":content]]
            let messages = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject:raw))
            let rows = ConversationTimelineEntry.make(messages, isRunning:false).map { Row(entry:$0, tools:[:], activity:nil) }
            return HistoryTurn(chunk:nil, rows:rows, navigation:[])
        }
        func overlay(_ turns: [HistoryTurn], removingPrompt: Bool = false) -> [String:ActivityNarrativeRow] {
            var result: [String:ActivityNarrativeRow] = [:]
            for row in turns.flatMap(\.rows) {
                result[row.entry.id] = ActivityNarrativeRow(narrative:.init(turnID:"review", stageID:"summary", phase:.editing,
                    headline:"annotation", source:.commentary, lifecycle:.streaming), isAnchor:removingPrompt, stageClosed:false)
            }
            return result
        }
        func equal(_ warm: History, _ reference: History, _ activity:[String:ActivityNarrativeRow], _ folded:Bool, _ label:String) {
            let value = warm.presented(activity:activity, foldsProcess:folded)
            let expected = reference.presented(activity:activity, foldsProcess:folded)
            precondition(value.rows == expected.rows && value.foldParents == expected.foldParents, "review differential: \(label)")
            comparisons += 1
        }
        let a = try turn("a"), b = try turn("b"), c = try turn("c")
        precondition(!a.presented(activity:[:], foldsProcess:true)!.foldParents.isEmpty, "non-vacuous process fold")
        for folded in [false, true] {
            for consumed in [false, true] {
                for noFoldConsumed in [false, true] {
                    let first = noFoldConsumed ? try turn("plain", process:false) : a
                    let priorTurns = [first,b,c]
                    let prior = History(turns:priorTurns)
                    _ = prior.presented(activity:[:], foldsProcess:folded)
                    let leads = try [turn("lead1"),turn("lead2"),turn("lead3")]
                    let next = leads + (consumed ? Array(priorTurns.dropFirst()) : priorTurns)
                    let warm = History(turns:next,prior:prior)
                    let reference = History(turns:next)
                    _ = prior.presented(activity:overlay(priorTurns), foldsProcess:!folded)
                    equal(warm,reference,[:],folded,"captured immutable value after prior overlay/shape mutation")
                    equal(warm,reference,[:],!folded,"mismatching fold shape fallback")
                    equal(warm,reference,overlay(next),folded,"current activity refuses adoption")
                    equal(warm,reference,[:],folded,"reuse capture after overlay memo overwrite")
                    equal(warm,reference,["unrelated":overlay(next).values.first!],folded,"irrelevant overlay is empty relevant")
                    equal(prior,History(turns:priorTurns),[:],folded,"COW does not mutate prior")
                }
            }
        }
        for removingPrompt in [false,true] {
            let prior = History(turns:[a,b,c])
            _ = prior.presented(activity:overlay([a,b,c],removingPrompt:removingPrompt),foldsProcess:true)
            let next = try [turn("overlay-lead")] + [a,b,c]
            equal(History(turns:next,prior:prior),History(turns:next),[:],true,"overlay-last capture refusal")
        }
        let missingMemo = History(turns:[a,b,c])
        let next = try [turn("no-memo-lead")] + [a,b,c]
        equal(History(turns:next,prior:missingMemo),History(turns:next),[:],true,"prior memo absent")
        let duplicateA = try turn("dup1",duplicate:"dup"), duplicateB = try turn("dup2",duplicate:"dup")
        let poisonedPrior = History(turns:[duplicateA,duplicateB,c])
        _ = poisonedPrior.presented(activity:[:],foldsProcess:true)
        let repaired = try [turn("replacement")] + [duplicateB,c]
        equal(History(turns:repaired,prior:poisonedPrior),History(turns:repaired),[:],true,"nonunique prior fallback cannot be adopted")
        let cleanPrior = History(turns:[duplicateB,c])
        _ = cleanPrior.presented(activity:[:],foldsProcess:true)
        let newlyPoisoned = [duplicateA,duplicateB,c]
        equal(History(turns:newlyPoisoned,prior:cleanPrior),History(turns:newlyPoisoned),[:],true,"nonunique current fallback")
        var randomState: UInt64 = 0x36_20261117
        func random(_ upper:Int) -> Int {
            randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
            return Int((randomState >> 32) % UInt64(upper))
        }
        var turns = [a,b,c]
        var prior = History(turns:turns)
        for step in 0..<240 {
            let shape = random(2)==0
            let activity = random(4)==0 ? overlay(turns) : [:]
            _ = prior.presented(activity:activity,foldsProcess:shape)
            let consumed = random(2)==0
            let leads = try (0..<(1+random(3))).map { try turn("rnd-\(step)-\($0)", process:random(3)>0) }
            let next = leads + (consumed ? Array(turns.dropFirst()) : turns)
            let warm = History(turns:next,prior:prior)
            _ = prior.presented(activity:overlay(turns),foldsProcess:!shape)
            let reference = History(turns:next)
            equal(warm,reference,[:],shape,"random captured shape \(step)")
            equal(warm,reference,[:],!shape,"random alternate shape \(step)")
            equal(warm,reference,overlay(next),true,"random overlay \(step)")
            turns = next; prior = warm
        }
        print("PASS: round-36 independent History differential \(comparisons) comparisons; both fold shapes, 3 leading turns, consumed no-fold turns, prior-after-capture mutations, both overlay gates, absent memo, both uniqueness gates, 240 deterministic update sequences")
    }
}
