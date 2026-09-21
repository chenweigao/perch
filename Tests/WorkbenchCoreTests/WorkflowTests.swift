import Foundation
import WorkbenchCore

func checkWorkflow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = DraftFile(url: directory.appendingPathComponent("drafts.json"))
    let host = UUID(), otherHost = UUID()
    let session = SessionReference(hostID: host, terminalID: "same-id", kind: .omp)
    let other = SessionReference(hostID: otherHost, terminalID: "same-id", kind: .omp)
    var queue = OutboundQueue()
    let sent = queue.enqueue("Keep this unconfirmed instruction", for: session, mode: .now)!
    _ = queue.nextDelivery(for: session, isStreaming: false)
    let pending = queue.enqueue("Queued for later", for: other, mode: .nextTurn)!
    let attachment = URL(fileURLWithPath: "/fixture/a file.png")
    let saved = SavedDrafts(text: [session.id: "草稿 with unicode 👋", other.id: "Other environment"], attachments: [session.id: [attachment]], outbox: queue)
    try file.flush(saved)
    let restored = try DraftFile(url: file.url).load()
    precondition(restored.text[session.id] == "草稿 with unicode 👋" && restored.text[other.id] == "Other environment")
    precondition(restored.attachments[session.id] == [attachment])
    precondition(restored.outbox.message(sent.id)?.text == sent.text)
    guard case .unknown = restored.outbox.message(sent.id)?.state else { preconditionFailure("Interrupted sends must not auto-replay") }
    precondition(restored.outbox.message(pending.id)?.state == .stoppedBeforeDelivery)
    precondition(restored.outbox.nextPendingID(for: other, isStreaming: false) == nil)
    var acknowledged = saved; acknowledged.text[session.id] = ""; acknowledged.attachments[session.id] = []
    try file.flush(acknowledged)
    let cleared = try file.load()
    precondition(cleared.text[session.id] == "")
    let corrupt = Data("not json".utf8); try corrupt.write(to: file.url)
    do { _ = try file.load(); preconditionFailure("Corrupt drafts must be reported") } catch {}
    let preserved = try Data(contentsOf: file.url)
    precondition(preserved == corrupt)

    let reference = ConversationFileReference(text: "src/foo.swift:42:7")!
    precondition(reference.path == "src/foo.swift" && reference.line == 42)
    precondition(ConversationFileReference(url: reference.url) == reference)
    precondition(ConversationFileReference(text: "/a b/file.swift#L8")?.line == 8)
    precondition(ConversationFileReference(text: "https://example.com/file.swift:4") == nil)
    precondition(ConversationFileReference(text: "javascript:alert(foo.bar)") == nil)
    let linked = ReplyDocument.parse("[Open source](src/foo.swift:42)")
    guard case .paragraph(let runs) = linked.first else { preconditionFailure("Expected file link paragraph") }
    precondition(runs.first?.link?.scheme == "perch-file")
    let matches = ConversationFileReference.matches(in: "See `src/foo.swift:42`, then /tmp/other.py#L9. https://host/file.swift:3")
    precondition(matches.count == 2 && matches[1].1.line == 9)

    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(#"[{"id":"a","role":"assistant","created_at":"","content":[{"type":"text","text":"**Match** one. MATCH two."},{"type":"thinking","thinking":"Match hidden"}]}]"#.utf8))
    let search = ConversationSearch()
    let hits = search.hits(in: messages, query: "match", running: false)
    precondition(hits.count == 2 && hits[1].occurrence == 1)
    precondition(search.hits(in: messages, query: "Match one", running: false).count == 1, "Search uses rendered body text")
    precondition(hits[0].entryID == ConversationTimelineEntry.make(messages)[0].id)
    precondition(search.hits(in: messages, query: "", running: false).isEmpty)
    let edited = try KimiWire.decoder().decode([KimiMessage].self, from: Data(#"[{"id":"a","role":"assistant","created_at":"","content":[{"type":"text","text":"**新正文** 👋 café"},{"type":"thinking","thinking":"Match hidden"}]}]"#.utf8))
    precondition(search.hits(in: edited, query: "match", running: true).isEmpty, "Same-ID edits invalidate cached text")
    precondition(search.hits(in: edited, query: "cafe", running: true).count == 1, "Keep rendered Unicode search semantics")
    precondition(search.hits(in: [], query: "cafe", running: false).isEmpty, "Removed messages must not remain searchable")
    precondition(search.hits(in: messages, query: "match", running: false) == hits, "Switching back restores current content and order")
    var navigation = SessionNavigation()
    navigation.visit("a"); navigation.visit("b"); navigation.visit("b")
    precondition(navigation.entries == ["a", "b"] && navigation.step(-1) == "a")
    navigation.visit("c"); precondition(!navigation.canGoForward && navigation.entries == ["a", "c"])

    var events = TaskEventTracker()
    let working = TaskEventState(running: true, pending: false, failed: false, completion: nil)
    let done = TaskEventState(running: false, pending: false, failed: false, completion: "1")
    precondition(events.observe(working, id: "a", online: true) == nil)
    precondition(events.observe(done, id: "a", online: false) == nil)
    precondition(events.observe(done, id: "a", online: true) == .completed)
    precondition(events.observe(done, id: "a", online: true) == nil)
    let waiting = TaskEventState(running: true, pending: true, failed: false, completion: "1")
    precondition(events.observe(waiting, id: "a", online: true) == .needsInput)
    precondition(events.observe(waiting, id: "a", online: true) == nil)
    precondition(events.observe(.init(running: false, pending: false, failed: true, completion: "1"), id: "a", online: true) == .failed)
    let defaults = TaskLaunchDefaults(hostID: host, provider: .omp, directory: "/fixture", model: "model")
    let restoredDefaults = try JSONDecoder().decode(TaskLaunchDefaults.self, from: JSONEncoder().encode(defaults))
    precondition(restoredDefaults == defaults)
    print("PASS: durable drafts and attachments, safe outbox recovery, file references, search, navigation and task events")
}
