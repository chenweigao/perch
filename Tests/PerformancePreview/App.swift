import AppKit
import QuartzCore
import SwiftUI
import WorkbenchCore

@main
struct PerformancePreviewApp: App {
    @NSApplicationDelegateAdaptor(PerformanceDelegate.self) private var delegate
    @StateObject private var benchmark = TranscriptBenchmark()
    var body: some Scene {
        WindowGroup("本地对话性能验收") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(benchmark.variant) · 本地渲染流水线").font(.headline)
                    Spacer()
                    Picker("场景", selection: $benchmark.scenario) {
                        ForEach(PerformanceScenario.allCases) { scenario in Text(scenario.label).tag(scenario) }
                    }.pickerStyle(.segmented).frame(width: 170).disabled(benchmark.running)
                    Button(benchmark.running ? "正在运行…" : "运行基准") { benchmark.run() }
                        .disabled(benchmark.running).accessibilityLabel("运行基准")
                }
                Text("同一 JSON → apply → SwiftUI transcript → AppKit layout/display；不含网络与模型生成。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(benchmark.status).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                BenchmarkHost(benchmark: benchmark).frame(width: 1180, height: 600)
            }.padding(16).frame(minWidth: 1212, minHeight: 700).preferredColorScheme(.light)
                .task { await benchmark.autorun() }
        }.defaultSize(width: 1240, height: 800)
    }
}

