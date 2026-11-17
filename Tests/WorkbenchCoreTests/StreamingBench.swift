import Foundation
import WorkbenchCore

/// The synchronous model work one streaming delta costs a long, running Kimi
/// session whose older pages were loaded by scrolling up: the conversation
/// mutation, the activity bar's derivation, the transcript's presentation
/// update and the transcript body's row projection, in the order the views
/// evaluate them; separately, an open find bar's search, and the older pages
/// that scrolling up prepends. Not part of the checked-in suite; run with
/// WORKBENCH_BENCH=streaming. It excludes SwiftUI/AppKit layout and FPS.
func benchStreamingDelta() throws {
    let completedTurns = Int(ProcessInfo.processInfo.environment["STREAMING_TURNS"] ?? "") ?? 230
    let cyclesPerTurn = 34
    let runningCycles = 20
    let measured = 30
    let thinking = String(repeating: "先确认当前实现与调用方的约束，再决定下一步 inspect the call sites. ", count: 9)
    let prompt = String(repeating: "请继续推进这个任务，修复问题并验证结果。", count: 8)
    let answer = (0..<12).map { "- 第 \($0) 项结论：`Identifier\($0)` 已经处理，并附带 English notes for the reader." }
        .joined(separator: "\n")
    let readOutput = (0..<60).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
    let bashOutput = (0..<24).map { "PASS case \($0) 通过 in 0.0\($0)s" }.joined(separator: "\n")
    let grepOutput = (0..<16).map { "Sources/File\($0).swift:\($0 * 7): match 匹配行" }.joined(separator: "\n")
    let oldBlock = (0..<14).map { "    let value\($0) = compute(\($0)) // 原有实现" }.joined(separator: "\n")
    let newBlock = (0..<16).map { "    let value\($0) = computeFaster(\($0)) // 新实现" }.joined(separator: "\n")
    let written = (0..<90).map { "line \($0): 写入的文件内容 with mixed text" }.joined(separator: "\n")

    var raw: [[String: Any]] = []
    var clock = 0
    func stamp() -> String { clock += 1; return String(format: "2026-10-23T%09d", clock) }
    func cycle(turn: Int, step: Int) {
        let id = "t\(turn)-s\(step)"
        let tool: [String: Any]
        let output: String
        switch step % 10 {
        case 0, 3, 6:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Read",
                    "input": ["file_path": "/repo/Sources/File\(step).swift"]]
            output = readOutput
        case 1, 4, 8:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Bash",
                    "input": ["command": "swift test --filter Case\(step)", "description": "Run case \(step)"]]
            output = bashOutput
        case 2, 7:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Grep",
                    "input": ["pattern": "compute\\(", "path": "/repo/Sources"]]
            output = grepOutput
        case 5:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Edit",
                    "input": ["file_path": "/repo/Sources/File\(step).swift", "old_string": oldBlock, "new_string": newBlock]]
            output = "ok"
        default:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Write",
                    "input": ["file_path": "/repo/Generated/Out\(turn)-\(step).swift", "content": written]]
            output = "ok"
        }
        var content: [[String: Any]] = [["type": "thinking", "thinking": thinking]]
        if step % 4 == 0 { content.append(["type": "text", "text": "检查第 \(step) 步的结果。"]) }
        content.append(tool)
        raw.append(["id": "a-\(id)", "role": "assistant", "created_at": stamp(), "content": content])
        raw.append(["id": "r-\(id)", "role": "tool", "created_at": stamp(), "content": [
            ["type": "tool_result", "tool_call_id": "call-\(id)", "is_error": false, "output": output]]])
    }
    func turn(_ turn: Int, running: Bool) {
        raw.append(["id": "u-\(turn)", "role": "user", "created_at": stamp(),
                    "content": [["type": "text", "text": "第 \(turn) 轮：\(prompt)"]]])
        for step in 0..<(running ? runningCycles : cyclesPerTurn) { cycle(turn: turn, step: step) }
        if !running {
            raw.append(["id": "f-\(turn)", "role": "assistant", "created_at": stamp(), "content": [
                ["type": "thinking", "thinking": thinking], ["type": "text", "text": "完成。\n\n\(answer)"]]])
        }
    }
    // Earlier turns of the same shape, read later as 100-message history pages.
    // A page boundary can split a turn and separate a call from its result.
    for index in -5..<0 { turn(index, running: false) }
    let earlierRaw = raw
    raw = []
    for index in 0...completedTurns { turn(index, running: index == completedTurns) }
    let snapshotJSON: [String: Any] = [
        "as_of_seq": 1, "epoch": "bench",
        "session": ["id": "s", "title": "bench", "updated_at": "1", "busy": true, "main_turn_active": true,
                    "metadata": ["cwd": "/repo"], "agent_config": ["model": "bench"]],
        "messages": ["items": raw, "has_more": false],
        "in_flight_turn": ["turn_id": 1, "assistant_text": "", "thinking_text": "开始思考。", "running_tools": []],
        "pending_approvals": [], "pending_questions": []
    ]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshotJSON)
    var conversation = KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: snapshotData))
    let decoder = KimiWire.decoder()
    func delta(_ text: String, offset: Int) throws -> KimiEvent {
        try decoder.decode(KimiEvent.self, from: JSONSerialization.data(withJSONObject: [
            "type": "thinking.delta", "session_id": "s", "epoch": "bench", "volatile": true, "offset": offset,
            "payload": ["agentId": "main", "turnId": 1, "delta": text]] as [String: Any]))
    }

    let handle = ConversationPresentationHandle()
    let cache = ConversationPresentationCache()
    // Round 27: existing find-bar metrics keep cross-instance semantics —
    // this instance renders through a fresh RenderedSourceCache, so nothing
    // is shared with other instances or metric phases. Within one pass the
    // cache still dedups repeated source strings, which the pre-cache code
    // re-rendered per occurrence: this fixture's tool outputs and answers
    // are template texts repeated across turns (probe on the 16,142-message
    // window: 18,216 source occurrences, 963 unique), so find_bar_cold_query
    // now measures render-unique + lookup-duplicates instead of render-
    // every-occurrence. The dedup is product behavior, not a bench change,
    // but its share of this metric is fixture-amplified; the round report
    // decomposes both effects with the probe counts.
    // Round 30: fresh entry cache as well — cross-instance entry reuse must
    // not leak into the per-instance metrics. Round 32: fresh prefix cache
    // too — this same-instance loop reuses through the instance earlier
    // after its first search, and no shared prefix node may serve or
    // survive across passes.
    let findBar = ConversationSearch(renderedCache: RenderedSourceCache(),
                                     entryCache: ConversationEntryCache(),
                                     prefixCache: ConversationPrefixCache())
    var findStage: [Double] = []
    let key = "host:kimi:s"
    var stages: [String: [Double]] = [:]
    var presentationStages: [String: [Double]] = [:]
    var rowCount = 0, entryCount = 0
    func ms(_ start: Double) -> Double { (benchNow() - start) * 1_000 }
    func nanos(_ value: UInt64) -> Double { Double(value) / 1_000_000 }
    var metrics: ConversationPresentationUpdateMetrics?
    let model = ConversationPresentationModel(key: key, metricsHandler: { metrics = $0 })
    _ = model.update(.init(messages: conversation.displayMessages, isRunning: true, epoch: "bench", language: "zh"))

    for update in 0..<(measured + 5) {
        let event = try delta("继续推理第 \(update) 段。", offset: conversation.live?.thinkingText.utf16.count ?? 0)
        var t = benchNow()
        _ = conversation.apply(event)
        let apply = ms(t)

        // KimiWorkspaceView: the status line's summary of the latest turn.
        t = benchNow()
        let workspaceMessages = conversation.displayMessages
        let display1 = ms(t)
        t = benchNow()
        let activity = ConversationActivity(messages: workspaceMessages, isRunning: true, liveTools: [], online: true,
                                            isThinking: true, isResponding: false)
        let activityMs = ms(t)

        // KimiTimeline + ConversationTranscript.
        t = benchNow()
        let timelineMessages = conversation.displayMessages
        let display2 = ms(t)
        let input = ConversationPresentationModel.Input(messages: timelineMessages, live: [], running: [], isRunning: true,
                                                        online: true, epoch: "bench", language: "zh")
        t = benchNow()
        let snapshot = handle.update(key: key, input: input, cache: cache)
        let presentation = ms(t)
        metrics = nil
        _ = model.update(input)
        t = benchNow()
        let presented = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
        let presentedMs = ms(t)
        t = benchNow()
        let memoryKeys = presented.rows.map { key + ":" + $0.entry.id }
        let contentsMs = ms(t)
        // An open find bar with a query searches again on every update.
        t = benchNow()
        let found = findBar.hits(in: timelineMessages, query: "已经处理", running: true)
        let findMs = ms(t)
        precondition(found.hits.count >= completedTurns)
        rowCount = memoryKeys.count
        precondition(activity.isVisible)
        if update < 2 {
            let reference = ConversationProcessFold.fold(rows: snapshot.displayedRows { _ in nil }, isRunning: true)
            let parents = reference.reduce(into: [String: String]()) { map, row in
                for folded in row.foldedRows ?? [] { map[folded.entry.id] = row.entry.id }
            }
            precondition(presented.rows == reference && presented.foldParents == parents, "presented must equal displayedRows + fold")
            let turn = workspaceMessages.lastIndex(where: \.isUserPrompt) ?? 0
            precondition(activity.edits?.total == SessionEditStats.derive(from: Array(workspaceMessages[turn...]))?.total)
            entryCount = snapshot.rows.count
        }
        guard update >= 5 else { continue }
        findStage.append(findMs)
        for (name, value) in [("apply", apply), ("display_messages_workspace", display1), ("conversation_activity", activityMs),
                              ("display_messages_timeline", display2), ("presentation_update", presentation),
                              ("presented_rows", presentedMs), ("memory_keys", contentsMs)] {
            stages[name, default: []].append(value)
        }
        if let metrics {
            for (name, value) in [("input_comparison", metrics.inputComparisonNanoseconds), ("tool_projection", metrics.toolProjectionNanoseconds),
                                  ("turn_projection", metrics.turnProjectionNanoseconds), ("narrative", metrics.narrativeNanoseconds),
                                  ("row_projection", metrics.rowProjectionNanoseconds), ("summary", metrics.summaryNanoseconds),
                                  ("retained_cost", metrics.retainedCostNanoseconds), ("total", metrics.totalNanoseconds)] {
                presentationStages[name, default: []].append(nanos(value))
            }
        }
    }
    // Scrolling up reads one 100-message page at a time; each is prepended to
    // the window the previous page left.
    let earlier = try decoder.decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: earlierRaw))
    var paged: [Double] = []
    var pageStages: [String: [Double]] = [:]
    var window = conversation.displayMessages
    for page in 0..<3 {
        let start = earlier.count - 100 * (page + 1)
        window = Array(earlier[start..<(start + 100)]) + window
        let messages = window
        let input = ConversationPresentationModel.Input(messages: messages, isRunning: true, epoch: "bench", language: "zh")
        var t = benchNow()
        let snapshot = handle.update(key: key, input: input, cache: cache)
        let presentation = ms(t)
        t = benchNow()
        let presented = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
        let presentedMs = ms(t)
        t = benchNow()
        _ = ConversationActivity(messages: messages, isRunning: true, isThinking: true)
        let activityMs = ms(t)
        paged.append(presentation + presentedMs + activityMs)
        let reference = ConversationPresentationModel(key: key).update(input)
            .presented(activity: [:], foldsProcess: true, isRunning: true)
        precondition(presented == reference, "a prepended page must present like a full projection")
        metrics = nil
        _ = model.update(input)
        for (name, value) in [("presentation_update", presentation), ("presented_rows", presentedMs),
                              ("conversation_activity", activityMs)] {
            pageStages[name, default: []].append(value)
        }
        if let metrics {
            for (name, value) in [("tool_projection", metrics.toolProjectionNanoseconds), ("turn_projection", metrics.turnProjectionNanoseconds),
                                  ("narrative", metrics.narrativeNanoseconds), ("row_projection", metrics.rowProjectionNanoseconds),
                                  ("retained_cost", metrics.retainedCostNanoseconds), ("model_total", metrics.totalNanoseconds)] {
                pageStages[name, default: []].append(nanos(value))
            }
        }
    }
    // Leaving the session releases its presentation state and loaded window.
    var released: [Double] = []
    for _ in 0..<3 {
        // An independent copy: the tuple is the only owner of the window and its projection.
        var held: (ConversationPresentationModel, ConversationPresentationModel.Snapshot, KimiConversation)? = try {
            let copy = KimiConversation(try decoder.decode(KimiSnapshot.self, from: snapshotData))
            let leaving = ConversationPresentationModel(key: key)
            let snapshot = leaving.update(.init(messages: copy.displayMessages, isRunning: true, epoch: "bench", language: "zh"))
            _ = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
            return (leaving, snapshot, copy)
        }()
        let t = benchNow()
        held = nil
        released.append(ms(t))
        precondition(held == nil)
    }
    // Round 16: the cold full-window first-query cost — a fresh
    // ConversationSearch per iteration, so every run pays the complete
    // render + match pass (the find bar pays it per open; workspace history
    // search pays it per executed explicit search — the product cancels
    // in-flight searches on query change rather than re-searching per
    // keystroke, round-27 review F3 wording fix). Measured last so it
    // cannot disturb the other metrics' timing. Round 32: a fresh prefix
    // cache per iteration as well — the cold path pays the whole-window
    // store (payload conversion + admission-cost walk) with zero reuse
    // benefit, the worst-case shape of the trade (round-26 F2 precedent).
    let coldWindow = conversation.displayMessages
    var coldFind: [Double] = []
    for _ in 0..<5 {
        let fresh = ConversationSearch(renderedCache: RenderedSourceCache(),
                                       entryCache: ConversationEntryCache(),
                                       prefixCache: ConversationPrefixCache())
        let t = benchNow()
        let found = fresh.hits(in: coldWindow, query: "已经处理", running: true)
        coldFind.append(ms(t))
        precondition(found.hits.count >= completedTurns)
    }
    // Round 27/30/32/33: the find-bar REOPEN shape — a fresh ConversationSearch
    // over ALL THREE process-wide shared caches (rendered sources + verified
    // entry results + verified prefix results). Round 32: the reopen's
    // prefix hits ONE shared prefix node — a single whole-window
    // verification (round-33 direct probes, both platforms, real bench
    // shape: the stored node's MATERIALIZED copy passes the per-message
    // BYTE comparison — sameWindowBits/sameWindow's bitwise tier compares
    // size bytes and skips stride padding — so a reopen pays ONE
    // whole-window byte comparison, ~1.2MB over the 16k-message bench
    // window ≈ 27µs, not per-entry verification; the profile leaf naming
    // for this bucket is release-inlining dependent and its exact closure
    // attribution stays open per the round-33 review F3)
    // plus reference adoption of the immutable node, replacing timeline
    // construction, per-entry key builds, lookups, verification copies and
    // the instance dictionary build. Round 33: this fixture's query matches
    // the prefix only, so the suffix contributes no hits and the result
    // SHARES the node's hits storage — no per-reopen copy or teardown of
    // the 18k-hit array (the concat guard). Round-30's per-entry shape
    // remains for the suffix (live-turn) search and as the prefix node's
    // miss path, as long as nodes stay admitted, unevicted and in the same
    // locale generation. A hit is not free: key construction, hashing, lock,
    // lastUse and the verification walk. Measured after every pre-existing metric so it
    // cannot disturb them; the shared cache is warmed once, out of timing,
    // by the first search, and every timed reopen must reproduce the warm
    // search's hits EXACTLY — a within-candidate warm-shape equality check,
    // NOT a proof of zero produces and NOT an independent oracle against
    // the pre-cache product (the pin's byteBudget-0 regime is the
    // render-every-occurrence oracle). The reopen-minus-cold delta inside
    // this one binary is the miss-path render of the unique sources plus
    // the miss/hit overhead difference — not an isolated pure-render
    // timing; both metrics share the duplicate-dedup effect described at
    // the findBar declaration, so neither is compared against the pre-cache
    // cold shape as if semantics were unchanged.
    let reopenWarmup = ConversationSearch()
    let reopenExpected = reopenWarmup.hits(in: coldWindow, query: "已经处理", running: true)
    precondition(reopenExpected.hits.count >= completedTurns)
    var reopenFind: [Double] = []
    for _ in 0..<5 {
        let reopen = ConversationSearch()
        let t = benchNow()
        let found = reopen.hits(in: coldWindow, query: "已经处理", running: true)
        reopenFind.append(ms(t))
        // Canonical == plus UTF-8 byte equality of every excerpt: String ==
        // alone would admit canonically-equal-but-byte-different renders
        // (round-27 review recheck: NFC-normalization mutants).
        precondition(found.hits == reopenExpected.hits
                     && found.hits.map { Array($0.excerpt.utf8) } == reopenExpected.hits.map { Array($0.excerpt.utf8) },
                     "shared rendered-source cache changed search results")
    }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    func line(_ name: String, _ value: Double, indent: String = "  ") -> String {
        indent + name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "median_ms=%8.2f", value)
    }
    // Round 33: reopen sits at the 0.01ms print floor (0.10ms), where
    // quantization alone is a 10% spread — finer deltas are unadjudicable.
    // This metric prints at 0.1µs resolution; the baseline side of the A/B
    // still prints two decimals (asymmetry disclosed in the round report).
    func line4(_ name: String, _ value: Double) -> String {
        "  " + name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "median_ms=%10.4f", value)
    }
    let order = ["apply", "display_messages_workspace", "conversation_activity", "display_messages_timeline",
                 "presentation_update", "presented_rows", "memory_keys"]
    let total = order.reduce(0) { $0 + median(stages[$1]!) }
    print("streaming_bench messages=\(conversation.displayMessages.count) entries=\(entryCount) rows=\(rowCount) measured=\(measured)")
    for name in order { print(line(name, median(stages[name]!))) }
    print(line("chain_total", total))
    print("  presentation_update breakdown (separate warm model with metrics):")
    for name in ["input_comparison", "tool_projection", "turn_projection", "narrative", "row_projection", "summary", "retained_cost", "total"] {
        print(line(name, median(presentationStages[name]!), indent: "    "))
    }
    print(line("find_bar_query_update", median(findStage)))
    print(line("find_bar_cold_query", median(coldFind)))
    print(line4("find_bar_reopen_query", median(reopenFind)))
    print(line("older_page_full_chain", median(paged)))
    for name in ["presentation_update", "presented_rows", "conversation_activity"] {
        print(line(name, median(pageStages[name]!), indent: "    "))
    }
    print("    presentation_update breakdown (separate warm model with metrics):")
    for name in ["tool_projection", "turn_projection", "narrative", "row_projection", "retained_cost", "model_total"] {
        print(line(name, median(pageStages[name]!), indent: "      "))
    }
    print(line("release_model_state", median(released)))
}
