import AppKit
import Darwin
import QuartzCore
import SwiftUI
import WorkbenchCore

// Isolated click-response and scroll fixture. It hosts the production
// ConversationScrollView/ConversationTranscript and the production
// SessionCatalog scoping. The list rows are a fixture: the real SessionSidebar
// depends on WorkbenchModel, which pulls in GhosttyTerminal and cannot be
// compiled standalone. Row geometry matches production (52 pt).
//
// Selection is invoked programmatically, so these timings exclude mouse event
// delivery and window-server presentation. They measure the application work
// between a selection and the content being laid out and submitted for display.

private let sessionCount = Int(ProcessInfo.processInfo.environment["NAVIGATION_SESSIONS"] ?? "500") ?? 500

private func fixtureSessions(_ count: Int) -> [WorkspaceSession] {
    let hosts = (0..<3).map { _ in UUID() }
    let sections: [WorkQueueSection] = [.attention, .review, .running, .other]
    return (0..<count).map { index in
        let kind: SessionKind = [.kimi, .omp, .qoder, .terminal][index % 4]
        return WorkspaceSession(
            reference: SessionReference(hostID: hosts[index % hosts.count], terminalID: "session-\(index)", kind: kind),
            title: "验收会话 \(index) · mixed Chinese and English title",
            directory: "/fixture/workspace/project-\(index % 37)/subdirectory",
            hostName: "fixture-host-\(index % hosts.count)",
            detail: "\(kind.label) · 结果待查看", online: index % 9 != 0,
            section: sections[index % sections.count], canMarkReviewed: index % 3 == 0,
            archived: index % 11 == 0, updatedAt: Double(count - index))
    }
}

final class NavigationMarker {
    var selectionID = ""
    // Identifies *which* conversation the transcript last rendered. A message
    // count would be equal for every fixture session, so the wait would pass on
    // the outgoing transcript and time nothing.
    var contentToken = ""
    // Scope and search changes are only observable once the list itself re-renders.
    var listToken = ""
}

@MainActor
final class NavigationModel: ObservableObject {
    @Published var selected: String = ""
    @Published var search = ""
    @Published var narrow = false
    @Published var showArchived = false
    @Published var inGroup = false
    @Published var conversation: KimiConversation?
    let all = fixtureSessions(sessionCount)
    let marker = NavigationMarker()
    weak var host: NSView?
    // Pre-decoded conversations: this measures a cache-hit switch, with no
    // network wait and no JSON decode on the click path. The bound mirrors
    // production's KimiConversationCache capacity; holding every salted
    // 200-turn conversation at once exhausts memory and measures swap instead.
    private var cache: [String: KimiConversation] = [:]
    private var cacheOrder: [String] = []
    static let cacheCapacity = 8
    private let workload = try! PerformanceWorkload(scenario: .assistant)
    private lazy var group = WorkItemGroup(name: "验收任务组", goal: "", nextStep: "",
                                           sessions: Array(all.prefix(all.count / 4).map(\.reference)))
    var scope: SessionScope {
        SessionCatalog.scope(all, starred: Array(all.prefix(12).map(\.reference)),
                             group: inGroup ? group : nil,
                             hostFilter: nil, search: search, onlyAttention: false,
                             showArchived: showArchived)
    }
    /// NAVIGATION_TURNS selects the heavier mixed-content history required for
    /// acceptance; unset keeps the streaming workload used by earlier runs.
    private static let historyTurns = Int(ProcessInfo.processInfo.environment["NAVIGATION_TURNS"] ?? "") ?? 0
    /// Salt by session id: production switches move between conversations with
    /// entirely different message IDs, so sharing one ID set across fixture
    /// sessions would let rows survive a switch that would rebuild in production.
    private func history(salt: String) throws -> KimiConversation {
        Self.historyTurns > 0 ? try NavigationHistory.conversation(turns: Self.historyTurns, salt: salt)
                              : try workload.conversation()
    }
    var historyTurnCount: Int { Self.historyTurns > 0 ? Self.historyTurns : PerformanceWorkload.historyTurns }
    var historySource: String { Self.historyTurns > 0 ? "navigation-mixed" : "streaming-workload" }
    func warm(_ ids: [String]) throws {
        guard ids.count <= Self.cacheCapacity else {
            throw NavigationError("cannot hold \(ids.count) conversations in a \(Self.cacheCapacity)-entry cache")
        }
        for id in ids where cache[id] == nil {
            cache[id] = try history(salt: id + ":")
            cacheOrder.append(id)
            while cacheOrder.count > Self.cacheCapacity { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
    }
    /// Throws rather than silently showing an empty transcript: a miss here would
    /// otherwise be timed as an unusually fast switch.
    func select(_ id: String) throws {
        guard let hit = cache[id] else { throw NavigationError("select(\(id)) missed the conversation cache") }
        selected = id
        conversation = hit
    }
    static func token(_ conversation: KimiConversation?) -> String { conversation?.messages.last?.id ?? "" }
    /// The token the transcript must reach for `id` to count as rendered.
    func contentToken(_ id: String) throws -> String {
        guard let hit = cache[id] else { throw NavigationError("no warmed conversation for \(id)") }
        return Self.token(hit)
    }
    func streamingBase() throws -> KimiConversation { try workload.conversation() }
    var streamEvents: [Data] { workload.events }
    /// Identifies the scope the list last rendered, so a scope change can be awaited.
    var scopeToken: String { "\(showArchived)|\(inGroup)|\(search)|\(scope.sessions.count)" }
}

struct NavigationRoot: View {
    @ObservedObject var model: NavigationModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("搜索", text: $model.search).textFieldStyle(.roundedBorder).padding(10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.scope.sessions) { item in
                            NavigationRow(item: item, selected: item.id == model.selected) { try? model.select(item.id) }
                        }
                    }.padding(.horizontal, 10)
                }
                SelectionMarker(id: model.selected, marker: model.marker).frame(height: 1)
                ListMarker(token: model.scopeToken, marker: model.marker).frame(height: 1)
            }.frame(width: 316)
            Divider()
            NavigationConversation(model: model)
                .frame(width: model.narrow ? 492 : nil)
                .id(ProcessInfo.processInfo.environment["NAVIGATION_RECREATE"] == "1" ? model.selected : "shared")
                .frame(maxWidth: .infinity)
        }.frame(maxHeight: .infinity).preferredColorScheme(.light)
    }
}

