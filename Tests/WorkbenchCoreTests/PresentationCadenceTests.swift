import Foundation
import WorkbenchCore

func checkBackgroundPresentationCadence() throws {
    func input(_ text: String, epoch: String = "one", language: String = "en") throws -> ConversationPresentationModel.Input {
        let data = try JSONSerialization.data(withJSONObject: [["id": "reply", "role": "assistant",
            "created_at": "", "content": [["type": "text", "text": text]]]])
        return .init(messages: try KimiWire.decoder().decode([KimiMessage].self, from: data), epoch: epoch, language: language)
    }
    let cache = ConversationPresentationCache()
    let handle = ConversationPresentationHandle()
    let tick = Date(timeIntervalSince1970: 100)
    let first = handle.update(key: "session", input: try input("start"), cache: cache, displayDate: tick)
    precondition(!handle.hasPendingUpdate)
    _ = handle.update(key: "session", input: try input("start"), cache: cache, displayDate: tick)
    precondition(!handle.hasPendingUpdate, "Unchanged content must not wake the background display")
    for n in 1...100 {
        let held = handle.update(key: "session", input: try input("token " + String(n)), cache: cache, displayDate: tick)
        precondition(handle.hasPendingUpdate)
        precondition(held === first, "Background tokens must reuse one presentation per tick")
    }
    precondition(cache.retainedPreparationCount == 1)
    let latest = try input("final token")
    let caughtUp = handle.update(key: "session", input: latest, cache: cache, displayDate: tick.addingTimeInterval(2))
    precondition(!handle.hasPendingUpdate, "A display flush must clear the pending flag")
    let reference = ConversationPresentationHandle().update(key: "session", input: latest)
    precondition(caughtUp.rows == reference.rows && cache.retainedPreparationCount == 2,
                 "The next display tick must include the final event without another network message")
    let foreground = handle.update(key: "session", input: try input("foreground"), cache: cache)
    precondition(foreground !== caughtUp, "Reactivation must catch up immediately")
    let nav = handle.update(key: "other", input: try input("other session"), cache: cache, displayDate: tick)
    let epoch = handle.update(key: "other", input: try input("new history", epoch: "two"), cache: cache, displayDate: tick)
    precondition(nav !== epoch, "History resets must bypass coalescing")
    let localized = handle.update(key: "other", input: try input("new history", epoch: "two", language: "zh"), cache: cache, displayDate: tick)
    precondition(localized !== epoch, "Language changes must bypass coalescing")
    let running = ConversationPresentationModel.Input(messages: try input("running").messages, isRunning: true, language: "en")
    let runningSnapshot = handle.update(key: "other", input: running, cache: cache, displayDate: tick)
    let stopped = ConversationPresentationModel.Input(messages: running.messages, isRunning: false, language: "en")
    let ended = handle.update(key: "other", input: stopped, cache: cache, displayDate: tick)
    precondition(runningSnapshot !== ended && !handle.hasPendingUpdate, "Turn completion must bypass the background delay")
    print("PASS: background transcript cadence coalesces tokens, flushes the final event, and preserves immediate foreground/navigation/epoch/language updates")
}
