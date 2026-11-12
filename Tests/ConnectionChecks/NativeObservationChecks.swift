import Foundation
import Observation
import WorkbenchCore

private final class NativeInvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); changed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@MainActor func checkNativeObservation() async throws {
    let host = SSHHost(name: "Observation", destination: "fixture")
    let client = NativeAgentConnection(host: host) { path, _ in
        if path == "/models" { return Data(#"{"models":[]}"#.utf8) }
        return Data(#"{"id":"a","provider":"omp","title":"Fixture","cwd":"/fixture","busy":false,"revision":1,"completed":0,"model":"fixture-model","messages":[],"interactions":[]}"#.utf8)
    }
    client.select("a")
    await ConnectionChecks.settle { client.snapshot?.id == "a" }
    let reader = NativeInvalidationFlag()
    withObservationTracking {
        _ = client.snapshot; _ = client.selectedID; _ = client.loadingOlder; _ = client.online
    } onChange: { reader.mark() }
    for index in 0..<40 { client.drafts["a"] = "Draft \(index)" }
    await client.loadModels()
    precondition(!reader.value, "draft and model catalog updates invalidated snapshot consumers")
    client.select("b")
    precondition(client.snapshot == nil && client.conversation.presentationSnapshot?.id == "a",
                 "pending selection must retain presentation only, never authoritative readiness")
    precondition(reader.value, "selection changes must invalidate snapshot consumers")
    client.disconnect()

    let state = NativeConversationState()
    state.select("a")
    var old: CheckedContinuation<Void, Error>?
    var oldReturned = false
    state.loadHistory {
        do { try await withCheckedThrowingContinuation { old = $0 } }
        catch { oldReturned = true; throw error }
    }
    await ConnectionChecks.settle { old != nil }
    state.select("b")
    var current: CheckedContinuation<Void, Error>?
    state.loadHistory { try await withCheckedThrowingContinuation { current = $0 } }
    await ConnectionChecks.settle { current != nil }
    old!.resume(throwing: URLError(.timedOut))
    await ConnectionChecks.settle { oldReturned }
    precondition(state.loadingOlder && state.actionError == nil,
                 "an old page failure cleared the replacement spinner or published an error")
    current!.resume()
    await ConnectionChecks.settle { !state.loadingOlder }

    var selection: CheckedContinuation<Void, Error>?
    var selectionReturned = false
    state.loadSelection {
        do { try await withCheckedThrowingContinuation { selection = $0 } }
        catch { selectionReturned = true; throw error }
    }
    await ConnectionChecks.settle { selection != nil }
    state.cancelLoads()
    selection!.resume(throwing: URLError(.cancelled))
    await ConnectionChecks.settle { selectionReturned }
    precondition(!state.isSelecting && state.actionError == nil && state.selectedID == "b",
                 "disconnect must cancel reads while preserving the selected session")
    state.loadSelection { throw URLError(.badServerResponse) }
    await ConnectionChecks.settle { !state.isSelecting }
    precondition(state.actionError != nil, "current selection failure must remain visible and retryable")
    state.snapshot = try JSONDecoder().decode(NativeAgentSnapshot.self, from: Data(#"{"id":"b","provider":"omp","title":"Fixture","cwd":"/fixture","busy":false,"revision":1,"completed":0,"model":"fixture-model","messages":[],"interactions":[]}"#.utf8))
    state.select("c")
    precondition(state.snapshot == nil && state.presentationSnapshot?.id == "b")
    state.select("b")
    precondition(state.snapshot == nil && state.presentationSnapshot?.id == "b",
                 "returning to a loaded session must restore presentation without exposing readiness")
    state.select(nil)
    precondition(state.presentationSnapshot == nil, "removal must release the retained presentation")

    func decodedSnapshot(_ id: String, text: String = "") throws -> NativeAgentSnapshot {
        let messages: [[String: Any]] = text.isEmpty ? [] : [[
            "id": "message-\(id)", "role": "assistant", "created_at": "",
            "content": [["type": "text", "text": text]]
        ]]
        let value: [String: Any] = [
            "id": id, "provider": "omp", "title": id, "cwd": "/fixture", "busy": false,
            "revision": 1, "completed": 0, "model": "fixture-model", "messages": messages,
            "interactions": []
        ]
        return try KimiWire.decoder().decode(NativeAgentSnapshot.self,
                                              from: JSONSerialization.data(withJSONObject: value))
    }
    let bounded = NativeConversationState(cacheCapacity: 2)
    for id in ["a", "b", "c"] {
        bounded.select(id)
        bounded.snapshot = try decodedSnapshot(id)
    }
    bounded.select("a")
    precondition(bounded.presentationSnapshot?.id == "c", "LRU must evict the oldest snapshot")
    bounded.select("b")
    precondition(bounded.snapshot == nil && bounded.presentationSnapshot?.id == "b",
                 "an admitted snapshot must remain available within the LRU bound")

    let payloadBound = NativeConversationState(cacheCapacity: 2, maximumCachedPayloadCost: 512)
    payloadBound.select("large")
    payloadBound.snapshot = try decodedSnapshot("large", text: String(repeating: "x", count: 2_000))
    payloadBound.select("small")
    payloadBound.snapshot = try decodedSnapshot("small")
    payloadBound.select("other")
    precondition(payloadBound.presentationSnapshot?.id == "small")
    payloadBound.select("large")
    precondition(payloadBound.presentationSnapshot?.id == "small",
                 "oversized snapshots must render while active but not enter the navigation cache")
    print("PASS: native observation isolation, bounded snapshot restoration and selection/history cancellation")
}