private struct NavigationConversation: View {
    @ObservedObject var model: NavigationModel
    var body: some View {
            ScrollViewReader { proxy in
                ConversationScrollView {
                    if let conversation = model.conversation {
                        ConversationTranscript(messages: conversation.displayMessages,
                                               sessionId: model.selected, isRunning: false)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.overlay(alignment: .topLeading) {
                    ContentMarker(token: NavigationModel.token(model.conversation), marker: model.marker)
                        .frame(width: 1, height: 1).allowsHitTesting(false)
                }
            }
    }
}

private struct NavigationRow: View {
    let item: WorkspaceSession
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.reference.kind.symbol).font(.system(size: 11))
                    .foregroundStyle(.secondary).frame(width: 15).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).lineLimit(1).font(.system(size: 13))
                    Text(item.online ? item.detail : "状态未同步").lineLimit(1)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 9).frame(height: 52)
            .background(selected ? .black.opacity(0.065) : hovered ? .black.opacity(0.03) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
}

private struct SelectionMarker: NSViewRepresentable {
    let id: String
    let marker: NavigationMarker
    func makeNSView(context: Context) -> NSView { marker.selectionID = id; return NSView() }
    func updateNSView(_ view: NSView, context: Context) { marker.selectionID = id }
}
private struct ListMarker: NSViewRepresentable {
    let token: String
    let marker: NavigationMarker
    func makeNSView(context: Context) -> NSView { marker.listToken = token; return NSView() }
    func updateNSView(_ view: NSView, context: Context) { marker.listToken = token }
}
private struct ContentMarker: NSViewRepresentable {
    let token: String
    let marker: NavigationMarker
    func makeNSView(context: Context) -> NSView { marker.contentToken = token; return NSView() }
    func updateNSView(_ view: NSView, context: Context) { marker.contentToken = token }
}

@MainActor
private func flushAndWait(_ host: NSView, until ready: @escaping () -> Bool, limit: Double = 5) async -> Double? {
    let start = CACurrentMediaTime()
    repeat {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        if ready() { return (CACurrentMediaTime() - start) * 1_000 }
    } while CACurrentMediaTime() - start < limit
    return nil
}

private func statistics(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return [
        "count": Double(sorted.count),
        "median_ms": sorted[sorted.count / 2],
        "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
        "max_ms": sorted.last ?? 0,
        "over_100ms": Double(sorted.filter { $0 > 100 }.count),
        "over_16_7ms": Double(sorted.filter { $0 > 16.7 }.count)
    ]
}

private func writeNavigationArtifact(_ name: String, _ report: [String: Any]) throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NAVIGATION_RESULTS"] ?? NSTemporaryDirectory())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
        to: folder.appendingPathComponent(name), options: .atomic)
}

@MainActor
final class NavigationRunner {
    let model: NavigationModel
    init(model: NavigationModel) { self.model = model }

    /// Switches cycle round-robin through the warmed set. A cache-hit switch only
    /// exists inside the cache window, so the resident set is the population.
    private func warmedTargets() throws -> [String] {
        let ids = model.scope.sessions.prefix(NavigationModel.cacheCapacity).map(\.id)
        try model.warm(Array(ids))
        return ids
    }

