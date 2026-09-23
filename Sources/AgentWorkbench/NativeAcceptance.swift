#if PERCH_ACCEPTANCE
import AppKit
import SwiftUI
import WorkbenchCore
import os

/// Compiled only into the isolated acceptance app. Production uses WorkbenchApp.
@MainActor final class NativeAcceptanceProbe: ObservableObject {
    static let shared = NativeAcceptanceProbe()
    @Published var query: String?
    var renderedQuery: String?
    var selection: String?
    let signposter = OSSignposter(subsystem: "dev.perch.nativeacceptance", category: .pointsOfInterest)
}

struct NativeDirectoryProbe: NSViewRepresentable {
    let query: String
    let selection: String?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        NativeAcceptanceProbe.shared.renderedQuery = query
        NativeAcceptanceProbe.shared.selection = selection
    }
}

@MainActor private final class NativeAcceptanceFixture {
    static let host = SSHHost(id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
                              name: "离线验收", destination: "")
    let sessions: [WorkspaceSession]
    private var snapshots: [String: Data]
    private var streamingSnapshot: [String: Any]?
    private(set) var requests: [String] = []
    init() throws {
        sessions = (0..<500).map { index in
            WorkspaceSession(reference: SessionReference(hostID: Self.host.id, terminalID: "session-\(index)", kind: .omp),
                             title: String(format: "验收会话 %04d · 中文 English", index),
                             directory: "/fixture/project-\(index % 20)", hostName: "离线验收", detail: "OMP · 就绪",
                             online: index % 17 != 16, section: .other, canMarkReviewed: false,
                             archived: index % 19 == 18, updatedAt: Double(500 - index))
        }
        // Only eight fixed local responses are resident, matching the tested
        // working set. No hundreds-of-conversations preload or remote fallback.
        var values: [String: Data] = [:]
        for session in sessions.prefix(8) {
            let id = session.reference.terminalID
            var messages: [[String: Any]] = []
            for turn in 1...200 {
                messages.append(["id": "\(id)-u-\(turn)", "role": "user", "created_at": "\(turn)-a",
                                 "content": [["type": "text", "text": "第 \(turn) 轮：检查原生阅读与切换。"]]])
                let text = """
                ## 第 \(turn) 轮结果

                中文与 English 混排，**完整正文**、`identifier` 和文件路径 `Sources/Example.swift:12`。

                \(String(repeating: "持续阅读应保持位置，后台更新不打断输入。Native interaction remains responsive.\n\n", count: 3))
                | 项目 | 状态 |
                | --- | --- |
                | 消息覆盖 | \(turn)/200 |

                ```swift
                let turn = \(turn)
                let result = await render(turn)
                ```
                """
                messages.append(["id": "\(id)-a-\(turn)", "role": "assistant", "created_at": "\(turn)-b",
                                 "content": [["type": "text", "text": text]]])
            }
            values[id] = try JSONSerialization.data(withJSONObject: [
                "id": id, "provider": "omp", "title": session.title, "cwd": session.directory,
                "busy": false, "revision": 1, "completed": 0, "model": "fixture-model",
                "messages": messages, "interactions": [], "commands": []
            ], options: [.sortedKeys])
        }
        snapshots = values
    }
    func advanceStream(_ step: Int) throws {
        if streamingSnapshot == nil {
            streamingSnapshot = try JSONSerialization.jsonObject(with: snapshots["session-0"]!) as? [String: Any]
        }
        var value = streamingSnapshot!
        var messages = value["messages"] as! [[String: Any]]
        // Bound the synthetic tail so long-run growth reflects the UI, not a
        // deliberately ever-growing response. Keep IDs and full history intact.
        messages[messages.count - 1]["content"] = [["type": "text", "text":
            "第 200 轮结果\n\n流式更新 \(step) · 中文 English\n\n" + String(repeating: "新增内容 ", count: 1 + step % 40)]]
        value["messages"] = messages
        value["busy"] = true
        value["revision"] = step + 2
        streamingSnapshot = value
        snapshots["session-0"] = try JSONSerialization.data(withJSONObject: value)
    }
    func request(_ path: String, body: JSONValue?) throws -> Data {
        requests.append(path)
        guard body == nil else { throw WorkbenchError("隔离验收不执行写请求：\(path)") }
        if path == "/models" { return Data(#"{"models":[]}"#.utf8) }
        let id = path.split(separator: "?")[0].replacingOccurrences(of: "/sessions/", with: "")
        guard path.hasPrefix("/sessions/"), let data = snapshots[id] else {
            throw WorkbenchError("隔离验收仅预置会话 0000–0007：\(path)")
        }
        return data
    }
}

@main struct NativeAcceptanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: WorkbenchModel
    private let fixture: NativeAcceptanceFixture
    init() {
        precondition(Bundle.main.bundleIdentifier == "dev.perch.nativeacceptance")
        precondition(!ActivitySummarySettings.shared.configuration.enabled, "Acceptance summaries must stay off")
        let fixture = try! NativeAcceptanceFixture()
        self.fixture = fixture
        let connection = NativeAgentConnection(host: NativeAcceptanceFixture.host) { path, body in
            try fixture.request(path, body: body)
        }
        _model = StateObject(wrappedValue: WorkbenchModel(acceptanceHost: NativeAcceptanceFixture.host,
                                                         sessions: fixture.sessions, native: connection))
    }
    var body: some Scene {
        WindowGroup("Perch · 隔离性能验收") {
            WorkbenchView(model: model).preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .frame(width: 1280, height: 820)
                .task {
                    model.open(fixture.sessions[0])
                    guard let mode = ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_MODE"] else { return }
                    await NativeAcceptanceRunner(model: model, fixture: fixture).run(mode)
                }
        }.defaultSize(width: 1280, height: 820).windowStyle(.hiddenTitleBar)
    }
}

@MainActor private final class NativeAcceptanceRunner {
    let model: WorkbenchModel
    let fixture: NativeAcceptanceFixture
    let probe = NativeAcceptanceProbe.shared
    init(model: WorkbenchModel, fixture: NativeAcceptanceFixture) { self.model = model; self.fixture = fixture }
    func run(_ mode: String) async {
        var report: [String: Any] = ["mode": mode, "history_turns": 200, "catalog_sessions": 500,
                                   "window_points": [1280, 820], "native_transport": "fixed in-memory JSON; real decode/select",
                                   "timing_boundary": "local state change through layout/display/CA flush, not event-to-photon or FPS"]
        do {
            try await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("隔离性能") }) else {
                throw WorkbenchError("Missing acceptance window")
            }
            try await settle(window) { self.hasMountedMessage(window, session: "session-0") }
            report["rss_before_mb"] = residentMB()
            if mode == "joint" {
                report.merge(try await joint(window)) { _, new in new }
            }
            if mode == "all" {
                var switches: [Double] = []
                for index in 1...16 {
                    let item = fixture.sessions[index % 8]
                    let span = probe.signposter.beginInterval("SessionSwitch")
                    let start = CACurrentMediaTime()
                    model.open(item)
                    try await settle(window) { self.hasMountedMessage(window, session: item.reference.terminalID) }
                    switches.append((CACurrentMediaTime() - start) * 1000)
                    probe.signposter.endInterval("SessionSwitch", span)
                    guard transcript(in: window) != nil else { throw WorkbenchError("Selected content has no mounted transcript") }
                }
                report["session_switch_ms"] = stats(switches)
                report["search_sheet"] = try await search(window, sheet: true)
                report["session_directory"] = try await search(window, sheet: false)
                model.open(fixture.sessions[0])
                try await settle(window) { !self.model.showDashboard && self.hasMountedMessage(window, session: "session-0") }
            } else if mode != "frames" && mode != "joint" { throw WorkbenchError("Unknown acceptance mode: \(mode)") }
            guard let scroll = transcript(in: window) else { throw WorkbenchError("No transcript scroll view") }
            var steps: [Double] = [], hosts: [[String: Int]] = []
            let positiveControl = ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_STALL"] == "1"
            report["intentional_stall_ms"] = positiveControl ? 120 : 0
            let span = probe.signposter.beginInterval("HistoryScroll")
            for step in 0..<120 {
                let extent = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                let y = max(0, extent - Double(step < 60 ? step : 119 - step) * 80)
                let start = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                if positiveControl && step == 40 {
                    let stall = probe.signposter.beginInterval("IntentionalStall")
                    usleep(120_000) // Isolated positive control, deliberately blocks the main thread.
                    probe.signposter.endInterval("IntentionalStall", stall)
                }
                await Task.yield()
                flush(window)
                steps.append((CACurrentMediaTime() - start) * 1000)
                if let counts = ConversationTranscript.retainedHosts(in: scroll) {
                    hosts.append(["mounted": counts.mounted, "retained": counts.retained, "retired": counts.retired])
                    guard counts.retained <= counts.mounted + 24 else { throw WorkbenchError("History hosts accumulated") }
                }
                try await Task.sleep(for: .milliseconds(16))
            }
            probe.signposter.endInterval("HistoryScroll", span)
            guard !hosts.isEmpty else { throw WorkbenchError("Missing host retention observations") }
            report["scroll_step_ms"] = stats(steps); report["host_counts"] = hosts
            report["rss_after_mb"] = residentMB(); report["requests"] = fixture.requests
            try await Task.sleep(for: .seconds(2))
            report["rss_settled_mb"] = residentMB(); report["status"] = "passed"
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription }
        do {
            let path = ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_RESULTS"]!
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: output.appendingPathComponent("result.json"), options: .atomic)
        } catch { fputs("Acceptance result write failed: \(error)\n", stderr); exit(1) }
        if ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_KEEP_OPEN"] != "1" {
            if report["status"] as? String != "passed" { exit(1) }
            NSApp.terminate(nil)
        }
    }
    private func search(_ window: NSWindow, sheet: Bool) async throws -> [String: Any] {
        probe.query = nil; probe.renderedQuery = nil
        if sheet { model.showSessionSearch = true } else { model.showAllSessions() }
        try await settle(window) { self.probe.renderedQuery != nil }
        var samples: [Double] = []
        var states: [[String: String]] = []
        for term in ["验收", "0002", "不存在的验收会话", "English", "project-3", ""] {
            let span = probe.signposter.beginInterval("DirectoryQuery")
            let start = CACurrentMediaTime()
            probe.query = term
            try await settle(window) { self.probe.renderedQuery == term }
            samples.append((CACurrentMediaTime() - start) * 1000)
            probe.signposter.endInterval("DirectoryQuery", span)
            // Correctness checks happen after timing, never by re-running the
            // search inside a readiness token on every rendering pass.
            let expected = fixture.sessions.first { !$0.archived && $0.online && $0.matchesSearch(term) }?.id
            guard probe.selection == expected else { throw WorkbenchError("Directory selection mismatch for \(term)") }
            states.append(["query": term, "selection": probe.selection ?? "none"])
        }
        if sheet {
            model.showSessionSearch = false
            try await settle(window) { window.sheets.isEmpty }
        }
        return ["query_to_layout_ms": stats(samples), "states": states,
                "input": "fixture publisher into production local @State; excludes keyboard/IME event delivery"]
    }
    private func joint(_ window: NSWindow) async throws -> [String: Any] {
        guard let scroll = transcript(in: window), let navigator = ConversationTranscript.navigator(in: scroll) else {
            throw WorkbenchError("Missing joint transcript")
        }
        navigator.select(80)
        try await settle(window) { navigator.current == 80 }
        let seconds = Double(ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_JOINT_SECONDS"] ?? "24") ?? 24
        let start = CACurrentMediaTime()
        var step = 0, switches = 0
        var input: [Double] = [], update: [Double] = [], samples: [[String: Double]] = []
        var nextSample = start
        let initialCPU = processCPU()
        while CACurrentMediaTime() - start < seconds {
            let tick = CACurrentMediaTime()
            if step % 5 == 0, let currentScroll = transcript(in: window) {
                let delta = step % 40 < 20 ? 120.0 : -120.0
                let extent = max(0, (currentScroll.documentView?.bounds.height ?? 0) - currentScroll.contentView.bounds.height)
                let y = min(extent, max(0, currentScroll.contentView.bounds.minY + delta))
                currentScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                currentScroll.reflectScrolledClipView(currentScroll.contentView)
                await Task.yield(); flush(window)
            }
            guard let activeScroll = transcript(in: window), let before = ConversationTranscript.readingAnchor(in: activeScroll) else {
                throw WorkbenchError("Missing reading anchor during streaming")
            }
            try fixture.advanceStream(step)
            let refreshStart = CACurrentMediaTime()
            let refresh = Task { try await model.native.acceptanceRefreshSelected() }
            let draft = "联合输入 \(step) · 中文 English"
            let inputStart = CACurrentMediaTime()
            model.native.drafts["session-0"] = draft
            try await settle(window, "draft step \(step)") { self.containsText(draft, in: window.contentView) }
            input.append((CACurrentMediaTime() - inputStart) * 1000)
            try checkTextContrast(in: window.contentView)
            try await refresh.value
            try await settle(window, "snapshot step \(step)") { self.model.native.snapshot?.revision == step + 2 }
            update.append((CACurrentMediaTime() - refreshStart) * 1000)
            guard model.native.drafts["session-0"] == draft,
                  let after = ConversationTranscript.readingAnchor(in: activeScroll),
                  after.entry == before.entry, abs(after.offset - before.offset) <= 1 else {
                throw WorkbenchError("Streaming lost draft or moved reading anchor")
            }
            if step % 30 == 29 {
                model.open(fixture.sessions[1])
                try await settle(window) { self.hasMountedMessage(window, session: "session-1") }
                model.open(fixture.sessions[0])
                try await settle(window, "return step \(step), expected \(before)") {
                    guard self.hasMountedMessage(window, session: "session-0"), self.containsText(draft, in: window.contentView),
                          let returned = self.transcript(in: window), let anchor = ConversationTranscript.readingAnchor(in: returned) else { return false }
                    return anchor.entry == before.entry && abs(anchor.offset - before.offset) <= 1
                }
                switches += 2
            }
            if let currentScroll = transcript(in: window), let counts = ConversationTranscript.retainedHosts(in: currentScroll) {
                guard counts.retained <= counts.mounted + 24, SelectableReplyText.recycledCount <= 64 else {
                    throw WorkbenchError("Joint fixture accumulated retained views")
                }
                if CACurrentMediaTime() >= nextSample {
                    samples.append(["elapsed_s": CACurrentMediaTime() - start, "rss_mb": residentMB(),
                        "cpu_seconds": processCPU() - initialCPU, "retained": Double(counts.retained),
                        "mounted": Double(counts.mounted), "retired": Double(counts.retired),
                        "recycled_text_views": Double(SelectableReplyText.recycledCount), "updates": Double(step + 1)])
                    nextSample = CACurrentMediaTime() + 30
                    try writeReport(["status": "running", "joint_samples": samples], name: "joint-progress.json")
                }
            }
            step += 1
            // Match the native provider's 400ms polling cadence, allowing idle
            // time rather than spinning at maximum fixture throughput.
            let delay = 0.4 - (CACurrentMediaTime() - tick)
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        return ["joint_duration_s": CACurrentMediaTime() - start, "joint_updates": step,
                "joint_switches": switches, "joint_input_to_layout_ms": stats(input),
                "joint_update_to_layout_ms": stats(update), "joint_samples": samples,
                "joint_cpu_seconds": processCPU() - initialCPU,
                "joint_note": "Real workbench; fixed full-history JSON updates, local draft binding, anchor and return checks at 2.5Hz. Excludes hardware keyboard/IME and network; CPU includes fixture serialization."]
    }
    private func checkTextContrast(in root: NSView?) throws {
        guard let root else { return }
        if let view = root as? ReplyTextView, view.isConversationBodyText, !view.string.isEmpty {
            var colors: [Double] = []
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: view.string.utf16.count)) { value, _, _ in
                    if let color = (value as? NSColor)?.usingColorSpace(.deviceRGB) {
                        colors.append(Double(max(color.redComponent, color.greenComponent, color.blueComponent)))
                    }
                }
            }
            guard colors.allSatisfy({ $0 < 0.8 }) else {
                throw WorkbenchError("Light fixture contains unreadable body text: \(view.effectiveAppearance.name.rawValue) \(colors)")
            }
        }
        for child in root.subviews { try checkTextContrast(in: child) }
    }
    private func containsText(_ text: String, in root: NSView?) -> Bool {
        guard let root else { return false }
        if let view = root as? NSTextView, view.string == text { return true }
        return root.subviews.contains { containsText(text, in: $0) }
    }
    private func processCPU() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    private func writeReport(_ report: [String: Any], name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_RESULTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private func settle(_ window: NSWindow, _ context: String = "UI", until ready: () -> Bool) async throws {
        let start = CACurrentMediaTime()
        repeat {
            try await Task.sleep(for: .milliseconds(1))
            flush(window)
            if ready() { return }
        } while CACurrentMediaTime() - start < 5
        throw WorkbenchError("UI readiness timeout: \(context), anchor=\(String(describing: transcript(in: window).flatMap { ConversationTranscript.readingAnchor(in: $0) }))")
    }
    private func flush(_ window: NSWindow) {
        for target in [window] + window.sheets {
            target.contentView?.layoutSubtreeIfNeeded(); target.contentView?.displayIfNeeded()
        }
        CATransaction.flush()
    }
    private func transcript(in window: NSWindow) -> NSScrollView? {
        var queue = window.contentView.map { [$0] } ?? []
        while let view = queue.popLast() {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               ConversationTranscript.retainedHosts(in: document) != nil { return scroll }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
    private func hasMountedMessage(_ window: NSWindow, session: String) -> Bool {
        guard model.native.snapshot?.id == session else { return false }
        var queue = window.contentView.map { [$0] } ?? []
        while let view = queue.popLast() {
            if view.identifier?.rawValue.contains(":" + session + "-") == true && !view.subviews.isEmpty { return true }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }
    private func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        return ["count": Double(sorted.count), "median": sorted[sorted.count / 2],
                "p95": sorted[Int(Double(sorted.count - 1) * 0.95)], "max": sorted.last!]
    }
    private func residentMB() -> Double {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return Double(info.resident_size) / 1_048_576
    }
}
#endif
