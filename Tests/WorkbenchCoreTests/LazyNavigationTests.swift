import Foundation
import WorkbenchCore

/// Pins round-2 shard A lazy navigation: cold projection builds identity-only
/// summaries (excerpt walk deferred to first read), materialized values equal
/// the eager factory byte-for-byte, and reference identity tracks turn rebuild
/// so view change detection never forces materialization.
func checkLazyNavigation() throws {
    func decode(_ raw: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    var raw: [[String: Any]] = []
    for i in 0..<12 {
        raw.append(["id": "u\(i)", "role": "user", "created_at": "u\(i)",
                    "content": [["type": "text", "text": "问题 \(i)：解释结论，混排 identifier 与 English words。"]]])
        if i % 3 == 0 {
            raw.append(["id": "t\(i)", "role": "assistant", "created_at": "t\(i)", "content": [
                ["type": "tool_use", "tool_call_id": "tool-\(i)", "tool_name": "Bash",
                 "input": ["command": "run fixture \(i)"]]]])
            raw.append(["id": "tr\(i)", "role": "tool", "created_at": "tr\(i)", "content": [
                ["type": "tool_result", "tool_call_id": "tool-\(i)", "is_error": false,
                 "output": ["rows": ["中文结果 ok"]]]]])
        }
        raw.append(["id": "a\(i)", "role": "assistant", "created_at": "a\(i)",
                    "content": [["type": "text", "text": "回答 \(i) 结论。\n\n```swift\nlet value = \(i)\n```"]]])
    }
    let messages = try decode(raw)
    let model = ConversationPresentationModel(key: "lazy-nav")
    let snapshot = model.update(.init(messages: messages, language: "zh"))
    let nav = snapshot.navigation
    precondition(nav.count >= 2, "lazy-nav fixture must yield multiple turns (chunk path)")

    // 1. Cold projection leaves earlier summaries unmaterialized (anti-blind:
    //    the tail turn stays eager, so a fully-eager regression fails here).
    for summary in nav.dropLast() {
        precondition(!summary.materialized, "cold projection must not extract earlier excerpts")
    }

    // 2/3. Per-turn eager reference: ids in order, excerpts byte-equal.
    var turns: [[KimiMessage]] = []
    var current: [KimiMessage] = []
    for message in messages {
        if message.isUserPrompt && !current.isEmpty { turns.append(current); current = [] }
        current.append(message)
    }
    if !current.isEmpty { turns.append(current) }
    var reference: [ConversationTurnSummary] = []
    for turn in turns {
        let entries = ConversationTimelineEntry.make(turn)
        if let summary = ConversationTurnSummary.make(turn, entries: entries) { reference.append(summary) }
    }
    precondition(nav.count == reference.count, "navigation count must equal eager reference")
    for (summary, eager) in zip(nav, reference) {
        precondition(summary.id == eager.id, "navigation id order must equal eager")
        precondition(summary.prompt == eager.prompt, "lazy prompt must equal eager byte-for-byte")
        precondition(summary.reply == eager.reply, "lazy reply must equal eager byte-for-byte")
        precondition(summary.materialized, "reading excerpts must materialize")
        precondition(summary.prompt == eager.prompt, "materialization must be idempotent")
    }

    // 4. Reference identity: input-equal update keeps instances; a rebuilt
    //    turn yields a new instance while reused turns keep theirs.
    let again = model.update(.init(messages: messages, language: "zh"))
    precondition(again.navigation.count == nav.count, "input-equal update keeps navigation shape")
    precondition(zip(again.navigation, nav).allSatisfy { $0 === $1 },
                 "input-equal update must keep summary instances")
    var edited = messages
    if let index = edited.firstIndex(where: { $0.id == "a0" }) {
        edited[index] = try decode([["id": "a0", "role": "assistant", "created_at": "a0",
                                     "content": [["type": "text", "text": "修改后的回答 0 结论。"]]]])[0]
    }
    let after = model.update(.init(messages: edited, language: "zh"))
    precondition(after.navigation.count == nav.count, "edit must keep turn count")
    precondition(after.navigation[0] !== nav[0], "rebuilt turn must yield a new summary instance")
    precondition(after.navigation[nav.count - 2] === nav[nav.count - 2],
                 "reused turn must keep its summary instance")

    // 5. Lazy factory defers; value equality materializes both sides.
    let entries0 = ConversationTimelineEntry.make(turns[0])
    let lazyRef = ConversationTurnSummary.lazy(turns[0], entries: entries0)
    let eagerRef = ConversationTurnSummary.make(turns[0], entries: entries0)
    precondition(lazyRef != nil && eagerRef != nil, "fixture turn 0 must yield a summary")
    precondition(!lazyRef!.materialized, "lazy factory must not extract")
    precondition(lazyRef! == eagerRef!, "lazy must equal eager by value")
    precondition(lazyRef!.materialized && eagerRef!.materialized, "equality must materialize both sides")

    // 6. Non-prompt turn yields no summary (guard parity with make).
    let noPrompt = try decode([["id": "x", "role": "assistant", "created_at": "x",
                                "content": [["type": "text", "text": "only answer"]]]])
    precondition(ConversationTurnSummary.lazy(noPrompt, entries: ConversationTimelineEntry.make(noPrompt)) == nil,
                 "lazy factory must mirror make's user-prompt guard")
    precondition(ConversationTurnSummary.make(turns[0], entries: entries0)!.materialized,
                 "the eager factory must extract at construction")

    /// Groups a window into turns the way the projection does, and builds the
    /// per-turn eager reference for it.
    func eagerReference(_ window: [KimiMessage]) -> [ConversationTurnSummary] {
        var groups: [[KimiMessage]] = [], current: [KimiMessage] = []
        for message in window {
            if message.isUserPrompt && !current.isEmpty { groups.append(current); current = [] }
            current.append(message)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.compactMap { ConversationTurnSummary.make($0, entries: ConversationTimelineEntry.make($0)) }
    }

    // 7. Reflexive comparison must not extract. A viewport refresh re-compares
    //    the navigation it already holds (ConversationTurnNavigation.update);
    //    without an identity short-circuit the deferred walk moves into the
    //    first scroll instead of disappearing.
    do {
        let reflexive = ConversationPresentationModel(key: "lazy-nav-reflexive")
        let first = reflexive.update(.init(messages: messages, language: "zh")).navigation
        let second = reflexive.update(.init(messages: messages, language: "zh")).navigation
        precondition(zip(first, second).allSatisfy { $0 === $1 }, "input-equal update must keep instances")
        // Reshape into a distinct buffer holding the same instances: Swift's
        // array equality skips element work only when both sides share one
        // buffer, so this is the comparison a viewport refresh actually makes.
        let reshaped = second.flatMap { [$0] }
        precondition(first == reshaped, "one navigation must equal a reshaped copy of itself")
        for summary in first.dropLast() {
            precondition(!summary.materialized, "reflexive equality must not extract earlier excerpts")
        }
        // Distinct instances with equal content still compare by value, and
        // that comparison extracts: the short-circuit only skips self-comparison.
        let rebuilt = eagerReference(messages)
        for (summary, eager) in zip(first.dropLast(), rebuilt.dropLast()) {
            precondition(summary !== eager, "the eager reference must be a distinct instance")
            precondition(summary == eager, "distinct instances with equal content must compare equal")
            precondition(summary.materialized, "a value comparison of distinct instances must extract")
        }
    }

    // 8. Streaming delta: only the tail turn rebuilds; earlier summaries keep
    //    their instances and stay deferred.
    do {
        let streaming = ConversationPresentationModel(key: "lazy-nav-stream")
        let cold = streaming.update(.init(messages: messages, language: "zh")).navigation
        let tail = try decode([
            ["id": "a11", "role": "assistant", "created_at": "a11",
             "content": [["type": "text", "text": "回答 11 结论。\n\n流式增量文本。"]]]])
        let grown = Array(messages.dropLast()) + tail
        let streamed = streaming.update(.init(messages: grown, isRunning: true, language: "zh")).navigation
        precondition(streamed.count == cold.count, "a tail delta must not change the turn count")
        precondition(zip(streamed.dropLast(), cold.dropLast()).allSatisfy { $0 === $1 },
                     "a tail delta must keep earlier summary instances")
        for summary in streamed.dropLast() {
            precondition(!summary.materialized, "a tail delta must not extract earlier excerpts")
        }
        precondition(streamed.last !== cold.last, "the streamed turn must yield a new instance")
        // A delta rebuilds the navigation array, so the viewport compares two
        // DISTINCT arrays that share their history instances. That comparison
        // must not extract either side (Swift's array equality only skips
        // element work when both sides share one buffer).
        precondition(Array(cold.dropLast()) == Array(streamed.dropLast()),
                     "history navigation must compare equal across a tail delta")
        for summary in streamed.dropLast() {
            precondition(!summary.materialized,
                         "comparing shared instances across distinct arrays must not extract")
        }
    }

    // 9. Prepended page: the window grows at the front, the reused suffix keeps
    //    its instances and stays deferred.
    do {
        let paging = ConversationPresentationModel(key: "lazy-nav-prepend")
        let cold = paging.update(.init(messages: messages, language: "zh")).navigation
        let older = try decode([
            ["id": "uOld", "role": "user", "created_at": "uOld",
             "content": [["type": "text", "text": "更早的一轮问题。"]]],
            ["id": "aOld", "role": "assistant", "created_at": "aOld",
             "content": [["type": "text", "text": "更早的一轮回答。"]]]])
        let prepended = paging.update(.init(messages: older + messages, language: "zh")).navigation
        precondition(prepended.count == cold.count + 1, "a prepended turn must add one navigation entry")
        let reference = eagerReference(older + messages)
        precondition(prepended.map(\.id) == reference.map(\.id),
                     "prepended navigation ids must equal the eager reference, got \(prepended.map(\.id))")
        // The prepended turn becomes a history turn; the previous tail turn
        // stays the tail and is rebuilt (eager) by every update.
        precondition(zip(prepended.dropFirst().dropLast(), cold.dropLast()).allSatisfy { $0 === $1 },
                     "a prepend must keep the reused history instances (identical=\(zip(prepended.dropFirst().dropLast(), cold.dropLast()).filter { $0 === $1 }.count)/\(cold.count - 1))")
        precondition(prepended.last !== cold.last, "the tail summary is rebuilt per update")
        for summary in prepended.dropLast() {
            precondition(!summary.materialized, "a prepend must not extract history excerpts")
        }
    }

    // 10. Language reset rebuilds every summary; the rebuilt excerpts equal the
    //     eager reference, so no stale cached value survives the reset.
    do {
        let localized = ConversationPresentationModel(key: "lazy-nav-language")
        let zh = localized.update(.init(messages: messages, language: "zh")).navigation
        _ = zh.first!.prompt
        precondition(zh.first!.materialized, "reading must materialize before the reset")
        let en = localized.update(.init(messages: messages, language: "en")).navigation
        precondition(en.count == zh.count, "a language reset must keep the turn count")
        precondition(zip(en, zh).allSatisfy { $0 !== $1 }, "a language reset must rebuild every summary")
        let reference = eagerReference(messages)
        for (summary, eager) in zip(en, reference) {
            precondition(summary.id == eager.id && summary.prompt == eager.prompt && summary.reply == eager.reply,
                         "post-reset excerpts must equal the eager reference")
        }
    }

    // 11. Same-ID interior edit: the rebuilt turn serves the edited text, not
    //     the excerpt cached before the edit.
    do {
        let edited = ConversationPresentationModel(key: "lazy-nav-edit")
        let cold = edited.update(.init(messages: messages, language: "zh")).navigation
        _ = cold[0].reply
        var changed = messages
        if let index = changed.firstIndex(where: { $0.id == "a0" }) {
            changed[index] = try decode([["id": "a0", "role": "assistant", "created_at": "a0",
                                         "content": [["type": "text", "text": "编辑后的回答 0 结论。"]]]])[0]
        }
        let after = edited.update(.init(messages: changed, language: "zh")).navigation
        precondition(after[0] !== cold[0], "an interior edit must rebuild the turn's summary")
        precondition(after[0].reply.contains("编辑后的回答"), "the rebuilt summary must serve the edited text")
        precondition(!after[0].reply.hasPrefix("回答 0"), "the pre-edit excerpt must not be served")
        precondition(cold[0].reply.contains("回答 0"), "the retained pre-edit instance keeps its own excerpt")
    }

    // 12. UTF-8 byte oracle (errata 7): Swift String equality is canonical, so
    //     pin the bytes on a normalization-sensitive fixture.
    do {
        let decomposed = "cafe\u{0301} nai\u{308}ve \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} 中文 \u{F900}"
        precondition(Array(decomposed.precomposedStringWithCanonicalMapping.utf8) != Array(decomposed.utf8),
                     "the byte fixture must be normalization-sensitive")
        var raw: [[String: Any]] = []
        for i in 0..<4 {
            raw.append(["id": "b\(i)", "role": "user", "created_at": "b\(i)",
                        "content": [["type": "text", "text": "问题 \(i)：\(decomposed)"]]])
            raw.append(["id": "br\(i)", "role": "assistant", "created_at": "br\(i)",
                        "content": [["type": "text", "text": "回答 \(i)：\(decomposed)\n\n```swift\nlet v = \(i)\n```"]]])
        }
        let window = try decode(raw)
        let byteNav = ConversationPresentationModel(key: "lazy-nav-bytes")
            .update(.init(messages: window, language: "zh")).navigation
        let reference = eagerReference(window)
        precondition(byteNav.count == reference.count, "byte fixture navigation count must match eager")
        for (summary, eager) in zip(byteNav, reference) {
            precondition(Array(summary.prompt.utf8) == Array(eager.prompt.utf8),
                         "lazy prompt bytes must equal eager bytes")
            precondition(Array(summary.reply.utf8) == Array(eager.reply.utf8),
                         "lazy reply bytes must equal eager bytes")
            precondition(summary.prompt.utf8.count > decomposed.utf8.count,
                         "the byte fixture prompt must carry the sensitive text")
        }
    }

    // 13. sameNavigation — the only comparison a viewport refresh may run.
    //     A rebuild that leaves every excerpt untouched (language, epoch or
    //     connection reset) must report "changed" rather than materialize a
    //     whole window to discover the texts are equal.
    do {
        let policy = ConversationPresentationModel(key: "lazy-nav-policy")
        let nav = policy.update(.init(messages: messages, language: "zh")).navigation
        let reference = eagerReference(messages)
        precondition(zip(nav, reference).allSatisfy { $0 !== $1 }, "the reference must be distinct instances")

        // (a) Identical instances inside a distinct buffer: equal, nothing extracted.
        precondition(ConversationTurnSummary.sameNavigation(nav, nav.flatMap { [$0] }),
                     "same instances must compare equal")
        for summary in nav.dropLast() {
            precondition(!summary.materialized, "identity comparison must not extract")
        }

        // (b) The reset shape: two independently projected navigations, distinct
        //     instances, both sides unmaterialized, equal content. Reporting
        //     "changed" costs the caller one republish; value equality would
        //     cost a full-window walk on both sides.
        let reset = ConversationPresentationModel(key: "lazy-nav-reset")
        let rebuilt = reset.update(.init(messages: messages, language: "zh")).navigation
        precondition(zip(nav, rebuilt).allSatisfy { $0 !== $1 }, "a rebuild must yield distinct instances")
        precondition(!ConversationTurnSummary.sameNavigation(nav, rebuilt),
                     "unmaterialized distinct instances must report changed")
        for summary in Array(nav.dropLast()) + Array(rebuilt.dropLast()) {
            precondition(!summary.materialized, "the rebuild comparison must not extract either side")
        }

        // (c) Once both sides are materialized the answer is by value, so a
        //     rebuilt tail carrying unchanged text still skips the refresh
        //     (the pre-lazy behaviour the streaming path depends on).
        precondition(zip(nav, reference).allSatisfy { $0 == $1 }, "fixtures must hold equal content")
        precondition(ConversationTurnSummary.sameNavigation(nav, reference),
                     "materialized equal content must compare equal")

        // (d) Count, id and content mismatches are never equal.
        precondition(!ConversationTurnSummary.sameNavigation(nav, Array(nav.dropFirst())),
                     "a count mismatch must report changed")
        var swapped = reference
        swapped[0] = ConversationTurnSummary.make(turns[1], entries: ConversationTimelineEntry.make(turns[1]))!
        precondition(!ConversationTurnSummary.sameNavigation(nav, swapped),
                     "an id mismatch must report changed")
        var editedMessages = messages
        if let index = editedMessages.firstIndex(where: { $0.id == "a11" }) {
            let replacement = try decode([["id": "a11", "role": "assistant", "created_at": "a11",
                                           "content": [["type": "text", "text": "完全不同的回答文本。"]]]])
            editedMessages[index] = replacement[0]
        }
        precondition(!ConversationTurnSummary.sameNavigation(nav, eagerReference(editedMessages)),
                     "a content mismatch must report changed")
    }

    print("PASS: lazy navigation — cold deferral (anti-blind), byte-equality, identity tracking, reflexive/stream/prepend/language/edit deferral, UTF-8 oracle, non-materializing change detection")
}
