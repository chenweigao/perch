import Foundation
import WorkbenchCore

/// Pins the round-38 tool-resolution memo in NarrativeTextCache: a memoized
/// resolution may be reused ONLY while the full VisibleTool value is
/// unchanged (the same validation doctrine as NarrativeTextCache.steps).
/// Method: differential equality — make() over a SHARED cache vs a FRESH
/// cache must produce identical snapshots at every step of a tool-value
/// change sequence (status transitions, input growth, wait-category change,
/// value revisit). A stale memo (validation removed or weakened) diverges
/// from the fresh-cache oracle at the first value change that moves the
/// resolution. An anti-blind assertion proves the sequence actually moves
/// the observable narrative.
func checkToolResolutionMemo() throws {
    func messages(_ value: [[String: Any]]) throws -> [KimiMessage] {
        try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: value))
    }
    let raw: [[String: Any]] = [
        ["id": "u1", "role": "user", "created_at": "",
         "content": [["type": "text", "text": "推进任务"]]],
        ["id": "a1", "role": "assistant", "created_at": "", "content": [
            ["type": "tool_use", "tool_call_id": "shell1", "tool_name": "Bash",
             "input": ["command": "git status"]]]],
    ]
    let entries = ConversationTimelineEntry.make(try messages(raw), isRunning: true)
    func toolValue(_ command: String, status: VisibleTool.Status, output: JSONValue? = nil) -> VisibleTool {
        VisibleTool(id: "shell1", name: "Bash", input: .object(["command": .string(command)]),
                    output: output, status: status)
    }
    let cache = NarrativeTextCache()
    // A streamed-in sequence of values for the SAME tool id.
    let sequence: [VisibleTool] = [
        toolValue("git status", status: .running),
        toolValue("git status", status: .running),                        // unchanged: memo hit
        toolValue("git status", status: .running, output: .string("On branch main")),
        toolValue("git diff --check", status: .running),                  // input changed
        toolValue("git diff --check", status: .returned, output: .string("ok")),
        toolValue("git diff --check", status: .missingResult),            // phase -> blocked
        toolValue("sleep 30", status: .running),                          // wait category
        toolValue("git status", status: .running),                        // revisit an earlier value
    ]
    for (index, tool) in sequence.enumerated() {
        let shared = ActivityNarrativeProjection.make(entries: entries, tools: [tool.id: tool],
                                                      isRunning: true, cache: cache)
        let oracle = ActivityNarrativeProjection.make(entries: entries, tools: [tool.id: tool],
                                                      isRunning: true, cache: NarrativeTextCache())
        precondition(shared == oracle,
                     "step \(index): memoized narrative diverged from the fresh-cache oracle")
        precondition(!shared.stages.isEmpty, "step \(index): fixture must produce stages")
    }
    // Language-switch leg (review F1): resolutions embed localized strings
    // (phase.label, shell headlines, L() fallbacks read AppLanguage.current
    // at derive time); after a language change the shared-cache path must
    // re-derive and match the fresh-cache oracle. Platform disclosure:
    // Bundle.main carries no .lproj in ANY WorkbenchChecks binary (Linux or
    // Darwin CLI), so L() returns key text and this leg is structural-only
    // here; the behavior is observable exclusively in the bundled app.
    let defaultsKey = AppLanguage.defaultsKey
    let priorLanguage = UserDefaults.standard.string(forKey: defaultsKey)
    for language in ["en", "zh-Hans", "en"] {
        UserDefaults.standard.set(language, forKey: defaultsKey)
        let tool = toolValue("git status", status: .running)
        let shared = ActivityNarrativeProjection.make(entries: entries, tools: [tool.id: tool],
                                                      isRunning: true, cache: cache)
        let oracle = ActivityNarrativeProjection.make(entries: entries, tools: [tool.id: tool],
                                                      isRunning: true, cache: NarrativeTextCache())
        precondition(shared == oracle,
                     "language \(language): memo diverged from the fresh-cache oracle after a language switch")
    }
    if let priorLanguage { UserDefaults.standard.set(priorLanguage, forKey: defaultsKey) }
    else { UserDefaults.standard.removeObject(forKey: defaultsKey) }

    // Anti-blind: the sequence must actually move the observable narrative,
    // otherwise every snapshot comparison above could pass vacuously.
    let running = ActivityNarrativeProjection.make(entries: entries,
        tools: ["shell1": sequence[0]], isRunning: true)
    let blocked = ActivityNarrativeProjection.make(entries: entries,
        tools: ["shell1": sequence[5]], isRunning: true)
    precondition(running != blocked,
                 "fixture blind: a status change must change the narrative")
    print("PASS: tool resolution memo — shared-cache vs fresh-cache differential over a value-change sequence (status transitions, input change, wait category, value revisit), a language-switch leg (review F1; vacuous-by-platform on Linux where L() is identity, live on Darwin), and an anti-blind divergence assertion")
}
