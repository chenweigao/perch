import Foundation
import WorkbenchCore

/// Round 42: differential pin for the displayMessages box-per-lineage memo.
///
/// Oracle design without replicating the getter: a TWIN conversation with an
/// independent memo box receives the identical mutation sequence and is read
/// EXACTLY ONCE per step (always a cold miss = fresh computation); the
/// memoized side is read twice per step (warm + forced hit). Equality at
/// every step proves the memo never serves a stale or divergent array.
/// Covers: streaming deltas (assistant/thinking), tool.progress, non-mutating
/// apply paths (stale offset, subagent), prepend, reconcile (box fork),
/// copy divergence (shared-box over-invalidation must stay correctness-only),
/// the live-dedup and nil-live shapes, concurrent mutators sharing one box
/// against per-thread twins, and anti-blind hit/miss counters.
func checkDisplayMessagesMemo() throws {
    func snapshotData(_ raw: [[String: Any]], live: [String: Any]?) throws -> Data {
        var json: [String: Any] = [
            "as_of_seq": 1, "epoch": "memo",
            "session": ["id": "s", "title": "memo", "updated_at": "1", "busy": true, "main_turn_active": true,
                        "metadata": ["cwd": "/repo"], "agent_config": ["model": "m"]],
            "messages": ["items": raw, "has_more": false],
            "pending_approvals": [], "pending_questions": [],
        ]
        if let live { json["in_flight_turn"] = live }
        return try JSONSerialization.data(withJSONObject: json)
    }
    let baseMessages: [[String: Any]] = [
        ["id": "u1", "role": "user", "created_at": "1", "content": [["type": "text", "text": "检查文件"]]],
        ["id": "a1", "role": "assistant", "created_at": "2", "content": [["type": "text", "text": "第一段回复"]]],
    ]
    func makeConversation(live: [String: Any]?) throws -> KimiConversation {
        KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: snapshotData(baseMessages, live: live)))
    }
    let decoder = KimiWire.decoder()
    func delta(_ text: String, offset: Int, thinking: Bool = false, agent: String = "main") throws -> KimiEvent {
        try decoder.decode(KimiEvent.self, from: JSONSerialization.data(withJSONObject: [
            "type": thinking ? "thinking.delta" : "assistant.delta", "session_id": "s", "epoch": "memo",
            "volatile": true, "offset": offset,
            "payload": ["agentId": agent, "turnId": 1, "delta": text]] as [String: Any]))
    }
    func toolProgress(_ update: String) throws -> KimiEvent {
        try decoder.decode(KimiEvent.self, from: JSONSerialization.data(withJSONObject: [
            "type": "tool.progress", "session_id": "s", "epoch": "memo", "volatile": true,
            "payload": ["agentId": "main", "turnId": 1, "toolCallId": "t1", "update": update]] as [String: Any]))
    }

    var steps = 0
    func compare(_ memoized: KimiConversation, _ twin: KimiConversation, _ label: String) {
        // memoized: two reads (second must be a warm hit); twin: one cold read.
        let warmA = memoized.displayMessages
        let warmB = memoized.displayMessages
        let cold = twin.displayMessages
        precondition(warmA == cold && warmB == cold,
            "displayMessages memo diverged [\(label)] step \(steps): warm==\(warmA == warmB) warmA==cold==\(warmA == cold)")
        steps += 1
    }

    // ---- serial differential sequence ------------------------------------
    let live0: [String: Any] = ["turn_id": 1, "assistant_text": "", "thinking_text": "开始思考。",
                                "running_tools": [["tool_call_id": "t1", "name": "Bash", "args": ["command": "ls"]]]]
    var memo = try makeConversation(live: live0)
    var twin = try makeConversation(live: live0)
    compare(memo, twin, "initial")

    var assistantText = ""
    for index in 0..<12 {
        let text = "第 \(index) 段:验证构建与合并,继续推进收尾。"
        _ = memo.apply(try delta(text, offset: assistantText.utf16.count))
        _ = twin.apply(try delta(text, offset: assistantText.utf16.count))
        assistantText += text
        compare(memo, twin, "assistant-delta-\(index)")
    }
    var thinkingText = "开始思考。"
    for index in 0..<4 {
        let text = "思考片段 \(index) 检查读取。"
        _ = memo.apply(try delta(text, offset: thinkingText.utf16.count, thinking: true))
        _ = twin.apply(try delta(text, offset: thinkingText.utf16.count, thinking: true))
        thinkingText += text
        compare(memo, twin, "thinking-delta-\(index)")
    }
    // tool.progress (live mutation → bump)
    _ = memo.apply(try toolProgress("building 45%"))
    _ = twin.apply(try toolProgress("building 45%"))
    compare(memo, twin, "tool-progress")
    // non-mutating applies: wrong offset (appendDelta refuses) and subagent —
    // memo must NOT bump and must keep serving the correct array.
    _ = memo.apply(try delta("坏偏移", offset: 999_999))
    _ = twin.apply(try delta("坏偏移", offset: 999_999))
    compare(memo, twin, "stale-offset-refused")
    _ = memo.apply(try delta("子代理文本", offset: assistantText.utf16.count, agent: "worker-1"))
    _ = twin.apply(try delta("子代理文本", offset: assistantText.utf16.count, agent: "worker-1"))
    compare(memo, twin, "subagent-ignored")

    // prepend a page
    let pageJSON: [String: Any] = ["has_more": true, "items": [
        ["id": "u0", "role": "user", "created_at": "-2", "content": [["type": "text", "text": "更早的请求"]]],
        ["id": "a0", "role": "assistant", "created_at": "-1", "content": [["type": "text", "text": "更早的回复"]]],
    ]]
    let page = try decoder.decode(KimiPage<KimiMessage>.self, from: JSONSerialization.data(withJSONObject: pageJSON))
    memo.prepend(page)
    twin.prepend(page)
    compare(memo, twin, "prepend-page")

    // Anti-blind mid-sequence: boxes are per-lineage (each mutation forks a
    // fresh one), so counters cover the current box's lifetime — which is
    // exactly one mutation→read→read cycle here. Both paths must have run:
    // a never-caching mutant shows hits == 0; an always-serve-cache mutant
    // shows misses == 0 (and the twin comparisons would diverge).
    let midStats = memo.displayMemoStats
    precondition(midStats.hits >= 1 && midStats.misses >= 1,
                 "warm and cold paths must both execute per lineage, got \(midStats)")

    // ---- copy divergence: mutation forks the box --------------------------
    do {
        let beforeCopy = memo.displayMessages
        var branch = memo
        _ = branch.apply(try delta("分支增量", offset: assistantText.utf16.count))
        // The origin's fields are unchanged; the branch's mutation replaced
        // only the BRANCH's box, so the origin keeps its warm cache — and it
        // must return the SAME array as before (never the branch's state).
        precondition(memo.displayMessages == beforeCopy,
                     "a diverged copy's mutation must not leak into the origin's displayMessages")
        var branchTwin = twin
        _ = branchTwin.apply(try delta("分支增量", offset: assistantText.utf16.count))
        let bd = branch.displayMessages
        let btd = branchTwin.displayMessages
        if bd != btd {
            print("R42DBG branch count=\(bd.count) twin count=\(btd.count)")
            for (i, (x, y)) in zip(bd, btd).enumerated() where x != y {
                print("R42DBG first diff at \(i): branch=\(x) twin=\(y)")
                break
            }
            print("R42DBG branchLive=\(String(describing: branch.live))")
            print("R42DBG twinLive=\(String(describing: branchTwin.live))")
        }
        precondition(bd == btd,
                     "the diverged copy must match an independent twin with the same mutation")
        compare(memo, twin, "post-divergence-origin")
    }

    // ---- reconcile forks the box ------------------------------------------
    do {
        let reconciled: [[String: Any]] = baseMessages + [
            ["id": "a2", "role": "assistant", "created_at": "9", "content": [["type": "text", "text": "reconcile 后的新回复"]]],
        ]
        let snap = try KimiWire.decoder().decode(KimiSnapshot.self, from: snapshotData(reconciled, live: nil))
        memo.reconcile(snap)
        twin.reconcile(snap)
        compare(memo, twin, "reconcile-nil-live")
    }

    // ---- dedup + nil-live shapes -------------------------------------------
    do {
        let dedupLive: [String: Any] = ["turn_id": 2, "assistant_text": "第一段回复", "thinking_text": "", "running_tools": []]
        var dedup = try makeConversation(live: dedupLive)
        var dedupTwin = try makeConversation(live: dedupLive)
        // The last assistant message already carries the live text → parts
        // empty → plain messages. Read twice on the memo side via compare.
        compare(dedup, dedupTwin, "dedup-live-equals-last")
        _ = dedup.apply(try delta("追加", offset: "第一段回复".utf16.count))
        _ = dedupTwin.apply(try delta("追加", offset: "第一段回复".utf16.count))
        compare(dedup, dedupTwin, "dedup-then-growth")
        let noLive = try makeConversation(live: nil)
        let noLiveTwin = try makeConversation(live: nil)
        compare(noLive, noLiveTwin, "nil-live")
    }

    // ---- concurrency: four threads share ONE box, each with a private twin --
    do {
        let shared = try makeConversation(live: live0)
        let failureCount = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 4) { thread in
            var own = shared                      // shares the box with `shared` and siblings
            var ownTwin = try! makeConversation(live: live0)  // independent box
            var text = ""
            for index in 0..<40 {
                let piece = "线程\(thread) 段\(index):构建验证。"
                let event = try! delta(piece, offset: text.utf16.count)
                _ = own.apply(event)
                _ = ownTwin.apply(event)
                text += piece
                if own.displayMessages != ownTwin.displayMessages {
                    failureCount.increment()
                }
            }
        }
        precondition(failureCount.value == 0,
                     "concurrent shared-box mutations diverged \(failureCount.value) times")
        // `shared` itself never mutated: its reads must still equal its own
        // fresh twin despite 160 cross-thread bumps (over-invalidation only).
        let sharedTwin = try makeConversation(live: live0)
        precondition(shared.displayMessages == sharedTwin.displayMessages,
                     "cross-thread box forks must never corrupt or stale the shared origin")
    }

    // ---- anti-blind ---------------------------------------------------------
    let stats = memo.displayMemoStats
    precondition(stats.hits > 0 && stats.misses > 0,
                 "memo must demonstrably hit and miss, got \(stats)")
    print("PASS: displayMessages memo — \(steps) serial differential steps + copy divergence + "
        + "reconcile fork + dedup/nil-live + 4-thread shared-box concurrency, all equal to "
        + "cold-compute twins (hits \(stats.hits), misses \(stats.misses))")
}

/// Minimal atomic counter for the concurrency leg.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