    /// Runs one switch and returns (selection feedback, first content actionable).
    private func switchTo(_ id: String, host: NSView) async throws -> (Double, Double) {
        let token = try model.contentToken(id)
        let start = CACurrentMediaTime()
        try model.select(id)
        guard let feedback = await flushAndWait(host, until: { self.model.marker.selectionID == id })
        else { throw NavigationError("selection feedback timed out") }
        guard await flushAndWait(host, until: {
            guard self.model.marker.contentToken == token else { return false }
            // The legacy streaming fixture has shared IDs; the salted mixed
            // history used by navigation acceptance must prove the mounted row.
            if self.model.historySource != "navigation-mixed" { return true }
            var views = [host]
            while let view = views.popLast() {
                if view.identifier?.rawValue.contains(":" + id + ":") == true, !view.subviews.isEmpty { return true }
                views.append(contentsOf: view.subviews)
            }
            return false
        }) != nil
        else { throw NavigationError("content timed out: expected \(token), marker \(model.marker.contentToken)") }
        return (feedback, (CACurrentMediaTime() - start) * 1_000)
    }

    func clickLatency() async throws -> [String: Any] {
        let targets = try warmedTargets()
        guard let host = model.host else { throw NavigationError("missing host") }
        var selection: [Double] = [], content: [Double] = []
        // One untimed warm-up switch so first-run allocation is not counted as latency.
        _ = try await switchTo(targets[0], host: host)
        FileHandle.standardError.write(Data("PROFILE_SWITCHES\n".utf8))
        for index in 1...(Int(ProcessInfo.processInfo.environment["NAVIGATION_SWITCHES"] ?? "40") ?? 40) {
            let (feedback, actionable) = try await switchTo(targets[index % targets.count], host: host)
            selection.append(feedback)
            content.append(actionable)
        }
        return ["selection_feedback": statistics(selection), "first_content_actionable": statistics(content),
                "switches": selection.count, "sessions": model.all.count,
                "selection_ms": selection, "content_ms": content,
                "distinct_conversations": targets.count,
                "note": "cache-hit switches only, cycling round-robin through the \(NavigationModel.cacheCapacity)-conversation cache window (production's KimiConversationCache capacity); each session has its own message IDs; excludes mouse event delivery, network and JSON decode"]
    }

    func scrollFrames() async throws -> [String: Any] {
        let target = model.scope.sessions[0].id
        try model.warm([target])
        guard let host = model.host else { throw NavigationError("missing host") }
        _ = try await switchTo(target, host: host)
        guard let scroll = findScrollView(host) else { throw NavigationError("no transcript scroll view") }
        let document = scroll.documentView?.bounds.height ?? 0
        let visible = scroll.contentView.bounds.height
        guard document > visible + 10 else { throw NavigationError("content shorter than viewport") }
        var frames: [Double] = []
        let stepPoints = ProcessInfo.processInfo.environment["NAVIGATION_SCROLL_STEP_POINTS"].flatMap(Double.init)
        let steps = stepPoints == nil ? 240 : 1200
        for index in 0..<steps {
            // Triangle sweep top→bottom→top, emulating continuous reading.
            let phase = Double(index % 120) / 119
            let progress = index % 240 < 120 ? phase : 1 - phase
            let currentHeight = scroll.documentView?.bounds.height ?? document
            let offset: CGFloat
            if let stepPoints {
                // Small continuous deltas exercise repeated layout of the same
                // rows; the original triangle makes almost viewport-sized jumps.
                let sweep = Double(index < steps / 2 ? index : steps - 1 - index)
                offset = min(max(0, currentHeight - visible), sweep * stepPoints)
            } else {
                offset = max(0, currentHeight - visible) * progress
            }
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            frames.append((CACurrentMediaTime() - start) * 1_000)
        }
        var result = statistics(frames)
        result["document_height"] = document
        result["viewport_height"] = visible
        result["final_document_height"] = scroll.documentView?.bounds.height ?? 0
        if let stepPoints { result["step_points"] = stepPoints }
        return ["scroll_step_ms": result, "steps": steps,
                "note": "programmatic scroll steps, each including layout, display and transaction flush; not a display-link frame rate"]
    }

