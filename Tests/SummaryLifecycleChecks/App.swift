import AppKit
import Foundation
import WorkbenchCore

@main struct SummaryLifecycleChecks {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Summary lifecycle timed out")
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier!.hasPrefix("dev.agentworkbench.summaryqa."))
        let settings = ActivitySummarySettings.shared
        var config = ActivitySummaryConfiguration()
        config.enabled = true; config.baseURL = "http://fixture.invalid/v1"; config.model = "fixture"
        try settings.updateConfiguration(config)
        func tool(_ id: String, _ name: String = "Read", _ status: VisibleTool.Status = .returned) -> VisibleTool {
            VisibleTool(id: id, name: name, input: .object(["path": .string("/fixture/\(id).swift")]), status: status)
        }
        func snapshot(_ tools: [VisibleTool], running: Bool = true, turn: String = "turn") throws -> ActivityNarrativeSnapshot {
            var raw: [[String: Any]] = [["id": turn, "role": "user", "created_at": "",
                "content": [["type": "text", "text": "Fix the sample app"]]]]
            raw += tools.map { ["id": "message-" + $0.id, "role": "assistant", "created_at": "",
                "content": [["type": "tool_use", "tool_call_id": $0.id, "tool_name": $0.name]]] }
            let messages = try KimiWire.decoder().decode([KimiMessage].self,
                from: JSONSerialization.data(withJSONObject: raw))
            return ActivityNarrativeProjection.make(entries: ConversationTimelineEntry.make(messages, isRunning: running),
                tools: Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) }), isRunning: running)
        }
        let read = tool("read")
        let edit = tool("edit", "Edit")
        let first = try snapshot([read])
        let second = try snapshot([read, edit])
        func batch(_ snapshot: ActivityNarrativeSnapshot, _ tools: [VisibleTool], closed: Bool = false) -> ActivitySummaryBatch {
            .init(groupID: snapshot.current!.stageID, phase: snapshot.current!.phase, tools: tools, closed: closed)
        }
        let firstBatch = batch(first, [read])
        let secondBatch = batch(second, [edit])
        var requests: [(ActivitySummaryBatch, ActivitySummaryResult?)] = []
        var unchanged = false
        let store = ActivityNarrativeStore(minimumInterval: 0) { batchConfig, batch, previous in
            precondition(batchConfig.model == "fixture")
            requests.append((batch, previous))
            return ActivitySummaryResult(subject: "Sample", phase: batch.phase,
                summary: unchanged ? "Do not display this wording" : "Summary \(requests.count)", shouldUpdate: !unchanged)
        }
        func observe(_ store: ActivityNarrativeStore, _ snapshot: ActivityNarrativeSnapshot, _ batch: ActivitySummaryBatch?,
                     session: String = "session", running: Bool = true, online: Bool = true) {
            store.observe(session: session, snapshot: snapshot, batch: batch, running: running,
                online: online, following: true, settings: settings)
        }
        observe(store, first, firstBatch)
        try await until { store.narrative(session: "session")?.headline == "Summary 1" }
        unchanged = true
        let firstEnded = try snapshot([read], running: false)
        observe(store, firstEnded, batch(firstEnded, [read], closed: true), running: false)
        try await until { requests.count == 2 }
        precondition(store.narrative(session: "session")?.headline == "Summary 1",
            "No-change within the same stage preserves its existing refinement")
        observe(store, second, secondBatch)
        try await until { requests.count == 3 }
        precondition(requests[2].1?.summary == "Summary 1", "Carry the preceding stage's summary as context")
        precondition(store.narrative(session: "session")?.source == .local,
            "No-change cannot copy a historical headline into a new stage")
        precondition(store.narrative(session: "session")?.headline != "Summary 1")
        let ended = try snapshot([read, edit], running: false)
        observe(store, ended, batch(ended, [edit], closed: true), running: false)
        try await until { requests.count == 4 }
        precondition(store.narrative(session: "session")?.source == .local)
        precondition(store.narrative(session: "session")?.lifecycle == .final)
        observe(store, ended, batch(ended, [edit], closed: true), running: false)
        try await Task.sleep(for: .milliseconds(30))
        precondition(requests.count == 4, "Task end is sent once")
        unchanged = false
        let newTurn = try snapshot([read], turn: "new-turn")
        observe(store, newTurn, batch(newTurn, [read]))
        try await until { requests.count == 5 }
        precondition(requests[4].1 == nil, "A different user request must not inherit the previous turn")
        print("PASS: stage context without duplicate headlines, same-stage no-change, one final event and turn isolation")

        var queued: [ActivitySummaryBatch] = []
        let throttled = ActivityNarrativeStore(minimumInterval: 0.15) { _, batch, _ in
            queued.append(batch)
            return ActivitySummaryResult(subject: "", phase: batch.phase, summary: "Queued \(queued.count)")
        }
        observe(throttled, first, firstBatch)
        try await until { queued.count == 1 }
        observe(throttled, second, secondBatch)
        try await Task.sleep(for: .milliseconds(20))
        observe(throttled, ended, batch(ended, [edit], closed: true), running: false)
        try await until { queued.count == 2 }
        precondition(queued[1].closed, "A burst must send the latest event after throttling")
        try await Task.sleep(for: .milliseconds(170))
        precondition(queued.count == 2)
        print("PASS: throttle merges intermediate events into the newest batch")

        var continuations: [CheckedContinuation<ActivitySummaryResult, Error>] = []
        let delayed = ActivityNarrativeStore(minimumInterval: 0) { _, _, _ in
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        observe(delayed, second, secondBatch)
        try await until { continuations.count == 1 }
        observe(delayed, ended, batch(ended, [edit], closed: true), running: false)
        continuations[0].resume(returning: .init(subject: "", phase: .editing, summary: "Stale result"))
        try await until { continuations.count == 2 }
        precondition(delayed.narrative(session: "session")?.headline != "Stale result")
        continuations[1].resume(returning: .init(subject: "", phase: .editing, summary: "Latest result"))
        try await until { delayed.narrative(session: "session")?.headline == "Latest result" }
        print("PASS: obsolete in-flight results cannot flash over a newer event")

        observe(delayed, first, firstBatch, session: "other")
        try await until { continuations.count == 3 }
        observe(delayed, first, nil, session: "other", online: false)
        continuations[2].resume(returning: .init(subject: "", phase: .exploring, summary: "After disconnect"))
        try await Task.sleep(for: .milliseconds(20))
        precondition(delayed.narrative(session: "other")?.headline != "After disconnect")
        observe(delayed, first, firstBatch, session: "other")
        try await until { continuations.count == 4 }
        // Change settings while a response ignores cancellation.
        settings.disable()
        observe(delayed, first, nil, session: "other")
        continuations[3].resume(returning: .init(subject: "", phase: .exploring, summary: "After disable"))
        try await Task.sleep(for: .milliseconds(20))
        precondition(delayed.narrative(session: "other")?.headline != "After disable")
        print("PASS: disconnect and disable cancel requests; reconnect can retry the interrupted event")
    }
}
