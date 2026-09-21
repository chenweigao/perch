import AppKit
import SwiftUI
import WorkbenchCore

@main struct WorkflowPreviewApp: App {
    @NSApplicationDelegateAdaptor(WorkflowDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Workflow preview") { WorkflowPreview().preferredColorScheme(.light)
            .environment(\.conversationReduceMotion, ProcessInfo.processInfo.environment["WORKFLOW_REDUCE_MOTION"] == "1") }
            .defaultSize(width: 950, height: 760)
    }
}
private struct WorkflowPreview: View {
    @State private var session = "A"
    @State private var disclosureSample = false
    @State private var showSource = false
    @State private var sourceLine = 42
    @State private var follow = true
    @State private var additions = 0
    @State private var query = "needle"
    @State private var search = ConversationSearch()
    @State private var match = 0
    @State private var openedFile = "No file opened"
    private var key: String { "fixture:" + (disclosureSample ? "disclosure" : session) }
    private var messages: [KimiMessage] {
        if disclosureSample {
            return try! KimiWire.decoder().decode([KimiMessage].self, from: Data(#"[{"id":"question","role":"user","created_at":"","content":[{"type":"text","text":"Check this fixture."}]},{"id":"tool","role":"assistant","created_at":"","content":[{"type":"tool_use","tool_call_id":"read","tool_name":"Read","input":{"path":"src/fixture.swift"}}]},{"id":"result","role":"tool","created_at":"","content":[{"type":"tool_result","tool_call_id":"read","is_error":false,"output":"Fixture output. No remote files were read."}]},{"id":"answer","role":"assistant","created_at":"","content":[{"type":"thinking","thinking":"First line of fixture reasoning.\nSecond line remains attached during layout.\nThird line retains the same light italic styling.\nFourth line completes this disclosure."},{"type":"text","text":"This reply below the disclosures should move smoothly and stay visible."}]}]"#.utf8))
        }
        let rows: [[String: Any]] = (0..<(40 + additions)).map { index in
            ["id": "\(session)-\(index)", "role": index == 0 ? "user" : "assistant", "created_at": "", "content": [
                ["type": "text", "text": "\(session) · Paragraph \(index). " + String(repeating: "This is a stable reading fixture. ", count: 4) + "needle \(index). Open `src/foo.swift:42`."],
                ["type": "thinking", "thinking": "Thought \(index) keeps its expansion when switching sessions."]]]
        }
        return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    private var hits: [ConversationSearchHit] { search.hits(in: messages, query: query, running: false) }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Session A") { select("A") }; Button("Session B") { select("B") }
                Button("Disclosures") { disclosureSample.toggle() }
                Button("Source line 42") { sourceLine = 42; showSource.toggle() }
                if showSource { Button("Line 80") { sourceLine = 80 } }
                Button("Append reply") { additions += 1 }
                TextField("Find", text: $query).frame(width: 140)
                Button("Next match") {
                    guard !hits.isEmpty else { return }
                    match = (match + 1) % hits.count; follow = false
                    ConversationReadingMemory.shared.following[key] = false
                    NotificationCenter.default.post(name: .init("PerchRevealConversationHit"), object: ConversationFindTarget(session: key, hit: hits[match], query: query))
                }
                Text("\(match + 1)/\(hits.count)")
            }.padding(.horizontal, 16)
            Text(openedFile).font(.caption)
            if showSource {
                RemoteSourceText(text: (1...100).map { "Line \($0): source fixture" }.joined(separator: "\n"), line: sourceLine)
            } else {
            ScrollViewReader { proxy in
                ConversationScrollView(showsScrollIndicator: true, onScroll: {
                    follow = $0; ConversationReadingMemory.shared.following[key] = $0
                }, onContentSizeChange: {
                    if ConversationReadingMemory.shared.following[key] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
                }) {
                    ConversationTranscript(messages: messages, sessionId: session, memoryKey: key)
                    Color.clear.frame(height: 1).id("bottom")
                }.overlay(alignment: .bottom) {
                    ReturnToLatestButton(isVisible: !follow, hasNewReply: additions > 0) { follow = true; ConversationReadingMemory.shared.following[key] = true; proxy.scrollTo("bottom", anchor: .bottom) }
                }.task(id: session) {
                    follow = ConversationReadingMemory.shared.following[key] ?? true
                    await Task.yield()
                    if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            }
        }.padding(.top, 20)
            .onReceive(NotificationCenter.default.publisher(for: .init("PerchOpenConversationFile"))) { value in
                if let url = value.object as? URL, let ref = ConversationFileReference(url: url) { openedFile = "Opened \(ref.path) at line \(ref.line ?? 1) in session \(session)" }
            }
    }
    private func select(_ value: String) { session = value; match = 0; follow = ConversationReadingMemory.shared.following[key] ?? true }
}
private final class WorkflowDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var frames: [[String: Any]] = []
    private var previous = ""
    private func sample() {
        var rows: [[String: Any]] = []
        func visit(_ view: NSView) {
            if let id = view.identifier?.rawValue, id.hasPrefix("thinking:") || id.hasPrefix("activity:") || id.hasPrefix("text:") {
                rows.append(["id": id, "y": view.frame.minY, "height": view.frame.height, "children": view.subviews.count])
            }
            view.subviews.forEach(visit)
        }
        NSApp.windows.first?.contentView.map(visit)
        let signature = rows.map { "\($0["id"]!) \($0["y"]!) \($0["height"]!) \($0["children"]!)" }.joined()
        if signature != previous { frames.append(["time": ProcessInfo.processInfo.systemUptime, "rows": rows]); previous = signature }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let path = ProcessInfo.processInfo.environment["WORKFLOW_LAYOUT_LOG"] {
            try? JSONSerialization.data(withJSONObject: frames).write(to: URL(fileURLWithPath: path))
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["WORKFLOW_LAYOUT_LOG"] != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sample() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum WorkbenchChrome { static let headerHeight: CGFloat = 48 }