    /// Traverse in half-viewport increments, so every turn must be observed in
    /// real mounted NSTextViews. Re-read document geometry as rows are measured.
    /// Timing is separate from the text traversal and coverage assertions.
    func readingCoverage() async throws -> [String: Any] {
        let target = model.scope.sessions[0].id
        try model.warm([target])
        guard let host = model.host else { throw NavigationError("missing host") }
        _ = try await switchTo(target, host: host)
        guard let scroll = findScrollView(host) else { throw NavigationError("no transcript scroll") }
        let initialRSS = residentMB()
        let expression = try NSRegularExpression(pattern: "第 ([0-9]+) 轮")
        let lastEntryID = model.conversation.map {
            ConversationProjection().update($0.displayMessages, isRunning: false).entries.last?.id
        } ?? nil
        var turns: Set<Int> = []
        var steps: [Double] = []
        var bottomPasses = 0
        var trace: [[String: Any]] = []
        var tailFound = false
        var offset: CGFloat = 0
        for _ in 0..<2_000 {
            let started = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            steps.append((CACurrentMediaTime() - started) * 1_000)
            var views: [NSView] = [scroll]
            var nativeRows: [[String: Any]] = []
            var frameTurns: [Int] = []
            while let view = views.popLast() {
                if let text = view as? NSTextView {
                    let value = text.string as NSString
                    for match in expression.matches(in: text.string, range: NSRange(location: 0, length: value.length)) {
                        if let turn = Int(value.substring(with: match.range(at: 1))) { turns.insert(turn); frameTurns.append(turn) }
                    }
                }
                if let id = view.identifier?.rawValue {
                    nativeRows.append(["id": id, "children": view.subviews.count,
                                       "y": view.frame.minY, "height": view.frame.height])
                }
                views.append(contentsOf: view.subviews)
            }
            if nativeRows.contains(where: { ($0["id"] as? String) == lastEntryID && ($0["children"] as? Int ?? 0) > 0 }) {
                tailFound = true
            }
            trace.append(["requested_y": offset, "position": scroll.contentView.bounds.minY,
                          "document_height": scroll.documentView?.bounds.height ?? 0,
                          "turns": frameTurns, "rows": nativeRows])
            let end = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            let position = scroll.contentView.bounds.minY
            bottomPasses = abs(end - position) < 1 ? bottomPasses + 1 : 0
            if bottomPasses == 3 { break }
            offset = min(end, position + scroll.contentView.bounds.height / 2)
        }
        if let directory = ProcessInfo.processInfo.environment["NAVIGATION_RESULTS"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]).write(
                to: folder.appendingPathComponent("reading-trace.json"), options: .atomic)
        }
        let missing = Set(1...model.historyTurnCount).subtracting(turns).sorted()
        guard missing.isEmpty, tailFound, bottomPasses == 3 else {
            throw NavigationError("reading coverage missing turns \(missing), tail=\(tailFound), bottom=\(bottomPasses)")
        }
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        let result: [String: Any] = ["observed_turns": turns.sorted(), "tail_found": tailFound,
                                   "reading_step_ms": statistics(steps), "document_height_after_reading": documentHeight]
        var report = result
        report["resident_mb_before_reading"] = initialRSS
        report["resident_mb_after_downward"] = residentMB()
        #if TRANSCRIPT_CHECKS
        // Reproduce reading upward after a long downward traversal. Inspect the
        // controller cache as well as mounted views; detached hosts used to grow
        // with every newly visited row. Timings are application work, not FPS.
        var upwardSteps: [Double] = []
        var retention: [[String: Int]] = []
        var topPasses = 0
        for _ in 0..<2_000 {
            let started = CACurrentMediaTime()
            let y = max(0, scroll.contentView.bounds.minY - scroll.contentView.bounds.height / 2)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            upwardSteps.append((CACurrentMediaTime() - started) * 1_000)
            guard let counts = ConversationTranscript.retainedHosts(in: scroll), counts.mounted > 0 else {
                throw NavigationError("upward reading lost the transcript rows")
            }
            guard counts.retained <= counts.mounted + 24 else {
                throw NavigationError("history hosts accumulated: \(counts.retained), mounted: \(counts.mounted)")
            }
            retention.append(["retained": counts.retained, "mounted": counts.mounted])
            topPasses = scroll.contentView.bounds.minY <= 1 ? topPasses + 1 : 0
            if topPasses == 3 { break }
        }
        guard topPasses == 3 else { throw NavigationError("upward reading never reached the beginning") }
        report["upward_reading_step_ms"] = statistics(upwardSteps)
        report["upward_reading_samples_ms"] = upwardSteps
        report["upward_host_counts"] = retention
        report["resident_mb_after_upward"] = residentMB()
        #endif
        report["warm_scroll"] = try await scrollFrames()
        report["switch_after_full_reading"] = try await clickLatency()
        var pulseDelay: [Double] = []
        let pulseStart = CACurrentMediaTime()
        while CACurrentMediaTime() - pulseStart < 3 {
            let scheduled = CACurrentMediaTime()
            try await Task.sleep(for: .milliseconds(16))
            pulseDelay.append(max(0, (CACurrentMediaTime() - scheduled) * 1_000 - 16))
        }
        report["cleanup_main_actor_delay_ms"] = statistics(pulseDelay)
        return report
    }

    #if TRANSCRIPT_CHECKS
    /// Does an arriving older page preserve the exact row and intra-row offset?
    /// Use the production prepend and native document, with no remote state.
    func prependAnchor() async throws -> [String: Any] {
        let target = model.scope.sessions[0].id
        try model.warm([target])
        guard let host = model.host else { throw NavigationError("missing host") }
        _ = try await switchTo(target, host: host)
        guard let scroll = findScrollView(host) else { throw NavigationError("no transcript scroll") }
        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(16))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            }
        }
        let fromBottom = ProcessInfo.processInfo.environment["NAVIGATION_ANCHOR_FROM_BOTTOM"] == "1"
        if fromBottom {
            for _ in 0..<4 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle()
            }
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: fromBottom ? scroll.contentView.bounds.minY - 1200 : 1800))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        guard let before = ConversationTranscript.readingAnchor(in: scroll) else { throw NavigationError("missing initial anchor") }
        let records = (0..<20).map { index in
            ["id": "older-\(index)", "role": index % 2 == 0 ? "user" : "assistant", "created_at": String(format: "%04d", index),
             "content": [["type": "text", "text": "更早的消息 \(index)。保留当前正在阅读的内容和位置。"]]] as [String: Any]
        }
        let page = try KimiWire.decoder().decode(KimiPage<KimiMessage>.self, from: JSONSerialization.data(withJSONObject: ["items": records, "has_more": false]))
        ConversationReadingMemory.shared.following[target] = false
        model.conversation?.prepend(page)
        try await settle()
        guard let after = ConversationTranscript.readingAnchor(in: scroll) else { throw NavigationError("missing final anchor") }
        let passed = before.entry == after.entry && abs(before.offset - after.offset) <= 1
        let report: [String: Any] = ["before_entry": before.entry, "before_offset": before.offset,
            "after_entry": after.entry, "after_offset": after.offset, "preserved": passed,
            "message_count": model.conversation?.messages.count ?? 0, "added_messages": records.count]
        try writeNavigationArtifact("anchor-detail.json", report)
        guard passed else { throw NavigationError("prepend moved reading anchor: \(before) -> \(after)") }
        return report
    }
    #endif

    #if TRANSCRIPT_CHECKS
    /// Check actual native text selection and reading memory across layout and session changes.
    func readingInteractions(searchOnly: Bool = false) async throws -> [String: Any] {
        let targets = try warmedTargets()
        guard let host = model.host else { throw NavigationError("missing host") }
        _ = try await switchTo(targets[0], host: host)
        guard let scroll = findScrollView(host) else { throw NavigationError("missing scroll") }
        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(16))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            }
        }
        var report: [String: Any] = [:]
        var failures: [String] = []
        func record(_ name: String, _ value: [String: Any]) throws {
            report[name] = value
            try writeNavigationArtifact("interaction-detail.json", report)
        }
        for query in ["fixture-195", "第 6 轮结果", "中文换行"] {
            guard let hit = ConversationSearch().hits(in: model.conversation!.displayMessages, query: query, running: false).first else {
                throw NavigationError("fixture query has no hit: \(query)")
            }
            NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(session: targets[0], hit: hit, query: query))
            try await settle()
            var stack = [scroll as NSView], selected: [String] = [], rows: [String] = []
            while let view = stack.popLast() {
                if let id = view.identifier?.rawValue { rows.append(id) }
                if let text = view as? ReplyTextView, text.selectedRange().length > 0 {
                    selected.append((text.string as NSString).substring(with: text.selectedRange()))
                }
                stack.append(contentsOf: view.subviews)
            }
            try record(query, ["selected": selected, "entry": hit.entryID, "mounted_rows": rows])
            if !selected.contains(query) { failures.append("search: " + query) }
        }
        if searchOnly {
            try record("failures", ["checks": failures])
            guard failures.isEmpty else { throw NavigationError("search failures: \(failures)") }
            return report
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1800))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        guard let before = ConversationTranscript.readingAnchor(in: scroll) else { throw NavigationError("missing anchor") }
        ConversationReadingMemory.shared.following[targets[0]] = false
        model.narrow = true
        try await settle()
        guard let narrow = ConversationTranscript.readingAnchor(in: scroll) else { throw NavigationError("missing resized anchor") }
        try record("resize", ["before_entry": before.entry, "after_entry": narrow.entry,
                              "before_offset": before.offset, "after_offset": narrow.offset])
        if before.entry != narrow.entry || abs(before.offset - narrow.offset) > 1 { failures.append("resize anchor") }
        ConversationReadingMemory.shared.following[targets[0]] = false
        _ = try await switchTo(targets[1], host: host)
        try await settle()
        _ = try await switchTo(targets[0], host: host)
        try await settle()
        guard let restored = ConversationTranscript.readingAnchor(in: scroll) else { throw NavigationError("missing restored anchor") }
        try record("session_return", ["before_entry": narrow.entry, "after_entry": restored.entry,
                                      "before_offset": narrow.offset, "after_offset": restored.offset])
        if narrow.entry != restored.entry || abs(narrow.offset - restored.offset) > 1 { failures.append("session return anchor") }
        try record("failures", ["checks": failures])
        guard failures.isEmpty else { throw NavigationError("interaction failures: \(failures)") }
        return report
    }
    #endif

    /// Workbench → archive → task group → conversation round trips, plus search
    /// keystrokes issued *while* the transcript is being scrolled. The second part
    /// answers whether input still lands during scrolling, which a scroll-only or
    /// switch-only measurement cannot show.
    func roundTrips() async throws -> [String: Any] {
        guard let host = model.host else { throw NavigationError("missing host") }
        // Each cycle must enter a *different* session. Re-selecting the same one
        // leaves the marker already matching, which would time one flush pass
        // instead of an actual switch.
        let targets = try warmedTargets()
        let target = targets[0]

        func applyScope(_ change: () -> Void) async throws -> Double {
            let start = CACurrentMediaTime()
            change()
            let token = model.scopeToken
            guard await flushAndWait(host, until: { self.model.marker.listToken == token }) != nil
            else { throw NavigationError("scope change did not reach the list") }
            return (CACurrentMediaTime() - start) * 1_000
        }

        var archive: [Double] = [], group: [Double] = [], back: [Double] = [], toSession: [Double] = []
        // One untimed warm-up cycle so first-run allocation is not counted.
        _ = try await applyScope { self.model.showArchived = true }
        _ = try await applyScope { self.model.showArchived = false }
        for cycle in 0..<20 {
            archive.append(try await applyScope { self.model.showArchived = true })
            group.append(try await applyScope { self.model.showArchived = false; self.model.inGroup = true })
            back.append(try await applyScope { self.model.inGroup = false })
            let entering = targets[cycle % targets.count]
            toSession.append(try await switchTo(entering, host: host).1)
        }

        // Input during scroll: drive the transcript and type between scroll steps,
        // then require the list to reflect each keystroke.
        _ = try await switchTo(target, host: host)
        var keystrokes: [Double] = []
        var dropped = 0
        let terms = ["项", "项目", "项目 1", "项目", "项", ""]
        if let scroll = findScrollView(host) {
            let document = scroll.documentView?.bounds.height ?? 0
            let visible = scroll.contentView.bounds.height
            for index in 0..<60 where document > visible + 10 {
                let offset = (document - visible) * Double(index % 20) / 19
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                let term = terms[index % terms.count]
                let start = CACurrentMediaTime()
                model.search = term
                let token = model.scopeToken
                if await flushAndWait(host, until: { self.model.marker.listToken == token }) != nil {
                    keystrokes.append((CACurrentMediaTime() - start) * 1_000)
                } else {
                    dropped += 1
                }
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            }
        }
        model.search = ""
        _ = await flushAndWait(host, until: { true })
        guard !keystrokes.isEmpty else { throw NavigationError("no keystrokes were measured") }

        return [
            "to_archive_ms": statistics(archive), "to_task_group_ms": statistics(group),
            "back_to_workbench_ms": statistics(back), "to_conversation_ms": statistics(toSession),
            "search_during_scroll_ms": statistics(keystrokes),
            "dropped_keystrokes": dropped, "cycles": archive.count,
            "note": "scope changes are timed until the list itself re-renders; search keystrokes are issued between scroll steps, so a dropped keystroke means input did not reach the list while scrolling"
        ]
    }

    /// Alternates cache-hit switching, search keystrokes and scrolling for a fixed
    /// wall-clock duration, sampling resident memory and live view/host counts so
    /// growth is visible rather than assumed.
    func soak(seconds: Double) async throws -> [String: Any] {
        guard let host = model.host else { throw NavigationError("missing host") }
        let ids = try warmedTargets()
        var switches = 0, scrollSteps = 0, searches = 0
        var switchMs: [Double] = [], scrollMs: [Double] = []
        var samples: [[String: Double]] = []
        let idleRSS = residentBytes()
        let start = CACurrentMediaTime()
        var nextSample = start
        while CACurrentMediaTime() - start < seconds {
            for id in ids {
                switchMs.append(try await switchTo(id, host: host).1)
                switches += 1
                if let scroll = findScrollView(host) {
                    let document = scroll.documentView?.bounds.height ?? 0
                    let visible = scroll.contentView.bounds.height
                    for step in 0..<12 where document > visible + 10 {
                        let offset = (document - visible) * Double(step) / 11
                        let stepStart = CACurrentMediaTime()
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
                        scrollMs.append((CACurrentMediaTime() - stepStart) * 1_000)
                        scrollSteps += 1
                    }
                }
                if CACurrentMediaTime() >= nextSample {
                    // Keep bounded two-minute checks observable as well as overnight runs.
                    nextSample = CACurrentMediaTime() + 10
                    var sample: [String: Double] = [
                        "elapsed_s": CACurrentMediaTime() - start,
                        "resident_mb": Double(residentBytes()) / 1_048_576,
                        "views": Double(countViews(host)),
                        "switches": Double(switches), "scroll_steps": Double(scrollSteps)
                    ]
                    #if TRANSCRIPT_CHECKS
                    if let counts = ConversationTranscript.retainedHosts(in: host) {
                        sample["retained_hosts"] = Double(counts.retained)
                        sample["mounted_hosts"] = Double(counts.mounted)
                        sample["retired_hosts"] = Double(counts.retired)
                    }
                    #endif
                    samples.append(sample)
                    try writeNavigationArtifact("progress.json", ["status": "running", "samples": samples,
                        "history_turns": model.historyTurnCount, "switches": switches, "scroll_steps": scrollSteps])
                }
                if CACurrentMediaTime() - start >= seconds { break }
            }
            model.search = searches % 2 == 0 ? "项目" : ""
            searches += 1
            _ = await flushAndWait(host, until: { true })
        }
        model.search = ""
        var result: [String: Any] = [
            "duration_s": CACurrentMediaTime() - start,
            "switches": switches, "scroll_steps": scrollSteps, "search_keystrokes": searches,
            "switch_ms": statistics(switchMs), "scroll_step_ms": statistics(scrollMs),
            "idle_resident_mb": Double(idleRSS) / 1_048_576,
            "final_resident_mb": Double(residentBytes()) / 1_048_576,
            "samples": samples,
            "note": "unattended soak on the isolated fixture; no remote agent, no production app state"
        ]
        #if TRANSCRIPT_CHECKS
        try await Task.sleep(for: .milliseconds(500))
        result["retired_hosts_after_settle"] = ConversationTranscript.retainedHosts(in: host)?.retired
        result["settled_resident_mb"] = residentMB()
        #endif
        return result
    }

    /// Compares an idle window with a sustained-streaming window on the same view,
    /// so CPU is attributable to streaming rather than to the fixture's own driver.
    func resourceComparison(seconds: Double) async throws -> [String: Any] {
        guard let host = model.host else { throw NavigationError("missing host") }
        let target = model.scope.sessions[0].id
        try model.warm([target])
        _ = try await switchTo(target, host: host)
        // Let the first layout settle so it belongs to neither window.
        try? await Task.sleep(for: .seconds(3))

        let idleBefore = processTime(), idleRSS = residentMB()
        let idleStart = CACurrentMediaTime()
        while CACurrentMediaTime() - idleStart < seconds { try? await Task.sleep(for: .milliseconds(100)) }
        let idleSeconds = CACurrentMediaTime() - idleStart
        let idleCPU = processTime() - idleBefore
        let idleAfterRSS = residentMB()

        var conversation = try model.streamingBase()
        let events = model.streamEvents
        var applied = 0
        let streamBefore = processTime(), streamRSS = residentMB()
        let streamStart = CACurrentMediaTime()
        while CACurrentMediaTime() - streamStart < seconds {
            for data in events {
                let event = try KimiWire.decoder().decode(KimiEvent.self, from: data)
                _ = conversation.apply(event)
                model.conversation = conversation
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
                applied += 1
                if CACurrentMediaTime() - streamStart >= seconds { break }
            }
            conversation = try model.streamingBase()
        }
        let streamSeconds = CACurrentMediaTime() - streamStart
        let streamCPU = processTime() - streamBefore
        let streamAfterRSS = residentMB()
        try model.select(target)
        _ = await flushAndWait(host, until: { true })

        return [
            "idle": ["seconds": idleSeconds, "cpu_seconds": idleCPU,
                     "cpu_percent_of_one_core": idleCPU / idleSeconds * 100,
                     "resident_mb_start": idleRSS, "resident_mb_end": idleAfterRSS],
            "streaming": ["seconds": streamSeconds, "cpu_seconds": streamCPU,
                          "cpu_percent_of_one_core": streamCPU / streamSeconds * 100,
                          "resident_mb_start": streamRSS, "resident_mb_end": streamAfterRSS,
                          "events_applied": applied, "events_per_second": Double(applied) / streamSeconds],
            "note": "idle keeps the same laid-out transcript on screen with no input; streaming applies real JSON events through the production transcript and forces layout/display each event. CPU is process user+system time from getrusage, including the fixture's own driver loop, so it is an upper bound rather than the app's steady-state cost."
        ]
    }

    private func processTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
             + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
    private func residentMB() -> Double { Double(residentBytes()) / 1_048_576 }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    private func countViews(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + countViews($1) }
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        // The sidebar's own scroll view comes first in the hierarchy; take the widest.
        var found: [NSScrollView] = []
        var stack = [view]
        while let next = stack.popLast() {
            if let scroll = next as? NSScrollView { found.append(scroll) }
            stack.append(contentsOf: next.subviews)
        }
        return found.max { $0.bounds.width < $1.bounds.width }
    }
}

