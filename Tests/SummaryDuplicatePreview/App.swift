import AppKit
import SwiftUI
import WorkbenchCore

@main struct SummaryDuplicatePreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("摘要重复复现") { SummaryPreview().preferredColorScheme(.light) }
            .defaultSize(width: 1000, height: 640)
    }
}

private struct SummaryPreview: View {
    @State private var phase = 1
    @StateObject private var store = ActivityNarrativeStore(minimumInterval: 0) { _, batch, _ in
        // Reproduce the actual service response that leaves the previous summary
        // unchanged. No network, credentials, or actual Agent session is involved.
        ActivitySummaryResult(subject: "", phase: batch.phase, summary: "无需更新", shouldUpdate: false)
    }
    private let progress = "已同步到最新 `main`，没有冲突；PR 只包含侧边栏折叠和对应验收代码，正在复跑检查。"
    private var running: Bool { phase != 2 }
    private var messages: [KimiMessage] {
        var rows: [[String: Any]] = []
        func message(_ id: String, _ role: String, _ part: [String: Any]) {
            rows.append(["id": id, "role": role, "created_at": "", "content": [part]])
        }
        func tool(_ id: String, _ name: String, _ input: [String: String], completed: Bool) {
            message(id, "assistant", ["type": "tool_use", "tool_call_id": id, "tool_name": name, "input": input])
            if completed {
                message(id + "-result", "tool", ["type": "tool_result", "tool_call_id": id,
                    "is_error": false, "output": "Synthetic fixture result"])
            }
        }
        message("user", "user", ["type": "text", "text": "核对改动并提交 PR"])
        message("intro", "assistant", ["type": "text", "text": "我先核对工作树和最新 main，然后提交改动并创建 PR。"])
        tool("git-status", "Bash", ["command": "git status --short"], completed: true)
        message("progress", "assistant", ["type": "text", "text": progress])
        tool("read", "Read", ["path": "/fixture/Sidebar.swift"], completed: true)
        if phase > 0 { tool("edit", "Edit", ["path": "/fixture/Sidebar.swift"], completed: phase == 2) }
        return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("摘要重复复现 · 生产组件 / 隔离数据").font(.headline)
            Picker("场景", selection: $phase) {
                Text("当前进展").tag(0)
                Text("新阶段 · 模型无需更新").tag(1)
                Text("本轮结束").tag(2)
            }.pickerStyle(.segmented)
            ConversationScrollView(showsScrollIndicator: true, onScroll: { _ in }, onContentSizeChange: {}) {
                ConversationTranscript(messages: messages, sessionId: "duplicate-fixture",
                    running: phase == 1 ? ["edit"] : [], isRunning: running,
                    allowsActivitySummaries: true, narrativeStore: store)
            }
            ConversationActivityBar(activity: ConversationActivity(messages: messages, isRunning: running,
                    running: phase == 1 ? ["edit"] : []), isRunning: running,
                narrativeSession: "duplicate-fixture", onReview: {}, narrativeStore: store)
            Text("继续此任务…").font(.title3).foregroundStyle(.secondary)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
            Text("模型响应固定为 should_update=false；不连接 SSH、Herdr 或摘要服务。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
            .task {
                var config = ActivitySummaryConfiguration()
                config.enabled = true; config.baseURL = "http://fixture.invalid/v1"; config.model = "fixture"
                try! ActivitySummarySettings.shared.updateConfiguration(config)
            }
    }
}

private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        precondition(Bundle.main.bundleIdentifier == "dev.agentworkbench.summaryduplicatepreview")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
