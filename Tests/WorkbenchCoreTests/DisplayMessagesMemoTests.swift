import Foundation
import WorkbenchCore

/// Round 42: differential pin for the displayMessages box-per-lineage memo.
///
/// Oracle design — REPLAY-BASED COLD ORACLE: a fresh conversation (hence a
/// fresh, empty memo box) replays the full operation log and is read
/// exactly once, which is a guaranteed cold miss (= fresh computation)
/// under ANY mutant. The first design used a persistent twin conversation
/// read once per step; the mutation battery exposed it as blind to
/// symmetric staleness — a fork-drop mutant made the twin's box stale too,
/// so both sides matched while serving outdated arrays (m2 survived).
/// A fresh box cannot be stale by construction, so this oracle kills
/// every fork-drop shape.
///
/// Coverage: streaming deltas (assistant/thinking), tool.progress,
/// non-mutating apply paths (stale offset refused, subagent ignored — the
/// memo must NOT fork and must keep serving the correct array), prepend,
/// reconcile (box fork via `self =`), copy divergence (a branch's mutation
/// forks only the branch's box; the origin's warm cache must stay correct
/// for ITS fields — the assertion that killed the revision-counter
/// design), dedup and nil-live shapes, 4-thread shared-box concurrency
/// against per-thread replay oracles, and anti-blind per-lineage hit/miss
/// counters.
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
    let live0: [String: Any] = ["turn_id": 1, "assistant_text": "", "thinking_text": "开始思考。",
                                "running_tools": [["tool_call_id": "t1", "name": "Bash", "args": ["command": "ls"]]]]
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
    let pageJSON: [String: Any] = ["has_more": true, "items": [
        ["id": "u0", "role": "user", "created_at": "-2", "content": [["type": "text", "text": "更早的请求"]]],
        ["id": "a0", "role": "assistant", "created_at": "-1", "content": [["type": "text", "text": "更早的回复"]]],
    ]]
    let page = try decoder.decode(KimiPage<KimiMessage>.self, from: JSONSerialization.data(withJSONObject: pageJSON))

    // ---- replay-based cold oracle -----------------------------------------
    var ops: [(inout KimiConversation) throws -> Void] = []
    func replayed(_ extra: ((inout KimiConversation) throws -> Void)? = nil) throws -> [KimiMessage] {
        var fresh = try makeConversation(live: live0)
        for op in ops { try op(&fresh) }
        if let extra { try extra(&fresh) }
        return fresh.displayMessages  // fresh box ⇒ cold miss ⇒ computed now
    }

    var memo = try makeConversation(live: live0)
    var steps = 0
    /// Applies the op to the memoized conversation, records it for replay,
    /// then compares two memo reads (cold-then-warm or warm-warm) against
    /// the replayed cold computation.
    func step(_ label: String, _ op: ((inout KimiConversation) throws -> Void)? = nil) throws {
        if let op {
            try op(&memo)
            ops.append(op)
        }
        let warmA = memo.displayMessages
        let warmB = memo.displayMessages
        let cold = try replayed()
        precondition(warmA == cold && warmB == cold,
            "displayMessages memo diverged [\(label)] step \(steps): warm==\(warmA == cold) counts \(warmA.count)/\(warmB.count)/\(cold.count)")
        steps += 1
    }

    try step("initial")
    var assistantText = ""
    for index in 0..<12 {
        let text = "第 \(index) 段:验证构建与合并,继续推进收尾。"
        let offset = assistantText.utf16.count
        let event = try delta(text, offset: offset)
        assistantText += text
        try step("assistant-delta-\(index)") { _ = $0.apply(event) }
    }
    var thinkingText = "开始思考。"
    for index in 0..<4 {
        let text = "思考片段 \(index) 检查读取。"
        let offset = thinkingText.utf16.count
        let event = try delta(text, offset: offset, thinking: true)
        thinkingText += text
        try step("thinking-delta-\(index)") { _ = $0.apply(event) }
    }
    do {
        let event = try toolProgress("building 45%")
        try step("tool-progress") { _ = $0.apply(event) }
        // Non-mutating applies: refused offset and subagent deltas must NOT
        // fork the box, and the served array must stay correct.
        let stale = try delta("坏偏移", offset: 999_999)
        try step("stale-offset-refused") { _ = $0.apply(stale) }
        let sub = try delta("子代理文本", offset: 999_999, agent: "worker-1")
        try step("subagent-ignored") { _ = $0.apply(sub) }
        try step("prepend-page") { $0.prepend(page) }
    }

    // Anti-blind: boxes are per-lineage (each forking mutation replaces
    // one), so counters cover the current box's lifetime — exactly one
    // mutation→read→read cycle here. Both paths must have run: a
    // never-caching mutant shows hits == 0; an always-serve-cache mutant
    // shows misses == 0 (and the replay comparisons would diverge).
    let midStats = memo.displayMemoStats
    precondition(midStats.hits >= 1 && midStats.misses >= 1,
                 "warm and cold paths must both execute per lineage, got \(midStats)")

    // ---- copy divergence: mutation forks only the branch's box ------------
    do {
        let beforeCopy = memo.displayMessages
        var branch = memo
        let event = try delta("分支增量", offset: assistantText.utf16.count)
        _ = branch.apply(event)
        // The origin's fields are unchanged; the branch's mutation replaced
        // only the BRANCH's box, so the origin keeps its warm cache — and it
        // must return the SAME array as before (never the branch's state).
        precondition(memo.displayMessages == beforeCopy,
                     "a diverged copy's mutation must not leak into the origin's displayMessages")
        let branchExpected = try replayed { _ = $0.apply(event) }
        precondition(branch.displayMessages == branchExpected,
                     "the diverged copy must match the replayed cold computation with the same mutation")
        try step("post-divergence-origin")
    }

    // ---- reconcile forks the box -------------------------------------------
    do {
        let reconciled: [[String: Any]] = baseMessages + [
            ["id": "a2", "role": "assistant", "created_at": "9", "content": [["type": "text", "text": "reconcile 后的新回复"]]],
        ]
        let snap = try KimiWire.decoder().decode(KimiSnapshot.self, from: snapshotData(reconciled, live: nil))
        try step("reconcile-nil-live") { $0.reconcile(snap) }
    }

    // ---- dedup + nil-live shapes (independent lineages) ---------------------
    do {
        let dedupLive: [String: Any] = ["turn_id": 2, "assistant_text": "第一段回复", "thinking_text": "", "running_tools": []]
        var dedup = try makeConversation(live: dedupLive)
        func dedupOracle() throws -> KimiConversation { try makeConversation(live: dedupLive) }
        func compareDedup(_ c: KimiConversation, _ o: KimiConversation, _ label: String) {
            let a = c.displayMessages
            let b = c.displayMessages
            precondition(a == o.displayMessages && b == o.displayMessages, "dedup shape diverged [\(label)]")
        }
        compareDedup(dedup, try dedupOracle(), "dedup-live-equals-last")
        let event = try delta("追加", offset: "第一段回复".utf16.count)
        _ = dedup.apply(event)
        var dedupO = try dedupOracle()
        _ = dedupO.apply(event)
        compareDedup(dedup, dedupO, "dedup-then-growth")
        let noLive = try makeConversation(live: nil)
        compareDedup(noLive, try makeConversation(live: nil), "nil-live")
    }

    // ---- concurrency: four threads share ONE box, per-thread replay oracle --
    do {
        let shared = try makeConversation(live: live0)
        let failureCount = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 4) { thread in
            var own = shared  // shares the box with `shared` and siblings
            var threadOps: [KimiEvent] = []
            var text = ""
            for index in 0..<40 {
                let piece = "线程\(thread) 段\(index):构建验证。"
                let event = try! delta(piece, offset: text.utf16.count)
                _ = own.apply(event)
                threadOps.append(event)
                text += piece
                // Per-thread replay oracle: fresh conversation, fresh box,
                // cold compute — immune to the shared box entirely.
                var fresh = try! makeConversation(live: live0)
                for e in threadOps { _ = fresh.apply(e) }
                if own.displayMessages != fresh.displayMessages {
                    failureCount.increment()
                }
            }
        }
        precondition(failureCount.value == 0,
                     "concurrent shared-box mutations diverged \(failureCount.value) times")
        // `shared` itself never mutated: its reads must still equal a fresh
        // cold computation despite 160 cross-thread box forks.
        let sharedOracle = try makeConversation(live: live0)
        precondition(shared.displayMessages == sharedOracle.displayMessages,
                     "cross-thread box forks must never corrupt or stale the shared origin")
    }

    // ---- anti-blind ---------------------------------------------------------
    let stats = memo.displayMemoStats
    precondition(stats.hits > 0 && stats.misses > 0,
                 "memo must demonstrably hit and miss, got \(stats)")
    print("PASS: displayMessages memo — \(steps) replay-oracle differential steps + copy divergence + "
        + "reconcile fork + dedup/nil-live + 4-thread shared-box concurrency, all equal to "
        + "cold replayed computation (hits \(stats.hits), misses \(stats.misses))")
}

/// Minimal atomic counter for the concurrency leg.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