struct NavigationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct NavigationHost: NSViewRepresentable {
    let model: NavigationModel
    func makeNSView(context: Context) -> NSHostingView<NavigationRoot> {
        let host = NSHostingView(rootView: NavigationRoot(model: model))
        model.host = host
        return host
    }
    func updateNSView(_ view: NSHostingView<NavigationRoot>, context: Context) {}
}

@main
struct NavigationPreviewApp: App {
    @NSApplicationDelegateAdaptor(NavigationDelegate.self) private var delegate
    @StateObject private var model = NavigationModel()
    @State private var status = "点击响应与滚动长帧验收 fixture"
    var body: some Scene {
        WindowGroup("导航与滚动验收") {
            if ProcessInfo.processInfo.environment["NAVIGATION_JOINT"] == "1" {
                JointInteractionPreview()
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(status).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                NavigationHost(model: model).frame(width: 1180, height: 600)
            }.padding(16).frame(minWidth: 1212, minHeight: 700)
                .task { await run() }
            }
        }.defaultSize(width: 1240, height: 800)
    }
    private func run() async {
        guard let mode = ProcessInfo.processInfo.environment["NAVIGATION_AUTORUN"] else { return }
        while model.host?.window?.isVisible != true { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(3))
        let runner = NavigationRunner(model: model)
        do {
            var report: [String: Any] = [
                "mode": mode, "sessions": model.all.count,
                // Without this a report cannot be told apart from one taken on a
                // different history, and two runs share the same filename shape.
                "history_turns": model.historyTurnCount,
                "history_source": model.historySource,
                "recreates_timeline": ProcessInfo.processInfo.environment["NAVIGATION_RECREATE"] == "1",
                "commit": Bundle.main.object(forInfoDictionaryKey: "PerchSourceCommit") as? String ?? "unknown",
                "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            if let buildURL = Bundle.main.url(forResource: "build", withExtension: "json") {
                report["build"] = try JSONSerialization.jsonObject(with: Data(contentsOf: buildURL))
            }
            try writeNavigationArtifact("started.json", report.merging(["status": "running"]) { _, b in b })
            if mode == "reading" { report.merge(try await runner.readingCoverage()) { a, _ in a } }
            else if mode == "search" { report.merge(try await runner.readingInteractions(searchOnly: true)) { a, _ in a } }
            else if mode == "interactions" { report.merge(try await runner.readingInteractions()) { a, _ in a } }
            else if mode == "anchor" { report.merge(try await runner.prependAnchor()) { a, _ in a } }
            else if mode == "scroll" { report.merge(try await runner.scrollFrames()) { a, _ in a } }
            else if mode == "soak" {
                let seconds = Double(ProcessInfo.processInfo.environment["NAVIGATION_SOAK_SECONDS"] ?? "1260") ?? 1_260
                report.merge(try await runner.soak(seconds: seconds)) { a, _ in a }
            }
            else if mode == "roundtrip" { report.merge(try await runner.roundTrips()) { a, _ in a } }
            else if mode == "resource" {
                let seconds = Double(ProcessInfo.processInfo.environment["NAVIGATION_WINDOW_SECONDS"] ?? "120") ?? 120
                report.merge(try await runner.resourceComparison(seconds: seconds)) { a, _ in a }
            }
            else { report.merge(try await runner.clickLatency()) { a, _ in a } }
            report["status"] = "passed"
            let file = "\(mode)-\(model.all.count)-\(Int(Date().timeIntervalSince1970)).json"
            try writeNavigationArtifact(file, report)
            try writeNavigationArtifact("result.json", report)
            status = "完成：\(file)"
        } catch {
            status = "失败：\(error.localizedDescription)"
            try? writeNavigationArtifact("result.json", ["status": "failed", "mode": mode,
                "error": error.localizedDescription, "history_turns": model.historyTurnCount])
            FileHandle.standardError.write(Data((status + "\n").utf8))
            if ProcessInfo.processInfo.environment["NAVIGATION_AUTOQUIT"] != nil { exit(1) }
            return
        }
        FileHandle.standardError.write(Data((status + "\n").utf8))
        if ProcessInfo.processInfo.environment["NAVIGATION_AUTOQUIT"] != nil { NSApp.terminate(nil) }
    }
}

final class NavigationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
