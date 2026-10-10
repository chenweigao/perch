import Foundation
import WorkbenchCore

func checkWorkflow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = DraftFile(url: directory.appendingPathComponent("drafts.json"))
    let host = UUID(), otherHost = UUID()
    let session = SessionReference(hostID: host, terminalID: "same-id", kind: .omp)
    let other = SessionReference(hostID: otherHost, terminalID: "same-id", kind: .omp)
    let searchable = WorkspaceSession(reference: session, title: "Café 中文体验", directory: "/work/perch", hostName: "Dev Mac",
                                      detail: "Ready", online: true, section: .other, canMarkReviewed: false)
    precondition(searchable.matchesSearch("  CAFE  \n OMP perch 中文  "), "Search combines words across title, agent and path")
    precondition(searchable.matchesSearch(" \t "), "Whitespace must show all sessions")
    precondition(!searchable.matchesSearch("perch missing"), "Every search term must match")
    let source = "中文 👋\r\nsecond\n"
    let second = RemoteFileContent.lineRange(in: source, line: 2)!
    precondition((source as NSString).substring(with: second) == "second\n", "File line links use UTF-16 and CRLF correctly")
    precondition(RemoteFileContent.lineRange(in: source, line: 3) == NSRange(location: (source as NSString).length, length: 0))
    precondition(RemoteFileContent.lineRange(in: source, line: 4) == nil)
    precondition(RemoteFileContent.lineRange(in: "one\ntwo", line: 3) == nil, "Missing lines must not highlight a different line")
    precondition(RemoteFileContent.lineRange(in: "", line: 1) == NSRange(location: 0, length: 0))
    precondition(RemoteFileContent.lineRange(in: source, line: 0) == nil)
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
    let coalesced = DraftFile(url: directory.appendingPathComponent("coalesced.json"))
    let didSave = DispatchSemaphore(value: 0)
    for index in 0..<1000 {
        coalesced.save(SavedDrafts(text: [session.id: "编辑 \(index)"]), coalescing: true) { error in
            precondition(error == nil)
            didSave.signal()
        }
    }
    precondition(didSave.wait(timeout: .now() + 5) == .success)
    let burst = try coalesced.load()
    precondition(burst.text[session.id] == "编辑 999")
    precondition(didSave.wait(timeout: .now() + 0.3) == .timedOut, "A burst of text changes should share one disk write")
    coalesced.save(SavedDrafts(text: [session.id: "older draft"]), coalescing: true) { _ in
        preconditionFailure("An immediate queue save supersedes the pending text callback")
    }
    coalesced.save(saved) { error in precondition(error == nil); didSave.signal() }
    precondition(didSave.wait(timeout: .now() + 5) == .success)
    let durableQueue = try coalesced.load()
    precondition(durableQueue.outbox.message(sent.id)?.text == sent.text)
    coalesced.save(saved, coalescing: true) { _ in preconditionFailure("Flush supersedes a pending save") }
    try coalesced.flush(acknowledged)
    Thread.sleep(forTimeInterval: 0.3)
    let flushed = try coalesced.load()
    precondition(flushed.text[session.id] == "", "A delayed save must not overwrite shutdown's final state")
    print("PASS: 1000 text edits coalesce; queue saves are immediate; flush cancels stale writes")
    let corrupt = Data("not json".utf8); try corrupt.write(to: file.url)
    do { _ = try file.load(); preconditionFailure("Corrupt drafts must be reported") } catch {}
    let preserved = try Data(contentsOf: file.url)
    precondition(preserved == corrupt)

    // Draft files from before the history/outbox fields existed must keep decoding.
    let legacy = Data(#"{"text":{"s1":"旧草稿"}}"#.utf8)
    let legacyDrafts = try JSONDecoder().decode(SavedDrafts.self, from: legacy)
    precondition(legacyDrafts.text["s1"] == "旧草稿" && legacyDrafts.history.isEmpty && legacyDrafts.outbox.allPendingCount == 0)
    var histories = SavedDrafts()
    histories.recordHistory("  ", for: "s1")
    precondition(histories.history["s1"] == nil, "Blank prompts are not history")
    histories.recordHistory("第一条", for: "s1"); histories.recordHistory("第二条", for: "s1")
    histories.recordHistory("第一条", for: "s1")
    precondition(histories.history["s1"] == ["第二条", "第一条"], "Recalling a repeat moves it to the end once")
    histories.recordHistory("别处", for: "s2")
    precondition(histories.history["s1"]?.count == 2 && histories.history["s2"] == ["别处"])
    for index in 0..<60 { histories.recordHistory("填充 \(index)", for: "s1") }
    precondition(histories.history["s1"]?.count == 50, "History stays bounded")
    let roundTrip = try JSONDecoder().decode(SavedDrafts.self, from: JSONEncoder().encode(histories))
    precondition(roundTrip.history == histories.history)

    // Folded pastes round-trip through the store; missing files are reported.
    let pasteStore = DraftPasteStore(directory: directory.appendingPathComponent("pastes"))
    let longPaste = String(repeating: "日志行 中文\n", count: 30)
    precondition(DraftPaste.shouldFold(longPaste) && !DraftPaste.shouldFold("短短一句"))
    let pasteID = try pasteStore.save(longPaste)
    let pasteDraft = "分析这段日志 \(DraftPaste.token(id: pasteID)) 重点看错误"
    let expanded = pasteStore.expand(pasteDraft)
    precondition(expanded.text == "分析这段日志 \(longPaste) 重点看错误" && expanded.missing.isEmpty)
    precondition(pasteStore.stats(for: pasteID)?.lines == 31, "Stats count trailing newline's empty tail")
    let missingPaste = pasteStore.expand("broken \(DraftPaste.token(id: "00000000"))")
    precondition(missingPaste.missing == ["00000000"] && missingPaste.text.contains(#"@paste("00000000")"#))
    let secondPaste = try pasteStore.save("第二段")
    precondition(pasteStore.expand("\(DraftPaste.token(id: pasteID))|\(DraftPaste.token(id: secondPaste))").text == "\(longPaste)|第二段")
    precondition(DraftPaste.references(in: pasteDraft).map(\.id) == [pasteID])
    pasteStore.prune(keeping: [pasteID])
    precondition(pasteStore.text(for: pasteID) == longPaste && pasteStore.text(for: secondPaste) == nil)

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
    precondition(ConversationFileReference.matches(in: String(repeating: "a.", count: 10_000)).isEmpty,
                 "Long tokens without line suffixes are not inline file references")
    let unicodeReferences = "👋 中文 src/main.swift:12:3 和 ../test.py#L8"
    let unicodeMatches = ConversationFileReference.matches(in: unicodeReferences)
    precondition(unicodeMatches.map { $0.1.line } == [12, 8])
    precondition(unicodeMatches.map { (unicodeReferences as NSString).substring(with: $0.0) }
                 == ["src/main.swift:12:3", "../test.py#L8"], "File links preserve UTF-16 ranges")

    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(#"[{"id":"a","role":"assistant","created_at":"","content":[{"type":"text","text":"**Match** one. MATCH two."},{"type":"thinking","thinking":"Match hidden"}]}]"#.utf8))
    let search = ConversationSearch()
    let hits = search.hits(in: messages, query: "match", running: false)
    precondition(hits.hits.count == 2 && hits.hits[1].occurrence == 1)
    precondition(search.hits(in: messages, query: "Match one", running: false).hits.count == 1, "Search uses rendered body text")
    precondition(hits.hits[0].entryID == ConversationTimelineEntry.make(messages)[0].id)
    precondition(search.hits(in: messages, query: "", running: false).hits.isEmpty)
    // Find-bar options: case sensitivity, regular expressions and role filters.
    precondition(search.hits(in: messages, query: "Match", running: false, options: ConversationFindOptions(caseSensitive: true)).hits.count == 1,
                 "Case-sensitive search skips the all-caps hit")
    precondition(search.hits(in: messages, query: "ma?tch", running: false, options: ConversationFindOptions(regex: true)).hits.count == 2,
                 "Regex search matches both spellings")
    precondition(search.hits(in: messages, query: "ma?[", running: false, options: ConversationFindOptions(regex: true)).queryError != nil,
                 "Invalid regex reports an error instead of zero silent hits")
    precondition(search.hits(in: messages, query: "match", running: false, options: ConversationFindOptions(role: .user)).hits.isEmpty,
                 "Role filter excludes assistant text from a user-only search")
    let toolMessages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(#"[{"id":"u1","role":"user","created_at":"","content":[{"type":"text","text":"run the tests"}]},{"id":"t1","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"c1","name":"Bash","input":{"command":"swift needle"}}]}]"#.utf8))
    precondition(search.hits(in: toolMessages, query: "needle", running: false, options: ConversationFindOptions(role: .tool)).hits.count == 1,
                 "Tool search covers tool input text once, not per wrapper entry")
    precondition(search.hits(in: toolMessages, query: "needle", running: false, options: ConversationFindOptions(role: .user)).hits.isEmpty,
                 "Tool content stays out of a user-only search")
    let edited = try KimiWire.decoder().decode([KimiMessage].self, from: Data(#"[{"id":"a","role":"assistant","created_at":"","content":[{"type":"text","text":"**新正文** 👋 café"},{"type":"thinking","thinking":"Match hidden"}]}]"#.utf8))
    precondition(search.hits(in: edited, query: "match", running: true).hits.isEmpty, "Same-ID edits invalidate cached text")
    precondition(search.hits(in: edited, query: "cafe", running: true).hits.count == 1, "Keep rendered Unicode search semantics")
    precondition(search.hits(in: [], query: "cafe", running: false).hits.isEmpty, "Removed messages must not remain searchable")
    precondition(search.hits(in: messages, query: "match", running: false) == hits, "Switching back restores current content and order")
    let boundaryText = "👋" + String(repeating: "a", count: 49) + "needle" + String(repeating: "b", count: 79) + "👋"
    let boundaryData = try JSONSerialization.data(withJSONObject: [["id": "boundary", "role": "assistant", "created_at": "", "content": [["type": "text", "text": boundaryText]]]])
    let boundaryMessages = try KimiWire.decoder().decode([KimiMessage].self, from: boundaryData)
    let excerpt = search.hits(in: boundaryMessages, query: "needle", running: false).hits[0].excerpt
    precondition(excerpt.hasPrefix("👋") && excerpt.hasSuffix("👋"), "Search excerpts must keep complete characters at both boundaries")
    var navigation = SessionNavigation()
    navigation.visit("a"); navigation.visit("b"); navigation.visit("b")
    precondition(navigation.entries == ["a", "b"] && navigation.step(-1) == "a")
    navigation.visit("c"); precondition(!navigation.canGoForward && navigation.entries == ["a", "c"])
    navigation.visit("d")
    let available: Set<String> = ["a", "d"]
    precondition(navigation.canStep(-1, isAvailable: available.contains))
    precondition(navigation.step(-1, isAvailable: available.contains) == "a", "Back skips unavailable sessions")
    precondition(navigation.canStep(1, isAvailable: available.contains))
    precondition(navigation.step(1, isAvailable: available.contains) == "d", "Forward skips the same unavailable sessions")
    let position = navigation.index
    precondition(!navigation.canStep(-1, isAvailable: { $0 == "d" }))
    precondition(navigation.step(-1, isAvailable: { $0 == "d" }) == nil)
    precondition(navigation.index == position, "Failed navigation must not move the history cursor")
    precondition(!navigation.canStep(1, isAvailable: available.contains), "Failed back must not create a forward destination")
    precondition(navigation.step(0, isAvailable: available.contains) == nil)
    precondition(navigation.step(-1, isAvailable: available.contains) == "a", "Restored sessions remain reachable after a failed back")
    navigation.visit("e")
    precondition(navigation.entries == ["a", "e"], "A new visit branches from the visible history position")

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
    let defaults = TaskLaunchDefaults(hostID: host, provider: .omp, directory: "/fixture", model: "model", thinking: .high)
    let restoredDefaults = try JSONDecoder().decode(TaskLaunchDefaults.self, from: JSONEncoder().encode(defaults))
    precondition(restoredDefaults == defaults)
    let legacyDefaults = Data("{\"hostID\":\"\(host.uuidString)\",\"provider\":\"omp\",\"directory\":\"/legacy\",\"model\":\"legacy-model\"}".utf8)
    let restoredLegacy = try JSONDecoder().decode(TaskLaunchDefaults.self, from: legacyDefaults)
    precondition(restoredLegacy.thinking == nil && restoredLegacy.directory == "/legacy")
    print("PASS: durable drafts and attachments, safe outbox recovery, file references, search, navigation and task events")
}
