import Foundation
import Observation
import WorkbenchCore

private final class KimiInvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); changed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@MainActor func checkKimiObservation() async throws {
    let client = selectionClient()
    defer {
        client.disconnect()
        UserDefaults.standard.removeObject(forKey: "kimi.session.\(client.host.id)")
    }
    var onlineEvents = 0
    var conversationEvents = 0
    client.onOnlineChanged = { onlineEvents += 1 }
    client.onConversationChanged = { _ in conversationEvents += 1 }
    client.select("a")
    await ConnectionChecks.settle { client.snapshotReady && client.goal != nil }
    precondition(conversationEvents > 0, "Naming bridge must receive selected snapshots")
    let before = conversationEvents
    let reader = KimiInvalidationFlag()
    withObservationTracking {
        _ = client.conversation; _ = client.selectedId; _ = client.snapshotReady
        _ = client.loadingOlder; _ = client.online
    } onChange: { reader.mark() }
    for index in 0..<40 { client.drafts["a"] = "Draft \(index)" }
    client.modelChoices["a"] = "fixture/other"
    client.models = []
    client.attachments["a"] = [URL(fileURLWithPath: "/fixture/image.png")]
    precondition(!reader.value && conversationEvents == before,
                 "Draft/model/attachment edits must not invalidate the reader or trigger naming")
    client.loadOlder()
    await ConnectionChecks.settle { !client.loadingOlder && client.conversation?.hasOlder == false }
    precondition(reader.value && conversationEvents > before, "History updates must reach reader and naming")
    client.disconnect(); client.disconnect()
    precondition(onlineEvents == 1, "Duplicate disconnects must not emit duplicate online changes")

    let state = KimiConversationState()
    state.selectedID = "a"
    var oldSelection: CheckedContinuation<Void, Never>?
    var oldSelectionReturned = false
    state.loadSelection {
        await withCheckedContinuation { oldSelection = $0 }
        oldSelectionReturned = true
    }
    await ConnectionChecks.settle { oldSelection != nil }
    state.cancelLoads(); state.selectedID = "b"
    var newSelection: CheckedContinuation<Void, Never>?
    state.loadSelection { await withCheckedContinuation { newSelection = $0 } }
    await ConnectionChecks.settle { newSelection != nil }
    oldSelection!.resume()
    await ConnectionChecks.settle { oldSelectionReturned }
    precondition(state.loading, "Old selection cleanup must not clear the new selection spinner")
    newSelection!.resume()
    await ConnectionChecks.settle { !state.loading }

    var oldPage: CheckedContinuation<Void, Error>?
    var oldPageReturned = false
    state.loadHistory {
        do { try await withCheckedThrowingContinuation { oldPage = $0 } }
        catch { oldPageReturned = true; throw error }
    }
    await ConnectionChecks.settle { oldPage != nil }
    state.cancelLoads()
    var newPage: CheckedContinuation<Void, Error>?
    var newPageReturned = false
    state.loadHistory {
        do { try await withCheckedThrowingContinuation { newPage = $0 } }
        catch { newPageReturned = true; throw error }
    }
    await ConnectionChecks.settle { newPage != nil }
    oldPage!.resume(throwing: URLError(.timedOut))
    await ConnectionChecks.settle { oldPageReturned }
    precondition(state.loadingOlder && state.actionError == nil,
                 "Old history errors and cleanup must not affect replacement reads")
    state.cancelLoads()
    newPage!.resume(throwing: URLError(.cancelled))
    await ConnectionChecks.settle { newPageReturned }
    precondition(!state.loadingOlder && state.actionError == nil && state.selectedID == "b",
                 "Disconnect cancels reads while retaining the selected session")
    state.loadHistory { throw URLError(.badServerResponse) }
    await ConnectionChecks.settle { !state.loadingOlder }
    precondition(state.actionError != nil, "Current page failures remain visible")
    print("PASS: Kimi observation, event bridges and stale selection/history cleanup isolation")
}