@MainActor
final class TranscriptBenchmark: ObservableObject {
    @Published var running = false
    @Published var scenario: PerformanceScenario = .assistant
    @Published var status = "24 轮历史 · 120 个事件/轮 · 3 轮测量；请保持窗口可见且尺寸不变。"
    let metadata: [String: String]
    var variant: String { metadata["variant"] ?? "unknown" }
    private let workloads = Dictionary(uniqueKeysWithValues: PerformanceScenario.allCases.map { ($0, try! PerformanceWorkload(scenario: $0)) })
    var workload: PerformanceWorkload { workloads[scenario]! }
    let marker = RenderMarkerState()
    weak var host: NSHostingView<PerformanceSurface>?
    let conversationModel = PerformanceConversationModel()
    private var onFinished: (() -> Void)?
    init() {
        let data = try! Data(contentsOf: Bundle.main.url(forResource: "build", withExtension: "json")!)
        metadata = try! JSONDecoder().decode([String: String].self, from: data)
    }
    /// Unattended run for this fixture only, so timing never competes with an
    /// accessibility-tree driver. Without the variable the button behaves as before.
    func autorun() async {
        guard let raw = ProcessInfo.processInfo.environment["PERFORMANCE_AUTORUN"],
              let requested = PerformanceScenario(rawValue: raw) else { return }
        scenario = requested
        while host?.window?.isVisible != true { try? await Task.sleep(for: .milliseconds(100)) }
        // Let the window settle and the fixed history lay out before timing.
        try? await Task.sleep(for: .seconds(3))
        await withCheckedContinuation { continuation in
            onFinished = { continuation.resume() }
            run()
        }
        onFinished = nil
        FileHandle.standardError.write(Data((status + "\n").utf8))
        if ProcessInfo.processInfo.environment["PERFORMANCE_AUTOQUIT"] != nil { NSApp.terminate(nil) }
    }
    func run() {
        guard !running, let host, host.window?.isVisible == true else { onFinished?(); return }
        let workload = self.workload
        running = true
        status = "\(workload.scenario.label)运行中；所有事件都逐个更新并校验最终文字。"
        Task { @MainActor in
            do {
                var reports: [[String: Any]] = []
                for trial in 0..<PerformanceWorkload.trials {
                    var conversation = try workload.conversation()
                    // Fully lay out the fixed history before timing streaming updates.
                    try await render(conversation, expectedUTF16: 0)
                    var frames: [Double] = []
                    let trialStart = CACurrentMediaTime()
                    for data in workload.events {
                        let start = CACurrentMediaTime()
                        let event = try KimiWire.decoder().decode(KimiEvent.self, from: data)
                        guard !conversation.apply(event) else { throw BenchmarkError("Unexpected reconciliation request") }
                        try await render(conversation, expectedUTF16: workload.output(in: conversation).utf16.count)
                        frames.append((CACurrentMediaTime() - start) * 1_000)
                    }
                    let elapsed = CACurrentMediaTime() - trialStart
                    guard workload.output(in: conversation) == workload.finalText else { throw BenchmarkError("Final text mismatch") }
                    let sorted = frames.sorted()
                    reports.append([
                        "trial": trial + 1, "events": frames.count, "wall_seconds": elapsed,
                        "events_per_second": Double(frames.count) / elapsed,
                        "median_event_ms": sorted[sorted.count / 2],
                        "p95_event_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                        "event_ms": frames, "final_utf16": marker.renderedUTF16
                    ])
                }
                let total = reports.reduce(0.0) { $0 + ($1["wall_seconds"] as! Double) }
                let rate = Double(PerformanceWorkload.trials * PerformanceWorkload.eventCount) / total
                let report: [String: Any] = [
                    "scope": "local JSON decode/apply/SwiftUI production split+transcript/AppKit layout/display; excludes remote/network and GPU presentation completion",
                    "workload_version": PerformanceWorkload.version, "workload_sha256": workload.fingerprint,
                    "scenario": workload.scenario.rawValue,
                    "history_turns": PerformanceWorkload.historyTurns, "events_per_trial": PerformanceWorkload.eventCount,
                    "metadata": metadata, "window_width": host.bounds.width, "window_height": host.bounds.height,
                    "host_width": host.bounds.width, "host_height": host.bounds.height,
                    "window_frame_width": host.window?.frame.width ?? 0, "window_frame_height": host.window?.frame.height ?? 0,
                    "content_viewport_width": marker.viewportSize.width, "content_viewport_height": marker.viewportSize.height,
                    "reading_width": marker.readingSize.width, "reading_document_height": marker.readingSize.height,
                    "display_scale": host.window?.backingScaleFactor ?? 0,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "aggregate_events_per_second": rate, "total_wall_seconds": total, "trials": reports
                ]
                let folder = URL(fileURLWithPath: metadata["results_dir"]!)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = folder.appendingPathComponent("\(variant.lowercased())-\(workload.scenario.rawValue)-\(Int(Date().timeIntervalSince1970)).json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: result, options: .atomic)
                status = workload.scenario.label + String(format: "完成 · %.2f events/s · %.2fs / %d events\n%@", rate, total, PerformanceWorkload.trials * PerformanceWorkload.eventCount, result.path)
            } catch { status = "失败：\(error.localizedDescription)" }
            running = false
            onFinished?()
        }
    }
    private func render(_ conversation: KimiConversation, expectedUTF16: Int) async throws {
        guard let host else { throw BenchmarkError("Missing hosting view") }
        #if PERFORMANCE_BASELINE
        host.rootView = PerformanceSurface(conversation: conversation, marker: marker)
        #else
        conversationModel.conversation = conversation
        #endif
        // SwiftUI reconciles content on its scheduled update. Count that latency
        // instead of assuming one run-loop turn always renders the new row.
        let deadline = CACurrentMediaTime() + 2
        repeat {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            if marker.renderedUTF16 == expectedUTF16 { return }
        } while CACurrentMediaTime() < deadline
        throw BenchmarkError("Frame marker mismatch: \(marker.renderedUTF16) != \(expectedUTF16)")
    }
}
private struct BenchmarkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BenchmarkHost: NSViewRepresentable {
    let benchmark: TranscriptBenchmark
    func makeNSView(context: Context) -> NSHostingView<PerformanceSurface> {
        #if PERFORMANCE_BASELINE
        let surface = PerformanceSurface(conversation: try! benchmark.workload.conversation(), marker: benchmark.marker)
        #else
        benchmark.conversationModel.conversation = try! benchmark.workload.conversation()
        let surface = PerformanceSurface(model: benchmark.conversationModel, marker: benchmark.marker)
        #endif
        let host = NSHostingView(rootView: surface)
        benchmark.host = host
        return host
    }
    func updateNSView(_ view: NSHostingView<PerformanceSurface>, context: Context) {}
}

/// Compile each version's actual production split/hosting implementation. The
/// fixture sidebar and controls are identical; only the supported initializer differs.
final class PerformanceConversationModel: ObservableObject {
    @Published var conversation: KimiConversation?
}

struct ObservedPerformanceTranscript: View {
    @ObservedObject var model: PerformanceConversationModel
    let marker: RenderMarkerState
    var body: some View {
        if let conversation = model.conversation {
            PerformanceTranscript(conversation: conversation, marker: marker)
        }
    }
}

struct PerformanceSurface: View {
    #if PERFORMANCE_BASELINE
    let conversation: KimiConversation
    #else
    let model: PerformanceConversationModel
    #endif
    let marker: RenderMarkerState
    var body: some View {
        #if PERFORMANCE_BASELINE
        WorkspaceSplitView(sidebar: { sidebar }) {
            PerformanceTranscript(conversation: conversation, marker: marker)
        }
        #else
        WorkspaceSplitView(newConversation: {}, sidebar: { sidebar },
                           header: { Text("本地性能验收").font(.headline) },
                           actions: { Image(systemName: "ellipsis") }) {
            ObservedPerformanceTranscript(model: model, marker: marker)
        }
        #endif
    }
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Workbench").font(.headline)
                ForEach(0..<24, id: \.self) { index in
                    Label("本地验收任务 \(index + 1)", systemImage: "bubble.left").font(.system(size: 12))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
}

final class RenderMarkerState {
    var renderedUTF16 = -1
    var viewportSize = CGSize.zero
    var readingSize = CGSize.zero
}
struct PerformanceTranscript: View {
    let conversation: KimiConversation
    let marker: RenderMarkerState
    var body: some View {
        #if PERFORMANCE_BASELINE
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { rows }
                .frame(width: ReplyStyle.readingWidth)
                .background { GeometryReader { geometry in LayoutMarker(size: geometry.size, reading: true, state: marker) } }
                .padding(24).frame(maxWidth: .infinity)
        }.defaultScrollAnchor(.bottom)
            .background { GeometryReader { geometry in LayoutMarker(size: geometry.size, reading: false, state: marker) } }
        #else
        ScrollViewReader { proxy in
            ConversationScrollView(onContentSizeChange: { proxy.scrollTo("bottom", anchor: .bottom) }) {
                ConversationTranscript(messages: conversation.displayMessages, sessionId: "performance-fixture", isRunning: true)
                RenderMarker(count: (conversation.live?.assistantText.utf16.count ?? 0) + (conversation.live?.thinkingText.utf16.count ?? 0), state: marker)
                    .frame(width: ReplyStyle.readingWidth, height: 1).id("bottom")
                    .background { GeometryReader { geometry in LayoutMarker(size: geometry.size, reading: true, state: marker) } }
            }.task {
                await Task.yield()
                if !Task.isCancelled { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }.background { GeometryReader { geometry in LayoutMarker(size: geometry.size, reading: false, state: marker) } }
        #endif
    }
    @ViewBuilder private var rows: some View {
        ConversationTranscript(messages: conversation.displayMessages, sessionId: "performance-fixture", isRunning: true)
        RenderMarker(count: (conversation.live?.assistantText.utf16.count ?? 0) + (conversation.live?.thinkingText.utf16.count ?? 0), state: marker).frame(height: 1)
    }
}

struct RenderMarker: NSViewRepresentable {
    let count: Int
    let state: RenderMarkerState
    func makeNSView(context: Context) -> NSView { state.renderedUTF16 = count; return NSView() }
    func updateNSView(_ view: NSView, context: Context) { state.renderedUTF16 = count }
}
/// Record actual measured regions without publishing state or adding another layout pass.
struct LayoutMarker: NSViewRepresentable {
    let size: CGSize
    let reading: Bool
    let state: RenderMarkerState
    private func record() {
        if reading { state.readingSize = size } else { state.viewportSize = size }
    }
    func makeNSView(context: Context) -> NSView { record(); return NSView() }
    func updateNSView(_ view: NSView, context: Context) { record() }
}
private final class PerformanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
